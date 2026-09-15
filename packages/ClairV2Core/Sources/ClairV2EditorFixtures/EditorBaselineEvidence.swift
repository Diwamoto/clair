import Foundation

/// A recorded measurement from a pre-v2 editor implementation, kept as a regression floor.
///
/// These are not targets. They are the numbers the previous implementations actually produced,
/// preserved so `E02`-`E10` can assert "we are at least not worse than the thing we deleted".
public struct EditorBaselineMeasurement: Sendable, Hashable {
  public let id: String
  public let surface: BaselineSurface
  public let fixture: String
  public let metric: String
  public let unit: String
  public let value: Double
  /// True when this value is a recorded failure rather than an acceptable result.
  public let isFailure: Bool
  public let note: String
  /// Relative path of the document this number was copied from.
  public let source: String

  public init(
    id: String,
    surface: BaselineSurface,
    fixture: String,
    metric: String,
    unit: String,
    value: Double,
    isFailure: Bool,
    note: String,
    source: String
  ) {
    self.id = id
    self.surface = surface
    self.fixture = fixture
    self.metric = metric
    self.unit = unit
    self.value = value
    self.isFailure = isFailure
    self.note = note
    self.source = source
  }
}

public enum BaselineSurface: String, Sendable, Hashable, CaseIterable {
  /// CodeEditSourceEditor + CodeEditTextView PoC, rejected by ADR-0014.
  case codeEditPoC = "editor.codeedit-poc"
  /// CodeMirror 6 in WKWebView, the v1 shipping default, removed in v2.
  case codeMirrorWebView = "editor.codemirror-webview"
  /// VS Code 1.136.1 measured through an isolated extension host, for orientation only.
  case vsCodeReference = "editor.vscode-reference"
}

/// Baseline evidence for the Clair v2 native editor.
///
/// Measurement conditions, taken verbatim from the PoC report, apply to every `codeEditPoC` and
/// `codeMirrorWebView` row below and must be restated whenever these numbers are cited:
///
/// - Apple M4 (10 logical CPU), 32 GiB, macOS 26.6.2, arm64, Swift 6.3.3, Release build.
/// - Editor viewport ~1164x710, 13 pt monospaced, wrapping off, minimap hidden.
/// - One process, one pass per condition; 20 repetitions per operation; p95 is nearest-rank (19th).
/// - RSS figures are *cumulative* process maxima that still retain previously opened documents,
///   not the standalone cost of one file.
/// - The VS Code rows are API-boundary timings from a separate extension host with a different
///   viewport and settings. They are orientation, not a like-for-like comparison.
///
/// This is not a controlled lab result and must not be presented as one. It is good enough for its
/// one job: recording the failure modes v2 is not allowed to reproduce.
public enum EditorBaselineEvidence {
  public static let pocReportPath = "docs/issues/native-editor/evidence/poc-report.md"
  public static let pocMeasurementsPath = "prototypes/native-editor-poc/MEASUREMENTS.md"
  public static let decisionPath = "docs/decisions/0014-clair-owned-text-engine.md"

  public static let measurementConditions = """
    Apple M4 (10 logical CPU), 32 GiB, macOS 26.6.2, arm64, Swift 6.3.3, Release build. \
    Editor viewport ~1164x710, 13 pt monospaced, wrapping off, minimap hidden. \
    One process and one pass per condition, 20 repetitions per operation, nearest-rank p95. \
    RSS values are cumulative process maxima across previously opened documents. \
    Not a thermally or environmentally controlled lab measurement.
    """

  public static let all: [EditorBaselineMeasurement] = [
    // MARK: CodeEdit PoC - the failures that motivated ADR-0014 Option D.

    EditorBaselineMeasurement(
      id: "BASE-CE-001",
      surface: .codeEditPoC,
      fixture: "10mb.swift",
      metric: "first_visible_highlight",
      unit: "ms",
      value: 4543.25,
      isFailure: true,
      note:
        "First visible colouring of a 10MB file. Detection polled at 20 ms until multiple colours appeared in the viewport; this is not full-file parse or final draw, so the true cost is higher.",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CE-002",
      surface: .codeEditPoC,
      fixture: "10mb.swift",
      metric: "cumulative_max_rss",
      unit: "MiB",
      value: 1077.7,
      isFailure: true,
      note:
        "ADR-0014 cites this together with BASE-CE-001 as '4.7 s and 1.1 GiB', the pair of numbers that rejected the CodeEdit adoption gate.",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CE-003",
      surface: .codeEditPoC,
      fixture: "long-line.ts",
      metric: "cumulative_max_rss",
      unit: "MiB",
      value: 1168.4,
      isFailure: true,
      note: "Cumulative maximum after the 1 MiB single-line fixture.",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CE-004",
      surface: .codeEditPoC,
      fixture: "long-line.ts",
      metric: "keystroke_median",
      unit: "ms",
      value: 684.86,
      isFailure: true,
      note:
        "Default scheduling policy run (maxSyncContentLength = 250,000 UTF-16). A single 1 MiB line makes each keystroke take over half a second.",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CE-005",
      surface: .codeEditPoC,
      fixture: "long-line.ts",
      metric: "keystroke_p95",
      unit: "ms",
      value: 693.29,
      isFailure: true,
      note: "Same run as BASE-CE-004.",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CE-006",
      surface: .codeEditPoC,
      fixture: "long-line.ts",
      metric: "scroll_p95",
      unit: "ms",
      value: 711.94,
      isFailure: true,
      note: "Default scheduling policy run. Scroll median was 0.18 ms, so the p95 is a stall, not a uniform slowdown.",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CE-007",
      surface: .codeEditPoC,
      fixture: "1mb.swift",
      metric: "keystroke_median",
      unit: "ms",
      value: 26.14,
      isFailure: true,
      note:
        "A ~1 MiB UTF-8 fixture containing Japanese stayed inside the synchronous-parse region because the threshold is measured in UTF-16 units. Over one 60 Hz frame per keystroke. Recorded as INV-COORD-002's motivating bug.",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CE-008",
      surface: .codeEditPoC,
      fixture: "1mb.swift",
      metric: "scroll_p95",
      unit: "ms",
      value: 26.50,
      isFailure: true,
      note: "Above the 16.7 ms frame budget. Lowering the async threshold fixed keystrokes but not scrolling.",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CE-009",
      surface: .codeEditPoC,
      fixture: "10mb.swift",
      metric: "eager_constructor_layout",
      unit: "ms",
      value: 90000.0,
      isFailure: true,
      note:
        "Lower bound, reported as 'over 90 seconds' rather than a precise figure. Passing a large string to the TextView initialiser eagerly laid out every line via addSubview at ~100% of one core, with a ~758 MiB physical footprint. Sample saved at prototypes/native-editor-poc/evidence/eager-constructor-sample.txt. This is INV-PERF-002.",
      source: pocReportPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CE-010",
      surface: .codeEditPoC,
      fixture: "10mb.swift",
      metric: "eager_constructor_footprint",
      unit: "MiB",
      value: 758.0,
      isFailure: true,
      note: "Physical footprint during the eager-layout failure in BASE-CE-009.",
      source: pocReportPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CE-011",
      surface: .codeEditPoC,
      fixture: "multi-cursor",
      metric: "undo_presses_for_one_gesture",
      unit: "count",
      value: 3.0,
      isFailure: true,
      note:
        "Correctness failure, not a timing one. Typing one character at 3 cursors needed 3 Undo presses with the stock upstream undo manager; the PoC only reached 1 by adding its own grouping adapter. This is INV-UNDO-001.",
      source: pocReportPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CE-012",
      surface: .codeEditPoC,
      fixture: "50-extra-tabs",
      metric: "open_and_show",
      unit: "ms",
      value: 3326.67,
      isFailure: true,
      note: "Default scheduling policy run; 1419.08 ms in the tuned run. Tab retention cost scales badly.",
      source: pocMeasurementsPath
    ),

    // MARK: CodeMirror in WKWebView - the v1 default that v2 removes.

    EditorBaselineMeasurement(
      id: "BASE-CM-001",
      surface: .codeMirrorWebView,
      fixture: "10mb.swift",
      metric: "set_document_round_trip",
      unit: "ms",
      value: 2997.26,
      isFailure: true,
      note: "Three seconds to hand a 10MB document across the WebView bridge. This is INV-PERF-006.",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CM-002",
      surface: .codeMirrorWebView,
      fixture: "10mb.swift",
      metric: "selection_round_trip_p95",
      unit: "ms",
      value: 5796.32,
      isFailure: true,
      note: "Moving the selection, not editing. Median was 22.79 ms, so this is a multi-second stall.",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CM-003",
      surface: .codeMirrorWebView,
      fixture: "10mb.swift",
      metric: "scroll_round_trip_p95",
      unit: "ms",
      value: 25043.03,
      isFailure: true,
      note: "25 seconds. The worst single number in the whole evidence set.",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-CM-004",
      surface: .codeMirrorWebView,
      fixture: "10mb.swift",
      metric: "document_bytes_over_bridge",
      unit: "bytes",
      value: 209_714_700,
      isFailure: true,
      note:
        "Observed transfer for 20 selection changes: the full document crossed the bridge on every selection event because the integration notifies with doc.toString(). This is INV-REV-005.",
      source: decisionPath
    ),

    // MARK: VS Code - orientation only, different host configuration.

    EditorBaselineMeasurement(
      id: "BASE-VS-001",
      surface: .vsCodeReference,
      fixture: "10mb.swift",
      metric: "keystroke_median",
      unit: "ms",
      value: 0.88,
      isFailure: false,
      note: "Extension-host API boundary, not key-to-glyph. Included to show the order of magnitude v2 is aiming at.",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-VS-002",
      surface: .vsCodeReference,
      fixture: "long-line.ts",
      metric: "keystroke_median",
      unit: "ms",
      value: 1.33,
      isFailure: false,
      note: "The long-line case that cost the PoC 684.86 ms (BASE-CE-004).",
      source: pocMeasurementsPath
    ),
    EditorBaselineMeasurement(
      id: "BASE-VS-003",
      surface: .vsCodeReference,
      fixture: "10mb.swift",
      metric: "open_and_show",
      unit: "ms",
      value: 181.89,
      isFailure: false,
      note: "Open plus show API round trip for a 10MB document.",
      source: pocMeasurementsPath
    ),
  ]

  public static func measurements(for surface: BaselineSurface) -> [EditorBaselineMeasurement] {
    all.filter { $0.surface == surface }
  }

  /// Every recorded failure. `E02`+ regression gates should be written against these.
  public static var failures: [EditorBaselineMeasurement] {
    all.filter(\.isFailure)
  }

  public static func measurement(withID id: String) -> EditorBaselineMeasurement? {
    all.first { $0.id == id }
  }

  /// The failure value a v2 implementation must stay strictly better than for a given metric.
  ///
  /// Returns the *best* (lowest) recorded failure for that fixture/metric pair, so a v2 result that
  /// beats it beats every recorded failure.
  public static func regressionCeiling(fixture: String, metric: String) -> Double? {
    all
      .filter { $0.isFailure && $0.fixture == fixture && $0.metric == metric }
      .map(\.value)
      .min()
  }
}
