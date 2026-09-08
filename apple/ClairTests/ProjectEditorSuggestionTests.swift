import Foundation
import XCTest

@testable import ClairApp

final class ProjectEditorSuggestionTests: XCTestCase {
  func testFakeProviderCreatesArbitraryInsertionDeletionAndReplacementEdits() async throws {
    let base = "zero\r\n🙂 old\r\nremove\r\nkeep\r\n"
    let proposed = "inserted\r\nzero\r\n🙂 new\r\nkeep\r\nadded\r\n"
    let provider = ProjectEditorFakeSuggestionProvider(proposedContent: proposed)
    let proposal = try await provider.propose(
      ProjectEditorSuggestionRequest(
        documentID: "doc", path: "fixture.txt", baseRevision: 4, baseContent: base
      )
    )

    XCTAssertEqual(proposal.baseRevision, 4)
    XCTAssertEqual(
      proposal.edits.map(\.replacementText), ["inserted\r\n", "🙂 new\r\n", "", "added\r\n"])
    XCTAssertEqual(proposal.edits.map(\.expectedText), ["", "🙂 old\r\n", "remove\r\n", ""])
    XCTAssertEqual(
      proposal.edits.map(\.range),
      [
        ProjectEditorUTF16Range(location: 0, length: 0),
        ProjectEditorUTF16Range(location: 6, length: 8),
        ProjectEditorUTF16Range(location: 14, length: 8),
        ProjectEditorUTF16Range(location: 28, length: 0),
      ])
  }

  func testLineApprovalAppliesAtomicallyAndOneUndoRestoresExactUnicodeBytes() throws {
    let base = "a\r\n🙂 old\r\nb"
    let proposed = "a\r\n🙂 new\r\nb\r\n"
    let document = ProjectEditorDocumentModel(content: base, revision: 7)
    let proposal = try ProjectEditorSuggestionModel.makeProposal(
      documentID: "doc", path: "fixture.txt", baseRevision: 7,
      baseContent: base, proposedContent: proposed
    )
    let applier = ProjectEditorSuggestionApplier()
    let changedLine = try XCTUnwrap(proposal.edits.first { $0.expectedText.contains("old") })

    let application = try applier.approve(
      proposal, selection: .line(id: changedLine.lineID), documentID: "doc", document: document
    )

    XCTAssertEqual(document.content, "a\r\n🙂 new\r\nb")
    XCTAssertEqual(application.change.undoUnit, .suggestion)
    XCTAssertNotNil(application.remainingProposal)
    XCTAssertNotEqual(application.remainingProposal?.edits.first?.id, proposal.edits.first?.id)

    _ = try applier.undoLast(documentID: "doc", document: document)
    XCTAssertEqual(document.content, base)
    XCTAssertEqual(document.revision, 9)
  }

  func testHunkApprovalAppliesAllRowsInTheHunkAndAllApprovalFinishesProposal() throws {
    let base = "one\ntwo\nthree\nfour\n"
    let proposed = "ONE\ntwo\nTHREE\nfour\n"
    let document = ProjectEditorDocumentModel(content: base)
    let proposal = try ProjectEditorSuggestionModel.makeProposal(
      documentID: "doc", path: "fixture.swift", baseRevision: 0,
      baseContent: base, proposedContent: proposed
    )
    XCTAssertEqual(proposal.hunkIDs.count, 2)
    let applier = ProjectEditorSuggestionApplier()
    let firstHunk = try XCTUnwrap(proposal.edits.first { $0.expectedText == "one\n" }?.hunkID)

    let partial = try applier.approve(
      proposal, selection: .hunk(id: firstHunk), documentID: "doc", document: document
    )
    XCTAssertEqual(document.content, "ONE\ntwo\nthree\nfour\n")
    XCTAssertEqual(partial.remainingProposal?.baseRevision, 1)
    XCTAssertEqual(partial.remainingProposal?.baseContent, document.content)

    let remaining = try XCTUnwrap(partial.remainingProposal)
    let completed = try applier.approve(
      remaining, selection: .all, documentID: "doc", document: document
    )
    XCTAssertNil(completed.remainingProposal)
    XCTAssertEqual(document.content, proposed)
  }

  func testRejectDoesNotMutateAndPartialLineSelectionReturnsUIError() throws {
    let document = ProjectEditorDocumentModel(content: "a\nb\n")
    let proposal = try ProjectEditorSuggestionModel.makeProposal(
      documentID: "doc", path: "a.txt", baseRevision: 0,
      baseContent: "a\nb\n", proposedContent: "a\nB\n"
    )
    let applier = ProjectEditorSuggestionApplier()

    XCTAssertEqual(applier.reject(proposal), .rejected)
    XCTAssertEqual(document.content, "a\nb\n")
    XCTAssertThrowsError(
      try applier.approve(
        proposal, selection: .range(ProjectEditorUTF16Range(location: 2, length: 1)),
        documentID: "doc", document: document
      )
    ) { error in
      XCTAssertEqual(
        error as? ProjectEditorSuggestionError,
        .unsupportedPartialSelection(ProjectEditorUTF16Range(location: 2, length: 1))
      )
    }
    XCTAssertEqual(document.revision, 0)
  }

  func testOldProposalIsRejectedAfterManualExternalAndUndoRevisionChanges() throws {
    let base = "before\n"
    let proposal = try ProjectEditorSuggestionModel.makeProposal(
      documentID: "doc", path: "a.txt", baseRevision: 0,
      baseContent: base, proposedContent: "after\n"
    )
    let applier = ProjectEditorSuggestionApplier()

    let manual = ProjectEditorDocumentModel(content: base)
    _ = try manual.apply(
      ProjectEditorTransaction(
        baseRevision: 0,
        edits: [ProjectEditorReplacement(range: .init(location: 0, length: 0), text: "x")],
        source: .user, undoUnit: .typing
      ))
    assertStale(proposal, applier: applier, document: manual)

    let external = ProjectEditorDocumentModel(content: base)
    external.replaceSnapshot(content: "external\n")
    assertStale(proposal, applier: applier, document: external)

    let undone = ProjectEditorDocumentModel(content: base)
    let applied = try applier.approve(proposal, documentID: "doc", document: undone)
    _ = try applier.undoLast(documentID: "doc", document: undone)
    XCTAssertEqual(undone.content, base)
    XCTAssertEqual(applied.change.revision, 1)
    assertStale(proposal, applier: applier, document: undone)
  }

  func testProposalPreservesTrailingNewlineAndUnicodeInFullApplication() throws {
    let base = "結合 e\u{301}\r\n🙂\r\n"
    let proposed = "結合 é\r\n🙂追加\r\n"
    let document = ProjectEditorDocumentModel(content: base, revision: 12)
    let proposal = try ProjectEditorSuggestionModel.makeProposal(
      documentID: "doc", path: "unicode.txt", baseRevision: 12,
      baseContent: base, proposedContent: proposed
    )
    let applier = ProjectEditorSuggestionApplier()
    _ = try applier.approve(proposal, documentID: "doc", document: document)
    XCTAssertEqual(document.content, proposed)
    XCTAssertEqual(Data(document.content.utf8), Data(proposed.utf8))
  }

  private func assertStale(
    _ proposal: ProjectEditorSuggestionProposal,
    applier: ProjectEditorSuggestionApplier,
    document: ProjectEditorDocumentModel
  ) {
    XCTAssertThrowsError(
      try applier.approve(proposal, documentID: "doc", document: document)
    ) { error in
      XCTAssertEqual(
        error as? ProjectEditorSuggestionError,
        .staleRevision(expected: proposal.baseRevision, actual: document.revision)
      )
    }
  }
}
