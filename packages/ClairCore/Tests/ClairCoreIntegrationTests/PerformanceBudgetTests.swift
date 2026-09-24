import ClairEditorFixtures
import Foundation
import SwiftTreeSitter
import Testing

@testable import ClairEditorCore
@testable import ClairEditorLanguage
@testable import ClairWorkspace

#if canImport(ClairEditorLanguageFixtures)
  import ClairEditorLanguageFixtures
#endif

/// `BUDGET-OP-100` gate: every user-initiated operation is either under 100 ms
/// on the main thread, or runs in the background behind a loading affordance.
/// Contract: docs/benchmarks/clair-v2-performance-budget.md.
///
/// This suite is deliberately adversarial. The corpus (`BudgetCorpus`) is built
/// to break each path, and a `.mainThread` operation over budget is a failure,
/// not a note. The only sanctioned fix is moving the work to
/// `.background(affordance:)` — never raising the budget.
@Suite(.serialized)
struct PerformanceBudgetTests {
  static let budgetMillis = 100.0

  /// How an operation is allowed to spend time.
  enum Mode: Sendable {
    /// Runs synchronously where the user is waiting. Must beat the budget.
    case mainThread
    /// Runs off the main thread. The named symbol must exist in the UI layer,
    /// so "it's async" cannot be claimed without something on screen saying so.
    case background(affordance: String)
  }

  struct Op {
    let id: String
    let mode: Mode
    let iterations: Int
    let body: () throws -> Void

    init(_ id: String, _ mode: Mode, iterations: Int = 5, _ body: @escaping () throws -> Void) {
      self.id = id
      self.mode = mode
      self.iterations = iterations
      self.body = body
    }
  }

  struct Measurement: Codable {
    let id: String
    let mode: String
    let affordance: String?
    let iterations: Int
    let medianMillis: Double
    let p95Millis: Double
    let maxRSSBytes: Int64
    let budgetMillis: Double?
    let verdict: String
  }

  /// Opt-in only. The corpus takes ~40 s to build and the measurements are
  /// meaningless on a loaded machine, so `make test-integration` must not drag
  /// this in — `scripts/benchmarks/run-budget.sh` sets `CLAIR_PERF`.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAIR_PERF"] != nil))
  func allOperationsMeetTheHundredMillisecondBudget() throws {
    let corpus = try BudgetCorpus.make()
    let uiSources = try Self.uiSourceText()
    var measurements: [Measurement] = []
    var violations: [String] = []

    for op in try Self.operations(corpus) {
      try op.body()  // §4: one warm-up is discarded before the measured samples.
      var samples: [Double] = []
      var peakRSS: Int64 = 0
      for _ in 0..<op.iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        try op.body()
        let end = DispatchTime.now().uptimeNanoseconds
        samples.append(Double(end - start) / 1_000_000)
        peakRSS = max(peakRSS, EditorBenchmark.currentMaxRSS())
      }
      samples.sort()
      let median = samples[samples.count / 2]
      // §4: nearest-rank p95, sorted[ceil(0.95 * n) - 1].
      let p95 = samples[
        max(0, min(Int((Double(samples.count) * 0.95).rounded(.up)) - 1, samples.count - 1))]

      let verdict: String
      var budget: Double?
      switch op.mode {
      case .mainThread:
        budget = Self.budgetMillis
        if p95 <= Self.budgetMillis {
          verdict = "pass"
        } else {
          verdict = "over-budget"
          violations.append(
            String(
              format: "%@: main-thread p95 %.1f ms over the %.0f ms budget (median %.1f ms)",
              op.id, p95, Self.budgetMillis, median))
        }
      case .background(let affordance):
        // Named off-main path must exist at all.
        if !uiSources.all.contains(affordance) {
          verdict = "missing-affordance"
          violations.append(
            "\(op.id): declared background but the UI layer has no `\(affordance)` "
              + "— nothing consumes this work, so the feature is not wired up")
        } else if p95 <= Self.budgetMillis {
          // Under budget, so nothing has to be shown while it runs.
          verdict = "background"
        } else if uiSources.withIndicator.contains(affordance) {
          verdict = "background+loading"
        } else {
          // The rule: over 100 ms means background *and* a loading indicator.
          verdict = "missing-loading-indicator"
          violations.append(
            String(
              format:
                "%@: background p95 %.1f ms over %.0f ms, but `%@` drives no progress indicator",
              op.id, p95, Self.budgetMillis, affordance))
        }
      }

      measurements.append(
        Measurement(
          id: op.id, mode: Self.label(op.mode), affordance: Self.affordance(op.mode),
          iterations: op.iterations, medianMillis: median, p95Millis: p95,
          maxRSSBytes: peakRSS, budgetMillis: budget, verdict: verdict))
      print(
        String(
          format: "budget %@ %@ median=%.2fms p95=%.2fms",
          verdict.padding(toLength: 18, withPad: " ", startingAt: 0),
          op.id.padding(toLength: 30, withPad: " ", startingAt: 0), median, p95))
    }

    try Self.writeReport(measurements)
    #expect(
      violations.isEmpty,
      Comment(rawValue: "BUDGET-OP-100 violations:\n" + violations.joined(separator: "\n")))
  }

  // MARK: - the operation table (the contract's source of truth)

  static func operations(_ c: BudgetCorpus.Corpus) throws -> [Op] {
    let tenMB = try String(contentsOf: c.fixtures["10mb"]!, encoding: .utf8)
    let longLine = try String(contentsOf: c.fixtures["long-line"]!, encoding: .utf8)
    let japanese = try String(contentsOf: c.fixtures["1mb-japanese"]!, encoding: .utf8)
    let wideFiles = WorkbenchFiles.scan(c.wide)
    let dirtyFiles = WorkbenchFiles.scan(c.dirty)
    let deepFiles = WorkbenchFiles.scan(c.deep)

    var ops: [Op] = []

    // --- project tree -------------------------------------------------------
    // The file watcher path runs this on a utility queue (ClairAppShell.diskChanged).
    ops.append(
      Op("tree.scan.20k", .background(affordance: "scanning")) {
        _ = WorkbenchFiles.scan(c.wide)
      })
    ops.append(
      Op("tree.scan.dirty", .background(affordance: "scanning")) {
        _ = WorkbenchFiles.scan(c.dirty)
      })
    // Called synchronously inside `switchProject` on every Project switch.
    ops.append(
      Op("tree.directories.20k", .mainThread, iterations: 20) {
        _ = WorkbenchFiles.directories(of: wideFiles)
      })
    // The sort inside `scan`, isolated: 20k paths through `treeOrder`.
    ops.append(
      Op("tree.order.sort.20k", .background(affordance: "scanning")) {
        _ = wideFiles.map(\.path).sorted(by: WorkbenchFiles.treeOrder)
      })
    ops.append(
      Op("tree.order.sort.deep", .background(affordance: "scanning")) {
        _ = deepFiles.map(\.path).sorted(by: WorkbenchFiles.treeOrder)
      })

    // --- git ----------------------------------------------------------------
    ops.append(
      Op("git.status.dirty", .background(affordance: "scanning")) {
        _ = WorkbenchFiles.gitStatus(c.dirty)
      })
    // U05 source-control view reads this from the main actor.
    ops.append(
      Op("git.changes.dirty", .mainThread) {
        _ = WorkbenchGit.changes(c.dirty)
      })
    ops.append(
      Op("git.diff.one-file", .mainThread) {
        _ = WorkbenchGit.diff(c.dirty, "src/group0/File0.swift", staged: false)
      })
    ops.append(
      Op("git.currentBranch", .mainThread, iterations: 20) {
        _ = WorkbenchGit.currentBranch(c.dirty)
      })
    var dirtyState = WorkbenchState()
    dirtyState.openProject(WorkbenchProject(name: "dirty", path: c.dirty), scanFiles: false)
    // `refreshStatus()` is what git.stage / git.commit / git.switch run after
    // mutating the repository — a full walk plus `git status`, on the main actor.
    ops.append(
      Op("git.refreshStatus.dirty", .mainThread) {
        var s = dirtyState
        s.refreshStatus()
      })
    ops.append(
      Op("git.review.dirty", .mainThread) {
        var s = dirtyState
        s.files = dirtyFiles
        _ = s.review(base: nil)
      })

    // --- command palette ----------------------------------------------------
    // `paletteView` calls `paletteItems` inside its SwiftUI body, so this runs
    // on the main actor on every keystroke.
    var wideState = WorkbenchState()
    wideState.openProject(WorkbenchProject(name: "wide", path: c.wide), scanFiles: false)
    wideState.files = wideFiles
    let registry = CommandRegistry.workbench
    for query in ["s", "servicehandler", "shi42"] {
      ops.append(
        Op("palette.files.rank.20k[\(query)]", .mainThread, iterations: 20) {
          _ = registry.paletteItems(.files, query: query, state: wideState)
        })
    }
    ops.append(
      Op("palette.commands.filter", .mainThread, iterations: 20) {
        _ = registry.paletteItems(.commands, query: "git", state: wideState)
      })

    // --- project-wide search ------------------------------------------------
    ops.append(
      Op("search.find.deep-200", .background(affordance: "searching")) {
        _ = try ProjectSearch.find(root: c.deep, files: deepFiles, .literal("needle-alpha"))
      })
    ops.append(
      Op("search.find.20k", .background(affordance: "searching"), iterations: 3) {
        _ = try ProjectSearch.find(
          root: c.wide, files: wideFiles, .literal("handlerForModule7File3"))
      })
    ops.append(
      Op("search.find.regex.20k", .background(affordance: "searching"), iterations: 3) {
        _ = try ProjectSearch.find(
          root: c.wide, files: wideFiles, .regex("handlerFor[A-Z][a-z]+7File3"))
      })
    // Replace rewrites files, so alternate between two spellings: repeatable and idempotent.
    var replaceToggle = false
    ops.append(
      Op("search.replace.deep-200", .background(affordance: "replacing")) {
        replaceToggle.toggle()
        let (from, to) =
          replaceToggle ? ("needle-alpha", "needle-beta") : ("needle-beta", "needle-alpha")
        _ = try ProjectSearch.replace(root: c.deep, files: deepFiles, .literal(from), with: to)
      })

    // --- opening a file -----------------------------------------------------
    // `EditorBuffers.prefetch` reads and ropes the file on a detached task.
    for (name, text) in [("10mb", tenMB), ("long-line", longLine), ("1mb-japanese", japanese)] {
      ops.append(
        Op("file.rope.\(name)", .background(affordance: "prefetch")) {
          _ = try TextBuffer(text)
        })
    }

    // --- saving a file ------------------------------------------------------
    // `ClairWorkbenchStore.run` does the history snapshot and the write on the
    // main actor before handing `file.save` to the registry.
    let history = LocalHistory(dir: URL(fileURLWithPath: c.scratch).appending(path: "history"))
    let savePath = "saved.swift"
    try tenMB.write(toFile: c.scratch + "/" + savePath, atomically: true, encoding: .utf8)
    let saveBuffer = try TextBuffer(tenMB)
    ops.append(
      Op("file.save.10mb", .mainThread) {
        try saveBuffer.snapshot.string().write(
          toFile: c.scratch + "/" + savePath, atomically: true, encoding: .utf8)
      })
    ops.append(
      Op("history.record.10mb", .mainThread) {
        try history.record(root: c.scratch, path: savePath)
      })
    try history.record(root: c.scratch, path: savePath)  // `preview` needs a version to diff against
    guard let version = try history.versions(root: c.scratch, path: savePath).first else {
      throw BudgetCorpus.CorpusError.missing("a recorded history version for \(savePath)")
    }
    // HistoryList computes the line diff in a detached task and shows `loading` meanwhile.
    ops.append(
      Op("history.preview.10mb", .background(affordance: "loading")) {
        _ = history.preview(version, root: c.scratch, path: savePath)
      })

    // --- editing ------------------------------------------------------------
    for (name, text) in [("10mb", tenMB), ("long-line", longLine), ("1mb-japanese", japanese)] {
      let buffer = try TextBuffer(text)
      let manager = EditorTransactionManager(
        buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
      let at = UTF8Offset(text.utf8.count / 2)
      var toggle = false
      ops.append(
        Op("editor.keystroke.\(name)", .mainThread, iterations: 20) {
          toggle.toggle()
          _ = try manager.apply([
            TextEdit(range: TextUTF8Range(at, at), replacement: toggle ? "x" : "y")
          ])
          _ = try manager.undo()
        })
    }

    // --- in-file search -----------------------------------------------------
    let tenMBSnapshot = try TextBuffer(tenMB).snapshot
    let longLineSnapshot = try TextBuffer(longLine).snapshot
    ops.append(
      Op("editor.find.literal.10mb", .mainThread) {
        _ = try TextSearch.find(.literal("example_1999"), in: tenMBSnapshot)
      })
    ops.append(
      Op("editor.find.regex.10mb", .mainThread) {
        _ = try TextSearch.find(.regex("example_[0-9]+9"), in: tenMBSnapshot)
      })
    ops.append(
      Op("editor.find.literal.long-line", .mainThread) {
        _ = try TextSearch.find(.literal("zzzz"), in: longLineSnapshot)
      })

    // --- syntax (E11 pre-check; JSON is the only vendored grammar) -----------
    #if canImport(ClairEditorLanguageFixtures)
      let jsonText = try String(contentsOf: c.largeJSON, encoding: .utf8)
      let jsonBuffer = try TextBuffer(jsonText)
      let language = Language(tree_sitter_json())
      let resetParser = try SyntaxParser(language: language)
      ops.append(
        Op("syntax.reset.4mb-json", .background(affordance: "highlights"), iterations: 3) {
          _ = try resetParser.reset(to: jsonBuffer.snapshot)
        })
      let updateParser = try SyntaxParser(language: language)
      _ = try updateParser.reset(to: jsonBuffer.snapshot)
      // A whitespace insert deep inside the document: tree-sitter must reparse
      // only around it, so `lastReadByteCount` stays far below the 4 MiB total.
      let jsonAt = UTF8Offset(jsonText.utf8.count / 2)
      ops.append(
        Op("syntax.update.4mb-json", .background(affordance: "highlights"), iterations: 20) {
          let old = jsonBuffer.snapshot
          let edit = TextEdit(range: TextUTF8Range(jsonAt, jsonAt), replacement: " ")
          try jsonBuffer.replace(edit.range, with: edit.replacement, basedOn: old.revision)
          _ = try updateParser.update(
            edits: [edit], oldSnapshot: old, newSnapshot: jsonBuffer.snapshot)
        })
    #endif

    // --- workspace state ----------------------------------------------------
    let persist = URL(fileURLWithPath: c.scratch).appending(path: "workspace.json")
    var persisted = wideState
    persisted.layouts["wide"] = persisted.layout
    try persisted.save(to: persist)
    // Runs in `ClairWorkbenchStore.init`, inside the startup budget.
    ops.append(
      Op("workspace.restore", .mainThread, iterations: 20) {
        _ = WorkbenchState.restore(from: persist, scanFiles: false)
      })
    ops.append(
      Op("workspace.save", .background(affordance: "persistenceQueue"), iterations: 20) {
        try persisted.save(to: persist)
      })
    // `state.snapshot` serialises the whole state for the CLI/MCP callers, on the main actor.
    ops.append(
      Op("state.snapshot.20k", .mainThread, iterations: 20) {
        var s = wideState
        _ = registry.execute("state.snapshot", state: &s)
      })
    ops.append(
      Op("project.switch.cached", .mainThread, iterations: 20) {
        var s = wideState
        s.switchProject(to: WorkbenchProject(name: "wide", path: c.wide), scanFiles: false)
      })

    return ops
  }

  // MARK: - helpers

  static func label(_ mode: Mode) -> String {
    switch mode {
    case .mainThread: "mainThread"
    case .background: "background"
    }
  }

  static func affordance(_ mode: Mode) -> String? {
    switch mode {
    case .mainThread: nil
    case .background(let a): a
    }
  }

  struct UISources {
    /// Every UI-layer source, concatenated.
    let all: String
    /// Only the sources that render a progress indicator. An over-budget
    /// background operation's affordance must appear in here, which is what
    /// stops "it's async" from being claimed with nothing on screen.
    let withIndicator: String
  }

  /// Tokens that count as a visible progress indicator.
  static let indicatorTokens = ["ProgressView", "ClairProgress"]

  static func uiSourceText() throws -> UISources {
    let appKit = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // ClairCoreIntegrationTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // ClairCore
      .appending(path: "Sources/ClairAppKit")
    let files = try FileManager.default
      .contentsOfDirectory(at: appKit, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
    let texts = try files.map { try String(contentsOf: $0, encoding: .utf8) }
    return UISources(
      all: texts.joined(separator: "\n"),
      withIndicator: texts.filter { text in indicatorTokens.contains(where: text.contains) }
        .joined(separator: "\n"))
  }

  /// Machine-readable report at `CLAIR_PERF_OUT`, if the runner asked for one.
  static func writeReport(_ measurements: [Measurement]) throws {
    guard let path = ProcessInfo.processInfo.environment["CLAIR_PERF_OUT"] else { return }
    struct Report: Codable {
      let contract: String
      let budgetMillis: Double
      let corpusLayoutVersion: Int
      let recordedAt: String
      let host: String
      let buildConfiguration: String
      let measurements: [Measurement]
    }
    #if DEBUG
      let configuration = "debug"
    #else
      let configuration = "release"
    #endif
    let report = Report(
      contract: "clair-v2-performance-budget", budgetMillis: budgetMillis,
      corpusLayoutVersion: BudgetCorpus.layoutVersion,
      recordedAt: ISO8601DateFormatter().string(from: Date()),
      host: hardwareModel(), buildConfiguration: configuration,
      measurements: measurements)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(report).write(to: url, options: .atomic)
  }
}

/// `hw.model` (e.g. `Mac16,10`) instead of the host name, so committed reports carry no personal machine name.
private func hardwareModel() -> String {
  var size = 0
  sysctlbyname("hw.model", nil, &size, nil, 0)
  var model = [CChar](repeating: 0, count: size)
  sysctlbyname("hw.model", &model, &size, nil, 0)
  return String(cString: model)
}
