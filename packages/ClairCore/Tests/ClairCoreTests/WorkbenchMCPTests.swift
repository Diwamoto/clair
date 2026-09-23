import Foundation
import XCTest

@testable import ClairWorkspace

/// V03 threat tests: the gate, not the adapter, is the authority.
final class WorkbenchMCPTests: XCTestCase {
  private let reg = CommandRegistry.workbench
  /// `run` mirrors the app: recheck the live state (`later`, i.e. after the card was answered), then execute.
  private func gate(
    _ id: String, _ input: CommandInput = [:], state: WorkbenchState = WorkbenchState(), later: WorkbenchState? = nil,
    approve: Bool = false
  ) -> (Result<CommandResult, CommandError>, asked: Int, ran: Int, confirmed: Bool) {
    var asked = 0, ran = 0, confirmed = false
    let r = MCPGate.handle(
      WorkbenchIPCRequest(command: id, input: input, via: .mcp), registry: reg, snapshot: { state },
      approve: { _, _, _ in asked += 1; return approve },
      run: { recheck, c in
        if let e = recheck(later ?? state) { return .failure(e) }
        ran += 1; confirmed = c; return .success(.ok)
      })
    return (r, asked, ran, confirmed)
  }

  func testAIUnavailableCommandRejectedWithoutPrompt() {
    for id in ["agent.launch", "project.open", "settings.set", "palette.commands"] {
      let g = gate(id, ["path": .string("/"), "profile": .string("claude"), "key": .string("showQuota"), "value": .bool(true)])
      XCTAssertEqual(try? g.0.get(), nil); XCTAssertEqual(g.asked + g.ran, 0, id)
      if case .failure(let e) = g.0 { XCTAssertEqual(e.code, .notAvailableToAI, id) }
    }
  }

  func testWriteAndDestructiveNeedApprovalAndDenialBlocks() {
    var s = WorkbenchState(); s.dirty.insert(s.active!)
    let denied = gate("tab.close", state: s)
    XCTAssertEqual(denied.asked, 1); XCTAssertEqual(denied.ran, 0)
    if case .failure(let e) = denied.0 { XCTAssertEqual(e.code, .denied) } else { XCTFail() }
    let ok = gate("tab.close", state: s, approve: true)
    XCTAssertEqual(ok.ran, 1); XCTAssertTrue(ok.confirmed)  // the card showed 破壊的
    XCTAssertFalse(gate("tab.close", approve: true).confirmed)  // approved as write: never skips a confirmation
    // read risk runs with no prompt
    let read = gate("state.snapshot"); XCTAssertEqual(read.asked, 0); XCTAssertEqual(read.ran, 1)
  }

  func testInvalidInputFailsBeforePrompt() {
    let g = gate("pane.focus", ["id": .int(99)])
    XCTAssertEqual(g.asked + g.ran, 0)
  }

  func testAdapterListsOnlyAIAvailableAndIgnoresClaimedRisk() throws {
    var seen: WorkbenchIPCRequest?
    let list = try XCTUnwrap(MCPServer.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, call: { _ in WorkbenchIPCReply() }))
    XCTAssertTrue(list.contains("state.snapshot")); XCTAssertFalse(list.contains("agent.launch")); XCTAssertFalse(list.contains("settings.set"))
    let denied = MCPServer.respond(to: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"agent.launch","arguments":{"profile":"claude","risk":"read"}}}"#, call: { seen = $0; return WorkbenchIPCReply() })
    XCTAssertNil(seen); XCTAssertTrue(try XCTUnwrap(denied).contains("unknown tool"))
    _ = MCPServer.respond(to: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"pane.focus","arguments":{"id":1}}}"#, call: { seen = $0; return WorkbenchIPCReply() })
    XCTAssertEqual(seen?.via, .mcp)
    XCTAssertNil(MCPServer.respond(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, call: { _ in WorkbenchIPCReply() }))
  }

  /// Review finding: approval of a clean `tab.close` (write) must not discard a buffer that became dirty,
  /// or close a different tab, while the card was up.
  func testApprovalDoesNotCoverEscalationOrRetargeting() {
    let clean = WorkbenchState()
    var dirty = clean; dirty.dirty.insert(clean.active!)
    let escalated = gate("tab.close", state: clean, later: dirty, approve: true)
    XCTAssertEqual(escalated.ran, 0)
    if case .failure(let e) = escalated.0 { XCTAssertEqual(e.code, .denied) } else { XCTFail() }
    var switched = clean; switched.tabs.append("other.swift"); switched.active = "other.swift"
    XCTAssertEqual(gate("tab.close", state: clean, later: switched, approve: true).ran, 0)
    XCTAssertEqual(gate("tab.close", state: clean, later: clean, approve: true).ran, 1)
  }

  func testArgumentsKeepJSONTypesAndRejectNonScalars() throws {
    let a = try XCTUnwrap(MCPServer.arguments(["id": 1, "zero": 0, "flag": true, "off": false, "r": 0.5, "s": "x"] as [String: Any]))
    XCTAssertEqual(a["id"], .int(1)); XCTAssertEqual(a["zero"], .int(0))
    XCTAssertEqual(a["flag"], .bool(true)); XCTAssertEqual(a["off"], .bool(false))
    XCTAssertEqual(a["r"], .double(0.5)); XCTAssertEqual(a["s"], .string("x"))
    // Parsed from the wire, like the adapter does.
    var seen: WorkbenchIPCRequest?
    _ = MCPServer.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"pane.focus","arguments":{"id":1}}}"#, call: { seen = $0; return WorkbenchIPCReply() })
    XCTAssertEqual(seen?.input["id"], .int(1))
    seen = nil
    let null = MCPServer.respond(to: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"tab.close","arguments":{"path":null}}}"#, call: { seen = $0; return WorkbenchIPCReply() })
    XCTAssertNil(seen); XCTAssertTrue(try XCTUnwrap(null).contains("invalid arguments"))
  }
}
