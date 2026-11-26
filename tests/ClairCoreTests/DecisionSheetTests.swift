import Foundation
import Testing

@testable import ClairWorkspace

@Suite struct DecisionSheetTests {
  private static func card() throws -> String {
    let dir = URL.temporaryDirectory.appending(path: "clair-ask-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appending(path: "c"), withIntermediateDirectories: true)
    try Data("<p>a</p>".utf8).write(to: dir.appending(path: "c/a.html"))
    try Data("<p>x</p>".utf8).write(to: dir.appending(path: "outside.html"))
    return dir.appending(path: "c.md").path
  }

  @Test(arguments: [
    (#"{"questions":[]}"#, "1 to"),
    (#"{"questions":[{"id":"a","prompt":"p","options":[{"id":"x","label":"X"}]},{"id":"a","kind":"text","prompt":"p"}]}"#, "unique"),
    (#"{"questions":[{"id":"a","kind":"single","prompt":"p"}]}"#, "needs options"),
    (#"{"questions":[{"id":"a","kind":"text","prompt":"p","options":[{"id":"x","label":"X"}]}]}"#, "takes no options"),
    (#"{"questions":[{"id":"a","prompt":"p","options":[{"id":"x","label":"X"}],"recommended":"y"}]}"#, "recommended"),
    (#"{"questions":[{"id":"a","prompt":"p","options":[{"id":"x","label":"X","html":"../outside.html"}]}]}"#, "is not a file"),
    (#"{"questions":[{"id":"a","prompt":"p","options":[{"id":"x","label":"X","html":"missing.html"}]}]}"#, "is not a file"),
    ("not json", "must be JSON"),
  ])
  func rejects(json: String, why: String) throws {
    let card = try Self.card()
    do throws(CommandError) { _ = try DecisionSheet.validate(json, card: card); Issue.record("accepted: \(json)") }
    catch { #expect(error.message.contains(why), "\(json): \(error.message)") }
  }

  @Test func openShowsThePanelAndAnsweringClosesIt() throws {
    let card = try Self.card(), r = CommandRegistry.workbench
    try DecisionSheet.validate(#"{"questions":[{"id":"q","kind":"text","prompt":"?"}]}"#, card: card).save(card: card)
    var s = WorkbenchState(); let tabs = s.tabs
    _ = try r.execute("ask.open", ["card": .string(card)], state: &s).get()
    #expect(s.decisionSheet == card && s.tabs == tabs, "a panel, not a tab")
    #expect(throws: CommandError.self) {
      try r.execute("ask.answer", ["card": .string(card), "answers": .string("{}"), "notes": .string(#"{"zz":"x"}"#)], confirmed: true, state: &s).get()
    }
    _ = try r.execute("ask.answer", ["card": .string(card), "answers": .string("{}"), "notes": .string(#"{"q":" 理由 "}"#)],
                      confirmed: true, state: &s).get()
    #expect(s.decisionSheet == nil)
    #expect(try #require(DecisionSheet.load(card: card)).summary.contains("— 補足: 理由"))
  }

  @Test func acceptsAndAnswers() throws {
    let card = try Self.card()
    let json = #"{"title":"T","questions":[{"id":"how","prompt":"この方式で進めます","options":[{"id":"a","label":"A","html":"a.html"},{"id":"b","label":"B"}],"recommended":"a"},{"id":"tags","kind":"multi","prompt":"どれ","options":[{"id":"x","label":"X"},{"id":"y","label":"Y"}],"recommended":["x","y"]},{"id":"note","kind":"text","prompt":"文言"}]}"#
    var sheet = try DecisionSheet.validate(json, card: card)
    #expect(sheet.questions[0].options?[0].html?.hasSuffix("/c/a.html") == true && sheet.questions[0].options?[0].html?.hasPrefix("/") == true)
    #expect(sheet.questions[1].recommended == ["x", "y"])
    try sheet.save(card: card)
    #expect(DecisionSheet.pending(card: card))

    var loaded = try #require(DecisionSheet.load(card: card))
    do { _ = try loaded.checked(["how": ["a", "b"]]); Issue.record("two picks on a single question") } catch {}
    do { _ = try loaded.checked(["how": ["z"]]); Issue.record("an unknown option") } catch {}
    try loaded.answer(["how": ["b"], "tags": ["x", "y"], "note": [" "]], comment: "急ぎ", card: card)
    #expect(!DecisionSheet.pending(card: card))
    #expect(loaded.summary == "1. この方式で進めます → B\n2. どれ → X / Y\n3. 文言 → (回答なし — agent が決める)\nコメント: 急ぎ")
    #expect(!loaded.reply(card: card).contains("\n"))
    let log = try String(contentsOfFile: DecisionSheet.folder(card: card) + "/decisions.md", encoding: .utf8)
    #expect(log.hasPrefix("# 判断の記録") && log.contains("2. どれ → X / Y"))
    do { try loaded.answer([:], comment: nil, card: card); Issue.record("answered twice") } catch {}
  }

  @Test func aSymlinkedCardFolderGetsNoPreview() throws {
    let card = try Self.card()
    let elsewhere = URL(fileURLWithPath: (card as NSString).deletingLastPathComponent).appending(path: "linked.md").path
    try FileManager.default.createSymbolicLink(atPath: DecisionSheet.folder(card: elsewhere), withDestinationPath: DecisionSheet.folder(card: card))
    let json = #"{"questions":[{"id":"a","prompt":"p","options":[{"id":"x","label":"X","html":"a.html"}]}]}"#
    _ = try DecisionSheet.validate(json, card: card)
    do throws(CommandError) { _ = try DecisionSheet.validate(json, card: elsewhere); Issue.record("previewed through a symlinked folder") }
    catch { #expect(error.message.contains("is not a file")) }
  }

  @Test func aPendingSheetHoldsTheCard() throws {
    let card = try Self.card()
    try DecisionSheet.validate(#"{"questions":[{"id":"q","kind":"text","prompt":"?"}]}"#, card: card).save(card: card)
    let c = WorkbenchState().board([ClairTodo(path: card, title: "c").with { $0.agent = "/gone#1" }]).cards.first
    #expect(c?.state == .blocked && c?.asking == 1)
    // A done card still says the owner has something to decide.
    let done = WorkbenchState().board([ClairTodo(path: card, title: "c").with { $0.result = "ok"; $0.doneAt = ISO8601DateFormatter().string(from: .now) }]).cards.first
    #expect(done?.state == .done && done?.asking == 1)
  }
}
