#if os(macOS)
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
  }

  /// A suggestion as the diff shows it. `stale`: the buffer changed since it was made, so it can no longer apply.
  struct PlacedSuggestion: Identifiable {
    let line: Int
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
    private(set) var version = 0
    private let file: URL?
    private let asynchronousPersistence: Bool
    private let persistenceQueue = DispatchQueue(label: "com.diwamoto.clair.review-save", qos: .utility)
    static let you = ReviewAuthor(displayName: "あなた", kind: .human)

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

    func add(root: String, path: String, line: Int, text: String? = nil, body: String, snapshot: TextSnapshot) {
      guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let l = try? snapshot.line(at: TextLineIndex(line - 1))
      else { return }
      let k = key(root, path), m = managers[k] ?? ReviewThreadManager()
      managers[k] = m
      let id = m.addThread(author: Self.you, body: body, anchor: ReviewAnchor(range: l.contentRange)).id
      lines[id] = line; texts[id] = text
      version += 1; save()
    }

    /// Open threads as a prompt for an agent: one `path:line` heading per thread, comments beneath. Nil when nothing is open.
    func prompt(root: String, path: String, in file: [String]? = nil) -> String? {
      let open = placed(root, path, in: file).filter { $0.thread.state == .open }.sorted { $0.line < $1.line }
      guard !open.isEmpty else { return nil }
      return "次のレビューコメントに対応してください。\n\n"
        + open.map { p in
          "\(path):\(p.line)" + (p.stale ? "（コメント後に行が変更されています）" : "") + "\n"
            + p.thread.comments.map { "- \($0.body)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    func resolve(root: String, path: String, id: UUID) { try? managers[key(root, path)]?.resolveThread(id: id); version += 1; save() }

    // MARK: suggestions

    /// A one-line replacement proposal on `line`, bound to the buffer's current revision.
    func suggest(root: String, path: String, line: Int, replacement: String, snapshot: TextSnapshot) {
      guard let l = try? snapshot.line(at: TextLineIndex(line - 1)) else { return }
      let k = key(root, path), m = managers[k] ?? ReviewThreadManager()
      managers[k] = m
      let s = m.addSuggestion(
        hunks: [ReviewSuggestionHunk(anchor: ReviewAnchor(range: l.contentRange), replacement: replacement)], baseRevision: snapshot.revision)
      suggestionLines[s.id] = line; version += 1
    }

    func suggestions(root: String, _ path: String, current: TextRevision?) -> [PlacedSuggestion] {
      _ = version
      return (managers[key(root, path)]?.suggestions ?? []).compactMap { s in
        suggestionLines[s.id].map { PlacedSuggestion(line: $0, suggestion: s, stale: s.state == .pending && s.baseRevision != current) }
      }
    }

    /// Applies into the open buffer as one undo unit. Returns a message on refusal, nil on success.
    func apply(root: String, path: String, id: UUID, in manager: EditorTransactionManager) -> String? {
      defer { version += 1 }
      do { try managers[key(root, path)]?.applySuggestion(id: id, in: manager); return nil }
      catch ReviewThreadManagerError.suggestionRevisionMismatch { return "バッファが変更されたため適用できません。" }
      catch { return "適用できません。" }
    }

    func reject(root: String, path: String, id: UUID) { try? managers[key(root, path)]?.rejectSuggestion(id: id); version += 1 }
  }

  /// Source-control sidebar: staged / changes / untracked sections with a stage toggle per row.
  struct ChangesList: View {
    let changes: [GitChange]
    let selected: DiffTarget?
    let onSelect: (DiffTarget) -> Void
    let onToggle: (GitChange, _ staged: Bool) -> Void
    /// Section-wide stage/unstage; the flag is the desired state.
    let onBulk: ([GitChange], _ stage: Bool) -> Void
    /// Starts a commit through the typed command registry.
    let onCommit: (String) -> Void
    let busy: Bool
    let operationMessage: String?
    @State private var message = ""
    @State private var hovered: DiffTarget?
    @State private var collapsed: Set<String> = []

    /// Same geometry as the explorer's treeRow in ClairAppShell: inset, rounded 24px row, 12px indent per level.
    private func treeRow<Content: View>(depth: Int, selected: Bool, action: @escaping () -> Void, @ViewBuilder _ content: () -> Content) -> some View {
      Button(action: action) {
        HStack(spacing: 10, content: content)
          .padding(.leading, 8 + CGFloat(depth + 1) * 12).padding(.trailing, 8).frame(height: 24)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(selected ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
          .contentShape(Rectangle())
      }.buttonStyle(.hoverWash).padding(.horizontal, 8)
    }

    private var canCommit: Bool { !busy && changes.contains(where: \.staged) && !message.trimmingCharacters(in: .whitespaces).isEmpty }

    private var commitBox: some View {
      VStack(alignment: .leading, spacing: 6) {
        TextField("コミットメッセージ", text: $message)
          .textFieldStyle(.plain).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textPrimary)
          .padding(.horizontal, 8).frame(height: 26)
          .background(C.surfaceActive, in: RoundedRectangle(cornerRadius: Radius.control))
          .onSubmit(commit)
        Button(action: commit) {
          Label("コミット", systemImage: "checkmark").font(Typography.font(Typography.sidebarStrong))
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
          VStack(spacing: 4) {
            Text("変更はありません").font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textSecondary)
            Text("working tree はきれいです。").font(Typography.font(Typography.sidebar)).foregroundStyle(C.textQuaternary)
          }.frame(maxWidth: .infinity).padding(16)
        } else {
          commitBox
          section("ステージ済み", changes.filter(\.staged)) { DiffTarget(path: $0.path, staged: true, untracked: false) }
          section("変更", changes.filter { $0.unstaged && !$0.untracked }) { DiffTarget(path: $0.path, staged: false, untracked: false) }
          section("未追跡", changes.filter(\.untracked)) { DiffTarget(path: $0.path, staged: false, untracked: true) }
        }
      }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [GitChange], _ target: @escaping (GitChange) -> DiffTarget) -> some View {
      if !rows.isEmpty {
        HStack(spacing: 4) {
          Text(title).font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textTertiary)
          Text("\(rows.count) ファイル").font(Typography.font(Typography.sidebar)).foregroundStyle(C.textQuaternary)
          Spacer()
          let stage = title != "ステージ済み"
          Button { onBulk(rows, stage) } label: {
            Text(stage ? "+" : "−").font(Typography.font(Typography.title)).foregroundStyle(C.textTertiary).frame(width: 18, height: 18)
          }.buttonStyle(.hoverWash).disabled(busy).help(stage ? "すべてステージに追加" : "すべてステージから外す")
        }.padding(.leading, 20).padding(.trailing, 12).frame(height: 26)
        // Tree styled like the explorer (24px rows, 12px indent, chevron + folder). A folder row is emitted
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
                Image(systemName: open ? "folder" : "folder.fill").font(.system(size: 10)).foregroundStyle(C.textTertiary).frame(width: 12)
                Text(dirs[d]).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
              }
            }
          }
          if !ids.contains(where: collapsed.contains) {
            let t = target(c), on = selected == t, name = c.path.split(separator: "/").last.map(String.init) ?? c.path
            let badge = c.untracked ? "U" : c.index == "A" || c.worktree == "A" ? "A" : c.index == "D" || c.worktree == "D" ? "D" : "M"
            treeRow(depth: dirs.count, selected: on, action: { onSelect(t) }) {
              Image(systemName: c.path.hasSuffix(".md") ? "text.alignleft" : "doc.text").font(.system(size: 10)).foregroundStyle(on ? C.textSecondary : C.textTertiary).frame(width: 12)
              Text(name).font(.system(size: 12, weight: on ? .semibold : .regular)).foregroundStyle(on ? C.textPrimary : C.textSecondary).lineLimit(1)
              Spacer(minLength: 0)
              if hovered == t {
                Button { onToggle(c, !t.staged) } label: {
                  Text(t.staged ? "−" : "+").font(Typography.font(Typography.title)).foregroundStyle(C.textTertiary).frame(width: 18, height: 18)
                }.buttonStyle(.hoverWash).disabled(busy).help(t.staged ? "ステージを取り消す" : "ステージに追加")
              }
              Text(badge).font(.system(size: 12, weight: .semibold)).foregroundStyle(badge == "A" || badge == "U" ? C.success : badge == "D" ? C.textTertiary : C.attention)
            }
            .onHover { hovered = $0 ? t : (hovered == t ? nil : hovered) }
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
    @State private var composing: Int?
    @State private var draft = ""
    @State private var suggesting = false
    @State private var applyError: String?
    @State private var hunk = -1
    @State private var sent = false
    @State private var compact = false
    @State private var editing = false
    /// A diff this long is cut with a notice instead of laying out every row.
    nonisolated static let maxLines = 5000

    struct Row: Sendable { let text: String; let newLine: Int? }

    /// Immutable, pre-parsed diff data. Construct this away from the main actor; a large diff must
    /// not be tokenised and counted again for every SwiftUI body evaluation.
    struct Model: Sendable {
      let text: String
      let rows: [Row]
      let added: Int
      let removed: Int
      let hunks: [Int]
      let visibleLines: Set<Int>
    }

    nonisolated static func model(_ text: String) -> Model {
      let parsed = rows(text)
      let counts = stats(parsed)
      return Model(
        text: text, rows: parsed, added: counts.added, removed: counts.removed,
        hunks: parsed.indices.filter { parsed[$0].text.hasPrefix("@@") },
        visibleLines: Set(parsed.compactMap(\.newLine)))
    }

    /// Parses `@@ -a,b +c,d @@` for `c`, then numbers context and added lines from there.
    nonisolated static func rows(_ text: String) -> [Row] {
      let all = text.split(separator: "\n", omittingEmptySubsequences: false)
      let body = all.drop { !$0.hasPrefix("@@") }
      if body.isEmpty { return all.filter { $0.hasPrefix("Binary") }.map { Row(text: String($0), newLine: nil) } }
      var n = 0
      return body.prefix(maxLines).map { l in
        if l.hasPrefix("@@") {
          n = l.split(separator: " ").first { $0.hasPrefix("+") }
            .flatMap { Int($0.dropFirst().split(separator: ",")[0]) } ?? 1
          return Row(text: String(l), newLine: nil)
        }
        if l.hasPrefix("-") || l.hasPrefix("\\") { return Row(text: String(l), newLine: nil) }
        defer { n += 1 }
        return Row(text: String(l), newLine: n)
      }
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
        HStack {
          Text(target.path).font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textPrimary)
          Text(target.staged ? "HEAD → index" : target.untracked ? "未追跡ファイル" : "index → 作業ツリー")
            .font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary)
          if added + removed > 0 {
            Text("+\(added)").font(Typography.font(Typography.chrome)).foregroundStyle(C.success)
            Text("−\(removed)").font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
          }
          Spacer()
          if editor != nil {
            Button(editing ? "差分" : "編集") { editing.toggle() }
              .font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).buttonStyle(.hoverWash)
              .help(editing ? "差分の表示に戻る" : "このファイルを編集する")
            if editing, let onSave {
              Button(isDirty ? "保存 ●" : "保存", action: onSave)
                .font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).buttonStyle(.hoverWash)
                .keyboardShortcut("s", modifiers: .command)
                .help("このファイルを保存する")
            }
          }
          if !editing {
            Button(compact ? "全文脈" : "変更箇所") { compact.toggle() }
              .font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).buttonStyle(.hoverWash)
              .help(compact ? "ファイル全体を表示" : "変更箇所に絞る")
          }
          if !editing && !hunks.isEmpty {
            Text("\(max(hunk, 0) + 1)/\(hunks.count)").font(Typography.font(Typography.micro)).foregroundStyle(C.textQuaternary)
            ForEach([-1, 1], id: \.self) { d in
              Button {
                hunk = min(max(hunk + d, 0), hunks.count - 1)
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(hunks[hunk], anchor: .top) }
              } label: { Image(systemName: d < 0 ? "chevron.up" : "chevron.down").foregroundStyle(C.chromeInk) }
                .buttonStyle(.hoverWash).keyboardShortcut(d < 0 ? .upArrow : .downArrow, modifiers: .option)
                .help(d < 0 ? "前の hunk (⌥↑)" : "次の hunk (⌥↓)")
            }
          }
          if let onSend {
            Button { onSend(); sent = true } label: {
              Text(sent ? "コピー済み（⌘V で貼り付け）" : "agent に送る").font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary)
            }.buttonStyle(.hoverWash).help("未解決コメントをプロンプトとしてコピーし、agent のターミナルへ移動")
          }
          Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(C.chromeInk) }.buttonStyle(.hoverWash)
        }.padding(.horizontal, 12).frame(height: 32).background(C.chromeRaised)
        if editing, let editor {
          editor
        } else if model.text.isEmpty {
          Text("差分はありません。").font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          GeometryReader { viewport in
            ScrollView([.vertical, .horizontal]) {
              LazyVStack(alignment: .leading, spacing: 0) {
                if !looseThreads.isEmpty || !looseSuggestions.isEmpty {
                  Text("この差分に表示できないコメント・提案").font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textTertiary).padding(.horizontal, 12).padding(.vertical, 6)
                  ForEach(looseThreads, id: \.key) { l, ts in
                    ForEach(ts) { thread($0, note: l == 0 ? "行が変更されたため位置を特定できません" : "\(l) 行目") }
                  }
                  ForEach(looseSuggestions) { suggestion($0) }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                  if !compact || r.text.hasPrefix("@@") || r.text.hasPrefix("+") || r.text.hasPrefix("-") || r.text.hasPrefix("\\") || threads[r.newLine ?? -1] != nil || suggestionsByLine[r.newLine ?? -1] != nil {
                    line(r).id(i)
                    if let n = r.newLine {
                      ForEach(threads[n] ?? []) { thread($0) }
                      ForEach(suggestionsByLine[n] ?? []) { suggestion($0) }
                      if composing == n { composer(n, text: String(r.text.dropFirst())) }
                    }
                  }
                }
                if rows.count == Self.maxLines {
                  Text("差分が長いため \(Self.maxLines) 行で打ち切りました。").font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).padding(12)
                }
              }
              .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
            }
          }
        }
      }.background(C.surface)
      }
    }

    private func line(_ r: Row) -> some View {
      let l = r.text
      return Text(l.isEmpty ? " " : String(l)).font(.system(size: 12, design: .monospaced))
        .foregroundStyle(l.hasPrefix("@@") ? C.textQuaternary : C.code)
        .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 18)
        .background(l.hasPrefix("+") ? C.success.opacity(0.12) : l.hasPrefix("-") ? C.danger.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if let n = r.newLine { composing = composing == n ? nil : n; draft = ""; suggesting = false } }
        .help(r.newLine == nil ? "" : "クリックしてコメント")
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
          Button("解決する") { onResolve(t.id) }.buttonStyle(.hoverWash).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
        } else {
          Text("解決済み").font(Typography.font(Typography.chrome)).foregroundStyle(C.success)
        }
      }
      .padding(8).frame(maxWidth: 520, alignment: .leading).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card))
      .opacity(t.state == .open ? 1 : 0.6).padding(.leading, 28).padding(.vertical, 4)
    }

    private func suggestion(_ p: PlacedSuggestion) -> some View {
      let pending = p.suggestion.state == .pending
      return VStack(alignment: .leading, spacing: 4) {
        Text("提案 · \(p.line) 行目").font(Typography.font(Typography.micro)).foregroundStyle(C.textQuaternary)
        Text("+ " + p.replacement).font(.system(size: 12, design: .monospaced)).foregroundStyle(C.code)
          .padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading).background(C.success.opacity(0.12))
        if pending {
          HStack(spacing: 8) {
            Button("適用") { applyError = onApply(p.id) }.buttonStyle(.hoverWash).foregroundStyle(p.stale ? C.textQuaternary : C.textPrimary).disabled(p.stale)
            Button("却下") { onReject(p.id) }.buttonStyle(.hoverWash).foregroundStyle(C.textTertiary)
            if p.stale { Text("バッファが変更されたため適用できません").foregroundStyle(C.attention) }
            else if let applyError { Text(applyError).foregroundStyle(C.attention) }
          }.font(Typography.font(Typography.chrome))
        } else {
          Text(p.suggestion.state == .applied ? "適用済み（未保存。⌘S で保存）" : p.suggestion.state == .rejected ? "却下済み" : "一部適用済み")
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
        TextField(suggesting ? "この行の置換後" : "コメント", text: $draft).textFieldStyle(.plain).font(Typography.font(Typography.chrome)).frame(width: 360)
          .onSubmit(submit)
        Button(suggesting ? "提案する" : "追加", action: submit).buttonStyle(.hoverWash).foregroundStyle(C.textSecondary)
        Button(suggesting ? "コメントに戻す" : "提案にする") { suggesting.toggle(); draft = suggesting ? text : "" }
          .buttonStyle(.hoverWash).foregroundStyle(C.textTertiary)
        Button("キャンセル") { composing = nil }.buttonStyle(.hoverWash).foregroundStyle(C.textTertiary)
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
          Text("AI が実行を求めています").font(.system(size: 13, weight: .semibold)).foregroundStyle(C.textPrimary)
          Spacer(minLength: 0)
          TimelineView(.periodic(from: .now, by: 1)) { c in
            Text("残り \(max(0, Int(deadline.timeIntervalSince(c.date).rounded(.up)))) 秒").font(.system(size: 11)).monospacedDigit().foregroundStyle(C.textQuaternary)
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
          Text("リスク \(risk.label)").font(.system(size: 11)).foregroundStyle(risk >= .destructive ? C.danger : C.textQuaternary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 8) {
          Spacer()
          approvalButton("拒否", primary: false) { decide(false) }.keyboardShortcut(.cancelAction)
          approvalButton("許可して実行", primary: true) { decide(true) }.keyboardShortcut(.return, modifiers: .command)
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
          TextField("Projectを検索", text: $query)
            .focused($queryFocused).task { queryFocused = true }  // task: runs after the field is in the window, unlike onAppear
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(C.textPrimary)
            .onSubmit(openSelected)
            .onKeyPress(.downArrow) { selection = min(selection + 1, max(displayedHits.count - 1, 0)); return .handled }
            .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
            .onChange(of: query) { selection = 0; search() }
          if searching { ProgressView().controlSize(.small) }
          Text("\(hits.count)件 · \(Set(hits.map(\.path)).count)ファイル").font(.system(size: 11)).foregroundStyle(C.textQuaternary)
          chip(".*", on: $regex, help: "正規表現")
          chip("Aa", on: $caseSensitive, help: "大文字小文字を区別")
        }
        .padding(.horizontal, 8).frame(height: 40)
        .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.hairline)).padding(12)
        .onChange(of: regex) { selection = 0; search() }
        .onChange(of: caseSensitive) { selection = 0; search() }

        if replaceMode {
          HStack(spacing: 6) {
            HStack(spacing: 8) {
              Image(systemName: "arrow.2.squarepath").font(.system(size: 13)).foregroundStyle(C.textQuaternary)
              TextField("置換", text: $replacement).textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(C.textPrimary)
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(L.hairline))
            let canReplace = !hits.isEmpty && !replacing && !searching
            Button(action: replaceAll) {
              Text(replacing ? "置換中…" : "すべて置換").font(.system(size: 11, weight: .semibold))
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
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(indexedGroups, id: \.path) { group in
              HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(C.textTertiary)
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
              }
            }
          }.padding(.horizontal, 8).padding(.bottom, 8)
        }.frame(minHeight: 322, maxHeight: 420)
        HStack(spacing: 8) {
          ForEach([("検索", false), ("置換 ⌥⌘F", true)], id: \.1) { label, mode in
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
    @State private var collapsedGroups: Set<String> = []
    @State private var archive: [AgentHistory]?
    @State private var archiveOpen = false

    private func label(_ s: AgentSession) -> (String, Color) {
      switch s.status {
      case .running: ("実行中", C.textTertiary)
      case .attention: ("入力待ち（ベル）", C.attention)
      case .exited(let c): (c == 0 ? "正常終了" : "異常終了 (exit \(c ?? -1))", C.textQuaternary)
      }
    }

    var body: some View {
      Text("エージェント").font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textTertiary)
        .padding(.horizontal, 20).frame(height: 26)
        .task {
          histories = await AgentHistoryStore.shared.load(.recent)
          historyLoading = false
        }
      if sessions.isEmpty {
        Text("起動中のエージェントはありません").font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textSecondary)
          .frame(maxWidth: .infinity).padding(16)
      }
      ForEach(sessions) { s in
        let (text, color) = label(s)
        Button { open(s) } label: {
          HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
              Text(s.title).font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textPrimary)
              if let activity = s.activity {
                Text(activity).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textSecondary).lineLimit(1)
              }
              Text("\(text) · \(s.project == current ? "" : s.project + " · ")\(s.cwd.split(separator: "/").last.map(String.init) ?? s.cwd)")
                .font(Typography.font(Typography.sidebar)).foregroundStyle(C.textQuaternary).lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 20).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.hoverWash)
      }
      HStack {
        Text("過去のチャット").font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textTertiary)
        Spacer()
        Button { Task { historyLoading = true; histories = await AgentHistoryStore.shared.refresh(.recent); archive = nil; archiveOpen = false; historyLoading = false } } label: {
          Image(systemName: "arrow.clockwise")
        }.buttonStyle(.plain).help("履歴を更新")
      }.padding(.horizontal, 20).padding(.top, 14)
      if historyLoading {
        Text("Loading...").font(Typography.font(Typography.sidebar)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 20).frame(height: 28)
      } else if histories.isEmpty {
        Text("履歴はありません").font(Typography.font(Typography.sidebar)).foregroundStyle(C.textQuaternary).padding(16)
      }
      // ponytail: regrouped on every render; cache in @State if history counts make this visible.
      historySections(AgentHistorySection.group(histories))
      Button {
        archiveOpen.toggle()
        if archiveOpen, archive == nil { Task { archive = await AgentHistoryStore.shared.load(.archive) } }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: archiveOpen ? "chevron.down" : "chevron.right").frame(width: 14)
          Text("アーカイブ（1ヶ月以上前）").font(Typography.font(Typography.sidebarStrong))
          Spacer(minLength: 0)
        }.foregroundStyle(C.textTertiary).padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4).contentShape(Rectangle())
      }.buttonStyle(.hoverWash)
      if archiveOpen {
        if let archive {
          if archive.isEmpty {
            Text("アーカイブはありません").font(Typography.font(Typography.sidebar)).foregroundStyle(C.textQuaternary).padding(16)
          }
          // Archive is older than every relative-day bucket, so its one section is labelled by project only.
          ForEach(AgentHistorySection.group(archive).flatMap(\.groups)) { group in historyGroup(group) }
        } else {
          Text("Loading...").font(Typography.font(Typography.sidebar)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 20).frame(height: 28)
        }
      }
    }

    @ViewBuilder private func historySections(_ sections: [AgentHistorySection]) -> some View {
      ForEach(sections) { section in
        Text(section.label).font(Typography.font(Typography.sidebarMicro)).foregroundStyle(C.textQuaternary)
          .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 3)
        ForEach(section.groups) { group in historyGroup(group) }
      }
    }

    @ViewBuilder private func historyGroup(_ group: AgentHistorySection.Group) -> some View {
          let collapsed = collapsedGroups.contains(group.id)
          Button {
            if collapsed { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: collapsed ? "chevron.right" : "chevron.down").frame(width: 14)
              Text(group.project).font(Typography.font(Typography.sidebarStrong)).lineLimit(1)
              Spacer(minLength: 0)
              Text("\(group.estimatedUSD.formatted(.currency(code: "USD"))) · \(group.histories.count) 件")
                .font(Typography.font(Typography.sidebarMicro)).foregroundStyle(C.textQuaternary)
            }.foregroundStyle(C.textSecondary).padding(.horizontal, 20).padding(.vertical, 4).contentShape(Rectangle())
          }.buttonStyle(.hoverWash)
          if !collapsed {
            ForEach(group.histories) { history in historyRow(history) }
          }
    }

    private func historyRow(_ history: AgentHistory) -> some View {
        Button { openHistory(history) } label: {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: history.provider == .claude ? "sparkles" : history.provider == .codex ? "chevron.left.forwardslash.chevron.right" : "square.stack.3d.up")
              .frame(width: 14).foregroundStyle(C.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
              Text(history.title).lineLimit(2).foregroundStyle(C.textPrimary)
              Text("\(history.provider.rawValue) · \(history.date.formatted(date: .abbreviated, time: .shortened))")
                .font(Typography.font(Typography.sidebarMicro)).foregroundStyle(C.textQuaternary)
            }
            Spacer(minLength: 0)
          }.padding(.leading, 34).padding(.trailing, 20).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.hoverWash)
    }
  }

  /// ccedit-style chat panel in the main area: user turns are right-aligned bubbles,
  /// consecutive assistant turns share one label, and very long turns start collapsed.
  struct AgentChatView: View {
    let history: AgentHistory
    let onClose: () -> Void

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Text(history.title).font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textPrimary).lineLimit(1)
          Text("\(history.provider.rawValue) · \(history.date.formatted(date: .abbreviated, time: .shortened))")
            .font(Typography.font(Typography.micro)).foregroundStyle(C.textQuaternary).lineLimit(1)
          Spacer(minLength: 0)
          Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(C.chromeInk) }.buttonStyle(.hoverWash).help("閉じる")
        }.padding(.horizontal, 12).frame(height: 32).background(C.chromeRaised)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(history.messages.enumerated()), id: \.element.id) { index, message in
              let previous = index > 0 ? history.messages[index - 1].role : nil
              Bubble(message: message, provider: history.provider.rawValue, showLabel: message.role != "user" && previous != message.role)
                .padding(.top, previous == nil ? 0 : previous == message.role ? 5 : 16)
            }
          }.padding(16).padding(.bottom, 16)
        }.clairScroller()
      }.frame(maxWidth: .infinity, maxHeight: .infinity).background(C.canvas)
    }

    private struct Bubble: View {
      let message: AgentHistory.Message
      let provider: String
      let showLabel: Bool
      @State private var expanded = false

      var body: some View {
        let long = message.text.count > 1500
        let text = long && !expanded ? String(message.text.prefix(1500)) + "…" : message.text
        let body = Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
          .font(Typography.font(Typography.chrome)).foregroundStyle(C.textPrimary).textSelection(.enabled)
        let more = Button(expanded ? "折りたたむ" : "続きを表示") { expanded.toggle() }
          .buttonStyle(.plain).font(Typography.font(Typography.micro)).foregroundStyle(C.textTertiary)
        if message.role == "user" {
          HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 4) {
              body.padding(.horizontal, 12).padding(.vertical, 8)
                .background(C.surfaceActive, in: RoundedRectangle(cornerRadius: 12))
              if long { more }
            }
          }
        } else {
          VStack(alignment: .leading, spacing: 4) {
            if showLabel { Text(provider).font(Typography.font(Typography.micro)).foregroundStyle(C.textQuaternary) }
            body
            if long { more }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 40)
        }
      }
    }
  }

#endif
