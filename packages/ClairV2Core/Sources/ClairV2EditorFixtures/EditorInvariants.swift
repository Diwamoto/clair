import Foundation

/// Machine-readable form of the Clair v2 editor core invariants.
///
/// The prose companion is `docs/editor/clair-v2-editor-invariants.md`. This type exists so that
/// `E02`+ can reference an invariant by stable ID from a test failure message instead of quoting
/// a paragraph, and so a dropped invariant shows up as a compile/test break rather than a silent
/// documentation edit.
///
/// Nothing here implements the editor. `E01` only fixes the contract that `E02`-`E10` must satisfy.
public struct EditorInvariant: Sendable, Hashable, Identifiable {
  /// Stable identifier, e.g. `INV-COORD-001`. Never reused after removal.
  public let id: String
  /// Area the invariant belongs to.
  public let category: Category
  /// One-line statement of the rule.
  public let statement: String
  /// Why the rule exists, usually traceable to a recorded failure.
  public let rationale: String
  /// Queue task IDs that are expected to prove this invariant.
  public let provenBy: [String]

  public enum Category: String, Sendable, Hashable, CaseIterable {
    case coordinates
    case revision
    case transaction
    case multiCursor
    case undo
    case externalEdit
    case performance
  }

  public init(
    id: String,
    category: Category,
    statement: String,
    rationale: String,
    provenBy: [String]
  ) {
    self.id = id
    self.category = category
    self.statement = statement
    self.rationale = rationale
    self.provenBy = provenBy
  }
}

public enum EditorInvariants {
  public static let all: [EditorInvariant] = [
    // MARK: Coordinates

    EditorInvariant(
      id: "INV-COORD-001",
      category: .coordinates,
      statement:
        "The buffer's canonical storage unit is the UTF-8 byte. Every other coordinate space (UTF-16 code unit, Unicode scalar, extended grapheme cluster, line/column) is a derived projection of a UTF-8 offset.",
      rationale:
        "Files are read and written as UTF-8. Picking UTF-16 as canonical would make every disk round trip a transcode, and picking grapheme clusters would make offsets depend on the Unicode version linked at runtime.",
      provenBy: ["E02"]
    ),
    EditorInvariant(
      id: "INV-COORD-002",
      category: .coordinates,
      statement:
        "Every offset accepted or returned by the public core API must be tagged with its coordinate space. A bare `Int` offset is not a valid parameter type.",
      rationale:
        "The CodeEdit PoC mixed UTF-16 selection ranges, UTF-8 fixture byte counts, and a UTF-16-based `maxSyncContentLength` threshold in one system. The 1MB Japanese fixture then landed on the wrong side of the synchronous-parse boundary and produced a 26.14 ms median keystroke.",
      provenBy: ["E02"]
    ),
    EditorInvariant(
      id: "INV-COORD-003",
      category: .coordinates,
      statement:
        "No public API may produce an offset that falls inside a UTF-8 continuation byte, between the halves of a UTF-16 surrogate pair, or inside an extended grapheme cluster. Cursor-visible positions must snap outward to a grapheme cluster boundary.",
      rationale:
        "Astral-plane characters and ZWJ emoji sequences are single user-perceived characters. Splitting them corrupts the document on delete and produces unpaired surrogates on LSP round trips.",
      provenBy: ["E02", "E03"]
    ),
    EditorInvariant(
      id: "INV-COORD-004",
      category: .coordinates,
      statement:
        "Caret motion, selection extension, and backward delete operate on extended grapheme cluster boundaries as computed by Swift's `Character` segmentation, not on scalars or code units.",
      rationale:
        "One press of Delete must remove one visible character: the whole `👨‍👩‍👧‍👦` sequence, the whole `e` + combining acute pair, and the whole `\\r\\n` pair.",
      provenBy: ["E03", "E07", "E08"]
    ),
    EditorInvariant(
      id: "INV-COORD-005",
      category: .coordinates,
      statement:
        "`\\r\\n` is exactly one line break and exactly one grapheme cluster. A lone `\\r`, a lone `\\n`, U+0085, U+2028, and U+2029 are each one line break. No coordinate may land between `\\r` and `\\n`.",
      rationale:
        "Mixed line endings are normal in real repositories; an offset between CR and LF makes line index and byte offset disagree.",
      provenBy: ["E02"]
    ),
    EditorInvariant(
      id: "INV-COORD-006",
      category: .coordinates,
      statement:
        "LSP positions are UTF-16 based and must be converted at the LSP boundary only. UTF-16 offsets never enter the buffer's internal indexes.",
      rationale:
        "Keeping the transcode at the edge means a protocol change cannot invalidate the line index.",
      provenBy: ["E05"]
    ),
    EditorInvariant(
      id: "INV-COORD-007",
      category: .coordinates,
      statement:
        "Text is stored exactly as read. The core never applies Unicode normalization (NFC/NFD) to document content; normalization may only be offered as an explicit, undoable user edit.",
      rationale:
        "Silent normalization rewrites bytes the user never touched, producing spurious diffs and breaking content-hash based external-change detection.",
      provenBy: ["E02"]
    ),
    EditorInvariant(
      id: "INV-COORD-008",
      category: .coordinates,
      statement:
        "Invalid UTF-8 in a file must be represented losslessly enough to round trip unchanged when the region is not edited, or the file must be refused as binary. Silent U+FFFD substitution on load is forbidden.",
      rationale:
        "Replacing undecodable bytes with U+FFFD and then saving destroys user data with no undo entry.",
      provenBy: ["E02"]
    ),

    // MARK: Revision

    EditorInvariant(
      id: "INV-REV-001",
      category: .revision,
      statement:
        "A document revision is an immutable, totally ordered value. Revisions increase strictly monotonically for content changes and are never reused within a document's lifetime.",
      rationale:
        "Anchors, diagnostics, completions, and AI suggestions are all validated by revision equality; a reused revision silently re-validates stale data.",
      provenBy: ["E02"]
    ),
    EditorInvariant(
      id: "INV-REV-002",
      category: .revision,
      statement:
        "Attribute-only changes (syntax highlight, diagnostics, review decorations) must not advance the content revision.",
      rationale:
        "The CodeEdit PoC initially advanced its revision from an `NSTextStorage` delegate that also fired for attribute changes, invalidating every comment anchor on each highlight pass.",
      provenBy: ["E02", "E05"]
    ),
    EditorInvariant(
      id: "INV-REV-003",
      category: .revision,
      statement:
        "A snapshot taken at revision R is immutable and readable from any thread without copying the whole document.",
      rationale:
        "Save, Tree-sitter parse, LSP sync, and AI review all need a consistent view while the user keeps typing.",
      provenBy: ["E02", "E05"]
    ),
    EditorInvariant(
      id: "INV-REV-004",
      category: .revision,
      statement:
        "Any result computed against revision R and delivered after the document has advanced past R must be rejected or rebased explicitly. Positional results are never applied by re-searching for matching text.",
      rationale:
        "String-matching a stale AI suggestion back onto a changed document applies the edit to the wrong place; the PoC recorded this as the reason stale suggestions are refused rather than re-based.",
      provenBy: ["E04", "E05", "E09"]
    ),
    EditorInvariant(
      id: "INV-REV-005",
      category: .revision,
      statement:
        "The whole-document `String` is never materialised on the typing hot path. Snapshots are produced only at explicit boundaries: save, parse, external sync, and AI hand-off.",
      rationale:
        "The current CodeMirror/WKWebView path pushes `doc.toString()` on every change or selection event; 20 selection round trips on the 10MB fixture moved 209,714,700 bytes across the bridge.",
      provenBy: ["E02", "E06"]
    ),

    // MARK: Transaction

    EditorInvariant(
      id: "INV-TXN-001",
      category: .transaction,
      statement:
        "Every content mutation goes through a transaction. A transaction applies atomically: it either produces exactly one new revision or leaves the document untouched.",
      rationale:
        "Partial application leaves anchors, line index, and parser state disagreeing with the text.",
      provenBy: ["E03"]
    ),
    EditorInvariant(
      id: "INV-TXN-002",
      category: .transaction,
      statement:
        "The edits within one transaction are expressed against the pre-transaction coordinate space, must not overlap, and are applied as if simultaneously.",
      rationale:
        "Applying multi-cursor edits sequentially against shifting offsets is the classic multi-cursor corruption bug; requiring pre-state coordinates makes ordering irrelevant.",
      provenBy: ["E03"]
    ),
    EditorInvariant(
      id: "INV-TXN-003",
      category: .transaction,
      statement:
        "Each transaction publishes a position-mapping function from the old revision to the new one, classifying every mapped position as preserved, shifted, or deleted.",
      rationale:
        "Anchors, selections, folds, and review threads must all move through the same mapping, or they drift apart from each other.",
      provenBy: ["E03", "E09"]
    ),
    EditorInvariant(
      id: "INV-TXN-004",
      category: .transaction,
      statement:
        "A position whose surrounding range was deleted becomes explicitly orphaned. It is never silently relocated to a neighbouring line.",
      rationale:
        "The PoC deliberately chose conservative orphaning after observing anchors reattach to the wrong line when an enclosing selection was replaced.",
      provenBy: ["E03", "E09"]
    ),

    // MARK: Multi-cursor

    EditorInvariant(
      id: "INV-MC-001",
      category: .multiCursor,
      statement:
        "A SelectionSet is always non-empty, kept sorted by start offset, and has no two ranges that overlap. Ranges that would overlap after an operation are merged before the operation is applied.",
      rationale:
        "Overlapping cursors cause the same text to be edited twice within one transaction.",
      provenBy: ["E03"]
    ),
    EditorInvariant(
      id: "INV-MC-002",
      category: .multiCursor,
      statement:
        "Correctness for an N-cursor operation is defined as: the result equals applying the same single-cursor operation independently at each of the N sites against the pre-transaction document.",
      rationale:
        "This gives every multi-cursor test a mechanical oracle, so `E03` can be verified differentially instead of by inspection.",
      provenBy: ["E03"]
    ),
    EditorInvariant(
      id: "INV-MC-003",
      category: .multiCursor,
      statement:
        "Each cursor retains its identity and its goal column across an operation. Vertical motion through short lines must not collapse cursors permanently.",
      rationale:
        "Losing goal column makes column editing unusable on ragged code.",
      provenBy: ["E03"]
    ),
    EditorInvariant(
      id: "INV-MC-004",
      category: .multiCursor,
      statement:
        "Rectangular selection is defined on visual columns, and a column that falls inside a wide (East Asian) glyph or inside a grapheme cluster snaps outward to a cluster boundary.",
      rationale:
        "CJK columns are the common case in this codebase's own fixtures.",
      provenBy: ["E03"]
    ),

    // MARK: Undo

    EditorInvariant(
      id: "INV-UNDO-001",
      category: .undo,
      statement:
        "One user gesture is one undo unit. A single keystroke applied at N cursors is undone by exactly one Undo.",
      rationale:
        "Measured failure: with CodeEditTextView's stock undo manager, typing `X` at 3 cursors required 3 Undos. The PoC only reached 1 Undo by adding its own grouping adapter, and kept the upstream behaviour recorded as an expected failure.",
      provenBy: ["E03"]
    ),
    EditorInvariant(
      id: "INV-UNDO-002",
      category: .undo,
      statement:
        "Undo restores the selection state that existed before the transaction, not just the text.",
      rationale:
        "Restoring text without cursors leaves the user unable to continue a multi-cursor edit after an undo.",
      provenBy: ["E03"]
    ),
    EditorInvariant(
      id: "INV-UNDO-003",
      category: .undo,
      statement:
        "IME composition is not undoable while marked. Only the committed result enters the undo stack, as one unit.",
      rationale:
        "Otherwise Undo walks backwards through candidate conversions, which no macOS text control does.",
      provenBy: ["E07"]
    ),
    EditorInvariant(
      id: "INV-UNDO-004",
      category: .undo,
      statement:
        "Undo/redo of an AI suggestion application is a single unit, and a partially applied suggestion leaves the remaining hunks recomputed against the new revision rather than left stale.",
      rationale:
        "Recorded PoC behaviour for partial apply; re-basing by text search is forbidden by INV-REV-004.",
      provenBy: ["E09"]
    ),

    // MARK: External edits

    EditorInvariant(
      id: "INV-EXT-001",
      category: .externalEdit,
      statement:
        "An edit arriving from outside the UI (file watcher, agent, LSP rename) is an ordinary transaction against a stated base revision and is subject to the same atomicity and mapping rules.",
      rationale:
        "A privileged side channel would bypass anchor mapping and undo grouping.",
      provenBy: ["E03"]
    ),
    EditorInvariant(
      id: "INV-EXT-002",
      category: .externalEdit,
      statement:
        "If the base revision of an external edit is stale, the edit is either rebased through the published position mapping or refused. It is never applied at raw offsets.",
      rationale:
        "An agent writing at offsets computed seconds ago corrupts text the user typed in between.",
      provenBy: ["E03"]
    ),
    EditorInvariant(
      id: "INV-EXT-003",
      category: .externalEdit,
      statement:
        "An unsaved buffer is never silently replaced by on-disk content. Divergence is surfaced as an explicit conflict.",
      rationale:
        "Data loss with no undo entry is the worst failure mode an editor can have.",
      provenBy: ["E03"]
    ),

    // MARK: Performance

    EditorInvariant(
      id: "INV-PERF-001",
      category: .performance,
      statement:
        "Work per edit is proportional to the size of the edit and the visible viewport, not to document size or line length.",
      rationale:
        "This is the structural answer to the PoC's 10MB numbers; it is a data-structure requirement, not a tuning goal.",
      provenBy: ["E02", "E06"]
    ),
    EditorInvariant(
      id: "INV-PERF-002",
      category: .performance,
      statement:
        "No code path performs eager layout of all lines, and no path allocates one view per line.",
      rationale:
        "Measured failure: passing a large string to CodeEditTextView's initialiser drove `TextView.init -> TextLayoutManager.layoutLines -> NSView.addSubview`, taking over 90 s at ~100% of one core with a ~758 MiB physical footprint.",
      provenBy: ["E06", "E08"]
    ),
    EditorInvariant(
      id: "INV-PERF-003",
      category: .performance,
      statement:
        "A single very long line is handled by the same viewport-bounded path as many short lines. Long-line handling must not regress to the whole-line-at-once behaviour.",
      rationale:
        "Measured failure: with the tuned default scheduling policy the 1 MiB single-line fixture produced a 684.86 ms median keystroke and a 693.29 ms p95.",
      provenBy: ["E06", "E10"]
    ),
    EditorInvariant(
      id: "INV-PERF-004",
      category: .performance,
      statement:
        "Resident memory for an open document is bounded by a small multiple of its byte size plus viewport state. Opening a 10MB file must not cost ~1 GiB.",
      rationale:
        "Measured failure: cumulative max RSS reached 1077.7 MiB after the 10MB fixture and 1168.4 MiB after the long-line fixture.",
      provenBy: ["E06", "E10"]
    ),
    EditorInvariant(
      id: "INV-PERF-005",
      category: .performance,
      statement:
        "Syntax highlighting, diagnostics, and search are cancellable background work. They never block input, and their absence degrades appearance only, never correctness.",
      rationale:
        "Measured failure: first visible colouring of the 10MB fixture took 4543.25 ms, and the synchronous-parse threshold that hid it for small files made 1 MiB keystrokes cost 26.14 ms.",
      provenBy: ["E05", "E06"]
    ),
    EditorInvariant(
      id: "INV-PERF-006",
      category: .performance,
      statement:
        "No editor hot path crosses a WebView, JavaScript, or cross-process serialisation boundary.",
      rationale:
        "ADR-0014 and the v2 rewrite plan forbid a CodeMirror/WKWebView fallback; the 10MB `setDocument` round trip cost 2997.26 ms.",
      provenBy: ["E06"]
    ),
  ]

  /// Invariants belonging to one category, in declaration order.
  public static func all(in category: EditorInvariant.Category) -> [EditorInvariant] {
    all.filter { $0.category == category }
  }

  /// Lookup by stable ID.
  public static func invariant(withID id: String) -> EditorInvariant? {
    all.first { $0.id == id }
  }
}
