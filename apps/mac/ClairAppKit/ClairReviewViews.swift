#if os(macOS)
  import ClairShared
  import ClairDesignSystem
  import ClairEditorCore
  import ClairReview
  import ClairWorkspace
  import Observation
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line
  private typealias W = DesignTokens.Wash

  /// U05: which side of a change the diff pane is showing.
  struct DiffTarget: Hashable, Sendable {
    let path: String
    let staged: Bool
    let untracked: Bool
    var against: String? = nil
    /// ADR-0022: Claude Code's proposed text for `path` (`WorkbenchDiffTab.proposal`).
    var proposal: String? = nil
  }

  /// A suggestion as the diff shows it. `stale`: the buffer changed since it was made, so it can no longer apply.
  struct PlacedSuggestion: Identifiable {
    let line: Int
    /// Last replaced line; equals `line` for a one-line proposal.
    var endLine: Int? = nil
    let suggestion: ReviewSuggestion
    let stale: Bool
    var id: UUID { suggestion.id }
    var replacement: String { suggestion.hunks.first?.replacement ?? "" }
  }

  /// Review threads anchored to a file line, persisted as JSON keyed by project root + path.
  /// Drift: a thread remembers its line's text; given the current file it moves to the nearest identical line,
  /// or is reported stale (line 0) when that text is gone.
  // ponytail: content match, not `rebase(through:)` — survives external/agent edits and reloads. A reworded line goes stale; blank/duplicate lines pick the nearest twin.
  // ponytail: suggestions are in-memory only (their base revision does not outlive the buffer).
  @MainActor @Observable final class ReviewStore {
    private var managers: [String: ReviewThreadManager] = [:]
    private var lines: [UUID: Int] = [:]
    private var texts: [UUID: String] = [:]
    private var suggestionLines: [UUID: Int] = [:]
    private var suggestionEnds: [UUID: Int] = [:]
    private(set) var version = 0
    private let file: URL?
    private let asynchronousPersistence: Bool
    private let persistenceQueue = DispatchQueue(label: "com.diwamoto.clair.review-save", qos: .utility)
    static let you = ReviewAuthor(displayName: "あなた", kind: .human)
    /// The author of a thread or suggestion an agent posted through `review.comment` / `review.suggest`.
    static let agent = ReviewAuthor(displayName: "Agent", kind: .agent)

    convenience init() {
      self.init(persistingAt: URL.applicationSupportDirectory.appending(path: "Clair/reviews.json"), asynchronously: true)
    }

    /// Explicit files stay synchronous so tests and importers can observe a fully loaded store.
    convenience init(file: URL?) { self.init(persistingAt: file, asynchronously: false) }

    private init(persistingAt file: URL?, asynchronously: Bool) {
      self.file = file
      asynchronousPersistence = asynchronously
      guard let file else { return }
      if asynchronously {
        Task { [weak self] in
          let all = await Task.detached(priority: .utility) { Self.read(file) }.value
          self?.load(all)
        }
      } else {
        load(Self.read(file))
      }
    }

    nonisolated private static func read(_ file: URL) -> [String: [ReviewThreadRecord]] {
      guard let data = try? Data(contentsOf: file) else { return [:] }
      return (try? JSONDecoder().decode([String: [ReviewThreadRecord]].self, from: data)) ?? [:]
    }

    private func load(_ all: [String: [ReviewThreadRecord]]) {
      for (k, rs) in all {
        // A comment created before the startup read completed is newer than the disk snapshot.
        guard managers[k] == nil else { continue }
        managers[k] = ReviewThreadManager(threads: rs.map(\.thread))
        for r in rs { lines[r.id] = r.line; texts[r.id] = r.text }
      }
      version += 1
    }

    private func key(_ root: String, _ path: String) -> String { root + "\0" + path }

    private func save() {
      guard let file else { return }
      let all = managers.mapValues { m in m.threads.compactMap { t in lines[t.id].map { ReviewThreadRecord(t, line: $0, text: texts[t.id]) } } }
      let write: @Sendable () -> Void = {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: file, options: .atomic)
      }
      if asynchronousPersistence { persistenceQueue.async(execute: write) } else { write() }
    }

    /// Nearest 1-based line in `file` whose text equals `text`.
    static func locate(_ text: String, near line: Int, in file: [String]) -> Int? {
      file.indices.filter { file[$0] == text }.map { $0 + 1 }.min { abs($0 - line) < abs($1 - line) }
    }

    /// Where each thread sits now. Without `file` (or for a thread saved before texts were kept) the saved line is trusted.
    private func placed(_ root: String, _ path: String, in file: [String]?) -> [(line: Int, saved: Int, thread: ReviewThread, stale: Bool)] {
      _ = version
      return (managers[key(root, path)]?.threads ?? []).compactMap { t in
        guard let saved = lines[t.id] else { return nil }
        guard let file, let text = texts[t.id] else { return (saved, saved, t, false) }
        return Self.locate(text, near: saved, in: file).map { ($0, saved, t, false) } ?? (saved, saved, t, true)
      }
    }

    /// 1-based file line → threads on it; stale threads (their line's text is gone) are under key 0.
    func threads(root: String, _ path: String, in file: [String]? = nil) -> [Int: [ReviewThread]] {
      var out: [Int: [ReviewThread]] = [:]
      for p in placed(root, path, in: file) { out[p.stale ? 0 : p.line, default: []].append(p.thread) }
      return out
    }

    /// Returns false (and adds nothing) for a blank body or a line past the end of `snapshot`.
    @discardableResult
    func add(
      root: String, path: String, line: Int, endLine: Int? = nil, text: String? = nil, body: String,
      author: ReviewAuthor? = nil, snapshot: TextSnapshot
    ) -> Bool {
      guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let range = Self.range(line, endLine, in: snapshot)
      else { return false }
      let k = key(root, path), m = managers[k] ?? ReviewThreadManager()
      managers[k] = m
      let id = m.addThread(author: author ?? Self.you, body: body, anchor: ReviewAnchor(range: range)).id
      lines[id] = line; texts[id] = text
      version += 1; save()
      return true
    }

    /// Lines `line...endLine` (1-based) of `snapshot` without the last terminator; nil past the end.
    static func range(_ line: Int, _ endLine: Int?, in snapshot: TextSnapshot) -> TextUTF8Range? {
      guard line >= 1, let first = try? snapshot.line(at: TextLineIndex(line - 1)),
        let last = try? snapshot.line(at: TextLineIndex(max(line, endLine ?? line) - 1))
      else { return nil }
      return TextUTF8Range(first.contentRange.lowerBound, last.contentRange.upperBound)
    }

    /// Every thread of `root` (or only `path`'s) as an agent reads it, placed in the current files.
    func list(root: String, path: String? = nil, file: (String) -> [String]?) -> [WorkbenchReviewThread] {
      let prefix = root + "\0"
      let paths = path.map { [$0] } ?? managers.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
      return paths.flatMap { p in
        placed(root, p, in: file(p)).sorted { $0.line < $1.line }.map { x in
          WorkbenchReviewThread(
            id: x.thread.id.uuidString, path: p, line: x.line, stale: x.stale, state: x.thread.state == .open ? "open" : "resolved",
            comments: x.thread.comments.filter { $0.state == .visible }.map { .init(author: $0.author.displayName, body: $0.body) })
        }
      }
    }

    /// Open threads as a prompt for an agent: one `path:line` heading per thread, comments beneath. Nil when nothing is open.
    func prompt(root: String, path: String, in file: [String]? = nil) -> String? {
      let open = placed(root, path, in: file).filter { $0.thread.state == .open }.sorted { $0.line < $1.line }
      guard !open.isEmpty else { return nil }
      return tr("次のレビューコメントに対応してください。\n\n")
        + open.map { p in
          "\(path):\(p.line)" + (p.stale ? tr("（コメント後に行が変更されています）") : "") + "\n"
            + p.thread.comments.map { "- \($0.body)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    func resolve(root: String, path: String, id: UUID) { try? managers[key(root, path)]?.resolveThread(id: id); version += 1; save() }

    // MARK: suggestions

    /// A replacement proposal for lines `line...endLine` (one line by default), bound to the buffer's current revision.
    /// Returns false (and adds nothing) for a line past the end of `snapshot`.
    @discardableResult
    func suggest(
      root: String, path: String, line: Int, endLine: Int? = nil, replacement: String, description: String? = nil, snapshot: TextSnapshot
    ) -> Bool {
      guard let range = Self.range(line, endLine, in: snapshot) else { return false }
      let k = key(root, path), m = managers[k] ?? ReviewThreadManager()
      managers[k] = m
      let s = m.addSuggestion(
        hunks: [ReviewSuggestionHunk(anchor: ReviewAnchor(range: range), replacement: replacement)], description: description,
        baseRevision: snapshot.revision)
      suggestionLines[s.id] = line
      if let endLine, endLine > line { suggestionEnds[s.id] = endLine }
      version += 1
      return true
    }

    func suggestions(root: String, _ path: String, current: TextRevision?) -> [PlacedSuggestion] {
      _ = version
      return (managers[key(root, path)]?.suggestions ?? []).compactMap { s in
        suggestionLines[s.id].map {
          PlacedSuggestion(line: $0, endLine: suggestionEnds[s.id], suggestion: s, stale: s.state == .pending && s.baseRevision != current)
        }
      }
    }

    /// Applies into the open buffer as one undo unit. Returns a message on refusal, nil on success.
    func apply(root: String, path: String, id: UUID, in manager: EditorTransactionManager) -> String? {
      defer { version += 1 }
      do { try managers[key(root, path)]?.applySuggestion(id: id, in: manager); return nil }
      catch ReviewThreadManagerError.suggestionRevisionMismatch { return tr("バッファが変更されたため適用できません。") }
      catch { return tr("適用できません。") }
    }

    func reject(root: String, path: String, id: UUID) { try? managers[key(root, path)]?.rejectSuggestion(id: id); version += 1 }
  }

  /// Source-control sidebar: staged / changes / untracked sections with a stage toggle per row.
  struct ChangesList: View {
    let changes: [GitChange]
    /// nil while `git status` is loading, false when it failed: neither may claim "no changes".
    let loaded: Bool?
    let selected: DiffTarget?
    let onSelect: (DiffTarget) -> Void
    let onToggle: (GitChange, _ staged: Bool) -> Void
    /// Asks to discard a file's change; the flag is the row's section (staged → back to HEAD).
    let onDiscard: (GitChange, _ staged: Bool) -> Void
    let menus: ClairMenuController
    let menu: (GitChange, _ staged: Bool) -> ClairMenuSpec
    /// Section-wide stage/unstage; the flag is the desired state.
    let onBulk: ([GitChange], _ stage: Bool) -> Void
    /// Starts a commit through the typed command registry.
    let onCommit: (String) -> Void
    let busy: Bool
    let operationMessage: String?
    @State private var message = ""
    @State private var hovered: DiffTarget?
    @State private var collapsed: Set<String> = []

    /// Same geometry as the explorer's treeRow in ClairAppShell: inset, rounded 28px row, 12px indent per level.
    /// `trailing` sits over the row instead of inside the Button label, where the row's own click would swallow it.
    private func treeRow<Content: View, Trailing: View>(depth: Int, selected: Bool, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder _ content: () -> Content) -> some View {
      ZStack(alignment: .trailing) {
        Button(action: action) {
          HStack(spacing: 10, content: content)
            .padding(.leading, 8 + CGFloat(depth + 1) * 12).padding(.trailing, 8).frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
            .contentShape(Rectangle())
        }.buttonStyle(.hoverWash)
        HStack(spacing: 10, content: trailing).padding(.trailing, 16)
      }.padding(.horizontal, 8)
    }

    private var canCommit: Bool { !busy && changes.contains(where: \.staged) && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var commitBox: some View {
      VStack(alignment: .leading, spacing: 6) {
        // Multi-line box, distinct from the button: Return commits, Command- or Option-Return inserts a newline.
        TextField(tr("コミットメッセージ"), text: $message, axis: .vertical)
          .textFieldStyle(.plain).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textPrimary)
          .lineLimit(3...8)
          .padding(.horizontal, 8).padding(.vertical, 6)
          .background(C.surfaceActive, in: RoundedRectangle(cornerRadius: Radius.control))
          // ponytail: Command-Return appends at the end, not at the caret; route through NSTextView if mid-text breaks matter.
          .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            message += "\n"
            return .handled
          }
          .onSubmit(commit)
        Button(action: commit) {
          Label(tr("コミット"), systemImage: "checkmark").font(Typography.font(Typography.sidebarStrong))
            .foregroundStyle(canCommit ? C.textPrimary : C.textQuaternary)
            .frame(maxWidth: .infinity).frame(height: 26)
            .background(C.surfaceActive, in: RoundedRectangle(cornerRadius: Radius.control))
        }.buttonStyle(.hoverWash).disabled(!canCommit)
      }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func commit() {
      guard canCommit else { return }
      onCommit(message)
    }

    var body: some View {
      VStack(spacing: 0) {
        if let operationMessage {
          HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.small) }
            Text(operationMessage).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textTertiary).lineLimit(3)
            Spacer(minLength: 0)
          }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        if changes.isEmpty {
          Text(loaded == true ? tr("変更はありません") : loaded == false ? tr("変更を取得できませんでした") : tr("変更を読み込み中…")).font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textSecondary)
            .frame(maxWidth: .infinity).padding(16)
        } else {
          commitBox
          section(tr("ステージ済み"), changes.filter(\.staged)) { DiffTarget(path: $0.path, staged: true, untracked: false) }
          section(tr("変更"), changes.filter { $0.unstaged && !$0.untracked }) { DiffTarget(path: $0.path, staged: false, untracked: false) }
          section(tr("未追跡"), changes.filter(\.untracked)) { DiffTarget(path: $0.path, staged: false, untracked: true) }
        }
      }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [GitChange], _ target: @escaping (GitChange) -> DiffTarget) -> some View {
      if !rows.isEmpty {
        HStack(spacing: 4) {
          Text(title).font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textTertiary)
          Text(tr("%@ ファイル", rows.count)).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textQuaternary)
          Spacer()
          let stage = title != tr("ステージ済み")
          Button { onBulk(rows, stage) } label: {
            Text(stage ? "+" : "−").font(Typography.font(Typography.title)).foregroundStyle(C.textTertiary).frame(width: 18, height: 18)
          }.buttonStyle(.hoverWash).disabled(busy).help(stage ? tr("すべてステージに追加") : tr("すべてステージから外す"))
        }.padding(.leading, 20).padding(.trailing, 12).frame(height: 26)
        // Tree styled like the explorer (28px rows, 12px indent, chevron + folder). A folder row is emitted
        // wherever a directory component first differs from the previous sorted path.
        let sorted = rows.sorted { $0.path < $1.path }
        ForEach(Array(sorted.enumerated()), id: \.element.path) { i, c in
          let dirs = c.path.split(separator: "/").dropLast().map(String.init)
          let prev = i > 0 ? sorted[i - 1].path.split(separator: "/").dropLast().map(String.init) : []
          let shared = zip(dirs, prev).prefix { $0 == $1 }.count
          let ids = dirs.indices.map { dirs[0...$0].joined(separator: "/") }
          ForEach(shared..<dirs.count, id: \.self) { d in
            if !ids[..<d].contains(where: collapsed.contains) {
              let open = !collapsed.contains(ids[d])
              treeRow(depth: d, selected: false, action: { if open { collapsed.insert(ids[d]) } else { collapsed.remove(ids[d]) } }) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(C.textTertiary)
                  .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                FileIcon.folder(open: open).image(size: 11, ink: C.textTertiary).frame(width: 16)
                Text(dirs[d]).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
              }
            }
          }
          if !ids.contains(where: collapsed.contains) {
            let t = target(c), on = selected == t, name = c.path.split(separator: "/").last.map(String.init) ?? c.path
            let badge = c.untracked ? "U" : c.index == "A" || c.worktree == "A" ? "A" : c.index == "D" || c.worktree == "D" ? "D" : "M"
            treeRow(depth: dirs.count, selected: on, action: { onSelect(t) }, trailing: {
              if hovered == t {
                Button { onDiscard(c, t.staged) } label: {
                  Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold)).foregroundStyle(C.textTertiary).frame(width: 18, height: 18)
                }.buttonStyle(.hoverWash).disabled(busy).help(c.untracked ? tr("ファイルを削除") : tr("変更を元に戻す"))
                Button { onToggle(c, !t.staged) } label: {
                  Text(t.staged ? "−" : "+").font(Typography.font(Typography.title)).foregroundStyle(C.textTertiary).frame(width: 18, height: 18)
                }.buttonStyle(.hoverWash).disabled(busy).help(t.staged ? tr("ステージを取り消す") : tr("ステージに追加"))
              }
              Text(badge).font(.system(size: 12, weight: .semibold)).foregroundStyle(badge == "A" || badge == "U" ? C.success : badge == "D" ? C.danger : C.attention)
                .allowsHitTesting(false)
            }) {
              Color.clear.frame(width: 10)  // chevron slot: a file lines up with its sibling folders
              FileIcon.forPath(c.path).image(size: 10, ink: on ? C.textSecondary : C.textTertiary).frame(width: 16)
              Text(name).font(.system(size: 12, weight: on ? .semibold : .regular)).foregroundStyle(on ? C.textPrimary : C.textSecondary).lineLimit(1)
              Spacer(minLength: 0)
            }
            .onHover { hovered = $0 ? t : (hovered == t ? nil : hovered) }
            .clairContextMenu(menus) { menu(c, t.staged) }
            .help(c.path)
          }
        }
      }
    }
  }

  /// Unified diff of one file. Colour is only for add/remove (state meaning); hunk headers stay quiet.
  /// Lines that exist on the new side can be commented.
  struct DiffView: View {
    let target: DiffTarget
    let model: Model
    /// Line → threads; key 0 holds stale ones (their line's text is gone).
    let threads: [Int: [ReviewThread]]
    let suggestions: [PlacedSuggestion]
    let onComment: (Int, _ lineText: String, _ body: String) -> Void
    let onSuggest: (Int, _ replacement: String) -> Void
    let onResolve: (UUID) -> Void
    /// Applies into the open buffer; a message means refused.
    let onApply: (UUID) -> String?
    let onReject: (UUID) -> Void
    /// Copies the open threads as an agent prompt; nil hides the button (nothing open).
    let onSend: (() -> Void)?
    let onClose: () -> Void
    let editor: EditorPane?
    let onSave: (() -> Void)?
    let isDirty: Bool
    /// Overrides the working-tree side label (a commit's diff names its commit).
    var label: String? = nil
    /// A historical diff has nowhere to anchor review comments.
    var commentable = true
    /// The commit view pins its own per-file header instead.
    var showsHeader = true
    /// Stages one change block (unstages it in a staged diff): the block's patch and whether to apply it in reverse.
    var onStageBlock: ((_ patch: String, _ reverse: Bool) -> Void)? = nil
    @State private var composing: Int?
    @State private var draft = ""
    @State private var suggesting = false
    @State private var applyError: String?
    @State private var hunk = -1
    @State private var sent = false
    /// Folds unchanged runs down to `context` lines around each change; `expanded` holds opened run starts.
    @State private var compact = true
    @State private var expanded: Set<Int> = []
    /// Split view: how far the diff is scrolled right; the halves stay pinned and scroll their text inside.
    @State private var hScroll: CGFloat = 0
    @State private var hovering = false
    @State private var wheelMonitor: Any?
    @AppStorage("clair.diffSplit") private var split = false
    @State private var editing = false
    /// A diff this long is cut with a notice instead of laying out every row.
    nonisolated static let maxLines = 5000

    struct Row: Sendable { let text: String; let newLine: Int?; var oldLine: Int? = nil }

    /// Immutable, pre-parsed diff data. Construct this away from the main actor; a large diff must
    /// not be tokenised and counted again for every SwiftUI body evaluation.
    struct Model: Sendable {
      let text: String
      let rows: [Row]
      let added: Int
      let removed: Int
      let hunks: [Int]
      /// Change blocks (runs of added/removed rows) by their first row, for staging one block.
      var blocks: [Int: Range<Int>] = [:]
      let visibleLines: Set<Int>
      /// Per row: the start index of the folded unchanged run it belongs to (nil = always shown).
      let fold: [Int?]
    }

    nonisolated static let context = 3

    /// Context rows further than `context` from any change collapse into runs keyed by their first row.
    nonisolated static func folds(_ rows: [Row]) -> [Int?] {
      let changed = rows.map { r in ["+", "-", "@@", "\\"].contains { r.text.hasPrefix($0) } }
      var dist = Array(repeating: Int.max, count: rows.count), d = Int.max
      for i in rows.indices { d = changed[i] ? 0 : (d == .max ? d : d + 1); dist[i] = d }
      d = .max
      for i in rows.indices.reversed() { d = changed[i] ? 0 : (d == .max ? d : d + 1); dist[i] = min(dist[i], d) }
      var out: [Int?] = [], start: Int?
      for i in rows.indices {
        if dist[i] > context { start = start ?? i; out.append(start) } else { start = nil; out.append(nil) }
      }
      return out
    }

    nonisolated static func model(_ text: String) -> Model {
      let parsed = rows(text)
      let counts = stats(parsed)
      let blocks = GitPatch.blocks(parsed.map { DiffLine(text: $0.text, oldLine: $0.oldLine, newLine: $0.newLine) })
      return Model(
        text: text, rows: parsed, added: counts.added, removed: counts.removed,
        hunks: parsed.indices.filter { parsed[$0].text.hasPrefix("@@") },
        blocks: Dictionary(uniqueKeysWithValues: blocks.map { ($0.lowerBound, $0) }),
        visibleLines: Set(parsed.compactMap(\.newLine)), fold: folds(parsed))
    }

    /// Parses `@@ -a,b +c,d @@` for `a` and `c`, then numbers old (context/removed) and new (context/added) lines.
    nonisolated static func rows(_ text: String) -> [Row] {
      let all = text.split(separator: "\n", omittingEmptySubsequences: false)
      // A submodule diff (`--submodule=diff`) carries several files: keep each `diff --git` line as a file
      // header and drop its index/---/+++ lines so they don't read as removed/added rows.
      let multi = all.lazy.filter { $0.hasPrefix("diff --git ") }.count > 1
      let body = all.drop { !$0.hasPrefix("@@") && !(multi && $0.hasPrefix("diff --git ")) }
      if body.isEmpty { return all.filter { $0.hasPrefix("Binary") }.map { Row(text: String($0), newLine: nil) } }
      var n = 0, o = 0, inHeader = false
      func start(_ l: Substring, _ sign: Character) -> Int {
        l.split(separator: " ").first { $0.first == sign }.flatMap { Int($0.dropFirst().split(separator: ",")[0]) } ?? 1
      }
      return body.prefix(maxLines).compactMap { l in
        if l.hasPrefix("diff --git ") { inHeader = true; return Row(text: String(l), newLine: nil) }
        if inHeader, !l.hasPrefix("@@") { return l.hasPrefix("Binary") ? Row(text: String(l), newLine: nil) : nil }
        inHeader = false
        if l.hasPrefix("@@") {
          n = start(l, "+"); o = start(l, "-")
          return Row(text: String(l), newLine: nil)
        }
        if l.hasPrefix("\\") { return Row(text: String(l), newLine: nil) }
        if l.hasPrefix("-") { defer { o += 1 }; return Row(text: String(l), newLine: nil, oldLine: o) }
        if l.hasPrefix("+") { defer { n += 1 }; return Row(text: String(l), newLine: n) }
        defer { n += 1; o += 1 }
        return Row(text: String(l), newLine: n, oldLine: o)
      }
    }

    /// Side-by-side pairing: a run of removed lines is zipped with the added run that follows it;
    /// context and hunk headers sit on both sides. `id` is the first source row's index (hunk scroll targets).
    struct Pair { let id: Int; let left: Row?; let right: Row? }
    nonisolated static func pairs(_ rows: [Row]) -> [Pair] {
      var out: [Pair] = [], i = 0
      while i < rows.count {
        let t = rows[i].text
        guard t.hasPrefix("-") || t.hasPrefix("+") else { out.append(Pair(id: i, left: rows[i], right: rows[i])); i += 1; continue }
        var del: [Int] = [], add: [Int] = []
        while i < rows.count, rows[i].text.hasPrefix("-") { del.append(i); i += 1 }
        while i < rows.count, rows[i].text.hasPrefix("+") { add.append(i); i += 1 }
        for k in 0..<max(del.count, add.count) {
          let l = k < del.count ? del[k] : nil, a = k < add.count ? add[k] : nil
          out.append(Pair(id: l ?? a!, left: l.map { rows[$0] }, right: a.map { rows[$0] }))
        }
      }
      return out
    }

    /// Added / removed line counts (rows start at the first hunk, so `+++`/`---` file headers are excluded).
    nonisolated static func stats(_ rows: [Row]) -> (added: Int, removed: Int) {
      (rows.filter { $0.text.hasPrefix("+") }.count, rows.filter { $0.text.hasPrefix("-") }.count)
    }

    var body: some View {
      let rows = model.rows
      let (added, removed) = (model.added, model.removed)
      let hunks = model.hunks
      // Threads/suggestions whose line is not in a hunk (or whose line went stale) would be invisible: list them on top.
      let visible = model.visibleLines
      let looseThreads = threads.filter { !visible.contains($0.key) }.sorted { $0.key < $1.key }
      let looseSuggestions = suggestions.filter { !visible.contains($0.line) }
      let suggestionsByLine = Dictionary(grouping: suggestions, by: \.line)
      ScrollViewReader { proxy in
      VStack(spacing: 0) {
        if showsHeader { HStack {
          Text(target.path).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary)
          Text(label ?? (target.against.map { "\($0) → \(target.path)" } ?? (target.staged ? "HEAD → index" : target.untracked ? tr("未追跡ファイル") : tr("index → 作業ツリー"))))
            .font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary)
          if added + removed > 0 {
            Text("+\(added)").font(Typography.font(Typography.chrome)).foregroundStyle(C.success)
            Text("−\(removed)").font(Typography.font(Typography.chrome)).foregroundStyle(C.danger)
          }
          Spacer()
          if editor != nil {
            Button(editing ? tr("差分") : tr("編集")) { editing.toggle() }
              .font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).buttonStyle(.hoverWash)
              .help(editing ? tr("差分の表示に戻る") : tr("このファイルを編集する"))
            if editing, let onSave {
              Button(isDirty ? tr("保存 ●") : tr("保存"), action: onSave)
                .font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).buttonStyle(.hoverWash)
                .keyboardShortcut("s", modifiers: .command)
                .help(tr("このファイルを保存する"))
            }
          }
          if !editing {
            Button { split.toggle() } label: { Image(systemName: split ? "rectangle" : "rectangle.split.2x1") }
              .accessibilityLabel(split ? tr("インライン") : tr("並べて表示"))
              .font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).buttonStyle(.hoverWash)
              .help(split ? tr("差分を 1 列で表示") : tr("変更前と変更後を左右に並べて表示"))
            Button(compact ? tr("全文脈") : tr("変更箇所")) { compact.toggle() }
              .font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).buttonStyle(.hoverWash)
              .help(compact ? tr("ファイル全体を表示") : tr("変更箇所に絞る"))
          }
          if !editing && !hunks.isEmpty {
            Text("\(max(hunk, 0) + 1)/\(hunks.count)").font(Typography.font(Typography.micro)).foregroundStyle(C.textQuaternary)
            ForEach([-1, 1], id: \.self) { d in
              Button {
                hunk = min(max(hunk + d, 0), hunks.count - 1)
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(hunks[hunk], anchor: .top) }
              } label: { Image(systemName: d < 0 ? "chevron.up" : "chevron.down").foregroundStyle(C.chromeInk) }
                .buttonStyle(.hoverWash).keyboardShortcut(d < 0 ? .upArrow : .downArrow, modifiers: .option)
                .help(d < 0 ? tr("前の hunk (⌥↑)") : tr("次の hunk (⌥↓)"))
            }
          }
          if let onSend {
            Button { onSend(); sent = true } label: {
              Text(sent ? tr("コピー済み（⌘V で貼り付け）") : tr("agent に送る")).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary)
            }.buttonStyle(.hoverWash).help(tr("未解決コメントをプロンプトとしてコピーし、agent のターミナルへ移動"))
          }
          Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(C.chromeInk) }.buttonStyle(.hoverWash)
        }.padding(.horizontal, 16).frame(height: 30).background(C.canvas)
          .overlay(alignment: .bottom) { Rectangle().fill(L.hairline).frame(height: 1) } }
        if editing, let editor {
          editor
        } else if model.text.isEmpty {
          Text(tr("差分はありません。")).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          GeometryReader { viewport in
            ScrollView(split ? .vertical : [.vertical, .horizontal]) {
              LazyVStack(alignment: .leading, spacing: 0) {
                if !looseThreads.isEmpty || !looseSuggestions.isEmpty {
                  Text(tr("この差分に表示できないコメント・提案")).font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textTertiary).padding(.horizontal, 12).padding(.vertical, 6)
                  ForEach(looseThreads, id: \.key) { l, ts in
                    ForEach(ts) { thread($0, note: l == 0 ? tr("行が変更されたため位置を特定できません") : tr("%@ 行目", l)) }
                  }
                  ForEach(looseSuggestions) { suggestion($0) }
                }
                let fold = model.fold
                let shown: (Int) -> Bool = { i in
                  guard compact, let s = fold[i], !expanded.contains(s) else { return true }
                  let n = rows[i].newLine ?? -1
                  return threads[n] != nil || suggestionsByLine[n] != nil
                }
                let items: [Pair] = split ? Self.pairs(rows) : rows.enumerated().map { Pair(id: $0, left: $1, right: $1) }
                // The divider stays centred; a line longer than its half is clipped and revealed by scrolling (12px mono ≈ 7.3pt/char).
                // The divider sits on the diff pane's centre line.
                let half: CGFloat = split ? (viewport.size.width - 1) / 2 : 0
                ForEach(items, id: \.id) { p in
                  let r = p.right ?? p.left!
                  if compact, let s = fold[p.id], s == p.id, !expanded.contains(s) {
                    let count = fold[s...].prefix { $0 == s }.count
                    Button { expanded.insert(s) } label: {
                      Text(tr("⋯ 変更のない %@ 行を表示", count)).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
                        .padding(.leading, 100).frame(minWidth: viewport.size.width, alignment: .leading).frame(height: 22)
                        .background(C.surface).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(tr("折りたたまれた行を展開"))
                  }
                  if shown(p.id) {
                    if let onStageBlock, let block = model.blocks[p.id] {
                      Button {
                        let lines = rows.map { DiffLine(text: $0.text, oldLine: $0.oldLine, newLine: $0.newLine) }
                        onStageBlock(GitPatch.patch(path: target.path, rows: lines, block: block), target.staged)
                      } label: {
                        Label(target.staged ? tr("このブロックのステージを解除") : tr("このブロックをステージ"), systemImage: target.staged ? "minus" : "plus")
                          .font(Typography.font(Typography.micro)).foregroundStyle(C.textTertiary)
                          .padding(.leading, 56).frame(height: 18)
                      }.buttonStyle(.hoverWash)
                    }
                    pairRow(p, half: half, width: viewport.size.width).id(p.id)
                    if let n = r.newLine {
                      ForEach(threads[n] ?? []) { thread($0) }
                      ForEach(suggestionsByLine[n] ?? []) { suggestion($0) }
                      if composing == n { composer(n, text: String(r.text.dropFirst())) }
                    }
                  }
                }
                if rows.count == Self.maxLines {
                  Text(tr("差分が長いため %@ 行で打ち切りました。", Self.maxLines)).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).padding(12)
                }
              }
              .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
              .clairScroller()
            }
            // Split view scrolls sideways by hand: the divider stays put and both halves move together.
            .onHover { hovering = $0 }
            .onAppear {
              wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                guard split, hovering, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return e }
                hScroll = min(max(0, hScroll - e.scrollingDeltaX), overflowWidth(viewport.size.width))
                return nil
              }
            }
            .onDisappear { wheelMonitor.map(NSEvent.removeMonitor); wheelMonitor = nil }
          }
        }
      }.background(C.canvas)
      }
    }

    private func line(_ r: Row, width: CGFloat) -> some View {
      // Mock Review diff: editor metrics (12px mono, 19px rows, canvas) with old/new 44px number gutters.
      let l = r.text, sign = l.first.map(String.init) ?? " "
      let added = sign == "+", removed = sign == "-", header = l.hasPrefix("@@")
      let tint: Color = added ? C.success.opacity(0.10) : removed ? C.danger.opacity(0.10) : .clear
      let mono = Font.system(size: 12, design: .monospaced)
      func gutter(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "").font(mono).foregroundStyle(C.lineNumber).padding(.trailing, 8).frame(width: 44, alignment: .trailing)
      }
      return HStack(spacing: 0) {
        // The old gutter is tinted only for a removed line (mock DiffRow).
        gutter(r.oldLine).frame(maxHeight: .infinity).background(removed ? .clear : C.canvas)
        gutter(r.newLine)
        Group {
          if header { Text(l).foregroundStyle(C.textQuaternary) }
          else { Text(l.dropFirst()).foregroundStyle(C.code) }  // the tint already marks +/−
        }
        .font(mono).padding(.horizontal, 12)
      }
      // Rows fill the viewport (the lazy stack proposes no width) and grow for long lines.
      .frame(minWidth: width, alignment: .leading).frame(height: 19).background(tint)
    }

    /// Extra scroll width so the longest line can be scrolled fully into its half (12px mono ≈ 7.3pt/char).
    private func overflowWidth(_ viewport: CGFloat) -> CGFloat {
      guard split else { return 0 }
      let longest = model.rows.lazy.map { $0.text.count }.max() ?? 0
      return max(0, 68 + 7.3 * CGFloat(longest) - (viewport - 1) / 2)
    }

    @ViewBuilder private func pairRow(_ p: Pair, half: CGFloat, width: CGFloat) -> some View {
      let r = p.right ?? p.left!
      Group {
        if split {
          HStack(spacing: 0) {
            cell(p.left, number: p.left?.oldLine, width: half)
            Rectangle().fill(L.hairline).frame(width: 1)
            cell(p.right, number: p.right?.newLine, width: width - half - 1)
          }.frame(height: 19)
        } else {
          line(r, width: width)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { if commentable, let n = r.newLine { composing = composing == n ? nil : n; draft = ""; suggesting = false } }
      .help(!commentable || r.newLine == nil ? "" : tr("クリックしてコメント"))
    }

    /// One side of the split view: its own number gutter, the line, and the line's tint; nil is the empty filler.
    private func cell(_ r: Row?, number: Int?, width: CGFloat) -> some View {
      let l = r?.text ?? "", sign = l.first.map(String.init) ?? " "
      let added = sign == "+", removed = sign == "-"
      let mono = Font.system(size: 12, design: .monospaced)
      return HStack(spacing: 0) {
        Text(number.map(String.init) ?? "").font(mono).foregroundStyle(C.lineNumber).padding(.trailing, 8).frame(width: 44, alignment: .trailing)
        Group {
          if l.hasPrefix("@@") { Text(l).foregroundStyle(C.textQuaternary) }
          else { Text(l.dropFirst()).foregroundStyle(C.code) }  // the tint already marks +/−
        }.font(mono).fixedSize().padding(.horizontal, 12).offset(x: -hScroll)
        .frame(maxWidth: .infinity, alignment: .leading).clipped()
      }
      .frame(width: width, alignment: .leading).frame(maxHeight: .infinity)
      .background(r == nil ? C.textQuaternary.opacity(0.06) : added ? C.success.opacity(0.10) : removed ? C.danger.opacity(0.10) : .clear)
      .background(C.canvas).clipped()  // opaque and clipped: a long line never shows through the other half
    }

    private func thread(_ t: ReviewThread, note: String? = nil) -> some View {
      VStack(alignment: .leading, spacing: 4) {
        if let note { Text(note).font(Typography.font(Typography.micro)).foregroundStyle(C.attention) }
        ForEach(t.comments) { c in
          HStack(alignment: .top, spacing: 8) {
            Text(c.author.displayName).font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textTertiary)
            Text(c.body).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary)
          }
        }
        if t.state == .open {
          Button(tr("解決する")) { onResolve(t.id) }.buttonStyle(.hoverWash).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
        } else {
          Text(tr("解決済み")).font(Typography.font(Typography.chrome)).foregroundStyle(C.success)
        }
      }
      .padding(8).frame(maxWidth: 520, alignment: .leading).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card))
      .opacity(t.state == .open ? 1 : 0.6).padding(.leading, 28).padding(.vertical, 4)
    }

    private func suggestion(_ p: PlacedSuggestion) -> some View {
      let pending = p.suggestion.state == .pending
      return VStack(alignment: .leading, spacing: 4) {
        Text(p.endLine.map { tr("提案 · %@–%@ 行目", p.line, $0) } ?? tr("提案 · %@ 行目", p.line))
          .font(Typography.font(Typography.micro)).foregroundStyle(C.textQuaternary)
        if let reason = p.suggestion.description {
          Text(reason).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary)
        }
        Text("+ " + p.replacement).font(.system(size: 12, design: .monospaced)).foregroundStyle(C.code)
          .padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading).background(C.success.opacity(0.12))
        if pending {
          HStack(spacing: 8) {
            Button(tr("適用")) { applyError = onApply(p.id) }.buttonStyle(.hoverWash).foregroundStyle(p.stale ? C.textQuaternary : C.textPrimary).disabled(p.stale)
            Button(tr("却下")) { onReject(p.id) }.buttonStyle(.hoverWash).foregroundStyle(C.textTertiary)
            if p.stale { Text(tr("バッファが変更されたため適用できません")).foregroundStyle(C.attention) }
            else if let applyError { Text(applyError).foregroundStyle(C.attention) }
          }.font(Typography.font(Typography.chrome))
        } else {
          Text(p.suggestion.state == .applied ? tr("適用済み（未保存。⌘S で保存）") : p.suggestion.state == .rejected ? tr("却下済み") : tr("一部適用済み"))
            .font(Typography.font(Typography.chrome)).foregroundStyle(p.suggestion.state == .applied ? C.success : C.textTertiary)
        }
      }
      .padding(8).frame(maxWidth: 520, alignment: .leading).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card))
      .opacity(pending ? 1 : 0.6).padding(.leading, 28).padding(.vertical, 4)
    }

    private func composer(_ n: Int, text: String) -> some View {
      let submit = {
        if suggesting { onSuggest(n, draft) } else { onComment(n, text, draft) }
        composing = nil
      }
      return HStack(spacing: 8) {
        TextField(suggesting ? tr("この行の置換後") : tr("コメント"), text: $draft).textFieldStyle(.plain).font(Typography.font(Typography.chrome)).frame(width: 360)
          .onSubmit(submit)
        Button(suggesting ? tr("提案する") : tr("追加"), action: submit).buttonStyle(.hoverWash).foregroundStyle(C.textSecondary)
        Button(suggesting ? tr("コメントに戻す") : tr("提案にする")) { suggesting.toggle(); draft = suggesting ? text : "" }
          .buttonStyle(.hoverWash).foregroundStyle(C.textTertiary)
        Button(tr("キャンセル")) { composing = nil }.buttonStyle(.hoverWash).foregroundStyle(C.textTertiary)
      }
      .padding(8).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card)).padding(.leading, 28).padding(.vertical, 4)
    }
  }

  /// U06: an AI (MCP) call at write-or-above risk waits here. Facts only: command, risk, arguments, time left.
  /// No answer by the deadline is a denial (V03); ⌘↩ allows, esc denies.
  struct ApprovalCard: View {
    let id: String
    let input: CommandInput
    let risk: CommandRisk
    let deadline: Date
    let decide: (Bool) -> Void

    private func value(_ a: CommandArg) -> String {
      switch a {
      case .string(let s): s
      case .int(let i): String(i)
      case .double(let d): String(d)
      case .bool(let b): String(b)
      }
    }

    /// Mock `Activity.tsx` approval card: titled header with a right-aligned tag, the command in a canvas box,
    /// a facts line, then right-aligned secondary/primary buttons. The mock's "session allow" has no gate behind it, so it is omitted.
    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Text(tr("AI が実行を求めています")).font(.system(size: 13, weight: .semibold)).foregroundStyle(C.textPrimary)
          Spacer(minLength: 0)
          TimelineView(.periodic(from: .now, by: 1)) { c in
            Text(tr("残り %@ 秒", max(0, Int(deadline.timeIntervalSince(c.date).rounded(.up))))).font(.system(size: 11)).monospacedDigit().foregroundStyle(C.textQuaternary)
          }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(L.hairline).frame(height: 1) }
        VStack(alignment: .leading, spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(id).foregroundStyle(C.textSecondary)
            ForEach(input.keys.sorted(), id: \.self) { k in Text("\(k): \(value(input[k]!))").foregroundStyle(C.textTertiary).lineLimit(2) }
          }
          .font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(8)
          .background(C.canvas, in: RoundedRectangle(cornerRadius: Radius.card))
          .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.hairline))
          Text(tr("リスク %@", risk.label)).font(.system(size: 11)).foregroundStyle(risk >= .destructive ? C.danger : C.textQuaternary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 8) {
          Spacer()
          approvalButton(tr("拒否"), primary: false) { decide(false) }.keyboardShortcut(.cancelAction)
          approvalButton(tr("許可して実行"), primary: true) { decide(true) }.keyboardShortcut(.return, modifiers: .command)
        }.padding(.horizontal, 16).padding(.bottom, 12)
      }
      .frame(width: 380)
      .background(W.faint).background(C.canvas, in: RoundedRectangle(cornerRadius: Radius.card))
      .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.stronger))
      .clipShape(RoundedRectangle(cornerRadius: Radius.card))
      .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private func approvalButton(_ title: String, primary: Bool, _ action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Text(title).font(.system(size: 11, weight: primary ? .semibold : .regular))
          .foregroundStyle(primary ? C.canvas : C.textSecondary)
          .padding(.horizontal, 12).frame(minHeight: 30)
          .background(primary ? C.textSecondary : W.medium, in: RoundedRectangle(cornerRadius: Radius.control))
      }.buttonStyle(.hoverWash)
    }
  }

  /// Focus a palette/search field on open. A terminal or editor NSView keeps first responder and
  /// swallows SwiftUI focus, so resign it and let the field land in the window first.
  @MainActor func focusField(_ focus: () -> Void) async {
    NSApp.keyWindow?.makeFirstResponder(nil)
    await Task.yield()
    focus()
  }

  /// U06: notification history (facts only — bell / exit). Rows are read state + source + fixed wording.
  /// V05: project-wide find/replace. Enter searches and replace all matches.
  struct SearchPanel: View {
    @Binding var query: String
    @Binding var replacement: String
    @Binding var regex: Bool
    @Binding var caseSensitive: Bool
    @Binding var selection: Int
    let hits: [SearchHit]
    let message: String
    let searching: Bool
    let replacing: Bool
    let search: () -> Void
    let replaceAll: () -> Void
    let close: () -> Void
    let open: (SearchHit) -> Void
    @State private var replaceMode = false
    @FocusState private var queryFocused: Bool

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(C.textQuaternary)
          TextField(tr("Projectを検索"), text: $query)
            .focused($queryFocused).task { await focusField { queryFocused = true } }
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(C.textPrimary)
            .onSubmit(openSelected)
            .onKeyPress(.downArrow) { selection = min(selection + 1, max(displayedHits.count - 1, 0)); return .handled }
            .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            .onChange(of: query) { selection = 0; search() }
          if searching { ProgressView().controlSize(.small) }
          Text(tr("%@件 · %@ファイル", hits.count, Set(hits.map(\.path)).count)).font(.system(size: 11)).foregroundStyle(C.textQuaternary)
          chip(".*", on: $regex, help: tr("正規表現"))
          chip("Aa", on: $caseSensitive, help: tr("大文字小文字を区別"))
        }
        .padding(.horizontal, 8).frame(height: 40)
        .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.hairline))
        .contentShape(Rectangle()).onTapGesture { queryFocused = true }  // the whole bar focuses, not just the text's hit box
        .padding(12)
        .onChange(of: regex) { selection = 0; search() }
        .onChange(of: caseSensitive) { selection = 0; search() }

        if replaceMode {
          HStack(spacing: 6) {
            HStack(spacing: 8) {
              Image(systemName: "arrow.2.squarepath").font(.system(size: 13)).foregroundStyle(C.textQuaternary)
              TextField(tr("置換"), text: $replacement).textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(C.textPrimary)
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.hairline))
            let canReplace = !hits.isEmpty && !replacing && !searching
            Button(action: replaceAll) {
              Text(replacing ? tr("置換中…") : tr("すべて置換")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(canReplace ? C.canvas : C.textQuaternary)
                .padding(.horizontal, 12).frame(height: 32)
                .background(canReplace ? C.textSecondary : W.medium, in: RoundedRectangle(cornerRadius: Radius.control))
            }.buttonStyle(.hoverWash).disabled(!canReplace)
          }
          .padding(.horizontal, 12).padding(.bottom, 8).disabled(replacing)
        }
        if !message.isEmpty {
          Text(message).font(Typography.font(Typography.micro)).foregroundStyle(C.textQuaternary)
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
        ScrollViewReader { proxy in ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(indexedGroups, id: \.path) { group in
              HStack(spacing: 6) {
                FileIcon.forPath(group.path).image(size: 11, ink: C.textTertiary)
                Text(URL(fileURLWithPath: group.path).lastPathComponent).font(.system(size: 11, weight: .semibold)).foregroundStyle(C.textTertiary)
                Spacer(minLength: 0)
                Text(group.path.split(separator: "/").dropLast().joined(separator: "/"))
                  .font(Typography.font(Typography.micro)).foregroundStyle(C.textQuaternary).lineLimit(1)
              }
              .padding(.horizontal, 8).frame(height: 26)
              ForEach(group.hits, id: \.index) { item in
                let selected = item.index == selection
                Button { selection = item.index; open(item.hit) } label: {
                  HStack(spacing: 8) {
                    Text("\(item.hit.line)").font(Typography.font(Typography.micro)).foregroundStyle(C.textQuaternary).frame(width: 32, alignment: .trailing)
                    Text(item.hit.text.trimmingCharacters(in: .whitespaces)).font(Typography.font(Typography.chrome))
                      .foregroundStyle(selected ? C.textPrimary : C.textSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                  }
                  .padding(.horizontal, 8).frame(height: 28)
                  .background(selected ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                  .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash).onHover { if $0 { selection = item.index } }
                .id(item.index)
              }
            }
          }.padding(.horizontal, 8).padding(.bottom, 8)
        }.onChange(of: selection) { proxy.scrollTo(selection) } }.frame(minHeight: 322, maxHeight: 420)
        HStack(spacing: 8) {
          ForEach([(tr("検索"), false), (tr("置換 ⌥⌘F"), true)], id: \.1) { label, mode in
            Button { replaceMode = mode } label: {
              Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(replaceMode == mode ? C.textPrimary : C.textTertiary)
                .padding(.horizontal, 8).frame(height: 20)
                .background(replaceMode == mode ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
            }.buttonStyle(.hoverWash)
          }
          Spacer()
          Button { replaceMode.toggle() } label: { EmptyView() }
            .keyboardShortcut("f", modifiers: [.command, .option]).hidden()
        }
        .padding(.horizontal, 12).frame(height: 34)
        .overlay(alignment: .top) { Rectangle().fill(L.hairline).frame(height: 1) }
      }
    }

    /// Option toggle drawn as a code-styled chip (VS Code idiom) instead of a system checkbox.
    private func chip(_ label: String, on: Binding<Bool>, help: String) -> some View {
      Button { on.wrappedValue.toggle() } label: {
        Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(on.wrappedValue ? C.textPrimary : C.textQuaternary)
          .frame(width: 30, height: 30)
          .background(on.wrappedValue ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
          .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(on.wrappedValue ? L.ring : L.hairline))
      }.buttonStyle(.hoverWash).help(help).accessibilityLabel(help).accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
    }

    private var displayedHits: [SearchHit] { Array(hits.prefix(500)) }

    /// Hits grouped by file in first-seen order, retaining their flat keyboard-navigation index.
    private var indexedGroups: [(path: String, hits: [(index: Int, hit: SearchHit)])] {
      var order: [String] = [], by: [String: [(index: Int, hit: SearchHit)]] = [:]
      for (index, hit) in displayedHits.enumerated() {
        if by[hit.path] == nil { order.append(hit.path) }
        by[hit.path, default: []].append((index, hit))
      }
      return order.map { ($0, by[$0]!) }
    }

    private func openSelected() {
      guard displayedHits.indices.contains(selection) else { search(); return }
      open(displayedHits[selection])
    }
  }

  struct SessionList: View {
    let sessions: [AgentSession]
    let current: String
    let open: (AgentSession) -> Void
    let openHistory: (AgentHistory) -> Void
    @State private var histories: [AgentHistory] = []
    @State private var historyLoading = true
    @State private var expandedGroups: Set<String> = []
    /// Rows shown per list (days, a day's projects, a project's chats); "show more" adds a page.
    @State private var shown: [String: Int] = [:]
    private static let page = 10
    @State private var archive: [AgentHistory]?
    @State private var archiveOpen = false
    /// cwd → "repo · branch", read off the main thread.
    @State private var gitLabels: [String: String] = [:]

    private func label(_ s: AgentSession) -> (String, Color) {
      switch s.status {
      case .running: (tr("実行中"), C.textTertiary)
      case .attention: (tr("入力待ち（ベル）"), C.attention)
      case .exited(let c): (c == 0 ? tr("正常終了") : tr("異常終了 (exit %@)", c ?? -1), C.textQuaternary)
      }
    }

    var body: some View {
      Text(tr("エージェント")).font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textTertiary)
        .padding(.horizontal, 20).frame(height: 26)
        .task {
          histories = await AgentHistoryStore.shared.load(.recent)
          historyLoading = false
        }
        .task(id: Set(sessions.map(\.cwd))) {
          for cwd in Set(sessions.map(\.cwd)) where gitLabels[cwd] == nil {
            gitLabels[cwd] = await Task.detached(priority: .utility) {
              let repo = WorkbenchGit.repoName(cwd) ?? URL(fileURLWithPath: cwd).lastPathComponent
              return [repo, WorkbenchGit.currentBranch(cwd)].compactMap { $0 }.joined(separator: " · ")
            }.value
          }
        }
      if sessions.isEmpty {
        Text(tr("起動中のエージェントはありません")).font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textSecondary)
          .frame(maxWidth: .infinity).padding(16)
      }
      ForEach(sessions) { s in
        let (text, color) = label(s)
        Button { open(s) } label: {
          HStack(alignment: .top, spacing: 8) {
            if let provider = AgentHistory.Provider(rawValue: s.title) {
              // Same avatar as past chats; the status dot rides its corner.
              ProviderAvatar(provider: provider, size: 26)
                .overlay(alignment: .bottomTrailing) {
                  Circle().fill(color).frame(width: 8, height: 8).overlay(Circle().strokeBorder(C.panel, lineWidth: 1.5))
                }
                .padding(.top, 1)
            } else {
              Circle().fill(color).frame(width: 6, height: 6).padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 2) {
              // The session title leads; the provider name is already the avatar.
              Text(s.activity ?? s.title).font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textPrimary).lineLimit(1)
              Text(([gitLabels[s.cwd] ?? URL(fileURLWithPath: s.cwd).lastPathComponent] + (s.status.isExited ? [text] : [])).joined(separator: " · "))
                .font(Typography.font(Typography.sidebar)).foregroundStyle(C.textQuaternary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if s.status == .attention {
              Image(systemName: "bell.badge.fill").font(.system(size: 13)).foregroundStyle(C.attention)
                .symbolEffect(.pulse).padding(.top, 5)
                .help(text).accessibilityLabel(text)
            }
          }
          .padding(.horizontal, 20).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.hoverWash)
      }
      HStack {
        Text(tr("過去のチャット")).font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textTertiary)
        Spacer()
        Button { Task { historyLoading = true; histories = await AgentHistoryStore.shared.refresh(.recent); archive = nil; archiveOpen = false; historyLoading = false } } label: {
          Image(systemName: "arrow.clockwise")
        }.buttonStyle(.plain).help(tr("履歴を更新"))
      }.padding(.horizontal, 20).padding(.top, 14)
      if historyLoading {
        Text("Loading...").font(Typography.font(Typography.sidebar)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 20).frame(height: 28)
      } else if histories.isEmpty {
        Text(tr("履歴はありません")).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textQuaternary).padding(16)
      }
      // ponytail: regrouped on every render; cache in @State if history counts make this visible.
      historyDays(histories, key: "recent")
      Button {
        archiveOpen.toggle()
        if archiveOpen, archive == nil { Task { archive = await AgentHistoryStore.shared.load(.archive) } }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: archiveOpen ? "chevron.down" : "chevron.right").frame(width: 14)
          Text(tr("アーカイブ（1ヶ月以上前）")).font(Typography.font(Typography.sidebarStrong))
          Spacer(minLength: 0)
        }.foregroundStyle(C.textTertiary).padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4).contentShape(Rectangle())
      }.buttonStyle(.hoverWash)
      if archiveOpen {
        if let archive {
          if archive.isEmpty {
            Text(tr("アーカイブはありません")).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textQuaternary).padding(16)
          }
          historyDays(archive, key: "archive")
        } else {
          Text("Loading...").font(Typography.font(Typography.sidebar)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 20).frame(height: 28)
        }
      }
    }

    /// One flat, uniquely keyed row of the date → project → chats list.
    private enum HistoryRow: Identifiable {
      case day(id: String, Date)
      case group(id: String, AgentHistoryGroup, collapsed: Bool)
      case chat(id: String, AgentHistory)
      case more(id: String, key: String, remaining: Int)
      var id: String {
        switch self {
        case .day(let id, _), .group(let id, _, _), .chat(let id, _), .more(let id, _, _): id
        }
      }
    }

    /// Date → project → chats, each list paged by `page`. Flattened into one ForEach: nested ForEach with
    /// conditional children inside the sidebar's LazyVStack dropped rows once a project repeated across days.
    private func historyRows(_ histories: [AgentHistory], key: String) -> [HistoryRow] {
      var rows: [HistoryRow] = []
      func more(_ list: String, total: Int) {
        if total > limit(list) { rows.append(.more(id: "\(list)::more", key: list, remaining: total - limit(list))) }
      }
      let days = AgentHistoryDay.group(histories)
      for day in days.prefix(limit(key)) {
        let dayKey = "\(key)::\(day.date.timeIntervalSince1970)"
        rows.append(.day(id: dayKey, day.date))
        for group in day.groups.prefix(limit(dayKey)) {
          let groupKey = "\(dayKey)::\(group.id)"
          let collapsed = !expandedGroups.contains(groupKey)
          rows.append(.group(id: groupKey, group, collapsed: collapsed))
          guard !collapsed else { continue }
          for (i, history) in group.histories.prefix(limit(groupKey)).enumerated() {
            rows.append(.chat(id: "\(groupKey)::\(i)", history))
          }
          more(groupKey, total: group.histories.count)
        }
        more(dayKey, total: day.groups.count)
      }
      more(key, total: days.count)
      return rows
    }

    @ViewBuilder private func historyDays(_ histories: [AgentHistory], key: String) -> some View {
      ForEach(historyRows(histories, key: key)) { row in
        switch row {
        case .day(_, let date):
          Text(dayTitle(date)).font(Typography.font(Typography.sidebarMicro)).foregroundStyle(C.textQuaternary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 2)
        case .group(let id, let group, let collapsed): historyGroup(group, id: id, collapsed: collapsed)
        case .chat(_, let history): historyRow(history)
        case .more(_, let key, let remaining):
          Button { shown[key] = limit(key) + Self.page } label: {
            Text(tr("さらに表示（残り %@ 件）", remaining)).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textTertiary)
              .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 4).contentShape(Rectangle())
          }.buttonStyle(.hoverWash)
        }
      }
    }

    private func limit(_ key: String) -> Int { shown[key] ?? Self.page }

    private func dayTitle(_ date: Date) -> String {
      if Calendar.current.isDateInToday(date) { return tr("今日") }
      if Calendar.current.isDateInYesterday(date) { return tr("昨日") }
      return date.formatted(.dateTime.month().day().weekday(.abbreviated))
    }

    /// Projects start collapsed, like ccedit's project list; opening one lists its chats newest first.
    private func historyGroup(_ group: AgentHistoryGroup, id: String, collapsed: Bool) -> some View {
          Button {
            if collapsed { expandedGroups.insert(id) } else { expandedGroups.remove(id) }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: collapsed ? "chevron.right" : "chevron.down").frame(width: 14)
              Text(group.project).font(Typography.font(Typography.sidebarStrong)).lineLimit(1)
              Spacer(minLength: 0)
              Text(tr("%@ · %@ · %@ 件", group.date.formatted(date: .omitted, time: .shortened), group.estimatedUSD.formatted(.currency(code: "USD")), group.histories.count))
                .font(Typography.font(Typography.sidebarMicro)).foregroundStyle(C.textQuaternary)
            }.foregroundStyle(C.textSecondary).padding(.horizontal, 20).padding(.vertical, 8).contentShape(Rectangle())
          }.buttonStyle(.hoverWash)
    }

    /// LINE-style chat-list row: provider avatar, title + time, last-message preview + prompt count.
    private func historyRow(_ history: AgentHistory) -> some View {
        Button { openHistory(history) } label: {
          HStack(alignment: .top, spacing: 10) {
            ProviderAvatar(provider: history.provider, size: 30)
            VStack(alignment: .leading, spacing: 3) {
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(history.title).font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                Text(listTime(history.date)).font(Typography.font(Typography.sidebarMicro)).foregroundStyle(C.textQuaternary)
              }
              HStack(alignment: .top, spacing: 6) {
                Text(history.preview).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textTertiary)
                  .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if history.promptCount > 0 {
                  Text("\(history.promptCount)").font(Typography.font(Typography.sidebarMicro)).monospacedDigit()
                    .foregroundStyle(C.textSecondary).padding(.horizontal, 6).frame(minWidth: 18, minHeight: 16)
                    .background(C.surfaceActive, in: Capsule()).help(tr("送信した依頼 %@ 件", history.promptCount))
                }
              }
            }
          }.padding(.leading, 30).padding(.trailing, 16).padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.hoverWash).help("\(history.provider.rawValue) · \(history.date.formatted(date: .abbreviated, time: .shortened))")
    }
  }

  /// Today → "14:32", yesterday → "昨日", within a week → weekday, older → "9/20" (LINE's chat-list clock).
  func listTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
    if calendar.isDateInYesterday(date) { return tr("昨日") }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? .max
    return days < 7 ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.month(.defaultDigits).day())
  }

  /// Stable per-project hue, like ccedit's projectHue.
  func projectTint(_ name: String) -> Color {
    let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
    return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.75)
  }

  extension AgentHistory.Provider {
    /// Brand tint used behind the provider avatar (ccedit: CL orange, CX violet, OC emerald).
    var tint: Color {
      switch self {
      case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
      case .codex: Color(red: 0.55, green: 0.45, blue: 0.95)
      case .opencode: Color(red: 0.2, green: 0.72, blue: 0.5)
      }
    }
  }

  extension AgentHistory {
    /// Last message, whitespace-collapsed, for the chat-list preview line.
    var preview: String {
      let text = messages.last { !$0.text.isEmpty && $0.role != "thinking" }?.text ?? ""
      return text.prefix(200).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
  }

  struct ProviderAvatar: View {
    let provider: AgentHistory.Provider
    let size: CGFloat
    var body: some View {
      ProviderBrandIcon(provider: provider.rawValue, size: size * 0.8)
        .frame(width: size, height: size)
        .help(provider.rawValue)
    }
  }

  /// ccedit-style (LINE-like) chat: user turns are right-aligned blue bubbles, assistant turns are
  /// left bubbles whose avatar shows once per run, opening at the latest message; and very long turns start collapsed.
  struct AgentChatView: View {
    let history: AgentHistory
    /// Body text size; follows the editor font size (⌘=/⌘-) so long chats stay readable.
    let fontSize: CGFloat
    /// nil when the chat cannot be resumed here (its directory is not a registered Project).
    let onResume: (() -> Void)?
    @State private var transcript: [AgentHistory.Message]?

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          ProviderAvatar(provider: history.provider, size: 28)
          VStack(alignment: .leading, spacing: 4) {
            Text(history.title).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(C.textPrimary).lineLimit(1)
            HStack(spacing: 5) {
              chip(history.provider.rawValue, tint: history.provider.tint)
              if let project = history.project { chip(URL(filePath: project).lastPathComponent, tint: projectTint(URL(filePath: project).lastPathComponent)) }
              chip(tr("依頼 %@ 件", history.promptCount))
              if let usd = history.estimatedUSD { chip(tr("推定 %@", usd.formatted(.currency(code: "USD")))) }
              chip(history.date.formatted(date: .abbreviated, time: .shortened))
            }
          }
          Spacer(minLength: 0)
          Button { onResume?() } label: { Label(tr("ターミナルで再開"), systemImage: "arrow.uturn.forward") }
            .buttonStyle(.hoverWash).disabled(onResume == nil)
            .help(onResume == nil ? tr("このチャットのディレクトリを Project に追加すると再開できます") : tr("%@ をターミナルで開き、このチャットを再開", history.provider.rawValue))
          if let command = history.resumeCommand {
            Button {
              NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
            } label: { Image(systemName: "doc.on.doc").foregroundStyle(C.chromeInk) }
              .buttonStyle(.hoverWash).help(tr("再開コマンドをコピー: %@", command)).accessibilityLabel(tr("再開コマンドをコピー"))
          }
        }.padding(.horizontal, 14).padding(.vertical, 8).background(C.chromeRaised)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            let items = AgentHistory.chatItems(transcript ?? [])
            if transcript == nil {
              ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(24)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
              let message = item.anchor
              let previous = index > 0 ? items[index - 1].anchor : nil
              let next = index + 1 < items.count ? items[index + 1].anchor : nil
              let newDay = previous.map { !Calendar.current.isDate($0.date, inSameDayAs: message.date) } ?? true
              // Progress sits on the agent's side, so it neither splits a run nor repeats the avatar.
              let side = { (m: AgentHistory.Message?) in m.map { $0.role == "user" } }
              if newDay { daySeparator(message.date).padding(.top, previous == nil ? 0 : 16).padding(.bottom, 12) }
              if case .progress(let steps) = item {
                ProgressRow(steps: steps, provider: history.provider, fontSize: fontSize, showLabel: newDay || side(previous) != false).padding(.top, previous == nil || newDay ? 0 : side(previous) == false ? 5 : 16)
              } else if message.text.hasPrefix("[Skill loaded") {
                systemPill(String(message.text.dropFirst().dropLast()).replacing("Skill loaded", with: tr("スキル読込")), icon: "wand.and.stars")
                  .padding(.top, previous == nil || newDay ? 0 : 8)
              } else {
              Bubble(message: message, provider: history.provider, fontSize: fontSize,
                     showLabel: message.role != "user" && (newDay || side(previous) != false),
                     showTime: side(next) != side(message))
                .padding(.top, previous == nil || newDay ? 0 : side(previous) == side(message) ? 5 : 16)
              }
            }
          }.padding(16).padding(.bottom, 16)
        }.defaultScrollAnchor(.bottom).clairScroller()
      }.frame(maxWidth: .infinity, maxHeight: .infinity).background(C.canvas)
        .task { transcript = await AgentHistoryStore.shared.transcript(history) }
    }

    private func systemPill(_ text: String, icon: String) -> some View {
      Label(text, systemImage: icon).font(.system(size: fontSize - 2)).foregroundStyle(C.textTertiary)
        .padding(.horizontal, 10).padding(.vertical, 3).background(C.surfaceActive.opacity(0.7), in: Capsule())
        .frame(maxWidth: .infinity)
    }

    private func chip(_ text: String, tint: Color? = nil) -> some View {
      HStack(spacing: 4) {
        if let tint { Circle().fill(tint).frame(width: 6, height: 6) }
        Text(text).lineLimit(1)
      }.font(.system(size: fontSize - 2)).foregroundStyle(C.textTertiary)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(C.canvas, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(C.divider.opacity(0.6), lineWidth: 1))
    }

    /// LINE-style centred day pill between turns from different days.
    private func daySeparator(_ date: Date) -> some View {
      Text(date.formatted(.dateTime.month().day().weekday(.abbreviated)))
        .font(.system(size: fontSize - 2)).foregroundStyle(C.textTertiary)
        .padding(.horizontal, 10).padding(.vertical, 3).background(C.surfaceActive.opacity(0.7), in: Capsule())
        .frame(maxWidth: .infinity)
    }

    /// An agent run's narration and thinking before its reply, folded by default.
    private struct ProgressRow: View {
      let steps: [AgentHistory.Message]
      let provider: AgentHistory.Provider
      let fontSize: CGFloat
      let showLabel: Bool
      @State private var expanded = false

      var body: some View {
        HStack(alignment: .top, spacing: 10) {
          Group { if showLabel { ProviderAvatar(provider: provider, size: 28) } }.frame(width: 28)
          VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
              HStack(spacing: 4) {
                Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                Text(tr("途中経過 %@ 件", steps.count))
              }
            }.buttonStyle(.plain).font(.system(size: fontSize - 3)).foregroundStyle(C.textTertiary)
              .accessibilityValue(expanded ? tr("折りたたむ") : tr("続きを表示"))
            if expanded {
              VStack(alignment: .leading, spacing: 8) {
                ForEach(steps) { step in
                  VStack(alignment: .leading, spacing: 2) {
                    // "Thinking" is the providers' own term, so it stays untranslated.
                    if step.role == "thinking" { Text(verbatim: "Thinking").font(.system(size: fontSize - 3)).foregroundStyle(C.textQuaternary) }
                    Text((try? AttributedString(markdown: step.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(step.text))
                      .font(.system(size: fontSize))
                      .foregroundStyle(step.role == "thinking" ? C.textTertiary : C.textSecondary).textSelection(.enabled)
                  }
                }
              }.padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(C.divider).frame(width: 2) }
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, showLabel ? 6 : 0)
        }.padding(.trailing, 40)
      }
    }

    private struct Bubble: View {
      let message: AgentHistory.Message
      let provider: AgentHistory.Provider
      let fontSize: CGFloat
      let showLabel: Bool
      let showTime: Bool
      @State private var expanded = false

      var body: some View {
        let long = message.text.count > 1500
        let text = long && !expanded ? String(message.text.prefix(1500)) + "…" : message.text
        let body = Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
          .font(.system(size: fontSize)).foregroundStyle(C.textPrimary).textSelection(.enabled)
        let more = Button(expanded ? tr("折りたたむ") : tr("続きを表示")) { expanded.toggle() }
          .buttonStyle(.plain).font(.system(size: fontSize - 3)).foregroundStyle(C.textTertiary)
        let time = Text(message.date.formatted(date: .omitted, time: .shortened))
          .font(.system(size: fontSize - 3)).foregroundStyle(C.textQuaternary)
        if message.role == "user" {
          HStack {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
              body.foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9)
                .background(C.debugBlue, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 5))
              HStack(spacing: 8) {
                if long { more }; if showTime { time }
                Button {
                  NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                  .buttonStyle(.plain).font(.system(size: fontSize - 3)).foregroundStyle(C.textTertiary)
                  .help(tr("プロンプトをコピー")).accessibilityLabel(tr("プロンプトをコピー"))
              }
            }.containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.72 }
          }
        } else {
          HStack(alignment: .top, spacing: 10) {
            Group {
              if showLabel { ProviderAvatar(provider: provider, size: 28) }
            }.frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
              body.padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(C.surfaceActive, in: UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 16))
              if long || showTime { HStack(spacing: 8) { if showTime { time }; if long { more } } }
            }
          }.padding(.trailing, 40)
        }
      }
    }
  }

#endif
