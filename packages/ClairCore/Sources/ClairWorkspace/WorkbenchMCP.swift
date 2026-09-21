import Foundation

// V03: `clair mcp serve` — stdio MCP adapter over the V02 IPC. Authorization never trusts the
// caller: risk and `aiAvailable` come from the registry inside the GUI process (`MCPGate`),
// so an agent that lies about a command's risk (or bypasses the adapter's tool list) gains nothing.
// Invariants/threat tests: docs/plans/clair-v03-mcp.md.

public enum MCPGate {
  /// Runs an `via: mcp` request. `approve` blocks until a human answers in the GUI; `run` executes with confirmation.
  public static func handle(
    _ req: WorkbenchIPCRequest, registry: CommandRegistry,
    snapshot: () -> WorkbenchState,
    approve: (String, CommandInput, CommandRisk) -> Bool,
    run: (String, CommandInput) -> Result<CommandResult, CommandError>
  ) -> Result<CommandResult, CommandError> {
    guard let d = registry.commands.first(where: { $0.id == req.command }) else {
      return .failure(CommandError(.unknownCommand, req.command))
    }
    guard d.aiAvailable else { return .failure(CommandError(.notAvailableToAI, "\(req.command) is not available to AI")) }
    switch registry.preflight(req.command, req.input, snapshot()) {
    case .failure(let e): return .failure(e)
    case .success(let risk):
      if risk >= .write, !approve(req.command, req.input, risk) {
        return .failure(CommandError(.denied, "\(req.command) was not approved in Clair"))
      }
      return run(req.command, req.input)
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
      var input = CommandInput()
      for (k, v) in (p?["arguments"] as? [String: Any]) ?? [:] {
        if let b = v as? Bool { input[k] = .bool(b) } else if let i = v as? Int { input[k] = .int(i) }
        else if let d = v as? Double { input[k] = .double(d) } else if let s = v as? String { input[k] = .string(s) }
      }
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
