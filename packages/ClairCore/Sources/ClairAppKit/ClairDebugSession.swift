#if os(macOS)
import ClairWorkspace
import Foundation
import Observation

/// Runtime state belongs to its Project (including a managed worktree's own
/// path/origin/branch), and is never written into workspace.json.
@MainActor @Observable final class ClairDebugSession {
  enum Phase: Equatable { case idle, starting, configuring, running, stopped, ended, failed(String) }
  struct Frame: Identifiable, Equatable {
    let id: Int
    let name: String
    let path: String?
    let line: Int
  }
  struct Variable: Identifiable, Equatable {
    let id: String
    let name: String
    let value: String
    let reference: Int
    let depth: Int
  }
  struct Thread: Identifiable, Equatable { let id: Int; let name: String }
  struct BreakpointStatus: Equatable { let adapterID: Int?; let verified: Bool; let line: Int; let message: String? }
  enum Start: Equatable { case launch(program: String, mode: String), attach(pid: Int) }

  let project: WorkbenchProject
  private(set) var phase: Phase = .idle
  private(set) var threads: [Thread] = []
  private(set) var frames: [Frame] = []
  private(set) var variables: [Variable] = []
  private(set) var console: [String] = []
  private(set) var selectedThread: Int?
  private(set) var selectedFrame: Int?
  private(set) var stoppedReason: String?
  private(set) var breakpoints: [String: Set<Int>] = [:]
  private(set) var breakpointStatus: [String: [Int: BreakpointStatus]] = [:]
  private var client: ClairDAPClient?
  private var generation = 0
  private var stopGeneration = 0
  private var selectionGeneration = 0
  private var expandingVariables: [String: Int] = [:]
  private var startConfiguration: Start?
  private let adapterExecutable: URL?

  init(project: WorkbenchProject, adapterExecutable: URL? = nil) {
    self.project = project; self.adapterExecutable = adapterExecutable
  }

  func start(_ configuration: Start) async {
    guard phase == .idle || phase == .ended || { if case .failed = phase { return true }; return false }() else { return }
    generation += 1
    stopGeneration += 1
    selectionGeneration += 1
    let current = generation
    threads = []; frames = []; variables = []; selectedThread = nil; selectedFrame = nil; stoppedReason = nil
    breakpointStatus = [:]
    expandingVariables = [:]
    do {
      switch configuration {
      case .launch(let raw, let mode):
        guard ["debug", "test", "exec"].contains(mode) else { throw ClairDAPClient.Failure.rejected("未対応の起動モードです") }
        let file = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: project.path)).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path == project.path || file.path.hasPrefix(project.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
          throw ClairDAPClient.Failure.rejected("起動対象は Project 内の既存ファイルまたはフォルダを選んでください")
        }
        startConfiguration = .launch(program: file.path, mode: mode)
      case .attach(let pid):
        guard pid > 0 else { throw ClairDAPClient.Failure.rejected("PID は正の整数にしてください") }
        startConfiguration = configuration
      }
      phase = .starting
      let adapter = ClairDAPClient(
        onEvent: { [weak self] data in Task { @MainActor in self?.handle(data, generation: current) } },
        onDisconnect: { [weak self] reason in Task { @MainActor in self?.disconnected(reason, generation: current) } })
      client = adapter
      try await adapter.start(root: project.path, executable: adapterExecutable)
      _ = try await adapter.request("initialize", arguments: Self.json([
        "clientID": "clair", "clientName": "Clair", "adapterID": "go", "locale": "ja-JP",
        "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path", "supportsVariableType": true,
      ]))
      guard generation == current else { return }
      // DAP permits launch/attach to reply only after configurationDone. Keep
      // the request in flight; the initialized event drives configuration.
      let args: [String: Any]
      let command: String
      switch startConfiguration! {
      case .launch(let program, let mode):
        command = "launch"
        args = ["type": "go", "request": "launch", "mode": mode, "program": program, "cwd": project.path, "stopOnEntry": false, "outputMode": "remote"]
      case .attach(let pid):
        command = "attach"
        args = ["type": "go", "request": "attach", "mode": "local", "processId": pid]
      }
      Task { [weak self] in
        do { _ = try await adapter.request(command, arguments: Self.json(args)) }
        catch { self?.fail(error, generation: current) }
      }
    } catch { fail(error, generation: current) }
  }

  func toggleBreakpoint(path: String, line: Int) {
    guard line > 0, path.hasPrefix(project.path + "/") else { return }
    let requested = breakpointStatus[path]?.first(where: { $0.value.line == line })?.key ?? line
    var lines = breakpoints[path] ?? []
    if !lines.insert(requested).inserted { lines.remove(requested) }
    breakpoints[path] = lines
    breakpointStatus[path]?[requested] = nil
    if let client, phase == .running || phase == .stopped {
      let current = generation
      Task {
        do { try await sendBreakpoints(path, client: client, generation: current) }
        catch { if current == generation { appendConsole("ブレークポイントを設定できません: \(error.localizedDescription)") } }
      }
    }
  }

  private func sendBreakpoints(_ path: String, client: ClairDAPClient, generation current: Int) async throws {
    let lines = (breakpoints[path] ?? []).sorted()
    let response = try await client.request("setBreakpoints", arguments: Self.json([
      "source": ["path": path], "breakpoints": lines.map { ["line": $0] }, "sourceModified": false,
    ]))
    guard current == generation, breakpoints[path] == Set(lines) else { return }
    let results = Self.body(response)["breakpoints"] as? [[String: Any]] ?? []
    breakpointStatus[path] = Dictionary(uniqueKeysWithValues: zip(lines, results).map { requested, result in
      (requested, BreakpointStatus(adapterID: result["id"] as? Int, verified: result["verified"] as? Bool ?? false,
        line: result["line"] as? Int ?? requested, message: result["message"] as? String))
    })
    for requested in lines where breakpointStatus[path]?[requested]?.verified == false {
      appendConsole("ブレークポイント \(URL(fileURLWithPath: path).lastPathComponent):\(requested): \(breakpointStatus[path]?[requested]?.message ?? "検証されませんでした")")
    }
  }

  private func configure(generation current: Int) async {
    guard current == generation, let client else { return }
    phase = .configuring
    do {
      for path in breakpoints.keys.sorted() { try await sendBreakpoints(path, client: client, generation: current) }
      _ = try await client.request("configurationDone")
      if current == generation, phase == .configuring { phase = .running }
    } catch { fail(error, generation: current) }
  }

  func control(_ command: String) async {
    guard let client else { return }
    let current = generation
    let stoppedAt = stopGeneration
    do {
      let args: [String: Any] = selectedThread.map { ["threadId": $0] } ?? [:]
      switch command {
      case "continue", "next", "stepIn", "stepOut":
        guard phase == .stopped, selectedThread != nil else { return }
        _ = try await client.request(command, arguments: Self.json(args))
        guard current == generation, stoppedAt == stopGeneration, phase == .stopped else { return }
        phase = .running; frames = []; variables = []; selectedFrame = nil
        stopGeneration += 1; selectionGeneration += 1; expandingVariables = [:]
      case "pause":
        guard phase == .running else { return }
        _ = try await client.request(command, arguments: Self.json(args))
        guard current == generation else { return }
      default: return
      }
    } catch {
      if current == generation { appendConsole("デバッグ操作 \(command) に失敗: \(error.localizedDescription)") }
    }
  }

  func stop() async {
    let (adapter, terminate) = endSession()
    if let adapter { await disconnect(adapter, terminate: terminate) }
  }

  private func endSession() -> (ClairDAPClient?, Bool) {
    guard phase != .ended || client != nil else { return (nil, false) }
    generation += 1
    stopGeneration += 1
    selectionGeneration += 1
    let adapter = client
    client = nil
    phase = .ended; threads = []; frames = []; variables = []; selectedThread = nil; selectedFrame = nil
    expandingVariables = [:]
    appendConsole("デバッグセッションを終了しました")
    // Attaching to an existing process never grants Clair permission to kill it.
    let terminate: Bool = { if case .launch? = startConfiguration { return true }; return false }()
    return (adapter, terminate)
  }

  private func disconnect(_ adapter: ClairDAPClient, terminate: Bool) async {
    _ = try? await adapter.request("disconnect", arguments: Self.json(["terminateDebuggee": terminate]))
    await adapter.stop()
  }

  func restart() async {
    guard let configuration = startConfiguration else { return }
    await stop()
    await start(configuration)
  }

  func selectThread(_ id: Int) {
    guard phase == .stopped, threads.contains(where: { $0.id == id }) else { return }
    selectedThread = id
    selectedFrame = nil
    frames = []; variables = []
    expandingVariables = [:]
    selectionGeneration += 1
    let current = generation, selection = selectionGeneration
    Task { await loadFrames(generation: current, selection: selection) }
  }

  func selectFrame(_ id: Int) {
    guard phase == .stopped, frames.contains(where: { $0.id == id }) else { return }
    selectedFrame = id
    variables = []
    expandingVariables = [:]
    selectionGeneration += 1
    let current = generation, selection = selectionGeneration
    Task { await loadVariables(frame: id, generation: current, selection: selection) }
  }

  func expandVariable(_ variable: Variable) {
    guard phase == .stopped, variable.reference > 0, let client,
      let index = variables.firstIndex(where: { $0.id == variable.id }) else { return }
    // A second click collapses the direct children; nested children follow them.
    if variables.indices.contains(index + 1), variables[index + 1].depth > variable.depth {
      let end = variables[(index + 1)...].firstIndex(where: { $0.depth <= variable.depth }) ?? variables.endIndex
      variables.removeSubrange((index + 1)..<end)
      return
    }
    let current = generation, selection = selectionGeneration
    guard expandingVariables[variable.id] == nil else { return }
    expandingVariables[variable.id] = selection
    Task {
      defer { if expandingVariables[variable.id] == selection { expandingVariables[variable.id] = nil } }
      do {
        let response = try await client.request("variables", arguments: Self.json(["variablesReference": variable.reference, "start": 0, "count": 200]))
        guard current == generation, selection == selectionGeneration, phase == .stopped,
          let index = variables.firstIndex(where: { $0.id == variable.id }) else { return }
        let children = Self.parseVariables(response, parent: variable.id, reference: variable.reference, depth: variable.depth + 1)
        variables.insert(contentsOf: children, at: index + 1)
      } catch { inspectionError(error, generation: current, selection: selection) }
    }
  }

  private func handle(_ data: Data, generation current: Int) {
    guard generation == current,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let event = object["event"] as? String
    else { return }
    let body = object["body"] as? [String: Any] ?? [:]
    switch event {
    case "initialized": Task { await configure(generation: current) }
    case "stopped":
      stoppedReason = body["reason"] as? String
      stopGeneration += 1
      if stoppedReason == "exception" {
        let detail = body["description"] as? String ?? body["text"] as? String ?? "例外で停止しました"
        appendConsole(detail)
        stoppedReason = detail
      }
      selectedThread = body["threadId"] as? Int
      selectedFrame = nil
      selectionGeneration += 1
      expandingVariables = [:]
      phase = .stopped
      Task { await refresh(generation: current) }
    case "continued": phase = .running; frames = []; variables = []; selectedFrame = nil; stopGeneration += 1; selectionGeneration += 1; expandingVariables = [:]
    case "output": if let output = body["output"] as? String { appendConsole(output.trimmingCharacters(in: .newlines)) }
    case "breakpoint":
      if let changed = body["breakpoint"] as? [String: Any],
        let match = breakpointMatch(changed) {
        let (path, requested) = match
        let actual = changed["line"] as? Int ?? requested
        breakpointStatus[path, default: [:]][requested] = BreakpointStatus(
          adapterID: changed["id"] as? Int, verified: changed["verified"] as? Bool ?? false,
          line: actual, message: changed["message"] as? String)
      }
    case "exited": appendConsole("終了コード: \(body["exitCode"] ?? "不明")")
    case "terminated":
      let (adapter, terminate) = endSession()
      if let adapter { Task { await disconnect(adapter, terminate: terminate) } }
    default: break
    }
  }

  private func refresh(generation current: Int) async {
    guard current == generation, phase == .stopped, let client else { return }
    let selection = selectionGeneration
    do {
      let threadResponse = try await client.request("threads")
      guard current == generation, selection == selectionGeneration, phase == .stopped else { return }
      let threadBody = Self.body(threadResponse)
      threads = (threadBody["threads"] as? [[String: Any]] ?? []).compactMap {
        guard let id = $0["id"] as? Int else { return nil }
        return Thread(id: id, name: $0["name"] as? String ?? "Thread \(id)")
      }
      if selectedThread == nil { selectedThread = threads.first?.id }
      selectionGeneration += 1
      await loadFrames(generation: current, selection: selectionGeneration)
    } catch { inspectionError(error, generation: current, selection: selection) }
  }

  private func loadFrames(generation current: Int, selection: Int) async {
    guard current == generation, selection == selectionGeneration, phase == .stopped,
      let client, let id = selectedThread else { return }
    do {
      let stackResponse = try await client.request("stackTrace", arguments: Self.json(["threadId": id, "startFrame": 0, "levels": 100]))
      guard current == generation, selection == selectionGeneration, phase == .stopped else { return }
      frames = (Self.body(stackResponse)["stackFrames"] as? [[String: Any]] ?? []).compactMap {
        guard let fid = $0["id"] as? Int else { return nil }
        return Frame(id: fid, name: $0["name"] as? String ?? "frame", path: ($0["source"] as? [String: Any])?["path"] as? String, line: $0["line"] as? Int ?? 0)
      }
      selectedFrame = frames.first?.id
      guard let selectedFrame else { variables = []; return }
      await loadVariables(frame: selectedFrame, generation: current, selection: selection)
    } catch { inspectionError(error, generation: current, selection: selection) }
  }

  private func loadVariables(frame: Int, generation current: Int, selection: Int) async {
    guard current == generation, selection == selectionGeneration, phase == .stopped, let client else { return }
    do {
      let scopesResponse = try await client.request("scopes", arguments: Self.json(["frameId": frame]))
      guard current == generation, selection == selectionGeneration, phase == .stopped else { return }
      let scopes = Self.body(scopesResponse)["scopes"] as? [[String: Any]] ?? []
      variables = []
      for scope in scopes {
        guard let ref = scope["variablesReference"] as? Int, ref > 0 else { continue }
        let variableResponse = try await client.request("variables", arguments: Self.json(["variablesReference": ref, "start": 0, "count": 200]))
        guard current == generation, selection == selectionGeneration, phase == .stopped else { return }
        variables += Self.parseVariables(variableResponse, parent: "scope:\(ref)", reference: ref, depth: 0)
      }
    } catch { inspectionError(error, generation: current, selection: selection) }
  }

  private func inspectionError(_ error: Error, generation current: Int, selection: Int) {
    guard current == generation, selection == selectionGeneration, phase == .stopped else { return }
    appendConsole("デバッグ情報を取得できません: \(error.localizedDescription)")
  }

  private static func parseVariables(_ response: Data, parent: String, reference: Int, depth: Int) -> [Variable] {
    (body(response)["variables"] as? [[String: Any]] ?? []).enumerated().map { n, value in
      Variable(id: "\(parent):\(reference):\(n)", name: value["name"] as? String ?? "?",
        value: value["value"] as? String ?? "", reference: value["variablesReference"] as? Int ?? 0, depth: depth)
    }
  }

  private func breakpointMatch(_ changed: [String: Any]) -> (String, Int)? {
    if let id = changed["id"] as? Int {
      for (path, statuses) in breakpointStatus {
        if let requested = statuses.first(where: { $0.value.adapterID == id })?.key { return (path, requested) }
      }
    }
    guard let path = (changed["source"] as? [String: Any])?["path"] as? String,
      let actual = changed["line"] as? Int else { return nil }
    if let requested = breakpointStatus[path]?.first(where: { $0.value.line == actual })?.key { return (path, requested) }
    if breakpoints[path]?.contains(actual) == true { return (path, actual) }
    return nil
  }

  private func appendConsole(_ line: String) {
    guard !line.isEmpty else { return }
    console.append(line)
    if console.count > 500 { console.removeFirst(console.count - 500) }
  }

  private func fail(_ error: Error, generation current: Int) {
    guard current == generation else { return }
    phase = .failed(error.localizedDescription)
    appendConsole(error.localizedDescription)
    if let client { Task { await client.stop() } }
    client = nil
  }

  private func disconnected(_ reason: String, generation current: Int) {
    guard current == generation, phase != .ended else { return }
    if case .failed = phase { return }
    phase = .failed(reason)
    appendConsole(reason)
    client = nil
  }

  private static func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
  private static func body(_ data: Data) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["body"] as? [String: Any] ?? [:]
  }
}
#endif
