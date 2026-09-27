import Foundation

// V03: `clair mcp serve` — stdio MCP adapter over the V02 IPC. Authorization never trusts the
// caller: risk and `aiAvailable` come from the registry inside the GUI process (`MCPGate`),
// so an agent that lies about a command's risk (or bypasses the adapter's tool list) gains nothing.
// Invariants/threat tests: docs/plans/clair-v03-mcp.md.

public enum MCPGate {
  /// Re-checks the live state right before execution; nil means the approval still covers it.
  public typealias Recheck = @Sendable (WorkbenchState) -> CommandError?

  /// Runs an `via: mcp` request. `approve` blocks until a human answers in the GUI. `run` must call the
  /// recheck on the live state and execute in the same main-actor turn, passing `confirmed` through.
  public static func handle(
    _ req: WorkbenchIPCRequest, registry: CommandRegistry,
    snapshot: () -> WorkbenchState,
    approve: (String, CommandInput, CommandRisk) -> Bool,
    run: (_ recheck: Recheck, _ confirmed: Bool) -> Result<CommandResult, CommandError>
  ) -> Result<CommandResult, CommandError> {
    guard let d = registry.commands.first(where: { $0.id == req.command }) else {
      return .failure(CommandError(.unknownCommand, req.command))
    }
    // V16: a CLI call from inside a Clair terminal may be an agent or the user. Non-AI commands are not
    // refused there (the user's own `clair open` keeps working) but always need approval in the GUI.
    let terminal = req.via == nil && req.caller != nil
    guard d.aiAvailable || terminal else { return .failure(CommandError(.notAvailableToAI, "\(req.command) is not available to AI")) }
    let seen = snapshot()
    switch registry.preflight(req.command, req.input, seen).map({ d.aiAvailable ? $0 : max($0, .write) }) {
    case .failure(let e): return .failure(e)
    case .success(let risk) where risk < .write:
      return run({ _ in nil }, false)
    case .success(let risk):
      guard approve(req.command, req.input, risk) else {
        return .failure(CommandError(.denied, "\(req.command) was not approved in Clair"))
      }
      // The human approved `risk` on `seen`. Implicit targets (active tab, focused pane, project) and the
      // risk itself may have moved while the card was up; never run something broader than what was shown.
      return run({ now in
        guard now.project == seen.project, now.active == seen.active, now.tree.focused == seen.tree.focused else {
          return CommandError(.denied, "\(req.command): Clair の状態が承認中に変わったため実行しませんでした")
        }
        switch registry.preflight(req.command, req.input, now) {
        case .failure(let e): return e
        case .success(let r) where r > risk:
          return CommandError(.denied, "\(req.command): 承認時より危険度が上がったため実行しませんでした")
        case .success: return nil
        }
      }, risk >= .destructive)
    }
  }
}

public enum MCPServer {
  static let protocolVersion = "2024-11-05"

  /// One JSON-RPC line in → one line out (nil for notifications). `call` performs the IPC round trip.
  public static func respond(
    to line: String, registry: CommandRegistry = .workbench,
    call: (WorkbenchIPCRequest) throws -> WorkbenchIPCReply
  ) -> String? {
    guard let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let method = msg["method"] as? String else {
      return reply(nil, error: (-32700, "parse error"))
    }
    guard let id = msg["id"] else { return nil }  // notification
    switch method {
    case "initialize":
      return reply(id, result: [
        "protocolVersion": protocolVersion, "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": "clair", "version": "2"],
      ])
    case "ping": return reply(id, result: [String: Any]())
    case "tools/list":
      return reply(id, result: ["tools": registry.commands.filter(\.aiAvailable).map(tool)])
    case "tools/call":
      let p = msg["params"] as? [String: Any]
      guard let name = p?["name"] as? String, registry.commands.contains(where: { $0.id == name && $0.aiAvailable }) else {
        return reply(id, error: (-32602, "unknown tool"))
      }
      guard let input = arguments(p?["arguments"]) else { return reply(id, error: (-32602, "invalid arguments")) }
      let out: (String, Bool)
      do {
        let r = try call(WorkbenchIPCRequest(command: name, input: input, via: .mcp))
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        if let e = r.error { out = (String(decoding: try enc.encode(e), as: UTF8.self), true) }
        else { out = (String(decoding: try enc.encode(r.result ?? .ok), as: UTF8.self), false) }
      } catch { out = ("Clair is not reachable: \(error)", true) }
      return reply(id, result: ["content": [["type": "text", "text": out.0]], "isError": out.1])
    default: return reply(id, error: (-32601, "method not found"))
    }
  }

  /// JSON scalars only. NSNumber bridges 0/1 to Bool, so JSON booleans are told apart by their CF type;
  /// null/array/object are rejected rather than dropped (a dropped `path` would retarget the active tab).
  static func arguments(_ raw: Any?) -> CommandInput? {
    guard let raw else { return [:] }
    guard let dict = raw as? [String: Any] else { return nil }
    var input = CommandInput()
    for (k, v) in dict {
      if let s = v as? String { input[k] = .string(s); continue }
      guard let n = v as? NSNumber else { return nil }
      if CFGetTypeID(n) == CFBooleanGetTypeID() { input[k] = .bool(n.boolValue) }
      else if CFNumberIsFloatType(n) { input[k] = .double(n.doubleValue) }
      else { input[k] = .int(n.intValue) }
    }
    return input
  }

  private static func tool(_ d: CommandDescriptor) -> [String: Any] {
    var props = [String: Any]()
    for p in d.params {
      var t: [String: Any] = ["type": p.kind == .int ? "integer" : p.kind == .double ? "number" : p.kind == .bool ? "boolean" : "string"]
      if let a = p.allowed { t["enum"] = a }
      props[p.name] = t
    }
    return [
      "name": d.id, "description": "\(d.title) (risk: \(d.risk.label))",
      "inputSchema": ["type": "object", "properties": props, "required": d.params.filter(\.required).map(\.name)],
    ]
  }

  private static func reply(_ id: Any?, result: [String: Any]? = nil, error: (Int, String)? = nil) -> String {
    var o: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
    if let result { o["result"] = result }
    if let error { o["error"] = ["code": error.0, "message": error.1] }
    return String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
  }
}
