#if os(macOS)
  import ClairShared
  import ClairEditorCore
  import ClairEditorLanguage
  import ClairEditorView
  import Foundation
  import Observation

  /// E12: the app's language servers — one `LanguageServerClient` per
  /// (Project root, server executable), started lazily by the first file that
  /// needs it and kept until quit. Documents are fed to a client strictly in
  /// call order (`feed`), so an older `didChange` can never overtake a newer
  /// one on its way into the actor.
  @MainActor @Observable final class LanguageServices {
    private struct Key: Hashable {
      let root: String
      let executable: String
    }

    @ObservationIgnored private var clients: [Key: LanguageServerClient] = [:]
    @ObservationIgnored private var feeds: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var resolving: [String: Task<URL?, Never>] = [:]
    /// Server state per (root, executable), for the status bar. `nil` = never needed.
    private var status: [Key: LanguageServerClient.Status] = [:]
    /// Latest accepted diagnostics per absolute path, with the revision they belong to.
    private(set) var diagnostics: [String: (revision: TextRevision, spans: [EditorDiagnosticSpan])] = [:]
    @ObservationIgnored private var sinks: [String: (TextRevision, [EditorDiagnosticSpan]) -> Void] = [:]
    /// Where servers are looked up; nil = the login-shell PATH (resolved off the main thread on first use).
    @ObservationIgnored private let searchPath: String?
    /// Applies an edit a server asked for (`workspace/applyEdit`, e.g. a code action's command); true when applied.
    @ObservationIgnored var onWorkspaceEdit: ((LanguageServerWorkspaceEdit) -> Bool)?

    init(searchPath: String? = nil) { self.searchPath = searchPath }

    private func key(_ path: String, root: String) -> (Key, LanguageServerCommand, EditorLanguageID)? {
      guard let id = EditorLanguageID.detect(path: path), let command = id.languageServer else { return nil }
      return (Key(root: root, executable: command.executable), command, id)
    }

    /// The client for `path`, spawning one on first use; nil if the language
    /// has no server or it is not installed (shown as such in the status bar).
    private func client(for path: String, root: String) async -> LanguageServerClient? {
      guard let (key, command, _) = key(path, root: root) else { return nil }
      if let existing = clients[key] { return existing }
      let lookup =
        resolving[command.executable]
        ?? Task.detached(priority: .utility) { [searchPath] in
          command.resolve(path: searchPath ?? LanguageServerCommand.loginPath)  // first call runs a login shell
        }
      resolving[command.executable] = lookup
      guard let executable = await lookup.value else {
        // Set once: every keystroke asks again, and each write would re-render the status bar.
        if status[key] == nil { status[key] = .failed(tr("%@ 未インストール", command.executable)) }
        return nil
      }
      if let existing = clients[key] { return existing }
      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] = searchPath ?? LanguageServerCommand.loginPath  // already computed by `lookup`
      let client = LanguageServerClient(
        command: command, executable: executable, root: URL(fileURLWithPath: root), environment: environment,
        onDiagnostics: { [weak self] path, revision, spans in
          Task { @MainActor in self?.deliver(path, revision, spans) }
        },
        onStatus: { [weak self] s in Task { @MainActor in self?.status[key] = s } },
        onApplyEdit: { [weak self] edit in await MainActor.run { self?.onWorkspaceEdit?(edit) ?? false } })
      clients[key] = client
      return client
    }

    /// Runs `body` after everything previously fed to the same client.
    private func feed(_ path: String, root: String, _ body: @escaping @Sendable (LanguageServerClient) async -> Void) {
      guard let (key, _, _) = key(path, root: root) else { return }
      let previous = feeds[key]
      feeds[key] = Task { [weak self] in
        await previous?.value
        guard let client = await self?.client(for: path, root: root) else { return }
        await body(client)
      }
    }

    private func deliver(_ path: String, _ revision: TextRevision, _ spans: [EditorDiagnosticSpan]) {
      diagnostics[path] = (revision, spans)
      sinks[path]?(revision, spans)
    }

    // MARK: - Documents

    /// A view for `path` came up: route its diagnostics there, and open (or resync) it on the server.
    func attach(_ path: String, root: String, snapshot: TextSnapshot, sink: @escaping (TextRevision, [EditorDiagnosticSpan]) -> Void) {
      guard let (_, _, id) = key(path, root: root) else { return }
      sinks[path] = sink
      if let cached = diagnostics[path] { sink(cached.revision, cached.spans) }
      feed(path, root: root) { await $0.open(path: path, languageID: id.lspLanguageID, snapshot: snapshot) }
    }

    func change(_ path: String, root: String, edits: [TextEdit], old: TextSnapshot, new: TextSnapshot) {
      feed(path, root: root) { await $0.change(path: path, edits: edits, old: old, new: new) }
    }

    func close(_ path: String, root: String) {
      guard key(path, root: root) != nil else { return }
      sinks[path] = nil
      diagnostics[path] = nil
      feed(path, root: root) { await $0.close(path: path) }
    }

    // MARK: - Requests (each waits behind the edits already fed)

    private func ask<T: Sendable>(
      _ path: String, root: String, _ body: @escaping @Sendable (LanguageServerClient) async -> T?
    ) async -> T? {
      guard let (key, _, _) = key(path, root: root) else { return nil }
      await feeds[key]?.value
      guard let client = await client(for: path, root: root) else { return nil }
      return await body(client)
    }

    func completion(_ path: String, root: String, at offset: UTF8Offset) async -> LanguageServerCompletion? {
      await ask(path, root: root) { await $0.completion(path: path, at: offset) }
    }

    func definition(_ path: String, root: String, at offset: UTF8Offset) async -> [LanguageServerLocation]? {
      await ask(path, root: root) { await $0.definition(path: path, at: offset) }
    }

    func references(_ path: String, root: String, at offset: UTF8Offset) async -> [LanguageServerLocation]? {
      await ask(path, root: root) { await $0.references(path: path, at: offset) }
    }

    func triggerCharacters(_ path: String, root: String) async -> Set<String> {
      await ask(path, root: root) { await $0.triggerCharacters } ?? []
    }

    func signatureTriggerCharacters(_ path: String, root: String) async -> Set<String> {
      await ask(path, root: root) { await $0.signatureTriggerCharacters } ?? []
    }

    func hover(_ path: String, root: String, at offset: UTF8Offset) async -> String? {
      await ask(path, root: root) { await $0.hover(path: path, at: offset) }
    }

    func signatureHelp(_ path: String, root: String, at offset: UTF8Offset) async -> LanguageServerSignature? {
      await ask(path, root: root) { await $0.signatureHelp(path: path, at: offset) }
    }

    func prepareRename(_ path: String, root: String, at offset: UTF8Offset, fallback: TextUTF8Range?) async -> (range: TextUTF8Range, placeholder: String)? {
      await ask(path, root: root) { await $0.prepareRename(path: path, at: offset, fallback: fallback) }
    }

    func rename(_ path: String, root: String, at offset: UTF8Offset, to name: String) async -> LanguageServerWorkspaceEdit? {
      await ask(path, root: root) { await $0.rename(path: path, at: offset, to: name) }
    }

    func codeActions(_ path: String, root: String, range: TextUTF8Range) async -> [LanguageServerCodeAction] {
      await ask(path, root: root) { await $0.codeActions(path: path, range: range) } ?? []
    }

    func run(_ action: LanguageServerCodeAction, path: String, root: String) async {
      _ = await ask(path, root: root) { client -> Bool? in await client.run(action); return true }
    }

    /// nil when no server formats `path` (the caller falls back to `DocumentFormatter`).
    func format(_ path: String, root: String, tabSize: Int, insertSpaces: Bool) async -> (edits: [TextEdit], snapshot: TextSnapshot)? {
      await ask(path, root: root) { client in
        guard await client.formats else { return nil }
        return await client.format(path: path, tabSize: tabSize, insertSpaces: insertSpaces)
      }
    }

    func documentSymbols(_ path: String, root: String) async -> [LanguageServerDocumentSymbol] {
      await ask(path, root: root) { await $0.documentSymbols(path: path) } ?? []
    }

    func save(_ path: String, root: String) {
      feed(path, root: root) { await $0.save(path: path) }
    }

    /// Every diagnostic currently published, by absolute path (for the problems list).
    var allDiagnostics: [(path: String, revision: TextRevision, spans: [EditorDiagnosticSpan])] {
      diagnostics.map { ($0.key, $0.value.revision, $0.value.spans) }.sorted { $0.path < $1.path }
    }

    /// `workspace/symbol` across every server already running for `root`.
    func symbols(root: String, matching query: String) async -> [LanguageServerLocation] {
      var found: [LanguageServerLocation] = []
      for (key, client) in clients where key.root == root {
        found += await client.symbols(matching: query)
      }
      return found
    }

    /// Status-bar text for `path`'s server, nil when its language has none.
    func statusText(_ path: String, root: String) -> (text: String, failed: Bool)? {
      guard let (key, _, _) = key(path, root: root), let s = status[key] else { return nil }
      switch s {
      case .starting: return (tr("%@ 起動中…", key.executable), false)
      case .running: return (key.executable, false)
      case .failed(let message): return (message, true)
      case .stopped: return (tr("%@ 停止", key.executable), true)
      }
    }
  }
#endif
