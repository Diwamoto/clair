import ClairEditorCore

/// `INV-RVW-004`: once stale or orphaned, an anchor never reverts to
/// `.attached` automatically — only an explicit re-attach (not modeled here)
/// can do that.
public enum ReviewAnchorState: Sendable, Equatable {
  case attached
  case stale
  case orphaned
}

/// A UTF-8 range shared by comments and AI suggestion hunks so they all move
/// through edits identically (`INV-RVW-001`).
public struct ReviewAnchor: Sendable, Equatable {
  public private(set) var range: TextUTF8Range
  public private(set) var state: ReviewAnchorState

  public init(range: TextUTF8Range, state: ReviewAnchorState = .attached) {
    self.range = range
    self.state = state
  }

  public var isAttached: Bool { state == .attached }

  /// Rebases through one transaction's edits (`INV-RVW-002`, `INV-RVW-003`).
  /// A no-op once the anchor is no longer `.attached` (`INV-RVW-004`).
  mutating func rebase(through edits: [TextEdit]) {
    guard state == .attached else { return }
    let lo = range.lowerBound.value
    let hi = range.upperBound.value
    let touching = edits.filter { lo < $0.range.upperBound.value && $0.range.lowerBound.value < hi }

    if touching.isEmpty {
      range = TextUTF8Range(
        UTF8Offset(Self.mapLowerBound(lo, through: edits)),
        UTF8Offset(Self.mapUpperBound(hi, through: edits)))
      return
    }
    if touching.count == 1, touching[0].range.lowerBound.value <= lo,
      touching[0].range.upperBound.value >= hi
    {
      state = .orphaned
      return
    }
    state = .stale
  }

  /// An edit ending exactly at the offset (including a zero-width insertion)
  /// pushes it past that edit, so a range never absorbs text inserted
  /// immediately before it. Every edit here is entirely before or after the
  /// offset, or a zero-width insertion touching it — the caller only reaches
  /// this once no edit overlaps the anchor's interior.
  private static func mapLowerBound(_ offset: Int, through edits: [TextEdit]) -> Int {
    var delta = 0
    for edit in edits where edit.range.upperBound.value <= offset {
      delta += edit.replacement.utf8.count - editWidth(edit)
    }
    return offset + delta
  }

  /// Unlike the lower bound, a zero-width insertion exactly at the offset does
  /// *not* push it forward, so a range never absorbs text appended immediately
  /// after it.
  private static func mapUpperBound(_ offset: Int, through edits: [TextEdit]) -> Int {
    var delta = 0
    for edit in edits where edit.range.upperBound.value <= offset {
      let isInsertionAtOffset =
        edit.range.lowerBound.value == edit.range.upperBound.value
        && edit.range.upperBound.value == offset
      guard !isInsertionAtOffset else { continue }
      delta += edit.replacement.utf8.count - editWidth(edit)
    }
    return offset + delta
  }

  private static func editWidth(_ edit: TextEdit) -> Int {
    edit.range.upperBound.value - edit.range.lowerBound.value
  }
}
