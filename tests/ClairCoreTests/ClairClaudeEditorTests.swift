import ClairWorkspace
import XCTest

final class ClairClaudeEditorTests: XCTestCase {
  func testInstallKeepsOtherSettingsAndNeverClobbers() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = ClairClaudeEditor.settings(home: home)
    try ClairClaudeEditor.install(home: home)  // no file yet
    XCTAssertTrue(ClairClaudeEditor.isInstalled(home: home))
    try Data(#"{"model":"opus","env":{"FOO":"1","VISUAL":"clair open --wait"}}"#.utf8).write(to: url)
    try ClairClaudeEditor.uninstall(home: home)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    XCTAssertEqual(json["model"] as? String, "opus"); XCTAssertEqual(json["env"] as? [String: String], ["FOO": "1"])

    try Data(#"{"env":{"VISUAL":"vim"}}"#.utf8).write(to: url)
    XCTAssertThrowsError(try ClairClaudeEditor.install(home: home))  // someone else's editor
    try ClairClaudeEditor.uninstall(home: home)  // not ours: untouched
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), #"{"env":{"VISUAL":"vim"}}"#)

    try Data("{ // comment".utf8).write(to: url)
    XCTAssertThrowsError(try ClairClaudeEditor.install(home: home))  // unreadable: never overwritten
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ // comment")
  }
}
