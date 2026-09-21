/// Applies edits to a `TextBuffer` as transactions, tracks a `TextSelectionSet`
/// through them, and maintains an Undo/Redo stack. One call to `apply` — however
/// many simultaneous multi-cursor edits it carries — is exactly one undo unit.
///
/// Not Sendable, for the same reason as `TextBuffer`: keep it on its owning actor.
public final class EditorTransactionManager {
  public let buffer: TextBuffer
  public private(set) var selection: TextSelectionSet

  private struct UndoEntry {
    var label: String?
    var forward: [TextEdit]
    var inverse: [TextEdit]
    var selectionBefore: TextSelectionSet
    var selectionAfter: TextSelectionSet
  }

  private var undoStack: [UndoEntry] = []
  private var redoStack: [UndoEntry] = []

  public init(buffer: TextBuffer, selection: TextSelectionSet) {
    self.buffer = buffer
    self.selection = selection
  }

  public var canUndo: Bool { !undoStack.isEmpty }
  public var canRedo: Bool { !redoStack.isEmpty }

  /// The edits actually written to the buffer by the most recent `apply`,
  /// `applyExternal`, `undo`, or `redo` call, in the coordinate space that
  /// was current immediately before that call. Lets a caller that owns
  /// out-of-band position state (e.g. `ReviewThreadManager`) rebase through
  /// exactly what changed — including an undo/redo's own inverse edits,
  /// which are not otherwise observable from outside.
  public private(set) var lastCommittedEdits: [TextEdit] = []

  /// Updates the tracked selection without creating an edit or undo entry
  /// — e.g. after a caret move or mouse drag that never touched the
  /// buffer (E07). `apply`/`applyExternal` map *this* selection through
  /// their edits as the pre-transaction state, so a host must keep it in
  /// sync with view-only selection changes for a later `apply` (typing,
  /// paste, …) to report the right post-edit selection.
  public func setSelection(_ selection: TextSelectionSet) {
    self.selection = selection
  }

  /// Applies `edits` as one transaction: one undo unit, and `selection` mapped
  /// through all of them together. Ranges are given in the buffer's current
  /// coordinate space and must be mutually non-overlapping and grapheme-aligned;
  /// nothing is written until every edit in the batch validates.
  /// The label of the most recent undo entry, if any. Useful for callers that
  /// route specific operations (e.g. AI suggestion apply) through the manager
  /// and need to know whether the next `undo()` will revert that operation.
  public var lastUndoLabel: String? { undoStack.last?.label }

  @discardableResult
  public func apply(_ edits: [TextEdit], label: String? = nil) throws -> TextSnapshot {
    let sorted = try TextEdit.sortedNonOverlapping(edits)
    let before = buffer.snapshot
    try Self.validateBoundaries(sorted, in: before)
    let inverse = try Self.inverse(of: sorted, in: before)
    try Self.commit(sorted, to: buffer)
    let selectionBefore = selection
    selection = selection.mapped(through: sorted)
    undoStack.append(
      UndoEntry(
        label: label, forward: sorted, inverse: inverse,
        selectionBefore: selectionBefore, selectionAfter: selection))
    redoStack.removeAll()
    lastCommittedEdits = sorted
    return buffer.snapshot
  }

  /// Applies an edit this manager did not originate (a file-watcher reload, an
  /// agent-applied patch) without creating an undo unit for it. Every pending
  /// undo/redo entry and the live selection are rebased through it so a later
  /// Undo still targets the right bytes.
  ///
  /// ponytail: an undo entry whose own edited range overlaps the external edit
  /// can no longer be cleanly inverted and is dropped rather than risking
  /// corruption; that one historical step becomes permanent. A full three-way
  /// merge of conflicting edits is out of scope for D5 — upgrade here if
  /// interactive conflict resolution becomes a product requirement.
  @discardableResult
  public func applyExternal(_ edits: [TextEdit]) throws -> TextSnapshot {
    let sorted = try TextEdit.sortedNonOverlapping(edits)
    try Self.validateBoundaries(sorted, in: buffer.snapshot)
    try Self.commit(sorted, to: buffer)
    selection = selection.mapped(through: sorted)
    undoStack = undoStack.compactMap { Self.rebase($0, through: sorted) }
    redoStack = redoStack.compactMap { Self.rebase($0, through: sorted) }
    lastCommittedEdits = sorted
    return buffer.snapshot
  }

  @discardableResult
  public func undo() throws -> TextSnapshot? {
    guard let entry = undoStack.popLast() else { return nil }
    try Self.commit(entry.inverse, to: buffer)
    selection = entry.selectionBefore
    redoStack.append(entry)
    lastCommittedEdits = entry.inverse
    return buffer.snapshot
  }

  @discardableResult
  public func redo() throws -> TextSnapshot? {
    guard let entry = redoStack.popLast() else { return nil }
    try Self.commit(entry.forward, to: buffer)
    selection = entry.selectionAfter
    undoStack.append(entry)
    lastCommittedEdits = entry.forward
    return buffer.snapshot
  }

  private static func validateBoundaries(_ edits: [TextEdit], in snapshot: TextSnapshot) throws {
    for edit in edits {
      _ = try snapshot.convert(edit.range.lowerBound, to: GraphemeUnit.self)
      _ = try snapshot.convert(edit.range.upperBound, to: GraphemeUnit.self)
    }
  }

  /// Applies edits highest-offset-first so each one's range, still expressed in
  /// the pre-transaction coordinate space, is valid at the moment it is used:
  /// nothing below an already-applied edit has moved yet.
  private static func commit(_ sortedEdits: [TextEdit], to buffer: TextBuffer) throws {
    for edit in sortedEdits.reversed() {
      try buffer.replace(edit.range, with: edit.replacement, basedOn: buffer.snapshot.revision)
    }
  }

  /// Builds the edits that undo `sortedEdits`, expressed in the coordinate
  /// space the document will be in *after* they are applied.
  private static func inverse(of sortedEdits: [TextEdit], in snapshot: TextSnapshot) throws
    -> [TextEdit]
  {
    var delta = 0
    var result: [TextEdit] = []
    result.reserveCapacity(sortedEdits.count)
    for edit in sortedEdits {
      let old = try snapshot.text(in: edit.range)
      let start = edit.range.lowerBound.value + delta
      let end = start + edit.insertedUTF8Count
      result.append(
        TextEdit(range: TextUTF8Range(UTF8Offset(start), UTF8Offset(end)), replacement: old))
      delta += edit.insertedUTF8Count - (edit.range.upperBound.value - edit.range.lowerBound.value)
    }
    return result
  }

  private static func rebase(_ entry: UndoEntry, through edits: [TextEdit]) -> UndoEntry? {
    guard !entry.inverse.contains(where: { overlaps($0.range, edits) }) else { return nil }
    return UndoEntry(
      label: entry.label,
      forward: mapEdits(entry.forward, through: edits),
      inverse: mapEdits(entry.inverse, through: edits),
      selectionBefore: entry.selectionBefore.mapped(through: edits),
      selectionAfter: entry.selectionAfter.mapped(through: edits)
    )
  }

  private static func mapEdits(_ edits: [TextEdit], through mapping: [TextEdit]) -> [TextEdit] {
    edits.map { edit in
      TextEdit(
        range: TextUTF8Range(
          UTF8Offset(TextEdit.map(edit.range.lowerBound.value, through: mapping)),
          UTF8Offset(TextEdit.map(edit.range.upperBound.value, through: mapping))
        ),
        replacement: edit.replacement
      )
    }
  }

  private static func overlaps(_ range: TextUTF8Range, _ edits: [TextEdit]) -> Bool {
    edits.contains {
      range.lowerBound.value < $0.range.upperBound.value
        && $0.range.lowerBound.value < range.upperBound.value
    }
  }
}
