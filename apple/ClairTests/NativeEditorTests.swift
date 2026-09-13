import AppKit
import Combine
import Foundation
import XCTest

@testable import ClairApp

@MainActor
final class NativeEditorTests: XCTestCase {
  func testAppKitNativeEditorRequiresExplicitDevOptIn() {
    let suiteName = "clair-native-editor-engine-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    XCTAssertFalse(
      ProjectEditorEngine.usesAppKitNativeEditor(
        defaults: defaults,
        environment: [:]
      )
    )
    XCTAssertTrue(
      ProjectEditorEngine.usesAppKitNativeEditor(
        defaults: defaults,
        environment: ["CLAIR_NATIVE_EDITOR": "1"]
      )
    )

    defaults.set(false, forKey: ProjectEditorEngine.nativeOptInDefaultsKey)
    XCTAssertFalse(
      ProjectEditorEngine.usesAppKitNativeEditor(
        defaults: defaults,
        environment: ["CLAIR_NATIVE_EDITOR": "1"]
      )
    )
  }

  func testEditorSavesOnlyAfterExplicitSaveAndUndoRestoresCleanState() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "notes.txt", content: "before 日本語 e\u{301}\n")
    let document = fixture.makeDocument(at: fileURL)

    document.replaceContent("after 🧑🏽‍💻 é\n")

    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(try String(contentsOf: fileURL), "before 日本語 e\u{301}\n")

    document.undo()

    XCTAssertEqual(document.content, "before 日本語 e\u{301}\n")
    XCTAssertFalse(document.isDirty)
    XCTAssertEqual(try String(contentsOf: fileURL), "before 日本語 e\u{301}\n")

    document.replaceContent("after 🧑🏽‍💻 é\n")
    try document.save()

    XCTAssertFalse(document.isDirty)
    XCTAssertEqual(try Data(contentsOf: fileURL), Data("after 🧑🏽‍💻 é\n".utf8))
  }

  func testTypingDoesNotPublishBufferForEveryKeystroke() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "typing.txt", content: "")
    let document = fixture.makeDocument(at: fileURL)
    var publicationCount = 0
    let cancellable = document.objectWillChange.sink { _ in
      publicationCount += 1
    }

    _ = try document.applyEditorChange(
      ProjectEditorWebChange(
        baseRevision: document.editorRevision,
        changes: [ProjectEditorWebEdit(from: 0, to: 0, insert: "日")],
        selection: ProjectEditorWebSelection(from: 1, to: 1),
        canUndo: true,
        canRedo: false
      ))
    let firstEditPublicationCount = publicationCount

    _ = try document.applyEditorChange(
      ProjectEditorWebChange(
        baseRevision: document.editorRevision,
        changes: [ProjectEditorWebEdit(from: 1, to: 1, insert: "本")],
        selection: ProjectEditorWebSelection(from: 2, to: 2),
        canUndo: true,
        canRedo: false
      ))

    XCTAssertGreaterThan(firstEditPublicationCount, 0)
    XCTAssertEqual(publicationCount, firstEditPublicationCount)
    XCTAssertEqual(document.content, "日本")

    let tokenBeforeReplacement = document.contentSyncToken
    document.replaceContent("外部置換")
    XCTAssertEqual(document.content, "外部置換")
    XCTAssertGreaterThan(document.contentSyncToken, tokenBeforeReplacement)
    XCTAssertGreaterThan(publicationCount, firstEditPublicationCount)

    withExtendedLifetime(cancellable) {}
  }

  func testMarkedTextCommitUpdatesTheDocumentOnce() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "ime.txt", content: "")
    let document = fixture.makeDocument(at: fileURL)
    let coordinator = ProjectSourceEditorView.Coordinator(document: document)
    let textView = NSTextView(frame: .zero)
    coordinator.textView = textView
    textView.delegate = coordinator
    textView.string = ""

    textView.setMarkedText(
      "日本",
      selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: 0, length: 0)
    )
    XCTAssertTrue(textView.hasMarkedText())

    textView.insertText("日本語", replacementRange: textView.markedRange())
    coordinator.textViewDidChange(Notification(name: NSText.didChangeNotification))

    XCTAssertFalse(textView.hasMarkedText())
    XCTAssertEqual(textView.string, "日本語")
    XCTAssertEqual(document.content, "日本語")
  }

  func testAppKitFallbackLineNumberModelHandlesEmptyAndMultilineText() {
    XCTAssertEqual(
      ProjectSourceLineNumberRulerView.lineNumber(
        atCharacterIndex: 0,
        in: "" as NSString
      ),
      1
    )
    XCTAssertEqual(
      ProjectSourceLineNumberRulerView.lineNumber(
        atCharacterIndex: 4,
        in: "one\n日本\nlast" as NSString
      ),
      2
    )
    XCTAssertEqual(
      ProjectSourceLineNumberRulerView.lineNumber(
        atCharacterIndex: 8,
        in: "one\n日本\nlast" as NSString
      ),
      3
    )
  }

  func testAppKitFallbackLineNumbersUseAStableDedicatedRuler() {
    let scrollView = NSScrollView(frame: .zero)
    let textView = NSTextView(frame: .zero)
    scrollView.documentView = textView
    let ruler = ProjectSourceLineNumberRulerView(
      scrollView: scrollView,
      textView: textView
    )
    scrollView.verticalRulerView = ruler

    XCTAssertTrue(ruler.clientView === textView)
    XCTAssertEqual(ruler.ruleThickness, ProjectSourceLineNumberRulerView.ruleThickness)
  }

  func testAppKitFallbackModelSyncClampsCaretWithoutReenteringDelegate() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "sync.txt", content: "long buffer\n")
    let document = fixture.makeDocument(at: fileURL)
    let coordinator = ProjectSourceEditorView.Coordinator(document: document)
    let textView = NSTextView(frame: .zero)
    textView.string = document.content
    textView.delegate = coordinator
    coordinator.textView = textView
    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

    document.replaceContent("短")
    coordinator.synchronizeTextViewFromModel(textView)

    XCTAssertEqual(textView.string, "短")
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertEqual(document.content, "短")
    XCTAssertFalse(coordinator.isUpdatingFromModel)
  }

  func testSearchSelectionConvertsLineAndCharacterColumnToUTF16Range() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "selection.txt", content: "one\n日本Hello\nlast\n")
    let document = fixture.makeDocument(at: fileURL)

    let range = document.selectionRange(
      for: ProjectEditorSelection(line: 2, column: 3, length: 5)
    )

    XCTAssertEqual(range, NSRange(location: 6, length: 5))
  }

  func testSyntaxHighlighterRecognizesSwiftTokensWithoutHighlightingStringContents() {
    let source = """
      import SwiftUI
      // note
      @MainActor
      struct Demo: View {
        let title = "return is only text here"
        func run(value: Int) -> String {
          return "done"
        }
      }
      """

    let tokens = ProjectSourceSyntaxHighlighter.tokens(
      in: source,
      fileExtension: "swift"
    )
    let text = source as NSString
    func tokenTexts(_ kind: ProjectSourceSyntaxTokenKind) -> [String] {
      tokens
        .filter { $0.kind == kind }
        .map { text.substring(with: $0.range) }
    }

    XCTAssertEqual(tokenTexts(.keyword), ["import", "struct", "let", "func", "return"])
    XCTAssertEqual(tokenTexts(.comment), ["// note"])
    XCTAssertEqual(tokenTexts(.attribute), ["@MainActor"])
    XCTAssertEqual(tokenTexts(.string), ["\"return is only text here\"", "\"done\""])
    XCTAssertEqual(tokenTexts(.function), ["run"])
    XCTAssertTrue(tokenTexts(.type).contains("SwiftUI"))
    XCTAssertTrue(tokenTexts(.type).contains("Demo"))
    XCTAssertTrue(tokenTexts(.type).contains("View"))
    XCTAssertTrue(tokenTexts(.type).contains("Int"))
    XCTAssertTrue(tokenTexts(.type).contains("String"))
  }

  func testSyntaxHighlighterAppliesDistinctTokenColorsAndPreservesFont() {
    let source = "let value = \"ok\" // note\n"
    let storage = NSTextStorage(string: source)
    let font = NSFont.monospacedSystemFont(ofSize: 14.5, weight: .regular)

    ProjectSourceSyntaxHighlighter.apply(
      to: storage,
      fileExtension: "swift",
      baseFont: font
    )

    let keywordColor =
      storage.attribute(
        .foregroundColor,
        at: 0,
        effectiveRange: nil
      ) as? NSColor
    let stringStart = (source as NSString).range(of: "\"ok\"").location
    let stringColor =
      storage.attribute(
        .foregroundColor,
        at: stringStart,
        effectiveRange: nil
      ) as? NSColor
    let commentStart = (source as NSString).range(of: "// note").location
    let commentColor =
      storage.attribute(
        .foregroundColor,
        at: commentStart,
        effectiveRange: nil
      ) as? NSColor

    XCTAssertNotNil(keywordColor)
    XCTAssertNotNil(stringColor)
    XCTAssertNotNil(commentColor)
    XCTAssertNotEqual(keywordColor, stringColor)
    XCTAssertNotEqual(stringColor, commentColor)
    XCTAssertNotEqual(keywordColor, commentColor)
    XCTAssertEqual(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
  }

  func testExternalRewriteWinsWhenTheTabHasNoUnsavedEdits() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "agent.txt", content: "disk-v1\n")
    let document = fixture.makeDocument(at: fileURL)

    try Data("disk-v2 from agent\n".utf8).write(to: fileURL)
    XCTAssertTrue(try document.refreshFromDisk())

    XCTAssertEqual(document.content, "disk-v2 from agent\n")
    XCTAssertFalse(document.isDirty)
  }

  func testExternalRewriteDoesNotClobberUnsavedEdits() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "agent.txt", content: "disk-v1\n")
    let document = fixture.makeDocument(at: fileURL)
    document.replaceContent("unsaved-v2 日本語\n")

    try Data("disk-v3 from agent\n".utf8).write(to: fileURL)
    XCTAssertFalse(try document.refreshFromDisk())

    XCTAssertEqual(document.content, "unsaved-v2 日本語\n")
    XCTAssertTrue(document.isDirty)
    XCTAssertNotNil(document.lastErrorMessage)
    XCTAssertEqual(try String(contentsOf: fileURL), "disk-v3 from agent\n")
  }

  func testSaveRefusesToOverwriteAnExternalChangeAndKeepsTheUnsavedBuffer() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "conflict.txt", content: "disk-v1\n")
    let document = fixture.makeDocument(at: fileURL)
    document.replaceContent("unsaved-v2\n")

    try Data("disk-v3 from agent\n".utf8).write(to: fileURL)

    XCTAssertThrowsError(try document.save()) { error in
      XCTAssertEqual(
        error as? ProjectEditorError,
        .externalChangeDetected(path: fileURL.standardizedFileURL.path)
      )
    }
    XCTAssertEqual(try String(contentsOf: fileURL), "disk-v3 from agent\n")
    XCTAssertEqual(document.content, "unsaved-v2\n")
    XCTAssertTrue(document.isDirty)
  }

  func testSurfaceKeepsMultipleEditorTabsIndependent() throws {
    let fixture = try EditorFixture()
    let firstURL = try fixture.makeFile(named: "first.txt", content: "one\n")
    let secondURL = try fixture.makeFile(named: "second.txt", content: "two\n")
    let surface = ProjectSurfaceModel(
      projectID: fixture.projectID,
      rootURL: fixture.root
    )

    surface.select(nodeID: firstURL.standardizedFileURL.path)
    let first = try XCTUnwrap(surface.activeTab)
    surface.select(nodeID: secondURL.standardizedFileURL.path)
    let second = try XCTUnwrap(surface.activeTab)
    first.replaceContent("edited one\n")

    XCTAssertEqual(surface.editorTabs.map(\.id), [first.id, second.id])
    XCTAssertEqual(first.content, "edited one\n")
    XCTAssertEqual(second.content, "two\n")
    XCTAssertTrue(first.isDirty)
    XCTAssertFalse(second.isDirty)
  }

  func testWatcherReloadsCleanContentAndPreservesSubsequentUnsavedEdits() async throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "watched.txt", content: "before\n")
    let surface = ProjectSurfaceModel(
      projectID: fixture.projectID,
      rootURL: fixture.root
    )
    surface.select(nodeID: fileURL.standardizedFileURL.path)
    let document = try XCTUnwrap(surface.activeTab)

    try Data("external\n".utf8).write(to: fileURL)

    await waitForDocument(document) { document in
      document.content == "external\n" && !document.isDirty
    }
    document.replaceContent("unsaved\n")
    try Data("second external\n".utf8).write(to: fileURL)
    await waitForDocument(document) { $0.lastErrorMessage != nil }
    XCTAssertEqual(document.content, "unsaved\n")
    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(try String(contentsOf: fileURL), "second external\n")
  }

  func testWatcherKeepsWatchingAfterExternalDeletionAndRecreation() async throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "watched.txt", content: "before\n")
    let surface = ProjectSurfaceModel(
      projectID: fixture.projectID,
      rootURL: fixture.root
    )
    surface.select(nodeID: fileURL.standardizedFileURL.path)
    let document = try XCTUnwrap(surface.activeTab)

    try FileManager.default.removeItem(at: fileURL)
    await waitForDocument(document) { document in
      document.isMissing
    }
    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(document.content, "before\n")

    try Data("recreated\n".utf8).write(to: fileURL)
    await waitForDocument(document) { document in
      document.lastErrorMessage != nil
    }

    // Recreating the path must not silently replace the tab's buffer. The
    // user still needs to resolve the external-change conflict explicitly.
    XCTAssertEqual(document.content, "before\n")
    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(try String(contentsOf: fileURL), "recreated\n")
  }

  func testNonUTF8FileOpensReadOnlyErrorTab() throws {
    let fixture = try EditorFixture()
    let fileURL = fixture.root.appendingPathComponent("binary.bin")
    try Data([0xFF, 0xFE, 0x00]).write(to: fileURL)
    let surface = ProjectSurfaceModel(
      projectID: fixture.projectID,
      rootURL: fixture.root
    )

    surface.select(nodeID: fileURL.standardizedFileURL.path)

    let tab = try XCTUnwrap(surface.activeTab)
    XCTAssertTrue(tab.isReadOnly)
    XCTAssertNotNil(tab.loadError)
    XCTAssertNil(surface.lastEditorErrorMessage)
  }

  func testWatcherLoadsFileCreatedAfterOpeningMissingTab() async throws {
    let fixture = try EditorFixture()
    let fileURL = fixture.root.appendingPathComponent("created-later.txt")
    let document = ProjectEditorTab(
      projectID: fixture.projectID,
      rootURL: fixture.root,
      url: fileURL
    )

    XCTAssertTrue(document.isMissing)
    XCTAssertFalse(document.isReadOnly)
    XCTAssertNil(document.loadError)
    XCTAssertEqual(document.content, "")
    try Data("created\n".utf8).write(to: fileURL)
    await waitForDocument(document) { document in
      document.content == "created\n" && !document.isMissing && !document.isDirty
    }
  }

  private func waitForDocument(
    _ document: ProjectEditorTab,
    timeout: TimeInterval = 3,
    matching predicate: (ProjectEditorTab) -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate(document) {
        return
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Timed out waiting for editor refresh", file: file, line: line)
  }
}

@MainActor
private final class EditorFixture {
  let projectID = UUID()
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clair-native-editor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
  }

  func makeFile(named name: String, content: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data(content.utf8).write(to: url)
    return url
  }

  func makeDocument(at url: URL) -> ProjectEditorTab {
    ProjectEditorTab(
      projectID: projectID,
      rootURL: root,
      url: url
    )
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }
}
