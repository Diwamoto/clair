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
      #"{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":99999}}}"#,
    ]
    try lines.joined(separator: "\n").write(to: dir.appending(path: "abc-1.jsonl"), atomically: true, encoding: .utf8)
    XCTAssertEqual(AgentContext.claudeTokens(session: "abc-1", home: home), 12003)
    XCTAssertNil(AgentContext.claudeTokens(session: "missing", home: home))
    XCTAssertNil(AgentContext.claudeTokens(session: "../x", home: home))
    XCTAssertEqual(AgentContext.claudeLimit(12003), 200_000)
    XCTAssertEqual(AgentContext.claudeLimit(300_000), 1_000_000)
  }
}
