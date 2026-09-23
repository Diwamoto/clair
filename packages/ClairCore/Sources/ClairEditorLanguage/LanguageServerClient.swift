import ClairEditorCore
import ClairEditorView
import Foundation
import JSONRPC
import LanguageServerProtocol

/// E12: which language server a language uses. gopls is the first-class one
/// (spec §13); the rest ride the same generic path and simply stay off when
/// their executable is not installed.
public struct LanguageServerCommand: Sendable, Hashable {
  public let executable: String
  public let arguments: [String]

  public init(executable: String, arguments: [String] = []) {
    self.executable = executable
    self.arguments = arguments
  }
}

extension EditorLanguageID {
  public var languageServer: LanguageServerCommand? {
    switch self {
    case .go: LanguageServerCommand(executable: "gopls")
    case .typescript, .javascript: LanguageServerCommand(executable: "typescript-language-server", arguments: ["--stdio"])
    case .python: LanguageServerCommand(executable: "pyright-langserver", arguments: ["--stdio"])
    case .rust: LanguageServerCommand(executable: "rust-analyzer")
    case .swift: LanguageServerCommand(executable: "sourcekit-lsp")
    case .json, .markdown, .shell, .ruby, .java, .php, .terraform: nil
    }
  }

  /// The LSP `languageId` for `didOpen`.
  public var lspLanguageID: String {
    switch self {
    case .typescript: "typescript"
    case .javascript: "javascript"
    default: rawValue
    }
  }
}

extension LanguageServerCommand {
  /// The user's login-shell `PATH`, plus `~/go/bin` (where `go install`
  /// puts gopls, often not on `PATH`). A Finder-launched app only has
  /// launchd's minimal `PATH`, so this is what the server is spawned with.
  public static let loginPath: String = {
    let p = Process()
    let out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "printf %s \"$PATH\""]
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    if (try? p.run()) != nil {
      let data = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      if p.terminationStatus == 0, let s = String(data: data, encoding: .utf8), !s.isEmpty { path = s }
    }
    return path + ":" + NSHomeDirectory() + "/go/bin"
  }()

  /// The executable on `path`, or nil when it is not installed.
  public func resolve(path: String = LanguageServerCommand.loginPath) -> URL? {
    path.split(separator: ":").lazy.map { URL(fileURLWithPath: String($0)).appending(path: executable) }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }
}

/// A jump target (definition, reference, symbol). 0-based line, UTF-16 column (LSP's own units).
public struct LanguageServerLocation: Sendable, Hashable {
  public let path: String
  public let line: Int
  public let character: Int
  public let title: String

  public init(path: String, line: Int, character: Int, title: String) {
    self.path = path
    self.line = line
    self.character = character
    self.title = title
  }
}

/// One completion candidate, already converted to document coordinates so
/// the host never touches LSP wire types.
public struct LanguageServerCompletionItem: Sendable, Hashable {
  public let label: String
  public let detail: String?
  /// What the list filters on (`filterText`, else `label`).
  public let filterText: String
  /// What accepting inserts.
  public let text: String
  /// The range the server wants replaced, in `LanguageServerCompletion.snapshot`.
  public let range: TextUTF8Range?
}

public struct LanguageServerCompletion: Sendable {
  public let items: [LanguageServerCompletionItem]
  /// The snapshot the request positions were computed on; item ranges are in it.
  public let snapshot: TextSnapshot
}

/// One running language server for one Project root: spawns it, runs the
/// LSP lifecycle, keeps every open document in sync incrementally, and
/// restarts it after a crash (reopening every document at its latest
/// revision). Every position-anchored answer is checked against the
/// document revision it was asked for and dropped when stale (`INV-REV-004`).
public actor LanguageServerClient {
  public enum Status: Sendable, Equatable {
    case starting, running, failed(String), stopped
  }

  /// Diagnostics for `path`, computed against `revision`; the caller drops
  /// them if its view has moved past that revision.
  public typealias DiagnosticsSink = @Sendable (_ path: String, _ revision: TextRevision, [EditorDiagnosticSpan]) -> Void

  public let command: LanguageServerCommand
  public let root: URL
  private let executable: URL
  private let environment: [String: String]
  private let onDiagnostics: DiagnosticsSink
  private let onStatus: @Sendable (Status) -> Void

  private struct Document {
    var session: LSPDocumentSession
    var snapshot: TextSnapshot
    let languageID: String
  }
  private var documents: [DocumentUri: Document] = [:]
  private var process: Process?
  private var connection: JSONRPCServerConnection?
  private var boot: Task<Void, Error>?
  private var events: Task<Void, Never>?
  private var generation = 0
  private var crashes: [Date] = []
  private var stopped = false
  public private(set) var status: Status = .stopped
  public private(set) var triggerCharacters: Set<String> = []
  /// The live server process, for tests that crash it on purpose.
  var pid: Int32? { process?.processIdentifier }

  /// Outgoing notifications are chained so they hit the wire in call order;
  /// a request first waits for the chain (`flush`), so it is never written
  /// ahead of a `didChange` it depends on.
  private var writes: Task<Void, Never>?
  private var writeID = 0

  /// Crash restarts allowed inside `crashWindow` before giving up.
  static let maxCrashes = 3
  static let crashWindow: TimeInterval = 60

  public init(
    command: LanguageServerCommand, executable: URL, root: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    onDiagnostics: @escaping DiagnosticsSink, onStatus: @escaping @Sendable (Status) -> Void = { _ in }
  ) {
    self.command = command
    self.executable = executable
    self.root = root
    self.environment = environment
    self.onDiagnostics = onDiagnostics
    self.onStatus = onStatus
  }

  // MARK: - Lifecycle

  private func setStatus(_ s: Status) {
    status = s
    onStatus(s)
  }

  /// Starts the server if it is not already up; every other call goes through this.
  private func ready() async throws -> JSONRPCServerConnection {
    if stopped { throw LanguageServerError.stopped }
    if case .failed = status, boot == nil { throw LanguageServerError.stopped }  // gave up after a crash loop
    if boot == nil { start() }
    try await boot!.value
    guard let connection else { throw LanguageServerError.stopped }
    return connection
  }

  private func start() {
    generation += 1
    let gen = generation
    setStatus(.starting)
    boot = Task { try await self.launch(gen) }
  }

  private func launch(_ gen: Int) async throws {
    let p = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    p.executableURL = executable
    p.arguments = command.arguments
    p.currentDirectoryURL = root
    p.environment = environment
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = FileHandle.nullDevice
    // A server that died mid-write must not SIGPIPE the whole app.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    p.terminationHandler = { [weak self] proc in
      let status = proc.terminationStatus
      Task { await self?.exited(gen, status: status) }
    }
    do { try p.run() } catch {
      setStatus(.failed("\(command.executable) を起動できません"))
      throw error
    }
    process = p
    let writer = stdin.fileHandleForWriting
    let channel = DataChannel(
      writeHandler: { try writer.write(contentsOf: $0) }, dataSequence: stdout.fileHandleForReading.dataStream)
    let conn = JSONRPCServerConnection(dataChannel: channel)
    connection = conn
    events?.cancel()
    events = Task { [weak self] in
      for await event in await conn.eventSequence { await self?.handle(event) }
    }

    let result = try await conn.initialize(Self.initializeParams(root: root))
    guard gen == generation else { throw LanguageServerError.stopped }
    triggerCharacters = Set(result.capabilities.completionProvider?.triggerCharacters ?? [])
    try await conn.initialized(InitializedParams())
    setStatus(.running)
    // After a restart, bring the new server up to every document's latest revision.
    for (uri, doc) in documents {
      let session = LSPDocumentSession(uri: uri, languageId: doc.languageID)
      try session.beginInitialize()
      try session.serverInitialized()
      let params = try session.open(doc.snapshot)
      documents[uri]?.session = session
      enqueue(.textDocumentDidOpen(params))
    }
  }

  private func exited(_ gen: Int, status code: Int32) {
    guard gen == generation, !stopped else { return }
    process = nil
    connection = nil
    boot = nil
    let now = Date()
    crashes = crashes.filter { now.timeIntervalSince($0) < Self.crashWindow } + [now]
    guard crashes.count <= Self.maxCrashes else {
      generation += 1
      setStatus(.failed("\(command.executable) が繰り返し終了したため停止しました (exit \(code))"))
      return
    }
    for uri in documents.keys { onDiagnostics(Self.path(uri), documents[uri]!.snapshot.revision, []) }
    // Restart eagerly so diagnostics come back without waiting for the next request.
    start()
  }

  /// `shutdown` → `exit`, then kill whatever is still running.
  public func stop() async {
    guard !stopped else { return }
    stopped = true
    generation += 1
    if let connection, status == .running {
      Task {
        try? await connection.shutdown()
        try? await connection.exit()
      }
      // A clean exit usually takes a few ms; a wedged server gets terminated below regardless.
      for _ in 0..<20 where process?.isRunning == true { try? await Task.sleep(for: .milliseconds(50)) }
    }
    events?.cancel()
    if let process, process.isRunning { process.terminate() }
    process = nil
    connection = nil
    setStatus(.stopped)
  }

  // MARK: - Document sync

  /// Opens `path` on the server, or — if it is already open at another
  /// revision (the buffer changed without `change`, e.g. a review suggestion
  /// applied straight to the buffer) — resyncs it to `snapshot`.
  public func open(path: String, languageID: String, snapshot: TextSnapshot) async {
    let uri = Self.uri(path)
    if documents[uri] != nil {
      guard documents[uri]!.snapshot.revision != snapshot.revision else { return }
      documents[uri]!.snapshot = snapshot
      resync(uri)
      return
    }
    let session = LSPDocumentSession(uri: uri, languageId: languageID)
    documents[uri] = Document(session: session, snapshot: snapshot, languageID: languageID)
    guard (try? await ready()) != nil, let doc = documents[uri], !doc.session.isOpen else { return }
    // Sessions start uninitialized; the server itself is already past `initialized` here.
    try? doc.session.beginInitialize()
    try? doc.session.serverInitialized()
    guard let params = try? doc.session.open(doc.snapshot) else { return }
    enqueue(.textDocumentDidOpen(params))
  }

  public func change(path: String, edits: [ClairEditorCore.TextEdit], old: TextSnapshot, new: TextSnapshot) {
    let uri = Self.uri(path)
    guard var doc = documents[uri] else { return }
    let inSync = doc.snapshot.revision == old.revision
    doc.snapshot = new
    documents[uri] = doc
    // Not open on the server yet (still booting/restarting): `launch` opens it at `new`.
    guard doc.session.isOpen else { return }
    guard inSync, let params = try? doc.session.change(edits: edits, oldSnapshot: old, newSnapshot: new) else {
      resync(uri)
      return
    }
    enqueue(.textDocumentDidChange(params))
  }

  public func close(path: String) {
    let uri = Self.uri(path)
    guard let doc = documents.removeValue(forKey: uri), doc.session.isOpen,
      let params = try? doc.session.close()
    else { return }
    enqueue(.textDocumentDidClose(params))
  }

  /// The server's copy diverged from ours (an edit we never saw): reopen at the current snapshot.
  private func resync(_ uri: DocumentUri) {
    guard var doc = documents[uri], let closed = try? doc.session.close() else { return }
    enqueue(.textDocumentDidClose(closed))
    let session = LSPDocumentSession(uri: uri, languageId: doc.languageID)
    try? session.beginInitialize()
    try? session.serverInitialized()
    guard let opened = try? session.open(doc.snapshot) else { return }
    doc.session = session
    documents[uri] = doc
    enqueue(.textDocumentDidOpen(opened))
  }

  private func enqueue(_ note: ClientNotification) {
    guard let connection else { return }
    let previous = writes
    writeID += 1
    writes = Task {
      await previous?.value
      try? await connection.sendNotification(note)
    }
  }

  /// Returns once every notification enqueued so far has been written.
  private func flush() async {
    while true {
      let id = writeID
      await writes?.value
      if id == writeID { return }
    }
  }

  // MARK: - Requests

  /// A position request on the document's current revision, or nil when it
  /// is not open, the server is down, or an edit landed before the answer.
  private func request<R: Sendable>(
    _ path: String, at offset: UTF8Offset,
    _ send: (JSONRPCServerConnection, TextDocumentPositionParams) async throws -> R
  ) async -> (R, TextSnapshot)? {
    guard let conn = try? await ready() else { return nil }
    await flush()
    let uri = Self.uri(path)
    guard let doc = documents[uri], doc.session.isOpen, let version = doc.session.version,
      let position = try? LSPCoordinates.position(offset, in: doc.snapshot)
    else { return nil }
    let params = TextDocumentPositionParams(textDocument: TextDocumentIdentifier(uri: uri), position: position)
    guard let response = try? await send(conn, params),
      let current = documents[uri], current.session.accept(response, requestedAtVersion: version) != nil
    else { return nil }
    return (response, doc.snapshot)
  }

  public func completion(path: String, at offset: UTF8Offset) async -> LanguageServerCompletion? {
    guard
      let (response, snapshot) = await request(path, at: offset, { conn, p in
        try await conn.completion(
          CompletionParams(
            textDocument: p.textDocument, position: p.position,
            context: CompletionContext(triggerKind: .invoked, triggerCharacter: nil)))
      })
    else { return nil }
    let items = (response?.items ?? []).sorted { ($0.sortText ?? $0.label) < ($1.sortText ?? $1.label) }
    return LanguageServerCompletion(
      items: items.map { item in
        let edit: (String, LSPRange)? =
          switch item.textEdit {
          case .optionA(let e)?: (e.newText, e.range)
          case .optionB(let e)?: (e.newText, e.insert)
          case nil: nil
          }
        return LanguageServerCompletionItem(
          label: item.label, detail: item.detail, filterText: item.filterText ?? item.label,
          text: edit?.0 ?? item.insertText ?? item.label,
          range: edit.flatMap { try? LSPCoordinates.utf8Range($0.1, in: snapshot) })
      }, snapshot: snapshot)
  }

  public func definition(path: String, at offset: UTF8Offset) async -> [LanguageServerLocation]? {
    guard let (response, _) = await request(path, at: offset, { try await $0.definition($1) }) else { return nil }
    switch response {
    case .optionA(let l)?: return [Self.location(l.uri, l.range)]
    case .optionB(let ls)?: return ls.map { Self.location($0.uri, $0.range) }
    case .optionC(let links)?: return links.map { Self.location($0.targetUri, $0.targetSelectionRange) }
    case nil: return []
    }
  }

  public func references(path: String, at offset: UTF8Offset) async -> [LanguageServerLocation]? {
    guard
      let (response, _) = await request(path, at: offset, { conn, p in
        try await conn.references(
          ReferenceParams(
            textDocument: p.textDocument, position: p.position,
            context: ReferenceContext(includeDeclaration: true)))
      })
    else { return nil }
    return (response ?? []).map { Self.location($0.uri, $0.range) }
  }

  /// `workspace/symbol`. Not anchored to a document revision, so nothing to reject.
  public func symbols(matching query: String) async -> [LanguageServerLocation] {
    guard let conn = try? await ready(),
      let response = try? await conn.workspaceSymbol(WorkspaceSymbolParams(query: query))
    else { return [] }
    switch response {
    case .optionA(let infos):
      return infos.map { Self.location($0.location.uri, $0.location.range, title: Self.title($0.name, $0.containerName)) }
    case .optionB(let symbols):
      return symbols.compactMap { s in
        switch s.location {
        case .optionA(let l)?: Self.location(l.uri, l.range, title: Self.title(s.name, s.containerName))
        case .optionB(let doc)?:
          LanguageServerLocation(path: Self.path(doc.uri), line: 0, character: 0, title: Self.title(s.name, s.containerName))
        case nil: nil
        }
      }
    }
  }

  // MARK: - Server → client

  private func handle(_ event: ServerEvent) async {
    switch event {
    case .notification(.textDocumentPublishDiagnostics(let params)):
      publish(params)
    case .notification: break
    case .request(_, let request): await answer(request)
    case .error: break
    }
  }

  private func publish(_ params: PublishDiagnosticsParams) {
    guard let doc = documents[params.uri], let accepted = doc.session.accept(params) else { return }
    let spans = accepted.compactMap { d -> EditorDiagnosticSpan? in
      guard let range = try? LSPCoordinates.utf8Range(d.range, in: doc.snapshot) else { return nil }
      return EditorDiagnosticSpan(range: range, severity: Self.severity(d.severity), message: d.message)
    }
    onDiagnostics(Self.path(params.uri), doc.snapshot.revision, spans)
  }

  /// The few server requests a real server waits on. gopls, for one, asks
  /// `workspace/configuration` during startup and stalls without an answer.
  private func answer(_ request: ServerRequest) async {
    switch request {
    case .workspaceConfiguration(let params, let reply):
      await reply(.success(params.items.map { _ in LSPAny.null }))
    case .workspaceFolders(let reply):
      await reply(.success([WorkspaceFolder(uri: Self.uri(root.path), name: root.lastPathComponent)]))
    case .clientRegisterCapability(_, let reply), .clientUnregisterCapability(_, let reply),
      .windowWorkDoneProgressCreate(_, let reply), .workspaceCodeLensRefresh(let reply),
      .workspaceSemanticTokenRefresh(let reply):
      await reply(nil)
    case .workspaceApplyEdit(_, let reply):
      await reply(.success(ApplyWorkspaceEditResult(applied: false, failureReason: "Clair does not apply server edits")))
    case .windowShowMessageRequest(_, let reply):
      await reply(.success(nil))
    case .windowShowDocument(_, let reply):
      await reply(.success(ShowDocumentResult(success: false)))
    case .custom:
      await request.relyWithError(LanguageServerError.unsupported)
    }
  }

  // MARK: - Helpers

  static func initializeParams(root: URL) -> InitializeParams {
    let uri = Self.uri(root.path)
    let json = """
      {"processId":\(ProcessInfo.processInfo.processIdentifier),"clientInfo":{"name":"Clair"},
       "rootUri":\(Self.jsonString(uri)),"rootPath":\(Self.jsonString(root.path)),
       "workspaceFolders":[{"uri":\(Self.jsonString(uri)),"name":\(Self.jsonString(root.lastPathComponent))}],
       "capabilities":{
        "workspace":{"configuration":true,"workspaceFolders":true,"symbol":{}},
        "textDocument":{
         "synchronization":{"didSave":false},
         "publishDiagnostics":{"versionSupport":true},
         "completion":{"completionItem":{"snippetSupport":false}},
         "definition":{"linkSupport":true},
         "references":{}}}}
      """
    // swiftlint:disable:next force_try — a fixed literal; a decode failure is a programming error caught by tests.
    return try! JSONDecoder().decode(InitializeParams.self, from: Data(json.utf8))
  }

  private static func jsonString(_ s: String) -> String {
    String(data: try! JSONEncoder().encode(s), encoding: .utf8)!
  }

  static func uri(_ path: String) -> DocumentUri { URL(fileURLWithPath: path).absoluteString }

  static func path(_ uri: DocumentUri) -> String { URL(string: uri)?.path ?? uri }

  private static func location(_ uri: DocumentUri, _ range: LSPRange, title: String? = nil) -> LanguageServerLocation {
    let path = Self.path(uri)
    return LanguageServerLocation(
      path: path, line: range.start.line, character: range.start.character,
      title: title ?? "\((path as NSString).lastPathComponent):\(range.start.line + 1)")
  }

  private static func title(_ name: String, _ container: String?) -> String {
    container.map { $0.isEmpty ? name : "\(name) — \($0)" } ?? name
  }

  private static func severity(_ s: DiagnosticSeverity?) -> EditorDiagnosticSeverity {
    switch s {
    case .warning?: .warning
    case .information?: .information
    case .hint?: .hint
    default: .error
    }
  }
}

public enum LanguageServerError: Error, Sendable {
  case stopped, unsupported
}
