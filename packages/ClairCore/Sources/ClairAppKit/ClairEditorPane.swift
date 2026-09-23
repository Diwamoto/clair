#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import ClairEditorCore
  import ClairEditorLanguage
  import ClairEditorView
  import Observation
  import SwiftUI

  private typealias C = DesignTokens.Color

  struct EditorBlame: Sendable, Equatable {
    let author: String
    let summary: String
  }

  /// Reads one complete working-tree blame off the UI thread. The result is published atomically.
  private enum EditorBlameLoader {
    static func load(root: String, path: String) -> [EditorBlame]? {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.currentDirectoryURL = URL(fileURLWithPath: root)
      process.arguments = ["-c", "core.quotePath=false", "blame", "--line-porcelain", "--", path]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      do { try process.run() } catch { return nil }

      var result: [EditorBlame] = []
      var author = ""
      var summary = ""
      var pending = Data()
      while !Task<Never, Never>.isCancelled {
        let chunk = pipe.fileHandleForReading.readData(ofLength: 64 * 1024)
        if chunk.isEmpty { break }
        pending.append(chunk)
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 10) {
          let line = String(decoding: pending[start..<newline], as: UTF8.self)
          if line.hasPrefix("author ") { author = String(line.dropFirst(7)) }
          else if line.hasPrefix("summary ") { summary = String(line.dropFirst(8)) }
          else if line.hasPrefix("\t") { result.append(EditorBlame(author: author, summary: summary)) }
          start = pending.index(after: newline)
        }
        pending.removeSubrange(..<start)
      }
      if Task<Never, Never>.isCancelled { process.terminate() }
      process.waitUntilExit()
      return process.terminationStatus == 0 && !Task<Never, Never>.isCancelled ? result : nil
    }
  }

  /// E11: one `SyntaxHighlighter` per open file, off the main thread.
  /// `SyntaxHighlighter`/`SyntaxParser` are not `Sendable` (see
  /// `SyntaxParser`'s doc comment — "keep one instance on its owning
  /// actor"), so this actor, not `EditorBuffers` itself, is what actually
  /// owns them; `EditorBuffers` only holds Sendable results and cancellable
  /// `Task` handles. `INV-PERF-005`: every call here either returns fast or
  /// is wrapped by its `EditorBuffers` caller in a `Task` that a file
  /// switch/close cancels (`dropHighlights`); a language with no vendored
  /// grammar (`EditorLanguageID.detect` returns nil) or a query that fails
  /// to compile degrades to empty highlights, never a crash or a stuck
  /// loading state.
  actor SyntaxHighlightActor {
    private var highlighters: [String: SyntaxHighlighter] = [:]

    func drop(_ path: String) { highlighters.removeValue(forKey: path) }

    /// Full parse, for a freshly opened file. `nil`/empty covers both "no
    /// vendored grammar for this extension" and "grammar/query failed to
    /// build" — either way the file still opens, just colorless.
    func reset(_ path: String, snapshot: TextSnapshot) -> SyntaxResult {
      guard let id = EditorLanguageID.detect(path: path), let highlighter = try? SyntaxHighlighter(languageID: id)
      else { return SyntaxResult(spans: [], folds: [], revision: snapshot.revision) }
      highlighters[path] = highlighter
      let spans = (try? highlighter.reset(to: snapshot)) ?? []
      return SyntaxResult(spans: spans, folds: highlighter.foldRanges, revision: snapshot.revision)
    }

    /// Differential reparse (`SyntaxParser.update`, never a from-scratch
    /// reparse on keystroke). Returns `nil` when there is no highlighter yet
    /// for `path` (undetected language, or racing ahead of the first
    /// `reset`) so the caller knows to leave whatever it already has alone.
    func update(
      _ path: String, edits: [TextEdit], oldSnapshot: TextSnapshot, newSnapshot: TextSnapshot
    ) -> SyntaxResult? {
      guard let highlighter = highlighters[path],
        let spans = try? highlighter.update(edits: edits, oldSnapshot: oldSnapshot, newSnapshot: newSnapshot)
      else { return nil }
      return SyntaxResult(spans: spans, folds: highlighter.foldRanges, revision: newSnapshot.revision)
    }
  }

  /// One parse's highlights and E13 fold candidates, tagged with the revision they describe.
  struct SyntaxResult: Sendable {
    let spans: [EditorHighlightSpan]
    let folds: [TextUTF8Range]
    let revision: TextRevision

    /// Paints the result; fold candidates only land on the revision they were computed for
    /// (`INV-REV-004` — a stale one would fold the wrong lines; the view maps the old set meanwhile).
    @MainActor func apply(to view: ClairEditorView?) {
      guard let view else { return }
      view.highlights = spans
      if view.snapshot.revision == revision { view.foldRanges = folds }
    }
  }

  /// U05: open editor buffers of the active Project. Owned by the workbench store; the store drops a
  /// path when the disk changed under it (principle 8: the unsaved buffer is discarded, not merged).
  @MainActor @Observable public final class EditorBuffers {
    public enum Load: @unchecked Sendable { case ready(EditorTransactionManager), failed(String) }

    private var loads: [String: Load] = [:]
    private var revisions: [String: Int] = [:]
    /// 1-based caret of each open file (status bar Ln/Col); grapheme columns.
    private(set) var caret: [String: (line: Int, col: Int)] = [:]
    private(set) var blame: [String: [EditorBlame]] = [:]
    private var blameTasks: [String: Task<Void, Never>] = [:]

    func startBlame(_ path: String, root: String, snapshot: TextSnapshot) {
      guard blame[path] == nil, blameTasks[path] == nil else { return }
      let rev = snapshot.revision
      blameTasks[path] = Task { [weak self] in
        let worker = Task.detached(priority: .utility) { EditorBlameLoader.load(root: root, path: path) }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard let self, !Task.isCancelled else { return }
        self.blameTasks[path] = nil
        // A completed file-wide result only belongs to the exact content revision opened above.
        guard case .ready(let manager) = self.loads[path], manager.buffer.snapshot.revision == rev,
          let result, result.count == snapshot.lineCount || result.count == snapshot.lineCount - 1 else { return }
        self.blame[path] = result
      }
    }

    func dropBlame(_ path: String) {
      blameTasks.removeValue(forKey: path)?.cancel()
      blame[path] = nil
    }

    func setCaret(_ path: String, _ sel: TextSelectionSet, in snapshot: TextSnapshot) {
      guard let head = sel.selections.first?.head,
        let p = try? snapshot.position(at: head, columnUnit: GraphemeUnit.self, rounding: .down)
      else { return }
      caret[path] = (p.line.value + 1, p.column.value + 1)
    }
    /// Search-hit jump target (1-based line, 0-based UTF-16 column); `nonce` makes a repeat jump to the same line still fire.
    private(set) var reveal: (path: String, line: Int, column: Int, nonce: Int)?
    /// Above this the file is refused rather than loaded whole (large-file paths are E10's scope).
    /// Spec §5.9: the canonical `10mb` fixture must open, and it is written in whole lines, so it lands a
    /// few bytes past 10 MiB — keep real headroom rather than an exact 10 MiB edge.
    nonisolated static let maxBytes = 16 * 1024 * 1024

    func reveal(_ path: String, line: Int, column: Int = 0) { reveal = (path, line, column, (reveal?.nonce ?? 0) + 1) }

    func isOpen(_ path: String) -> Bool { if case .ready = loads[path] { true } else { false } }

    /// Bumped on drop so the surface rebuilds even when the path is unchanged.
    func revision(_ path: String) -> Int { revisions[path, default: 0] }

    func load(_ path: String, root: String) -> Load {
      if let l = loads[path] { return l }
      let l = Self.read(root + "/" + path)
      loads[path] = l
      return l
    }

    /// Rebuilds the surface from the buffer after it was changed outside the view (a review suggestion applied).
    func refresh(_ path: String) { revisions[path, default: 0] += 1 }

    func drop(_ paths: Set<String>) {
      for path in paths {
        dropBlame(path)
        let hadLoad = loads.removeValue(forKey: path) != nil
        let pending = loading.removeValue(forKey: path)
        pending?.task.cancel()
        if hadLoad || pending != nil { revisions[path, default: 0] += 1 }
        if let open = languagePaths.removeValue(forKey: path) { language.close(open.path, root: open.root) }
        savedFolds[path] = nil
      }
      dropHighlights(paths)
    }

    // MARK: - E12 language servers

    let language = LanguageServices()
    /// Buffers open on a language server: relative path → (absolute path, root).
    private var languagePaths: [String: (path: String, root: String)] = [:]

    /// Opens (or resyncs) the buffer on its language server and routes its diagnostics into `view`.
    func attachLanguage(_ path: String, root: String, snapshot: TextSnapshot, view: ClairEditorView) {
      let absolute = root + "/" + path
      languagePaths[path] = (absolute, root)
      language.attach(absolute, root: root, snapshot: snapshot) { [weak view] revision, spans in
        // `INV-REV-004`: diagnostics for any other revision are dropped; the view already rebased the old ones.
        guard let view, view.snapshot.revision == revision else { return }
        view.diagnostics = spans
      }
    }

    // MARK: - E11 syntax highlighting

    private let syntax = SyntaxHighlightActor()
    /// Paths whose first (`reset`) highlight parse hasn't finished yet. A
    /// freshly opened file's `ProgressView` overlay (`EditorPane.body`) keys
    /// off this so its first paint doesn't flash from colorless to colored
    /// (dogfood review, 2026-09-22) — only the *initial* parse shows it;
    /// per-keystroke `updateHighlights` never touches this set.
    private(set) var highlightsLoading: Set<String> = []
    private var highlightTasks: [String: Task<Void, Never>] = [:]

    /// Kicks off the background initial parse for a freshly opened file.
    /// Cancellable (`INV-PERF-005`): superseded by a second call for the
    /// same path only if the first was already dropped, and `dropHighlights`
    /// cancels it outright on file switch/close. `onSpans` lands back on the
    /// main actor (this method is itself `@MainActor`-isolated, and `Task {
    /// }` inherits that isolation around its `await`) and only ever assigns
    /// `ClairEditorView.highlights` — an attribute overlay that never calls
    /// through `EditorTransactionManager`, so it cannot advance the content
    /// revision (`INV-REV-002`).
    func startHighlighting(
      _ path: String, manager: EditorTransactionManager, onSpans: @escaping (SyntaxResult) -> Void
    ) {
      guard highlightTasks[path] == nil else { return }
      highlightsLoading.insert(path)
      let snapshot = manager.buffer.snapshot
      let syntax = self.syntax
      highlightTasks[path] = Task { [weak self] in
        let result = await syntax.reset(path, snapshot: snapshot)
        guard !Task.isCancelled else { return }
        onSpans(result)
        self?.highlightsLoading.remove(path)
        self?.highlightTasks.removeValue(forKey: path)
      }
    }

    /// Differential reparse after one committed edit. Same attribute-only
    /// guarantee as `startHighlighting`: `onSpans` only ever reaches
    /// `view.highlights`, never `manager`.
    func updateHighlights(
      _ path: String, edits: [TextEdit], oldSnapshot: TextSnapshot, newSnapshot: TextSnapshot,
      onSpans: @escaping (SyntaxResult) -> Void
    ) {
      let syntax = self.syntax
      Task {
        guard let result = await syntax.update(path, edits: edits, oldSnapshot: oldSnapshot, newSnapshot: newSnapshot)
        else { return }
        guard !Task.isCancelled else { return }
        onSpans(result)
      }
    }

    // MARK: - E13 folding

    /// Folds per path with the revision they were last valid at, so a rebuilt view (tab switch) restores them.
    private var savedFolds: [String: (revision: TextRevision, folds: [TextUTF8Range])] = [:]
    private var views: [String: WeakView] = [:]
    private struct WeakView { weak var view: ClairEditorView? }

    /// The live editor view of `path`, for commands that act on its caret (fold/unfold).
    func view(_ path: String) -> ClairEditorView? { views[path]?.view }

    func attachFolds(_ path: String, view: ClairEditorView) {
      views[path] = WeakView(view: view)
      if let saved = savedFolds[path], saved.revision == view.snapshot.revision { view.folds = saved.folds }
      view.onFoldsChange = { [weak self, weak view] folds in
        guard let view else { return }
        self?.savedFolds[path] = (view.snapshot.revision, folds)
      }
    }

    private func dropHighlights(_ paths: Set<String>) {
      for path in paths {
        highlightTasks.removeValue(forKey: path)?.cancel()
        highlightsLoading.remove(path)
      }
      let syntax = self.syntax
      Task { for path in paths { await syntax.drop(path) } }
    }

    /// Invalidates every clean cached or in-flight file after an operation may have replaced the
    /// working tree. Closed tabs remain cached for fast reopen, so limiting this to visible tabs
    /// would let a branch switch resurrect content from the previous branch.
    func dropAll(except preserved: Set<String>) {
      drop(Set(loads.keys).union(loading.keys).subtracting(preserved))
    }

    private struct PendingLoad {
      let id: Int
      let task: Task<Load?, Never>
    }
    private var loading: [String: PendingLoad] = [:]
    private var loadID = 0

    /// Already-read buffer, or nil while it still has to be read (see `prefetch`).
    func peek(_ path: String) -> Load? { loads[path] }

    /// Reads and parses off the main thread so a tab switch never blocks on I/O. A drop while the read is in
    /// flight bumps the revision and the stale result is discarded.
    func prefetch(_ path: String, root: String) async {
      while loads[path] == nil, !Task.isCancelled {
        let rev = revision(path)
        let pending: PendingLoad
        if let existing = loading[path] {
          pending = existing
        } else {
          loadID += 1
          let worker = Task.detached(priority: .userInitiated) { () -> Load? in
            guard !Task.isCancelled else { return nil }
            let load = Self.read(root + "/" + path)
            return Task.isCancelled ? nil : load
          }
          pending = PendingLoad(id: loadID, task: worker)
          loading[path] = pending
        }
        let load = await withTaskCancellationHandler(
          operation: { await pending.task.value },
          onCancel: { pending.task.cancel() })
        if loading[path]?.id == pending.id { loading.removeValue(forKey: path) }
        guard !Task.isCancelled else { return }
        guard let load else { continue }
        if revision(path) == rev, loads[path] == nil { loads[path] = load }
      }
    }

    func save(_ path: String, root: String) throws {
      guard case .ready(let m) = loads[path] else { return }
      try m.buffer.snapshot.string().write(toFile: root + "/" + path, atomically: true, encoding: .utf8)
      dropBlame(path)
      startBlame(path, root: root, snapshot: m.buffer.snapshot)
    }

    nonisolated private static func read(_ full: String) -> Load {
      guard let data = FileManager.default.contents(atPath: full) else { return .failed("ファイルを読み込めません。") }
      guard data.count <= maxBytes else { return .failed("\(maxBytes >> 20) MiB を超えるファイルは開けません。") }
      guard let text = String(data: data, encoding: .utf8), let buffer = try? TextBuffer(text) else {
        return .failed("UTF-8 のテキストではないため開けません。")
      }
      return .ready(EditorTransactionManager(buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0))))
    }
  }

  /// The editor leaf of the pane tree: the active tab's file, or an explicit empty / error state.
  struct EditorPane: View {
    let buffers: EditorBuffers
    let root: String?
    let path: String?
    var softWrap = false
    var debugLine: Int? = nil
    var debugBreakpoints: Set<Int> = []
    var onToggleDebugBreakpoint: ((Int) -> Void)? = nil
    let onEdit: (String) -> Void
    let onCaret: (String, TextSelectionSet, TextSnapshot) -> Void

    var body: some View {
      if let path, let root {
        switch buffers.peek(path) {
        case nil:
          // Instant feedback while the file is read and roped in the background.
          VStack(spacing: 0) {
            breadcrumb(path)
            Text("Loading...").frame(maxWidth: .infinity, maxHeight: .infinity).background(C.canvas)
          }.task(id: path) { await buffers.prefetch(path, root: root) }
        case .ready(let m)?:
          VStack(spacing: 0) {
            breadcrumb(path)
            ZStack(alignment: .topTrailing) {
              EditorSurface(
                manager: m, buffers: buffers, root: root, path: path, softWrap: softWrap,
                debugLine: debugLine, debugBreakpoints: debugBreakpoints, onToggleDebugBreakpoint: onToggleDebugBreakpoint,
                onCaret: { onCaret(path, $0, m.buffer.snapshot) },
                reveal: buffers.reveal?.path == path ? buffers.reveal : nil, onEdit: { onEdit(path) }
              ).id("\(path)#\(buffers.revision(path))")
              // E11 dogfood review (2026-09-22): a small corner spinner while
              // the file's *initial* highlight parse is in flight, so a big
              // file doesn't flash from colorless to colored — never shown
              // again after this file's first parse, incremental updates on
              // keystroke are fast enough (BUDGET-OP-100) to need nothing.
              if buffers.highlightsLoading.contains(path) {
                ProgressView().controlSize(.small).padding(8)
              }
            }
          }
        case .failed(let message)?: note(message)
        }
      } else {
        note("ファイルを選択してください。")
      }
    }

    /// Mock `PathBreadcrumb`: 24px, directory parts quiet, the file name semibold.
    private func breadcrumb(_ path: String) -> some View {
      let parts = path.split(separator: "/").map(String.init)
      return HStack(spacing: 4) {
        ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
          if i > 0 { Text("›").font(.system(size: 11)).foregroundStyle(C.textQuaternary) }
          Text(part).font(.system(size: 11, weight: i == parts.count - 1 ? .semibold : .regular))
            .foregroundStyle(i == parts.count - 1 ? C.textSecondary : C.textQuaternary).lineLimit(1)
        }
        Spacer(minLength: 0)
        if let line = buffers.caret[path]?.line, let lines = buffers.blame[path], lines.indices.contains(line - 1) {
          let info = lines[line - 1]
          Text("\(info.author) · \(info.summary)")
            .font(.system(size: 10)).foregroundStyle(C.textQuaternary).lineLimit(1)
            .help("行 \(line): \(info.author) · \(info.summary)")
        }
      }.padding(.horizontal, 12).frame(height: 24).background(C.canvas)
    }

    private func note(_ s: String) -> some View {
      Text(s).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
    }
  }

  /// U05: overlay scroller with no track; only the knob is drawn, squarer than AppKit's pill, in Clair text tokens.
  /// Shared by the editor and SwiftUI scroll views (`.clairScroller()`).
  final class ClairScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    // Half of AppKit's thickness, so the hit area matches the thin knob.
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
      super.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle) / 2
    }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
      let k = rect(for: .knob)
      let r = k.height > k.width ? k.insetBy(dx: 1, dy: 2) : k.insetBy(dx: 2, dy: 1)
      NSColor(hitPart == .knob ? C.textSecondary : C.textTertiary).withAlphaComponent(hitPart == .knob ? 0.7 : 0.45).setFill()
      NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
    }
  }

  /// Swaps the enclosing SwiftUI `ScrollView`'s AppKit scrollers for `ClairScroller`.
  private struct ClairScrollerInstaller: NSViewRepresentable {
    final class Probe: NSView {
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let scroll = enclosingScrollView, !(scroll.verticalScroller is ClairScroller) else { return }
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.verticalScroller = ClairScroller(); scroll.horizontalScroller = ClairScroller()
      }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
  }

  extension View {
    /// Apply to the content inside a `ScrollView`.
    func clairScroller() -> some View { background(ClairScrollerInstaller()) }
  }

  private struct EditorSurface: NSViewRepresentable {
    let manager: EditorTransactionManager
    let buffers: EditorBuffers
    let root: String
    let path: String
    let softWrap: Bool
    let debugLine: Int?
    let debugBreakpoints: Set<Int>
    let onToggleDebugBreakpoint: ((Int) -> Void)?
    let onCaret: (TextSelectionSet) -> Void
    let reveal: (path: String, line: Int, column: Int, nonce: Int)?
    let onEdit: () -> Void

    final class Coordinator {
      var nonce = 0
      var completion: CompletionController?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
      scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
      scroll.verticalScroller = ClairScroller(); scroll.horizontalScroller = ClairScroller()
      scroll.drawsBackground = true; scroll.backgroundColor = NSColor(C.canvas)
      // Mock editor: 12px mono on 19px rows, One Dark on the canvas colour, 54px gutter.
      let view = ClairEditorView(
        snapshot: manager.buffer.snapshot, selection: manager.selection,
        font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineHeight: 19)
      view.background = NSColor(C.canvas); view.textColor = NSColor(C.code)
      view.caretColor = NSColor(C.textPrimary); view.selectionColor = NSColor(C.debugBlue).withAlphaComponent(0.3)
      view.gutterWidth = 54
      view.lineNumberColor = NSColor(C.lineNumber); view.currentLineNumberColor = NSColor(C.textTertiary)
      view.debugStoppedLine = debugLine; view.debugBreakpoints = debugBreakpoints
      view.debugLineColor = NSColor(C.debugBlue).withAlphaComponent(0.14)
      view.debugBreakpointColor = NSColor(C.danger)
      view.onToggleBreakpoint = onToggleDebugBreakpoint
      let completion = CompletionController(language: buffers.language, path: root + "/" + path, root: root)
      completion.view = view
      context.coordinator.completion = completion
      view.keyInterceptor = { [weak completion] in completion?.handle($0) ?? false }
      view.onCommitEdits = { [weak view, manager, onEdit, buffers, path, root, weak completion] edits in
        guard let view else { return }
        let old = manager.buffer.snapshot
        guard let new = try? manager.apply(edits) else { return }
        view.applyEdits(edits, oldSnapshot: old, newSnapshot: new, selection: manager.selection)
        buffers.dropBlame(path)
        onEdit()
        // E12: the server sees the same incremental edit, in order, then the list refilters.
        buffers.language.change(root + "/" + path, root: root, edits: edits, old: old, new: new)
        completion?.didEdit(edits)
        // E11: background differential reparse; never blocks this closure,
        // never touches `manager` (INV-REV-002 — see `updateHighlights`'s
        // doc comment).
        buffers.updateHighlights(path, edits: edits, oldSnapshot: old, newSnapshot: new) { [weak view] in
          $0.apply(to: view)
        }
      }
      view.onSelectionChange = { [weak manager, onCaret, weak completion] in
        manager?.setSelection($0); onCaret($0); completion?.didMoveCaret()
      }
      scroll.documentView = view
      // E11: kick off this file's initial background highlight parse once,
      // when its `ClairEditorView` is first created.
      buffers.startHighlighting(path, manager: manager) { [weak view] in $0.apply(to: view) }
      buffers.startBlame(path, root: root, snapshot: manager.buffer.snapshot)
      view.softWrap = softWrap
      scroll.hasHorizontalScroller = !softWrap
      buffers.attachFolds(path, view: view)
      buffers.attachLanguage(path, root: root, snapshot: manager.buffer.snapshot, view: view)
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
      if let view = scroll.documentView as? ClairEditorView {
        view.debugStoppedLine = debugLine
        view.debugBreakpoints = debugBreakpoints
        view.onToggleBreakpoint = onToggleDebugBreakpoint
      }
      if let view = scroll.documentView as? ClairEditorView, view.softWrap != softWrap {
        view.softWrap = softWrap
        scroll.hasHorizontalScroller = !softWrap
      }
      guard let r = reveal, r.nonce != context.coordinator.nonce, let view = scroll.documentView as? ClairEditorView else { return }
      context.coordinator.nonce = r.nonce
      DispatchQueue.main.async { view.reveal(line: r.line - 1, utf16Column: r.column) }  // after the new view is laid out and in a window
    }
  }
#endif
