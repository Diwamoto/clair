import LanguageServerProtocol
import XCTest

@testable import ClairV2EditorCore
@testable import ClairV2EditorLanguage

final class EditorLanguageLSPTests: XCTestCase {
  private func initializedSession(uri: DocumentUri = "file:///doc.txt") throws -> LSPDocumentSession
  {
    let session = LSPDocumentSession(uri: uri, languageId: "plaintext")
    try session.beginInitialize()
    try session.serverInitialized()
    return session
  }

  func testDidOpenBeforeInitializedIsRejected() throws {
    let session = LSPDocumentSession(uri: "file:///doc.txt", languageId: "plaintext")
    let buffer = try TextBuffer("hi")
    XCTAssertThrowsError(try session.open(buffer.snapshot)) { error in
      XCTAssertEqual(
        error as? LSPSessionError,
        .invalidLifecycleTransition(from: .uninitialized, to: "didOpen"))
    }
  }

  func testOpenSetsVersionFromRevisionSequence() throws {
    let session = try initializedSession()
    let buffer = try TextBuffer("hello")
    let params = try session.open(buffer.snapshot)

    XCTAssertEqual(params.textDocument.version, 0)
    XCTAssertEqual(params.textDocument.text, "hello")
    XCTAssertEqual(session.version, 0)
    XCTAssertThrowsError(try session.open(buffer.snapshot)) { error in
      XCTAssertEqual(error as? LSPSessionError, .documentAlreadyOpen)
    }
  }

  func testChangeBeforeOpenIsRejected() throws {
    let session = try initializedSession()
    let buffer = try TextBuffer("hi")
    XCTAssertThrowsError(
      try session.change(edits: [], oldSnapshot: buffer.snapshot, newSnapshot: buffer.snapshot)
    ) { error in
      XCTAssertEqual(error as? LSPSessionError, .documentNotOpen)
    }
  }

  func testIncrementalChangeUsesUTF16Coordinates() throws {
    let session = try initializedSession()
    // "🎉" is one UTF-16 surrogate pair (2 code units) but 4 UTF-8 bytes;
    // this only produces the right LSP range if `change` converts through
    // UTF-16, not UTF-8 byte counts.
    let buffer = try TextBuffer("a🎉bc")
    let opened = try session.open(buffer.snapshot)
    XCTAssertEqual(opened.textDocument.version, 0)

    let old = buffer.snapshot
    let editRange = TextUTF8Range(UTF8Offset(5), UTF8Offset(6))  // the "b"
    let edit = ClairV2EditorCore.TextEdit(range: editRange, replacement: "X")
    try buffer.replace(edit.range, with: edit.replacement, basedOn: old.revision)
    let new = buffer.snapshot

    let params = try session.change(edits: [edit], oldSnapshot: old, newSnapshot: new)
    XCTAssertEqual(params.textDocument.version, 1)
    XCTAssertEqual(session.version, 1)
    XCTAssertEqual(params.contentChanges.count, 1)
    let change = try XCTUnwrap(params.contentChanges.first)
    XCTAssertEqual(change.text, "X")
    // "🎉" occupies UTF-16 offsets 1-2 (surrogate pair), so "b" is at
    // character 3, not byte offset 5.
    XCTAssertEqual(
      change.range,
      LSPRange(start: Position(line: 0, character: 3), end: Position(line: 0, character: 4)))
  }

  func testCloseRequiresOpenDocument() throws {
    let session = try initializedSession()
    XCTAssertThrowsError(try session.close()) { error in
      XCTAssertEqual(error as? LSPSessionError, .documentNotOpen)
    }
    let buffer = try TextBuffer("hi")
    try session.open(buffer.snapshot)
    XCTAssertNoThrow(try session.close())
  }

  func testShutdownAndExitLifecycle() throws {
    let session = try initializedSession()
    XCTAssertThrowsError(try session.exit()) { error in
      XCTAssertEqual(
        error as? LSPSessionError, .invalidLifecycleTransition(from: .initialized, to: "exit"))
    }
    try session.beginShutdown()
    XCTAssertEqual(session.lifecycle, .shuttingDown)
    try session.exit()
    XCTAssertEqual(session.lifecycle, .exited)
  }

  func testStaleDiagnosticsAreRejectedByVersion() throws {
    let session = try initializedSession()
    let buffer = try TextBuffer("a")
    try session.open(buffer.snapshot)  // version 0

    let old = buffer.snapshot
    try buffer.replace(
      TextUTF8Range(UTF8Offset(0), UTF8Offset(1)), with: "b", basedOn: old.revision)
    _ = try session.change(edits: [], oldSnapshot: old, newSnapshot: buffer.snapshot)  // version 1

    let stale = PublishDiagnosticsParams(
      uri: session.uri, version: 0, diagnostics: [Diagnostic(range: .zero, message: "stale")])
    let fresh = PublishDiagnosticsParams(
      uri: session.uri, version: 1, diagnostics: [Diagnostic(range: .zero, message: "fresh")])
    let unversioned = PublishDiagnosticsParams(
      uri: session.uri, diagnostics: [Diagnostic(range: .zero, message: "unversioned")])

    XCTAssertNil(session.accept(stale))
    XCTAssertEqual(session.accept(fresh)?.first?.message, "fresh")
    XCTAssertEqual(session.accept(unversioned)?.first?.message, "unversioned")
  }

  func testStaleCompletionResponseIsRejectedByRequestVersion() throws {
    let session = try initializedSession()
    let buffer = try TextBuffer("a")
    try session.open(buffer.snapshot)
    let requestVersion = session.version!

    let old = buffer.snapshot
    try buffer.replace(
      TextUTF8Range(UTF8Offset(0), UTF8Offset(1)), with: "b", basedOn: old.revision)
    _ = try session.change(edits: [], oldSnapshot: old, newSnapshot: buffer.snapshot)

    let response = CompletionList(isIncomplete: false, items: [])
    XCTAssertNil(session.accept(response, requestedAtVersion: requestVersion))
    XCTAssertNotNil(session.accept(response, requestedAtVersion: session.version!))
  }
}
