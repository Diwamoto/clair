import Foundation
import XCTest
@testable import ClairWorkspace

final class AgentContextTokensTests: XCTestCase {
  func testLatestMainChainUsageAfterCompactSkippingSynthetic() throws {
    let (home, dir) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(dir, [
      #"{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":150000,"cache_creation_input_tokens":5000}}}"#,
      #"{"type":"user","message":{"content":"/compact"}}"#,
      #"{"type":"assistant","message":{"usage":{"input_tokens":3,"cache_read_input_tokens":0,"cache_creation_input_tokens":12000}}}"#,
      #"{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":99999}}}"#,
      // An API error writes a synthetic reply with all-zero usage last; the real usage before it wins.
      #"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
    ])
    XCTAssertEqual(AgentContext.claude(session: "abc-1", cwd: "/nonexistent", home: home, env: [:]).tokens, 12003)
    XCTAssertNil(AgentContext.claude(session: "missing", cwd: "/", home: home, env: [:]).tokens)
    XCTAssertNil(AgentContext.claude(session: "../x", cwd: "/", home: home, env: [:]).tokens)
  }

  func testLimitFollowsClaudeCodeModelPrecedence() throws {
    let (home, _) = try fixture()
    let cwd = home.appending(path: "repo")
    defer { try? FileManager.default.removeItem(at: home) }
    func limit(_ tokens: Int = 12_000, switched: String? = nil, env: [String: String] = [:]) -> Int? {
      AgentContext.limit(tokens, switched: switched, cwd: cwd.path, home: home, env: env)
    }
    XCTAssertNil(limit(), "no source names a model: unknown, not 200k")
    XCTAssertEqual(limit(300_000), 1_000_000, "usage past 200k proves 1M")
    try settings(home.appending(path: ".claude/settings.json"), "opus")
    XCTAssertNil(limit(), "an alias without [1m] may be 1M by default: unknown, not 200k")
    try settings(cwd.appending(path: ".claude/settings.json"), "opus[1m]")
    XCTAssertEqual(limit(), 1_000_000, "project settings outrank user")
    try settings(cwd.appending(path: ".claude/settings.local.json"), "sonnet")
    XCTAssertNil(limit(), "local settings outrank project")
    XCTAssertEqual(limit(env: ["ANTHROPIC_MODEL": "claude-opus-5-5[1m]"]), 1_000_000, "env outranks settings")
    XCTAssertEqual(limit(switched: "<local-command-stdout>Set model to `Opus 5.5 (1M context)`", env: ["ANTHROPIC_MODEL": "sonnet"]),
      1_000_000, "in-session /model outranks everything")
    // Real /model stdout names the display name only; it decides, and says nothing about the window.
    XCTAssertNil(limit(switched: "<local-command-stdout>Set model to `Opus 5.5` and saved as your default for new sessions</local-command-stdout>",
      env: ["ANTHROPIC_MODEL": "opus[1m]"]))
  }

  func testSessionModelSwitchIsReadFromTail() {
    let data = Data([
      #"{"type":"user","message":{"content":"<local-command-stdout>Set model to `opus[1m]`</local-command-stdout>"}}"#,
      #"{"type":"user","message":{"content":[{"type":"tool_result","content":"Set model to `x`"}]}}"#,
      #"{"type":"assistant","message":{"usage":{"input_tokens":5}}}"#,
    ].joined(separator: "\n").utf8)
    let r = AgentContext.scan(data)
    XCTAssertEqual(r.tokens, 5)
    XCTAssertEqual(r.model, "<local-command-stdout>Set model to `opus[1m]`</local-command-stdout>")
  }

  func testUnknownContextEncodesAsNull() throws {
    let row = WorkbenchAgent(key: "k", project: "p", pane: 1, profile: "codex", cwd: "/", status: "idle", exitCode: nil,
      activity: nil, delegated: false, parent: nil, concierge: false)
    let json = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
    XCTAssertTrue(json.contains(#""contextTokens":null"#) && json.contains(#""contextLimit":null"#), json)
  }

  private func fixture() throws -> (URL, URL) {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let dir = home.appending(path: ".claude/projects/-tmp-x")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (home, dir)
  }
  private func write(_ dir: URL, _ lines: [String]) throws {
    try lines.joined(separator: "\n").write(to: dir.appending(path: "abc-1.jsonl"), atomically: true, encoding: .utf8)
  }
  private func settings(_ url: URL, _ model: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"model":"\#(model)"}"#.write(to: url, atomically: true, encoding: .utf8)
  }
}
