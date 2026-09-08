import Foundation

/// The UTF-16 edit envelope exchanged by the CodeMirror bridge.
///
/// CodeMirror positions are UTF-16 offsets, matching the document contract.
/// Every edit in one message addresses the same pre-edit revision; this is
/// important for multi-range IME, paste, and multi-cursor transactions.
struct ProjectEditorWebEdit: Codable, Equatable, Sendable {
  let from: Int
  let to: Int
  let insert: String

  init(from: Int, to: Int, insert: String) {
    self.from = from
    self.to = to
    self.insert = insert
  }

  var replacement: ProjectEditorReplacement {
    ProjectEditorReplacement(
      range: ProjectEditorUTF16Range(
        location: from,
        length: to - from
      ),
      text: insert
    )
  }
}

struct ProjectEditorWebSelection: Codable, Equatable, Sendable {
  let from: Int
  let to: Int

  init(from: Int, to: Int) {
    self.from = from
    self.to = to
  }

  var range: ProjectEditorUTF16Range {
    ProjectEditorUTF16Range(
      location: from,
      length: to - from
    )
  }
}

struct ProjectEditorWebChange: Codable, Equatable, Sendable {
  let baseRevision: UInt64
  let changes: [ProjectEditorWebEdit]
  let selection: ProjectEditorWebSelection
  let canUndo: Bool
  let canRedo: Bool

  init(
    baseRevision: UInt64,
    changes: [ProjectEditorWebEdit],
    selection: ProjectEditorWebSelection,
    canUndo: Bool,
    canRedo: Bool
  ) {
    self.baseRevision = baseRevision
    self.changes = changes
    self.selection = selection
    self.canUndo = canUndo
    self.canRedo = canRedo
  }

  func transaction(
    source: ProjectEditorChangeSource = .user,
    undoUnit: ProjectEditorUndoUnit = .typing
  ) -> ProjectEditorTransaction {
    ProjectEditorTransaction(
      baseRevision: baseRevision,
      edits: changes.map(\.replacement),
      source: source,
      undoUnit: undoUnit
    )
  }
}

struct ProjectEditorWebSelectionChange: Codable, Equatable, Sendable {
  let selection: ProjectEditorWebSelection
  let canUndo: Bool
  let canRedo: Bool
}

extension ProjectEditorWebChange {
  init?(messageBody: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(messageBody),
      let data = try? JSONSerialization.data(withJSONObject: messageBody),
      let decoded = try? JSONDecoder().decode(Self.self, from: data)
    else {
      return nil
    }
    self = decoded
  }
}

extension ProjectEditorWebSelectionChange {
  init?(messageBody: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(messageBody),
      let data = try? JSONSerialization.data(withJSONObject: messageBody),
      let decoded = try? JSONDecoder().decode(Self.self, from: data)
    else {
      return nil
    }
    self = decoded
  }
}

/// Pure bridge state used by the native adapter and by contract tests.
///
/// Selection-only events never capture a document snapshot or advance the
/// revision. A rejected edit leaves both the text and the revision untouched,
/// allowing the host to send an explicit full snapshot back to WebKit.
final class ProjectEditorWebBridgeModel {
  let document: ProjectEditorDocumentModel

  init(content: String, revision: UInt64 = 0) {
    document = ProjectEditorDocumentModel(content: content, revision: revision)
  }

  var content: String {
    document.content
  }

  var revision: UInt64 {
    document.revision
  }

  @discardableResult
  func apply(
    _ change: ProjectEditorWebChange,
    source: ProjectEditorChangeSource = .user,
    undoUnit: ProjectEditorUndoUnit = .typing
  ) throws -> ProjectEditorDocumentChange {
    let transaction = change.transaction(source: source, undoUnit: undoUnit)
    let documentChange = try document.apply(transaction)

    // CodeMirror reports the post-transaction selection. An invalid selection
    // must not undo an accepted text transaction; the next full resync will
    // provide a valid selection if a broken bridge ever sends one.
    try? document.setSelection(change.selection.range)
    return documentChange
  }

  func applySelection(_ change: ProjectEditorWebSelectionChange) throws {
    try document.setSelection(change.selection.range)
  }

  func replaceSnapshot(content: String, revision: UInt64? = nil) {
    document.replaceSnapshot(content: content, revision: revision)
  }
}
