import Foundation
import XCTest
@testable import ClairWorkspace

final class AgentContextTokensTests: XCTestCase {
  func testLatestMainChainUsageAfterCompact() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let dir = home.appending(path: ".claude/projects/-tmp-x")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let lines = [
      #"{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":150000,"cache_creation_input_tokens":5000}}}"#,
      #"{"type":"user","message":{"content":"/compact"}}"#,
      #"{"type":"assistant","message":{"usage":{"input_tokens":3,"cache_read_input_tokens":0,"cache_creation_input_tokens":12000}}}"#,
      #"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0}}}"#,
      #"{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":99999}}}"#,
    ]
    try lines.joined(separator: "\n").write(to: dir.appending(path: "abc-1.jsonl"), atomically: true, encoding: .utf8)
    XCTAssertEqual(AgentContext.claudeTokens(session: "abc-1", home: home), 12003)
    XCTAssertNil(AgentContext.claudeTokens(session: "missing", home: home))
    XCTAssertNil(AgentContext.claudeTokens(session: "../x", home: home))
    XCTAssertNil(AgentContext.claudeLimit(12003, home: home))
    XCTAssertEqual(AgentContext.claudeLimit(300_000, home: home), 1_000_000)
    try #"{"model":"opus[1m]"}"#.write(to: home.appending(path: ".claude/settings.json"), atomically: true, encoding: .utf8)
    XCTAssertEqual(AgentContext.claudeLimit(12003, home: home), 1_000_000)
    let row = WorkbenchAgent(key: "k", project: "p", pane: 1, profile: "codex", cwd: "/", status: "idle", exitCode: nil,
      activity: nil, delegated: false, parent: nil, concierge: false)
    let json = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
    XCTAssertTrue(json.contains(#""contextTokens":null"#) && json.contains(#""contextLimit":null"#), json)
  }
}
