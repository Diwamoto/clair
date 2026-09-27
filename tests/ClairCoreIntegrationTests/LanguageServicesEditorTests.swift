import AppKit
import Foundation
import Testing

@testable import ClairAppKit
@testable import ClairEditorCore
@testable import ClairEditorLanguage
@testable import ClairEditorView

/// E12: the app-side wiring (`LanguageServices` + `CompletionController` +
/// `ClairEditorView`) against a real gopls, the way `EditorSurface` hooks them
/// up. Skipped when gopls is not installed (`CLAIR_TEST_PATH` can point at one).
#if os(macOS)
  @MainActor @Suite(.serialized)
  struct LanguageServicesEditorTests {
    private func wait(_ timeout: Duration = .seconds(30), until done: () -> Bool) async -> Bool {
      let clock = ContinuousClock()
      let end = clock.now + timeout
      while clock.now < end {
        if done() { return true }
        try? await Task.sleep(for: .milliseconds(50))
      }
      return false
    }

    private func key(_ code: UInt16, _ chars: String) -> NSEvent {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func e12EditorDiagnosticsRebaseCompletionAcceptsAndDefinitionResolves() async throws {
      let searchPath = LanguageServerClientTests.path
      guard EditorLanguageID.go.languageServer!.resolve(path: searchPath) != nil else {
        print("E12: gopls not installed; skipping the editor wiring test")
        return
      }
      let root = FileManager.default.temporaryDirectory.appending(path: "clair-e12-app-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try "module example.com/e12\n\ngo 1.21\n".write(to: root.appending(path: "go.mod"), atomically: true, encoding: .utf8)
      let source = LanguageServerClientTests.source
      try source.write(to: root.appending(path: "main.go"), atomically: true, encoding: .utf8)
      let path = root.path + "/main.go"

      let services = LanguageServices(searchPath: searchPath)
      let manager = EditorTransactionManager(buffer: try TextBuffer(source), selection: TextSelectionSet(cursor: UTF8Offset(0)))
      let view = ClairEditorView(snapshot: manager.buffer.snapshot, selection: manager.selection)
      view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
      let completion = CompletionController(language: services, path: path, root: root.path)
      completion.view = view
      view.keyInterceptor = { completion.handle($0) }
      view.onCommitEdits = { edits in
        let old = manager.buffer.snapshot
        guard let new = try? manager.apply(edits) else { return }
        view.applyEdits(edits, oldSnapshot: old, newSnapshot: new, selection: manager.selection)
        services.change(path, root: root.path, edits: edits, old: old, new: new)
        completion.didEdit(edits)
      }
      services.attach(path, root: root.path, snapshot: manager.buffer.snapshot) { revision, spans in
        guard view.snapshot.revision == revision else { return }
        view.diagnostics = spans
      }

      // Diagnostics reach the view, with their message for the hover tooltip.
      #expect(await wait { view.diagnostics.contains { $0.message.contains("unused") } })
      let unused = try #require(view.diagnostics.first { $0.message.contains("unused") })
      #expect(try view.snapshot.text(in: unused.range) == "unused")

      // An edit above rebases the underline at once (INV-REV-004), before gopls republishes.
      view.onCommitEdits?([TextEdit(range: TextUTF8Range(UTF8Offset(0), UTF8Offset(0)), replacement: "// e12\n")])
      let moved = try #require(view.diagnostics.first { $0.message.contains("unused") })
      #expect(moved.range.lowerBound.value == unused.range.lowerBound.value + 7)
      #expect(try view.snapshot.text(in: moved.range) == "unused")
      #expect(await wait { services.statusText(path, root: root.path)?.text == "gopls" })

      // Type `_ = g` then `.` at the end of main: the `.` trigger opens the list, `H` filters it, Return accepts.
      #expect(await wait { completion.triggers.contains(".") })
      let end = UTF8Offset(view.snapshot.string().utf8.count - "}\n".utf8.count)
      manager.setSelection(TextSelectionSet(cursor: end))
      view.configure(snapshot: manager.buffer.snapshot, selection: manager.selection, diagnostics: view.diagnostics)
      view.onCommitEdits?(manager.selection.edits(replacingEachWith: "\t_ = g"))
      completion.dismiss()  // `g` alone may have opened it; the `.` is what this checks
      view.onCommitEdits?(manager.selection.edits(replacingEachWith: "."))
      #expect(await wait { completion.isOpen && completion.shown.contains { $0.label == "Hello" } })
      view.onCommitEdits?(manager.selection.edits(replacingEachWith: "H"))
      #expect(completion.shown.first?.label == "Hello")
      view.keyDown(with: key(36, "\r"))
      #expect(!completion.isOpen)
      #expect(view.snapshot.string().hasSuffix("\t_ = g.Hello}\n"))  // `_ = g.Hello}` is valid Go: a method value
      // One ordinary edit: the server gets it and republishes for exactly this revision.
      let accepted = view.snapshot.revision
      #expect(await wait { services.diagnostics[path]?.revision == accepted })

      // Definition of the accepted `Hello` is its declaration (0-based line 7 after the added header comment).
      let text = view.snapshot.string()
      let hello = UTF8Offset(text.utf8.count - "llo}\n".utf8.count)
      let defs = try #require(await services.definition(path, root: root.path, at: hello))
      #expect(defs.first?.path == path && defs.first?.line == 7)
      let greeter = UTF8Offset(text.utf8.distance(from: text.startIndex, to: text.range(of: "Greeter struct")!.lowerBound))
      #expect((await services.references(path, root: root.path, at: greeter) ?? []).count >= 3)
    }
  }
#endif
