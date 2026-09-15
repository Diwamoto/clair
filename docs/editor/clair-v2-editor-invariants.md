# Clair v2 editor core invariants

`E01` (D4, depends on `B01`). This is the prose companion to the machine-readable
invariant list in
[`packages/ClairV2Core/Sources/ClairV2EditorFixtures/EditorInvariants.swift`](../../packages/ClairV2Core/Sources/ClairV2EditorFixtures/EditorInvariants.swift).
Each invariant below has a stable ID (`INV-CATEGORY-NNN`) that later tasks (`E02`-`E10`,
see [the rewrite plan](../plans/clair-v2-native-rewrite.md) Phase 3 and
[the queue](../plans/clair-v2-native-rewrite-queue.md)) must satisfy and may cite directly in a
test failure message. IDs are never reused after removal.

This document does not implement the editor. It fixes the contract `E02` (buffer/coordinates/
revision), `E03` (transaction/multi-cursor/undo/external edit), `E05`-`E09` (parse, layout, IME,
mobile, review) must build against, and records the concrete failure values from the CodeEdit PoC
and the CodeMirror/WKWebView v1 default so later work has a regression floor instead of a vague
"be fast" goal.

## 1. Why this exists: prior failures

Clair evaluated `CodeEditSourceEditor`/`CodeEditTextView` as an AppKit-native replacement for the
WKWebView/CodeMirror 6 editor. The PoC is preserved at
[`prototypes/native-editor-poc`](../../prototypes/native-editor-poc), its narrative report at
[`docs/issues/native-editor/evidence/poc-report.md`](../issues/native-editor/evidence/poc-report.md),
raw numbers at
[`prototypes/native-editor-poc/MEASUREMENTS.md`](../../prototypes/native-editor-poc/MEASUREMENTS.md),
and the resulting decision at
[ADR-0014](../decisions/0014-clair-owned-text-engine.md), which rejected adopting CodeEdit as the
production engine and committed Clair to an owned text engine shared by editor and terminal.

The measured failures that motivate this document (measurement conditions: Apple M4, 32 GiB,
macOS 26.6.2, Swift 6.3.3 Release; ~1164x710 viewport, 13 pt monospaced, wrapping off; 20
repetitions per operation, nearest-rank p95; RSS is cumulative process maximum, not per-document
— see `EditorBaselineEvidence.measurementConditions` for the full statement that must be restated
whenever these numbers are cited elsewhere):

| ID | Fixture | Metric | Value | Note |
|---|---|---|---|---|
| `BASE-CE-001` | 10mb.swift | first visible highlight | 4543.25 ms | Detected by polling, not full parse. |
| `BASE-CE-002` | 10mb.swift | cumulative max RSS | 1077.7 MiB | Cited together with `BASE-CE-001` in ADR-0014 as "4.7 s and 1.1 GiB". |
| `BASE-CE-003` | long-line.ts | cumulative max RSS | 1168.4 MiB | 1 MiB single line. |
| `BASE-CE-004`/`005` | long-line.ts | keystroke median / p95 | 684.86 / 693.29 ms | Default scheduling policy (`maxSyncContentLength = 250,000` UTF-16). |
| `BASE-CE-006` | long-line.ts | scroll p95 | 711.94 ms | Median was 0.18 ms — a stall, not uniform slowdown. |
| `BASE-CE-007`/`008` | 1mb.swift (Japanese) | keystroke median / scroll p95 | 26.14 / 26.50 ms | Threshold measured in UTF-16 units put a UTF-8 ~1 MiB Japanese fixture on the wrong side of the sync/async boundary. Motivates `INV-COORD-002`. |
| `BASE-CE-009`/`010` | 10mb.swift | eager constructor layout / footprint | >90,000 ms / 758 MiB | Passing a large string to the text view's initializer laid out every line via `addSubview` eagerly. Motivates `INV-PERF-002`. |
| `BASE-CE-011` | multi-cursor | undo presses for one gesture | 3 | Stock upstream undo manager; PoC needed a custom grouping adapter to reach 1. Motivates `INV-UNDO-001`. |
| `BASE-CE-012` | 50-extra-tabs | open and show | 3326.67 ms (default policy) / 1419.08 ms (other run) | Tab retention cost scales badly. |
| `BASE-CM-001` | 10mb.swift | `setDocument` round trip | 2997.26 ms | CodeMirror/WKWebView, the v1 shipping default. Motivates `INV-PERF-006`. |
| `BASE-CM-002`/`003` | 10mb.swift | selection / scroll round trip p95 | 5796.32 / 25043.03 ms | Worst recorded number in the whole evidence set. |
| `BASE-CM-004` | 10mb.swift | bytes over bridge (20 selections) | 209,714,700 bytes | `doc.toString()` on every selection event. Motivates `INV-REV-005`. |
| `BASE-VS-001`-`003` | various | keystroke median, open+show | 0.88-1.33 ms, 181.89 ms | VS Code, orientation only — different host/API boundary, not a like-for-like comparison. |

The full, machine-readable table with IDs, units, and per-row provenance lives in
[`EditorBaselineEvidence.swift`](../../packages/ClairV2Core/Sources/ClairV2EditorFixtures/EditorBaselineEvidence.swift).
`EditorBaselineEvidence.regressionCeiling(fixture:metric:)` returns the best (lowest) recorded
failure for a fixture/metric pair — a v2 measurement that beats it beats every recorded failure,
and `E02`-`E10` performance tests should assert against it rather than an arbitrary number.

These are not targets to approach. They are floors a native rewrite must clear decisively, because
they are the reason the rewrite exists.

## 2. Coordinate model (`INV-COORD-*`)

- **Canonical storage is the UTF-8 byte offset** (`INV-COORD-001`). UTF-16 code unit, Unicode
  scalar, extended grapheme cluster, and line/column are all derived projections of a UTF-8 offset,
  never a second source of truth.
- **Every offset in the public API is tagged with its coordinate space** (`INV-COORD-002`). A bare
  `Int` is not a valid offset parameter. `BASE-CE-007` is what happens when a UTF-16-measured
  threshold is silently compared against UTF-8 byte counts: a ~1 MiB Japanese file landed on the
  wrong side of a sync/async boundary and produced a 26.14 ms median keystroke.
- **No public offset may split a UTF-8 continuation byte, a UTF-16 surrogate pair, or a grapheme
  cluster** (`INV-COORD-003`). Cursor-visible positions snap outward to a grapheme cluster
  boundary. Astral-plane characters and ZWJ emoji sequences are one user-perceived character; the
  API must never let them be split.
- **Caret motion, selection extension, and backward delete operate on extended grapheme cluster
  boundaries** as Swift's `Character` segmentation defines them, not scalars or code units
  (`INV-COORD-004`). One Delete removes one visible character, whether that is `👨‍👩‍👧‍👦`, an `e`
  + combining acute pair, or a `\r\n` pair.
- **Line breaks**: `\r\n` is exactly one line break and one grapheme cluster; a lone `\r`, a lone
  `\n`, U+0085 (NEL), U+2028 (LS), and U+2029 (PS) are each one line break; no coordinate may land
  between `\r` and `\n` (`INV-COORD-005`). Mixed line endings are ordinary in real repositories.
- **LSP boundary transcoding only**: LSP positions are UTF-16 based and are converted at the LSP
  boundary; UTF-16 offsets never enter the buffer's internal indexes (`INV-COORD-006`).
- **No silent normalization**: the core never applies NFC/NFD to document content; normalization is
  only offered as an explicit, undoable user edit (`INV-COORD-007`). Silent rewriting produces
  spurious diffs and breaks content-hash based external-change detection.
- **Invalid UTF-8 is never silently replaced**: a file with invalid UTF-8 must round-trip losslessly
  in unedited regions, or be refused as binary. Silent U+FFFD substitution on load is forbidden
  (`INV-COORD-008`) because it destroys user data with no undo entry.

## 3. Revision and immutability model (`INV-REV-*`)

- **A document revision is immutable and totally ordered**, strictly monotonic for content changes,
  never reused within a document's lifetime (`INV-REV-001`). Anchors, diagnostics, completions, and
  AI suggestions are all validated by revision equality; reuse silently re-validates stale data.
- **Attribute-only changes do not advance the content revision** (`INV-REV-002`): syntax
  highlighting, diagnostics, and review decorations are not content edits. The CodeEdit PoC
  initially advanced its revision from an `NSTextStorage` delegate that also fired for attribute
  changes, invalidating every comment anchor on each highlight pass.
- **A snapshot at revision R is immutable and readable from any thread without copying the whole
  document** (`INV-REV-003`). Save, Tree-sitter parse, LSP sync, and AI review all need a
  consistent view while the user keeps typing.
- **Stale results are rejected or rebased explicitly, never re-applied by re-searching text**
  (`INV-REV-004`). String-matching a stale AI suggestion back onto a changed document applies the
  edit to the wrong place; this is why stale suggestions are refused rather than rebased by search.
- **The whole-document `String` is never materialized on the typing hot path** (`INV-REV-005`).
  Snapshots are produced only at explicit boundaries: save, parse, external sync, AI hand-off. The
  CodeMirror/WKWebView path pushes `doc.toString()` on every change or selection event; 20 selection
  round trips on the 10MB fixture moved 209,714,700 bytes across the bridge (`BASE-CM-004`).

## 4. Transaction model (`INV-TXN-*`)

- **Every content mutation goes through a transaction that applies atomically**: it produces
  exactly one new revision or leaves the document untouched (`INV-TXN-001`). Partial application
  leaves anchors, line index, and parser state disagreeing with the text.
- **Edits within one transaction are expressed against the pre-transaction coordinate space, do not
  overlap, and are applied as if simultaneous** (`INV-TXN-002`). This is the structural fix for the
  classic multi-cursor corruption bug where sequential application against shifting offsets
  corrupts later edits.
- **Each transaction publishes a position-mapping function** from the old revision to the new one,
  classifying every mapped position as preserved, shifted, or deleted (`INV-TXN-003`). Anchors,
  selections, folds, and review threads all move through the same mapping or they drift apart.
- **A position whose surrounding range was deleted becomes explicitly orphaned**, never silently
  relocated to a neighbouring line (`INV-TXN-004`) — the PoC deliberately chose conservative
  orphaning after observing anchors reattach to the wrong line.

## 5. Multi-cursor correctness (`INV-MC-*`)

- **A `SelectionSet` is always non-empty, sorted by start offset, with no overlapping ranges**;
  ranges that would overlap after an operation are merged first (`INV-MC-001`).
- **Correctness for an N-cursor operation is defined as: the result equals applying the same
  single-cursor operation independently at each of the N sites against the pre-transaction
  document** (`INV-MC-002`). This gives every multi-cursor test a mechanical oracle so `E03` can be
  verified differentially instead of by inspection.
- **Each cursor keeps its identity and goal column across an operation**; vertical motion through
  short lines must not permanently collapse cursors (`INV-MC-003`).
- **Rectangular selection is defined on visual columns**, and a column landing inside a wide
  (East Asian) glyph or a grapheme cluster snaps outward to a cluster boundary (`INV-MC-004`) — CJK
  columns are the common case in this codebase's own fixtures.

## 6. Undo model (`INV-UNDO-*`)

- **One user gesture is one undo unit**: a single keystroke applied at N cursors is undone by
  exactly one Undo (`INV-UNDO-001`). Measured failure: with `CodeEditTextView`'s stock undo manager,
  typing `X` at 3 cursors required 3 Undos (`BASE-CE-011`); the PoC only reached 1 Undo by adding
  its own grouping adapter, and left the upstream behavior recorded as an expected failure.
- **Undo restores selection state, not just text** (`INV-UNDO-002`) — otherwise the user cannot
  continue a multi-cursor edit after an undo.
- **IME composition is not undoable while marked**; only the committed result enters the undo stack,
  as one unit (`INV-UNDO-003`) — otherwise Undo walks backwards through candidate conversions, which
  no macOS text control does.
- **Undo/redo of an AI suggestion application is one unit**, and a partially applied suggestion
  leaves remaining hunks recomputed against the new revision rather than left stale
  (`INV-UNDO-004`) — re-basing by text search is forbidden by `INV-REV-004`.

## 7. External and agent edits (`INV-EXT-*`)

- **An edit from outside the UI (file watcher, agent, LSP rename) is an ordinary transaction
  against a stated base revision**, subject to the same atomicity and mapping rules
  (`INV-EXT-001`) — a privileged side channel would bypass anchor mapping and undo grouping.
- **A stale-based external edit is rebased through the published position mapping or refused, never
  applied at raw offsets** (`INV-EXT-002`) — an agent writing at offsets computed seconds ago
  corrupts text the user typed in between.
- **An unsaved buffer is never silently replaced by on-disk content**; divergence is surfaced as an
  explicit conflict (`INV-EXT-003`) — silent data loss with no undo entry is the worst failure mode
  an editor can have.

## 8. Performance invariants (`INV-PERF-*`)

- **Work per edit is proportional to the edit size and the visible viewport, not document size or
  line length** (`INV-PERF-001`). This is a data-structure requirement, not a tuning goal, and it is
  the structural answer to the PoC's 10MB numbers.
- **No code path performs eager layout of all lines or allocates one view per line**
  (`INV-PERF-002`). Measured failure: passing a large string to `CodeEditTextView`'s initializer
  drove `TextView.init -> TextLayoutManager.layoutLines -> NSView.addSubview`, taking over 90 s at
  ~100% of one core with a ~758 MiB footprint (`BASE-CE-009`/`010`).
- **A single very long line is handled by the same viewport-bounded path as many short lines**
  (`INV-PERF-003`). Measured failure: the tuned default scheduling policy produced a 684.86 ms
  median keystroke and 693.29 ms p95 on a 1 MiB single-line fixture (`BASE-CE-004`/`005`).
- **Resident memory for an open document is bounded by a small multiple of its byte size plus
  viewport state** (`INV-PERF-004`). Measured failure: cumulative max RSS reached 1077.7 MiB after
  the 10MB fixture and 1168.4 MiB after the long-line fixture (`BASE-CE-002`/`003`).
- **Syntax highlighting, diagnostics, and search are cancellable background work**; they never
  block input, and their absence degrades appearance only, never correctness (`INV-PERF-005`).
  Measured failure: first visible colouring of the 10MB fixture took 4543.25 ms, and the
  synchronous-parse threshold that hid this for small files made 1 MiB Japanese keystrokes cost
  26.14 ms (`BASE-CE-001`, `BASE-CE-007`).
- **No editor hot path crosses a WebView, JavaScript, or cross-process serialization boundary**
  (`INV-PERF-006`) — ADR-0014 and the v2 rewrite plan forbid a CodeMirror/WKWebView fallback; the
  10MB `setDocument` round trip cost 2997.26 ms (`BASE-CM-001`).

## 9. Fixtures and benchmark harness

- **Unicode test corpus**: [`UnicodeCorpus.swift`](../../packages/ClairV2Core/Sources/ClairV2EditorFixtures/UnicodeCorpus.swift)
  embeds named cases (CRLF, mixed line endings, CJK, combining marks, ZWJ emoji family, regional
  indicator flags, RTL, ZWJ + variation selector) plus a `deleteBoundaryCases` list built for
  `INV-COORD-003`/`004` boundary tests. Cases are embedded so correctness tests do not depend on
  reading files from disk; the same cases are also written to a `unicode-corpus.swift` fixture file
  by the generator below for tests that want an on-disk file.
- **10MB and long-line fixtures**: [`EditorFixtureGenerator.swift`](../../packages/ClairV2Core/Sources/ClairV2EditorFixtures/EditorFixtureGenerator.swift)
  defines `canonicalFixtures` (`10mb`, `long-line`, `1mb-japanese`, `unicode-corpus`) and generates
  them deterministically rather than checking multi-megabyte binaries into git. Run
  `scripts/v2-editor-fixtures.sh generate` to materialize them under
  `.build/v2-editor-fixtures/` (gitignored via `.build/`), or `clean`/`list` to remove/inspect them.
  The `EditorFixtureGenerator` SwiftPM executable target backing the script is exercised directly by
  `EditorFixtureGeneratorTests` in `EditorFixturesTests.swift`.
- **Benchmark harness**: [`EditorBenchmark.swift`](../../packages/ClairV2Core/Sources/ClairV2EditorFixtures/EditorBenchmark.swift)
  defines `EditorBenchmark.Operation` (name, fixture, iteration count, async closure) and
  `EditorBenchmark.run(_:)`, which reports median and nearest-rank p95 latency plus `getrusage`
  max RSS. `E01` fixes the harness shape and units only; `E02`-`E10` plug concrete buffer/layout/IME
  operations into it and are expected to assert results against
  `EditorBaselineEvidence.regressionCeiling(fixture:metric:)`.

## 10. Traceability

`EditorInvariants.all` in `EditorInvariants.swift` is the single source of truth for invariant IDs;
this document must not introduce an ID that is not also present there, and vice versa
(`EditorInvariantsTests` in `EditorFixturesTests.swift` enforces uniqueness, ID format, and that
every invariant has a non-empty statement, rationale, and `provenBy` list). When `E02`-`E10` close
out an invariant with a passing test, update `provenBy` in the same commit rather than leaving it
aspirational.
