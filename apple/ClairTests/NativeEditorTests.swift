import AppKit
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
    let fileURL = try fixture.makeFile(named: "notes.txt", content: "before\n")
    let document = fixture.makeDocument(at: fileURL)

    document.replaceContent("after\n")

    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(try String(contentsOf: fileURL), "before\n")

    document.undo()

    XCTAssertEqual(document.content, "before\n")
    XCTAssertFalse(document.isDirty)
    XCTAssertEqual(try String(contentsOf: fileURL), "before\n")

    document.replaceContent("after\n")
    try document.save()

    XCTAssertFalse(document.isDirty)
    XCTAssertEqual(try String(contentsOf: fileURL), "after\n")
  }

  func testEditorPreservesUnicodeEmojiAndCombiningTextAsUTF8() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "unicode.txt", content: "")
    let document = fixture.makeDocument(at: fileURL)
    let unicodeContent = "日本語🙂 🧑🏽‍💻 e\u{301} と é\n"

    document.replaceContent(unicodeContent)
    try document.save()

    XCTAssertEqual(try Data(contentsOf: fileURL), Data(unicodeContent.utf8))
    XCTAssertEqual(document.content, unicodeContent)
    XCTAssertFalse(document.isDirty)
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

  func testSyntaxHighlighterAppliesOneDarkColorsToTextStorage() {
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

    XCTAssertTrue(keywordColor?.isEqual(WorkspaceChrome.nsRGB(199, 131, 218)) == true)
    XCTAssertTrue(stringColor?.isEqual(WorkspaceChrome.nsRGB(152, 195, 121)) == true)
    XCTAssertTrue(commentColor?.isEqual(WorkspaceChrome.nsRGB(104, 117, 110)) == true)
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

  func testExternalDeletionRetainsTheTabAndItsBufferContent() throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "deleted.txt", content: "keep me\n")
    let document = fixture.makeDocument(at: fileURL)

    try FileManager.default.removeItem(at: fileURL)
    XCTAssertTrue(try document.refreshFromDisk())

    XCTAssertTrue(document.isMissing)
    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(document.content, "keep me\n")
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

  func testWatcherReloadsAnExternalRewriteWhenTheTabIsClean() async throws {
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
  }

  func testWatcherDoesNotClobberUnsavedEditsOnExternalRewrite() async throws {
    let fixture = try EditorFixture()
    let fileURL = try fixture.makeFile(named: "watched.txt", content: "before\n")
    let surface = ProjectSurfaceModel(
      projectID: fixture.projectID,
      rootURL: fixture.root
    )
    surface.select(nodeID: fileURL.standardizedFileURL.path)
    let document = try XCTUnwrap(surface.activeTab)
    document.replaceContent("unsaved\n")

    try Data("external\n".utf8).write(to: fileURL)

    await waitForDocument(document) { document in
      document.lastErrorMessage != nil
    }
    XCTAssertEqual(document.content, "unsaved\n")
    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(try String(contentsOf: fileURL), "external\n")
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

  func testMissingFileOpensEmptyEditableTab() throws {
    let fixture = try EditorFixture()
    let fileURL = fixture.root.appendingPathComponent("missing.txt")
    let tab = ProjectEditorTab(
      projectID: fixture.projectID,
      rootURL: fixture.root,
      url: fileURL
    )

    XCTAssertTrue(tab.isMissing)
    XCTAssertFalse(tab.isReadOnly)
    XCTAssertNil(tab.loadError)
    XCTAssertEqual(tab.content, "")
  }

  func testWatcherLoadsFileCreatedAfterOpeningMissingTab() async throws {
    let fixture = try EditorFixture()
    let fileURL = fixture.root.appendingPathComponent("created-later.txt")
    let document = ProjectEditorTab(
      projectID: fixture.projectID,
      rootURL: fixture.root,
      url: fileURL
    )

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
