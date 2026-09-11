@preconcurrency import Foundation
@preconcurrency import Network
import SwiftUI

enum DebugSessionState: String, CaseIterable, Equatable, Sendable {
  case idle
  case launching
  case running
  case stopped
  case terminating
  case exited
  case failed

  var title: String {
    switch self {
    case .idle:
      "待機中"
    case .launching:
      "起動中"
    case .running:
      "実行中"
    case .stopped:
      "停止中"
    case .terminating:
      "終了中"
    case .exited:
      "終了"
    case .failed:
      "失敗"
    }
  }

  var isActive: Bool {
    switch self {
    case .launching, .running, .stopped, .terminating:
      true
    case .idle, .exited, .failed:
      false
    }
  }
}

struct DebugSourceLocation: Equatable, Sendable {
  let path: String
  let line: Int
  let column: Int

  init(path: String, line: Int, column: Int = 1) {
    self.path = path
    self.line = max(1, line)
    self.column = max(1, column)
  }
}

struct DebugBreakpoint: Identifiable, Equatable, Sendable {
  let id: String
  let sourcePath: String
  let line: Int
  var verified: Bool
  var message: String?

  init(
    id: String = UUID().uuidString,
    sourcePath: String,
    line: Int,
    verified: Bool = false,
    message: String? = nil
  ) {
    self.id = id
    self.sourcePath = sourcePath
    self.line = max(1, line)
    self.verified = verified
    self.message = message
  }
}

struct DebugStackFrame: Identifiable, Equatable, Sendable {
  let id: Int
  let name: String
  let sourcePath: String?
  let line: Int?
  let column: Int?
}

struct DebugVariable: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let type: String?
  let value: String
  let variablesReference: Int

  init(
    id: String = UUID().uuidString,
    name: String,
    type: String? = nil,
    value: String,
    variablesReference: Int = 0
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.value = value
    self.variablesReference = variablesReference
  }
}

struct DebugConsoleEntry: Identifiable, Equatable, Sendable {
  enum Kind: String, Sendable {
    case command
    case output
    case error
    case status
  }

  let id: UUID
  let kind: Kind
  let text: String
  let date: Date

  init(kind: Kind, text: String, date: Date = Date()) {
    self.id = UUID()
    self.kind = kind
    self.text = text
    self.date = date
  }
}

enum DebugLaunchMode: String, CaseIterable, Equatable, Hashable, Sendable {
  case launch
  case attach

  var title: String {
    switch self {
    case .launch:
      "起動"
    case .attach:
      "Attach"
    }
  }
}

struct DebugLaunchConfiguration: Equatable, Sendable {
  var mode: DebugLaunchMode = .launch
  var programPath: String
  var arguments: [String] = []
  var environment: [String: String] = [:]
  var stopOnEntry = true
  var processID: Int32?

  init(projectRootURL: URL) {
    programPath = projectRootURL.path
  }
}

enum DebugDAPMessage: Sendable {
  case response(
    requestSequence: Int,
    command: String,
    success: Bool,
    message: String?,
    body: Data?
  )
  case event(name: String, body: Data?)
  case diagnostic(String)
}

enum DebugDAPError: Error, Equatable, LocalizedError, Sendable {
  case invalidHeader
  case missingContentLength
  case invalidContentLength
  case frameTooLarge
  case invalidJSON
  case notConnected
  case processNotFound
  case transport(String)

  var errorDescription: String? {
    switch self {
    case .invalidHeader:
      "DAP header is invalid."
    case .missingContentLength:
      "DAP Content-Length header is missing."
    case .invalidContentLength:
      "DAP Content-Length header is invalid."
    case .frameTooLarge:
      "DAP frame exceeds the safety limit."
    case .invalidJSON:
      "DAP payload is not valid JSON."
    case .notConnected:
      "DAP connection is not available."
    case .processNotFound:
      "Delve executable was not found."
    case .transport(let message):
      message
    }
  }
}

struct DebugDAPFrameDecoder: Sendable {
  static let maximumFrameSize = 4 * 1024 * 1024

  private(set) var buffer = Data()

  mutating func append(_ data: Data) throws -> [Data] {
    buffer.append(data)
    var payloads: [Data] = []
    let delimiter = Data("\r\n\r\n".utf8)

    while let headerRange = buffer.range(of: delimiter) {
      let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
      guard let header = String(data: headerData, encoding: .ascii) else {
        throw DebugDAPError.invalidHeader
      }

      var contentLength: Int?
      for line in header.components(separatedBy: "\r\n") where !line.isEmpty {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
          throw DebugDAPError.invalidHeader
        }
        if parts[0].lowercased() == "content-length" {
          guard let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
            throw DebugDAPError.invalidContentLength
          }
          contentLength = length
        }
      }

      guard let contentLength else {
        throw DebugDAPError.missingContentLength
      }
      guard contentLength >= 0, contentLength <= Self.maximumFrameSize else {
        throw DebugDAPError.frameTooLarge
      }

      let payloadStart = headerRange.upperBound
      let payloadEnd = payloadStart + contentLength
      guard buffer.count >= payloadEnd else {
        break
      }
      payloads.append(buffer.subdata(in: payloadStart..<payloadEnd))
      buffer.removeSubrange(0..<payloadEnd)
    }

    guard buffer.count <= Self.maximumFrameSize + 1024 else {
      throw DebugDAPError.frameTooLarge
    }
    return payloads
  }

  static func encode(payload: Data) throws -> Data {
    guard payload.count <= maximumFrameSize else {
      throw DebugDAPError.frameTooLarge
    }
    var frame = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
    frame.append(payload)
    return frame
  }
}

private final class DebugDAPTransport: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.diwamoto.clair.debug-dap")
  private var listener: NWListener?
  private var connection: NWConnection?
  private var process: Process?
  private var decoder = DebugDAPFrameDecoder()
  private var nextSequence = 1
  private var stderrBuffer = Data()
  private var onMessage: (@Sendable (DebugDAPMessage) -> Void)?
  private var onReady: (@Sendable () -> Void)?
  private var onClosed: (@Sendable (String) -> Void)?
  private var didNotifyClose = false

  func start(
    delveURL: URL,
    rootURL: URL,
    onReady: @escaping @Sendable () -> Void,
    onMessage: @escaping @Sendable (DebugDAPMessage) -> Void,
    onClosed: @escaping @Sendable (String) -> Void
  ) throws {
    self.onReady = onReady
    self.onMessage = onMessage
    self.onClosed = onClosed

    let listener = try NWListener(using: .tcp, on: .any)
    self.listener = listener
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.launchProcess(delveURL: delveURL, rootURL: rootURL, listener: listener)
      case .failed(let error):
        self.notifyClosed("DAP listener failed: \(error.localizedDescription)")
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      self.queue.async {
        guard self.connection == nil else {
          connection.cancel()
          return
        }
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
          guard let self else { return }
          switch state {
          case .ready:
            self.onReady?()
            self.receive()
          case .failed(let error):
            self.notifyClosed("DAP connection failed: \(error.localizedDescription)")
          case .cancelled:
            self.notifyClosed("DAP connection closed.")
          default:
            break
          }
        }
        connection.start(queue: self.queue)
      }
    }
    listener.start(queue: queue)
  }

  func send(command: String, arguments: [String: Any] = [:]) -> Int? {
    queue.sync {
      guard let connection else {
        onMessage?(.diagnostic(DebugDAPError.notConnected.localizedDescription))
        return nil
      }
      let sequence = nextSequence
      nextSequence += 1
      var object: [String: Any] = [
        "seq": sequence,
        "type": "request",
        "command": command,
      ]
      if !arguments.isEmpty {
        object["arguments"] = arguments
      }
      guard
        JSONSerialization.isValidJSONObject(object),
        let payload = try? JSONSerialization.data(withJSONObject: object),
        let frame = try? DebugDAPFrameDecoder.encode(payload: payload)
      else {
        onMessage?(.diagnostic("Could not encode DAP request \(command)."))
        return sequence
      }
      connection.send(content: frame, completion: .contentProcessed { [weak self] error in
        guard let self, let error else { return }
        self.notifyClosed("DAP send failed: \(error.localizedDescription)")
      })
      return sequence
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      self.connection?.cancel()
      self.listener?.cancel()
      if let process = self.process, process.isRunning {
        process.terminate()
      }
      self.process = nil
      self.connection = nil
      self.listener = nil
    }
  }

  private func launchProcess(delveURL: URL, rootURL: URL, listener: NWListener) {
    guard let port = listener.port?.rawValue else {
      notifyClosed("DAP listener did not receive a port.")
      return
    }

    let process = Process()
    process.executableURL = delveURL
    process.arguments = [
      "dap",
      "--client-addr=127.0.0.1:\(port)",
      "--listen=127.0.0.1:0",
      "--only-same-user",
    ]
    process.currentDirectoryURL = rootURL
    let stderr = Pipe()
    process.standardError = stderr
    process.standardOutput = Pipe()
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
      guard let self else { return }
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self.queue.async {
        self.stderrBuffer.append(data)
        while let newline = self.stderrBuffer.firstIndex(of: 0x0A) {
          let lineData = self.stderrBuffer.prefix(upTo: newline)
          self.stderrBuffer.removeSubrange(...newline)
          if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
            self.onMessage?(.diagnostic(line))
          }
        }
      }
    }
    process.terminationHandler = { [weak self] process in
      guard let self else { return }
      self.queue.async {
        self.notifyClosed("Delve exited with status \(process.terminationStatus).")
      }
    }
    do {
      try process.run()
      self.process = process
    } catch {
      notifyClosed("Could not start Delve: \(error.localizedDescription)")
    }
  }

  private func receive() {
    connection?.receive(
      minimumIncompleteLength: 1,
      maximumLength: DebugDAPFrameDecoder.maximumFrameSize
    ) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      self.queue.async {
        if let data, !data.isEmpty {
          do {
            for payload in try self.decoder.append(data) {
              self.handle(payload: payload)
            }
          } catch {
            self.onMessage?(.diagnostic(error.localizedDescription))
            self.notifyClosed(error.localizedDescription)
            return
          }
        }
        if isComplete {
          self.notifyClosed("DAP server closed the connection.")
        } else if let error {
          self.notifyClosed("DAP receive failed: \(error.localizedDescription)")
        } else {
          self.receive()
        }
      }
    }
  }

  private func handle(payload: Data) {
    guard
      let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
      let type = object["type"] as? String
    else {
      onMessage?(.diagnostic(DebugDAPError.invalidJSON.localizedDescription))
      return
    }

    switch type {
    case "response":
      let body = object["body"].flatMap { value -> Data? in
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
      }
      onMessage?(
        .response(
          requestSequence: (object["request_seq"] as? NSNumber)?.intValue ?? 0,
          command: object["command"] as? String ?? "",
          success: (object["success"] as? NSNumber)?.boolValue ?? false,
          message: object["message"] as? String,
          body: body
        )
      )
    case "event":
      let body = object["body"].flatMap { value -> Data? in
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
      }
      onMessage?(.event(name: object["event"] as? String ?? "", body: body))
    default:
      onMessage?(.diagnostic("Unsupported DAP message type: \(type)"))
    }
  }

  private func notifyClosed(_ message: String) {
    guard !didNotifyClose else { return }
    didNotifyClose = true
    onClosed?(message)
  }
}

@MainActor
final class DebugSessionModel: ObservableObject {
  let projectID: UUID
  let projectRootURL: URL

  @Published private(set) var state: DebugSessionState = .idle
  @Published private(set) var lastErrorMessage: String?
  @Published private(set) var breakpoints: [DebugBreakpoint] = []
  @Published private(set) var stackFrames: [DebugStackFrame] = []
  @Published private(set) var variables: [DebugVariable] = []
  @Published private(set) var console: [DebugConsoleEntry] = []
  @Published private(set) var currentLocation: DebugSourceLocation?
  @Published private(set) var selectedFrameID: Int?
  @Published private(set) var supportsPause = false
  @Published private(set) var supportsRestart = false
  @Published var configuration: DebugLaunchConfiguration

  private var transport: DebugDAPTransport?
  private var generation = 0
  private var pendingCommands: [Int: String] = [:]
  private var initialized = false
  private var configurationDone = false
  private var configurationDoneRequested = false
  private var currentThreadID: Int?
  private var currentScopesReference = 0

  init(projectID: UUID, projectRootURL: URL) {
    self.projectID = projectID
    self.projectRootURL = projectRootURL.standardizedFileURL
    self.configuration = DebugLaunchConfiguration(projectRootURL: projectRootURL)
  }

  deinit {
    transport?.stop()
  }

  var canStart: Bool {
    switch state {
    case .idle, .exited, .failed:
      true
    case .launching, .running, .stopped, .terminating:
      false
    }
  }

  var canContinue: Bool {
    state == .stopped
  }

  func start() {
    guard canStart else { return }
    clearRuntimeState()
    generation += 1
    let currentGeneration = generation
    state = .launching
    lastErrorMessage = nil
    appendConsole(.status, "デバッグセッションを開始しています")

    guard let delveURL = Self.resolveDelve() else {
      fail("Delve (dlv) が見つかりません。PATHまたは設定を確認してください。")
      return
    }

    let transport = DebugDAPTransport()
    self.transport = transport
    do {
      try transport.start(
        delveURL: delveURL,
        rootURL: projectRootURL,
        onReady: { [weak self] in
          Task { @MainActor [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.sendInitialize()
          }
        },
        onMessage: { [weak self] message in
          Task { @MainActor [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.handle(message)
          }
        },
        onClosed: { [weak self] reason in
          Task { @MainActor [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.handleTransportClosed(reason)
          }
        }
      )
    } catch {
      fail(error.localizedDescription)
    }
  }

  func stop() {
    guard state.isActive || state == .failed else { return }
    state = .terminating
    appendConsole(.status, "デバッグセッションを終了しています")
    if let sequence = send("disconnect", arguments: ["terminateDebuggee": true]) {
      pendingCommands[sequence] = "disconnect"
    } else {
      finishStop()
    }
  }

  func restart() {
    guard state == .stopped || state == .running else { return }
    generation += 1
    transport?.stop()
    transport = nil
    state = .idle
    start()
  }

  func continueExecution() {
    guard canContinue, let threadID = currentThreadID else { return }
    _ = send("continue", arguments: ["threadId": threadID])
    state = .running
  }

  func pause() {
    guard state == .running else { return }
    _ = send("pause", arguments: ["threadId": currentThreadID ?? 0])
  }

  func stepOver() {
    step(command: "next")
  }

  func stepInto() {
    step(command: "stepIn")
  }

  func stepOut() {
    step(command: "stepOut")
  }

  func toggleBreakpoint(sourcePath: String, line: Int) {
    let normalizedPath = normalizedSourcePath(sourcePath)
    let rootPath = projectRootURL.path
    guard normalizedPath == rootPath || normalizedPath.hasPrefix(rootPath + "/") else {
      appendConsole(.error, "Project外のソースにはブレークポイントを設定できません。")
      return
    }
    let normalizedLine = max(1, line)
    if let index = breakpoints.firstIndex(where: {
      $0.sourcePath == normalizedPath && $0.line == normalizedLine
    }) {
      breakpoints.remove(at: index)
    } else {
      breakpoints.append(
        DebugBreakpoint(sourcePath: normalizedPath, line: normalizedLine)
      )
    }
    if initialized {
      sendBreakpoints(for: normalizedPath)
    }
  }

  func selectFrame(_ frame: DebugStackFrame) {
    selectedFrameID = frame.id
    currentLocation = frame.sourcePath.flatMap { path in
      guard let line = frame.line else { return nil }
      return DebugSourceLocation(path: path, line: line, column: frame.column ?? 1)
    }
    if currentScopesReference != 0 {
      _ = send("scopes", arguments: ["frameId": frame.id])
      currentScopesReference = 0
    }
  }

  func evaluate(_ expression: String) {
    let query = expression.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    appendConsole(.command, "> \(query)")
    _ = send(
      "evaluate",
      arguments: [
        "expression": query,
        "frameId": selectedFrameID ?? 0,
        "context": "repl",
      ]
    )
  }

  func clearConsole() {
    console.removeAll()
  }

  func shutdown() {
    generation += 1
    transport?.stop()
    transport = nil
  }

  private func sendInitialize() {
    let sequence = send(
      "initialize",
      arguments: [
        "clientID": "clair",
        "clientName": "Clair",
        "adapterID": "delve",
        "locale": "ja-JP",
        "linesStartAt1": true,
        "columnsStartAt1": true,
        "pathFormat": "path",
      ]
    )
    if let sequence {
      pendingCommands[sequence] = "initialize"
    }
  }

  private func sendLaunchOrAttach() {
    switch configuration.mode {
    case .launch:
      var arguments: [String: Any] = [
        "mode": "debug",
        "program": relativeOrAbsoluteProgramPath(configuration.programPath),
        "cwd": projectRootURL.path,
        "stopOnEntry": configuration.stopOnEntry,
      ]
      if !configuration.arguments.isEmpty {
        arguments["args"] = configuration.arguments
      }
      if !configuration.environment.isEmpty {
        arguments["env"] = configuration.environment
      }
      let sequence = send("launch", arguments: arguments)
      if let sequence { pendingCommands[sequence] = "launch" }
    case .attach:
      guard let processID = configuration.processID, processID > 0 else {
        fail("AttachするPIDを入力してください。")
        return
      }
      let sequence = send(
        "attach",
        arguments: [
          "mode": "local",
          "processId": processID,
          "stopOnEntry": configuration.stopOnEntry,
        ]
      )
      if let sequence { pendingCommands[sequence] = "attach" }
    }
  }

  private func sendBreakpoints(for path: String) {
    let points = breakpoints.filter { $0.sourcePath == path }.map {
      ["line": $0.line, "column": 1]
    }
    let sequence = send(
      "setBreakpoints",
      arguments: [
        "source": ["path": path],
        "breakpoints": points,
        "sourceModified": false,
      ]
    )
    if let sequence { pendingCommands[sequence] = "setBreakpoints:\(path)" }
  }

  private func sendConfigurationDone() {
    guard !configurationDone, !configurationDoneRequested else { return }
    configurationDoneRequested = true
    let sequence = send("configurationDone")
    if let sequence { pendingCommands[sequence] = "configurationDone" }
  }

  private func step(command: String) {
    guard state == .stopped, let threadID = currentThreadID else { return }
    let sequence = send(command, arguments: ["threadId": threadID])
    if let sequence { pendingCommands[sequence] = command }
    state = .running
  }

  private func send(_ command: String, arguments: [String: Any] = [:]) -> Int? {
    transport?.send(command: command, arguments: arguments)
  }

  private func handle(_ message: DebugDAPMessage) {
    switch message {
    case .diagnostic(let message):
      appendConsole(.error, message)
    case .response(let requestSequence, let command, let success, let message, let body):
      let pending = pendingCommands.removeValue(forKey: requestSequence) ?? command
      guard success else {
        fail(message ?? "DAP request failed: \(pending)")
        return
      }
      handleResponse(command: pending, body: body)
    case .event(let name, let body):
      handleEvent(name: name, body: body)
    }
  }

  private func handleResponse(command: String, body: Data?) {
    switch command {
    case "initialize":
      if let capabilities = jsonObject(from: body) {
        supportsPause = capabilities["supportsPauseRequest"] as? Bool ?? false
        supportsRestart = capabilities["supportsRestartRequest"] as? Bool ?? false
      }
      initialized = true
      sendLaunchOrAttach()
    case "launch", "attach":
      appendConsole(.status, "Delveに接続しました")
      if !configurationDone {
        sendConfigurationDone()
      }
    case "configurationDone":
      configurationDone = true
      if state == .launching { state = .running }
    case "threads":
      if let object = jsonObject(from: body),
        let threads = object["threads"] as? [[String: Any]],
        let thread = threads.first,
        let threadID = (thread["id"] as? NSNumber)?.intValue
      {
        currentThreadID = threadID
        let sequence = send(
          "stackTrace",
          arguments: ["threadId": threadID, "startFrame": 0, "levels": 50]
        )
        if let sequence { pendingCommands[sequence] = "stackTrace" }
      }
    case "stackTrace":
      parseStackTrace(body)
    case "scopes":
      parseScopes(body)
    case "variables":
      parseVariables(body)
    case "evaluate":
      if let object = jsonObject(from: body) {
        let result = object["result"] as? String ?? "(no result)"
        let type = object["type"] as? String
        appendConsole(.output, type.map { "\(result) · \($0)" } ?? result)
      }
    case "disconnect":
      finishStop()
    default:
      if command.hasPrefix("setBreakpoints:") {
        applyBreakpointResponse(body, sourcePath: String(command.dropFirst("setBreakpoints:".count)))
      }
    }
  }

  private func handleEvent(name: String, body: Data?) {
    switch name {
    case "initialized":
      for path in Set(breakpoints.map(\.sourcePath)) {
        sendBreakpoints(for: path)
      }
      sendConfigurationDone()
    case "stopped":
      state = .stopped
      if let object = jsonObject(from: body) {
        currentThreadID = (object["threadId"] as? NSNumber)?.intValue
        if let description = object["description"] as? String {
          appendConsole(.status, description)
        }
      }
      let sequence = send("threads")
      if let sequence { pendingCommands[sequence] = "threads" }
    case "continued":
      state = .running
    case "output":
      if let object = jsonObject(from: body), let output = object["output"] as? String {
        appendConsole(.output, output.trimmingCharacters(in: .newlines))
      }
    case "breakpoint":
      if let object = jsonObject(from: body), let breakpoint = object["breakpoint"] as? [String: Any] {
        updateBreakpointVerification(breakpoint)
      }
    case "exited", "terminated":
      state = .exited
      appendConsole(.status, name == "exited" ? "デバッグ対象が終了しました" : "デバッグセッションが終了しました")
    default:
      break
    }
  }

  private func parseStackTrace(_ body: Data?) {
    guard let object = jsonObject(from: body),
      let frames = object["stackFrames"] as? [[String: Any]]
    else {
      stackFrames = []
      return
    }
    stackFrames = frames.compactMap { frame in
      guard let id = (frame["id"] as? NSNumber)?.intValue,
        let name = frame["name"] as? String
      else { return nil }
      let source = frame["source"] as? [String: Any]
      return DebugStackFrame(
        id: id,
        name: name,
        sourcePath: (source?["path"] as? String).map(normalizedSourcePath),
        line: (frame["line"] as? NSNumber)?.intValue,
        column: (frame["column"] as? NSNumber)?.intValue
      )
    }
    if let first = stackFrames.first {
      selectedFrameID = first.id
      currentLocation = first.sourcePath.flatMap { path in
        guard let line = first.line else { return nil }
        return DebugSourceLocation(path: path, line: line, column: first.column ?? 1)
      }
      let sequence = send("scopes", arguments: ["frameId": first.id])
      if let sequence { pendingCommands[sequence] = "scopes" }
    }
  }

  private func parseScopes(_ body: Data?) {
    guard let object = jsonObject(from: body),
      let scopes = object["scopes"] as? [[String: Any]]
    else { return }
    let scope = scopes.first { ($0["name"] as? String)?.lowercased().contains("local") == true }
      ?? scopes.first
    guard let scope, let reference = (scope["variablesReference"] as? NSNumber)?.intValue,
      reference != 0
    else { return }
    currentScopesReference = reference
    let sequence = send("variables", arguments: ["variablesReference": reference])
    if let sequence { pendingCommands[sequence] = "variables" }
  }

  private func parseVariables(_ body: Data?) {
    guard let object = jsonObject(from: body),
      let values = object["variables"] as? [[String: Any]]
    else { return }
    variables = values.prefix(200).compactMap { value in
      guard let name = value["name"] as? String else { return nil }
      return DebugVariable(
        name: name,
        type: value["type"] as? String,
        value: value["value"] as? String ?? "",
        variablesReference: (value["variablesReference"] as? NSNumber)?.intValue ?? 0
      )
    }
  }

  private func applyBreakpointResponse(_ body: Data?, sourcePath: String) {
    guard let object = jsonObject(from: body),
      let values = object["breakpoints"] as? [[String: Any]]
    else { return }
    let requested = breakpoints.filter { $0.sourcePath == sourcePath }
    for (index, value) in values.enumerated() where index < requested.count {
      guard let breakpointIndex = breakpoints.firstIndex(where: { $0.id == requested[index].id }) else { continue }
      breakpoints[breakpointIndex].verified = (value["verified"] as? Bool) ?? false
      breakpoints[breakpointIndex].message = value["message"] as? String
    }
  }

  private func updateBreakpointVerification(_ object: [String: Any]) {
    guard let source = object["source"] as? [String: Any],
      let path = source["path"] as? String,
      let line = (object["line"] as? NSNumber)?.intValue
    else { return }
    let normalizedPath = normalizedSourcePath(path)
    guard let index = breakpoints.firstIndex(where: {
      $0.sourcePath == normalizedPath && $0.line == line
    }) else { return }
    breakpoints[index].verified = (object["verified"] as? Bool) ?? false
    breakpoints[index].message = object["message"] as? String
  }

  private func handleTransportClosed(_ reason: String) {
    if state == .terminating {
      finishStop()
      return
    }
    guard state != .exited else { return }
    if state == .launching || state == .running || state == .stopped {
      fail(reason)
    }
  }

  private func finishStop() {
    transport?.stop()
    transport = nil
    state = .exited
    initialized = false
    configurationDone = false
    pendingCommands.removeAll()
    appendConsole(.status, "デバッグセッションを終了しました")
  }

  private func fail(_ message: String) {
    lastErrorMessage = message
    state = .failed
    appendConsole(.error, message)
    transport?.stop()
    transport = nil
  }

  private func clearRuntimeState() {
    stackFrames = []
    variables = []
    currentLocation = nil
    selectedFrameID = nil
    currentThreadID = nil
    currentScopesReference = 0
    pendingCommands.removeAll()
    initialized = false
    configurationDone = false
    configurationDoneRequested = false
    supportsPause = false
    supportsRestart = false
  }

  private func appendConsole(_ kind: DebugConsoleEntry.Kind, _ text: String) {
    guard !text.isEmpty else { return }
    console.append(DebugConsoleEntry(kind: kind, text: text))
    if console.count > 500 {
      console.removeFirst(console.count - 500)
    }
  }

  private func jsonObject(from data: Data?) -> [String: Any]? {
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return object
  }

  private func normalizedSourcePath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path, relativeTo: projectRootURL).standardizedFileURL
    return url.path
  }

  private func relativeOrAbsoluteProgramPath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path, relativeTo: projectRootURL).standardizedFileURL
    if url.path == projectRootURL.path {
      return "."
    }
    let root = projectRootURL.path.hasSuffix("/") ? projectRootURL.path : projectRootURL.path + "/"
    if url.path.hasPrefix(root) {
      return String(url.path.dropFirst(root.count))
    }
    return url.path
  }

  private static func resolveDelve() -> URL? {
    var candidates: [URL] = []
    if let configured = ProcessInfo.processInfo.environment["CLAIR_DLV_PATH"], !configured.isEmpty {
      candidates.append(URL(fileURLWithPath: configured))
    }
    if let path = ProcessInfo.processInfo.environment["PATH"] {
      candidates.append(contentsOf: path.split(separator: ":").map {
        URL(fileURLWithPath: String($0)).appendingPathComponent("dlv")
      })
    }
    candidates += [
      URL(fileURLWithPath: "/opt/homebrew/bin/dlv"),
      URL(fileURLWithPath: "/usr/local/bin/dlv"),
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("go/bin/dlv"),
    ]
    return candidates.first {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
  }
}

struct DebugControlToolbar: View {
  @ObservedObject var session: DebugSessionModel

  var body: some View {
    HStack(spacing: 3) {
      ChromeActionButton(
        width: 28,
        height: 28,
        isActive: session.state == .running,
        help: session.state == .running ? "一時停止" : "続行",
        action: {
          if session.state == .running {
            session.pause()
          } else {
            session.continueExecution()
          }
        },
        label: {
          Image(systemName: session.state == .running ? "pause.fill" : "play.fill")
            .font(.system(size: 12, weight: .semibold))
        }
      )
      .disabled(session.state != .running && !session.canContinue)

      ChromeActionButton(
        width: 28,
        height: 28,
        help: "ステップオーバー",
        action: session.stepOver,
        label: {
          Image(systemName: "arrow.right")
            .font(.system(size: 12, weight: .medium))
        }
      )
      .disabled(session.state != .stopped)

      ChromeActionButton(
        width: 28,
        height: 28,
        help: "ステップイン",
        action: session.stepInto,
        label: {
          Image(systemName: "arrow.down.to.line")
            .font(.system(size: 12, weight: .medium))
        }
      )
      .disabled(session.state != .stopped)

      ChromeActionButton(
        width: 28,
        height: 28,
        help: "ステップアウト",
        action: session.stepOut,
        label: {
          Image(systemName: "arrow.up.to.line")
            .font(.system(size: 12, weight: .medium))
        }
      )
      .disabled(session.state != .stopped)

      Divider()
        .frame(height: 18)
        .padding(.horizontal, 3)

      ChromeActionButton(
        width: 28,
        height: 28,
        help: "再起動",
        action: session.restart,
        label: {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 12, weight: .medium))
        }
      )
      .disabled(!session.state.isActive)

      ChromeActionButton(
        width: 28,
        height: 28,
        help: "停止",
        action: session.stop,
        label: {
          Image(systemName: "stop.fill")
            .font(.system(size: 11, weight: .semibold))
        }
      )
      .disabled(!session.state.isActive && session.state != .failed)
    }
  }
}

struct ProjectDebugSidebarView: View {
  @ObservedObject var session: DebugSessionModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        DebugSidebarSectionLabel(title: "変数")
        if session.variables.isEmpty {
          Text(session.state == .stopped ? "変数を取得しています…" : "停止すると表示されます")
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.textMuted)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        } else {
          ForEach(session.variables) { variable in
            VStack(alignment: .leading, spacing: 2) {
              Text(variable.name)
                .font(WorkspaceChrome.chromeFont(size: 11, weight: .medium))
                .foregroundStyle(WorkspaceChrome.debugBlueText)
              Text([variable.type, variable.value].compactMap { $0 }.joined(separator: " · "))
                .font(WorkspaceChrome.chromeFont(size: 9))
                .foregroundStyle(WorkspaceChrome.textMuted)
                .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
          }
        }

        DebugSidebarSectionLabel(title: "コールスタック")
        if session.stackFrames.isEmpty {
          Text(session.state == .stopped ? "スタックを取得しています…" : "停止すると表示されます")
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.textMuted)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        } else {
          ForEach(session.stackFrames) { frame in
            Button {
              session.selectFrame(frame)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(frame.name)
                  .font(WorkspaceChrome.chromeFont(size: 11, weight: .medium))
                  .foregroundStyle(
                    frame.id == session.selectedFrameID
                      ? WorkspaceChrome.textPrimary
                      : WorkspaceChrome.textTertiary
                  )
                  .lineLimit(1)
                if let path = frame.sourcePath, let line = frame.line {
                  Text("\(URL(fileURLWithPath: path).lastPathComponent):\(line)")
                    .font(WorkspaceChrome.chromeFont(size: 9))
                    .foregroundStyle(WorkspaceChrome.textMuted)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 14)
              .padding(.vertical, 6)
              .background(
                frame.id == session.selectedFrameID
                  ? WorkspaceChrome.debugBlue.opacity(0.10)
                  : Color.clear
              )
              .overlay(alignment: .leading) {
                if frame.id == session.selectedFrameID {
                  Rectangle()
                    .fill(WorkspaceChrome.debugBlue)
                    .frame(width: 2)
                }
              }
            }
            .buttonStyle(.plain)
          }
        }

        DebugSidebarSectionLabel(title: "ブレークポイント")
        if session.breakpoints.isEmpty {
          Text("設定されていません")
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.textMuted)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        } else {
          ForEach(session.breakpoints) { breakpoint in
            Button {
              session.toggleBreakpoint(
                sourcePath: breakpoint.sourcePath,
                line: breakpoint.line
              )
            } label: {
              HStack(spacing: 8) {
                Circle()
                  .fill(breakpoint.verified ? WorkspaceChrome.danger : WorkspaceChrome.attention)
                  .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                  Text(URL(fileURLWithPath: breakpoint.sourcePath).lastPathComponent)
                    .font(WorkspaceChrome.chromeFont(size: 11))
                    .foregroundStyle(WorkspaceChrome.textPrimary)
                    .lineLimit(1)
                  Text("\(breakpoint.line)行目")
                    .font(WorkspaceChrome.chromeFont(size: 9))
                    .foregroundStyle(WorkspaceChrome.textMuted)
                }
                Spacer(minLength: 0)
                if breakpoint.verified {
                  Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(WorkspaceChrome.success)
                }
              }
              .padding(.horizontal, 14)
              .frame(minHeight: 30)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }

        if let error = session.lastErrorMessage {
          DebugSidebarSectionLabel(title: "診断")
          Text(error)
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.danger)
            .lineLimit(4)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.hidden)
    .background(WorkspaceChrome.chrome)
  }
}

private struct DebugSidebarSectionLabel: View {
  let title: String

  var body: some View {
    Text(title)
      .font(WorkspaceChrome.chromeFont(size: 9, weight: .bold))
      .foregroundStyle(WorkspaceChrome.textMuted)
      .padding(.horizontal, 14)
      .padding(.top, 14)
      .padding(.bottom, 6)
  }
}

struct DebugStartCard: View {
  @ObservedObject var session: DebugSessionModel

  private var processIDBinding: Binding<String> {
    Binding(
      get: { session.configuration.processID.map(String.init) ?? "" },
      set: { session.configuration.processID = Int32($0) }
    )
  }

  private var programPathBinding: Binding<String> {
    Binding(
      get: { session.configuration.programPath },
      set: { session.configuration.programPath = $0 }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "ladybug")
          .foregroundStyle(WorkspaceChrome.debugBlueText)
        Text("Debug")
          .font(WorkspaceChrome.chromeFont(size: 14, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
        Spacer(minLength: 0)
      }

      Text("Go / Delve のデバッグセッションを開始します。")
        .font(WorkspaceChrome.chromeFont(size: 11))
        .foregroundStyle(WorkspaceChrome.textTertiary)

      Picker("モード", selection: $session.configuration.mode) {
        ForEach(DebugLaunchMode.allCases, id: \.self) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      if session.configuration.mode == .launch {
        TextField("実行対象", text: programPathBinding)
          .textFieldStyle(.roundedBorder)
      } else {
        TextField("PID", text: processIDBinding)
          .textFieldStyle(.roundedBorder)
      }

      Toggle("開始時に停止", isOn: $session.configuration.stopOnEntry)
        .font(WorkspaceChrome.chromeFont(size: 11))

      HStack {
        Spacer(minLength: 0)
        Button("セッションを開始") {
          session.start()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }
    }
    .padding(18)
    .frame(maxWidth: 380)
    .background(
      WorkspaceChrome.chromeRaised,
      in: RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.overlay, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.overlay, style: .continuous)
        .stroke(WorkspaceChrome.borderStrong, lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
  }
}

struct DebugConsoleView: View {
  @ObservedObject var session: DebugSessionModel
  @State private var expression = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("デバッグコンソール")
          .font(WorkspaceChrome.chromeFont(size: 10, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textTertiary)
        Text(session.state.title)
          .font(WorkspaceChrome.chromeFont(size: 9))
          .foregroundStyle(session.state == .failed ? WorkspaceChrome.danger : WorkspaceChrome.textMuted)
        Spacer(minLength: 0)
        Button("クリア") {
          session.clearConsole()
        }
        .buttonStyle(.plain)
        .font(WorkspaceChrome.chromeFont(size: 9))
        .foregroundStyle(WorkspaceChrome.textMuted)
      }
      .padding(.horizontal, 12)
      .frame(height: 30)
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(WorkspaceChrome.chromeLineSoft)
          .frame(height: 1)
      }

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(session.console) { entry in
              Text(entry.text)
                .font(WorkspaceChrome.chromeFont(size: 10))
                .foregroundStyle(color(for: entry.kind))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(entry.id)
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .onChange(of: session.console.last?.id) { _, id in
          guard let id else { return }
          withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(id, anchor: .bottom)
          }
        }
      }

      HStack(spacing: 6) {
        Text(">")
          .font(WorkspaceChrome.chromeFont(size: 10, weight: .bold))
          .foregroundStyle(WorkspaceChrome.debugBlueText)
        TextField("式を評価…", text: $expression)
          .textFieldStyle(.plain)
          .font(WorkspaceChrome.chromeFont(size: 10))
          .onSubmit {
            submitExpression()
          }
        Button("評価") {
          submitExpression()
        }
        .buttonStyle(.plain)
        .font(WorkspaceChrome.chromeFont(size: 9, weight: .semibold))
        .foregroundStyle(WorkspaceChrome.textPrimary)
        .disabled(expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(.horizontal, 12)
      .frame(height: 28)
      .overlay(alignment: .top) {
        Rectangle()
          .fill(WorkspaceChrome.chromeLineSoft)
          .frame(height: 1)
      }
    }
    .background(WorkspaceChrome.chrome)
  }

  private func submitExpression() {
    session.evaluate(expression)
    expression = ""
  }

  private func color(for kind: DebugConsoleEntry.Kind) -> Color {
    switch kind {
    case .command:
      WorkspaceChrome.debugBlueText
    case .output:
      WorkspaceChrome.textTertiary
    case .error:
      WorkspaceChrome.danger
    case .status:
      WorkspaceChrome.textMuted
    }
  }
}
