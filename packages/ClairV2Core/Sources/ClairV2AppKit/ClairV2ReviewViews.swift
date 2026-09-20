#if os(macOS)
  import ClairV2DesignSystem
  import ClairV2EditorCore
  import ClairV2Review
  import ClairV2Workspace
  import Observation
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  /// U05: which side of a change the diff pane is showing.
  struct DiffTarget: Equatable {
    let path: String
    let staged: Bool
    let untracked: Bool
  }

  /// Review threads of the active Project, anchored to a file line. In memory only (no persistence yet).
  // ponytail: the line is fixed at creation and `rebase(through:)` is not fed editor edits; wire both when threads persist.
  @MainActor @Observable final class ReviewStore {
    private var managers: [String: ReviewThreadManager] = [:]
    private var lines: [UUID: Int] = [:]
    private(set) var version = 0
    static let you = ReviewAuthor(displayName: "あなた", kind: .human)

    /// 1-based file line → threads on it.
    func threads(_ path: String) -> [Int: [ReviewThread]] {
      _ = version
      var out: [Int: [ReviewThread]] = [:]
      for t in managers[path]?.threads ?? [] { if let l = lines[t.id] { out[l, default: []].append(t) } }
      return out
    }

    func add(path: String, line: Int, body: String, snapshot: TextSnapshot) {
      guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let l = try? snapshot.line(at: TextLineIndex(line - 1))
      else { return }
      let m = managers[path] ?? ReviewThreadManager()
      managers[path] = m
      lines[m.addThread(author: Self.you, body: body, anchor: ReviewAnchor(range: l.contentRange)).id] = line
      version += 1
    }

    func resolve(path: String, id: UUID) { try? managers[path]?.resolveThread(id: id); version += 1 }
  }

  /// Source-control sidebar: staged / changes / untracked sections with a stage toggle per row.
  struct ChangesList: View {
    let changes: [GitChange]
    let selected: DiffTarget?
    let onSelect: (DiffTarget) -> Void
    let onToggle: (GitChange, _ staged: Bool) -> Void

    var body: some View {
      if changes.isEmpty {
        VStack(spacing: 4) {
          Text("変更はありません").font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textSecondary)
          Text("working tree はきれいです。").font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary)
        }.frame(maxWidth: .infinity).padding(16)
      } else {
        section("ステージ済み", changes.filter(\.staged)) { DiffTarget(path: $0.path, staged: true, untracked: false) }
        section("変更", changes.filter { $0.unstaged && !$0.untracked }) { DiffTarget(path: $0.path, staged: false, untracked: false) }
        section("未追跡", changes.filter(\.untracked)) { DiffTarget(path: $0.path, staged: false, untracked: true) }
      }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [GitChange], _ target: @escaping (GitChange) -> DiffTarget) -> some View {
      if !rows.isEmpty {
        HStack(spacing: 4) {
          Text(title).font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textTertiary)
          Text("\(rows.count)").font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary)
          Spacer()
        }.padding(.leading, 20).padding(.trailing, 12).frame(height: 26)
        ForEach(rows, id: \.path) { c in
          let t = target(c), on = selected == t
          HStack(spacing: 4) {
            Text(c.path.split(separator: "/").last.map(String.init) ?? c.path)
              .font(Typography.font(Typography.chrome)).lineLimit(1)
              .foregroundStyle(c.untracked ? C.success : on ? C.textPrimary : C.textSecondary)
            Spacer()
            if c.untracked { Text("未追跡").font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary) }
            Button { onToggle(c, !t.staged) } label: {
              Text(t.staged ? "−" : "+").font(Typography.font(Typography.title)).foregroundStyle(C.textTertiary).frame(width: 18, height: 18)
            }.buttonStyle(.plain).help(t.staged ? "ステージを取り消す" : "ステージに追加")
          }
          .padding(.horizontal, 8).frame(height: 26)
          .background(on ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
          .padding(.horizontal, 8).contentShape(Rectangle()).onTapGesture { onSelect(t) }
        }
      }
    }
  }

  /// Unified diff of one file. Colour is only for add/remove (state meaning); hunk headers stay quiet.
  /// Lines that exist on the new side can be commented.
  struct DiffView: View {
    let target: DiffTarget
    let text: String
    let threads: [Int: [ReviewThread]]
    let onComment: (Int, String) -> Void
    let onResolve: (UUID) -> Void
    let onClose: () -> Void
    @State private var composing: Int?
    @State private var draft = ""
    /// A diff this long is cut with a notice instead of laying out every row.
    static let maxLines = 5000

    struct Row { let text: Substring; let newLine: Int? }

    /// Parses `@@ -a,b +c,d @@` for `c`, then numbers context and added lines from there.
    static func rows(_ text: String) -> [Row] {
      let all = text.split(separator: "\n", omittingEmptySubsequences: false)
      let body = all.drop { !$0.hasPrefix("@@") }
      if body.isEmpty { return all.filter { $0.hasPrefix("Binary") }.map { Row(text: $0, newLine: nil) } }
      var n = 0
      return body.prefix(maxLines).map { l in
        if l.hasPrefix("@@") {
          n = l.split(separator: " ").first { $0.hasPrefix("+") }
            .flatMap { Int($0.dropFirst().split(separator: ",")[0]) } ?? 1
          return Row(text: l, newLine: nil)
        }
        if l.hasPrefix("-") || l.hasPrefix("\\") { return Row(text: l, newLine: nil) }
        defer { n += 1 }
        return Row(text: l, newLine: n)
      }
    }

    var body: some View {
      let rows = Self.rows(text)
      VStack(spacing: 0) {
        HStack {
          Text(target.path).font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textPrimary)
          Text(target.staged ? "ステージ済み" : target.untracked ? "未追跡" : "変更").font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary)
          Spacer()
          Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(C.chromeInk) }.buttonStyle(.plain)
        }.padding(.horizontal, 12).frame(height: 32).background(C.chromeRaised)
        if text.isEmpty {
          Text("差分はありません。").font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                line(r)
                if let n = r.newLine {
                  ForEach(threads[n] ?? []) { thread($0) }
                  if composing == n { composer(n) }
                }
              }
              if rows.count == Self.maxLines {
                Text("差分が長いため \(Self.maxLines) 行で打ち切りました。").font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).padding(12)
              }
            }
          }
        }
      }.background(C.surface)
    }

    private func line(_ r: Row) -> some View {
      let l = r.text
      return Text(l.isEmpty ? " " : String(l)).font(.system(size: 12, design: .monospaced))
        .foregroundStyle(l.hasPrefix("@@") ? C.textQuaternary : C.code)
        .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 18)
        .background(l.hasPrefix("+") ? C.success.opacity(0.12) : l.hasPrefix("-") ? C.danger.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if let n = r.newLine { composing = composing == n ? nil : n; draft = "" } }
        .help(r.newLine == nil ? "" : "クリックしてコメント")
    }

    private func thread(_ t: ReviewThread) -> some View {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(t.comments) { c in
          HStack(alignment: .top, spacing: 8) {
            Text(c.author.displayName).font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textTertiary)
            Text(c.body).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary)
          }
        }
        if t.state == .open {
          Button("解決する") { onResolve(t.id) }.buttonStyle(.plain).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
        } else {
          Text("解決済み").font(Typography.font(Typography.chrome)).foregroundStyle(C.success)
        }
      }
      .padding(8).frame(maxWidth: 520, alignment: .leading).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card))
      .opacity(t.state == .open ? 1 : 0.6).padding(.leading, 28).padding(.vertical, 4)
    }

    private func composer(_ n: Int) -> some View {
      HStack(spacing: 8) {
        TextField("コメント", text: $draft).textFieldStyle(.plain).font(Typography.font(Typography.chrome)).frame(width: 360)
          .onSubmit { onComment(n, draft); composing = nil }
        Button("追加") { onComment(n, draft); composing = nil }.buttonStyle(.plain).foregroundStyle(C.textSecondary)
        Button("キャンセル") { composing = nil }.buttonStyle(.plain).foregroundStyle(C.textTertiary)
      }
      .padding(8).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card)).padding(.leading, 28).padding(.vertical, 4)
    }
  }

  /// U06: notification history (facts only — bell / exit). Rows are read state + source + fixed wording.
  struct SessionList: View {
    let sessions: [AgentSession]
    let current: String
    let open: (AgentSession) -> Void

    private func label(_ s: AgentSession) -> (String, Color) {
      switch s.status {
      case .running: ("実行中", C.textTertiary)
      case .attention: ("入力待ち（ベル）", C.attention)
      case .exited(let c): (c == 0 ? "正常終了" : "異常終了 (exit \(c ?? -1))", C.textQuaternary)
      }
    }

    var body: some View {
      Text("エージェント").font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textTertiary)
        .padding(.horizontal, 20).frame(height: 26)
      if sessions.isEmpty {
        Text("起動中のエージェントはありません").font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textSecondary)
          .frame(maxWidth: .infinity).padding(16)
      }
      ForEach(sessions) { s in
        let (text, color) = label(s)
        Button { open(s) } label: {
          HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
              Text(s.title).font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textPrimary)
              Text("\(text) · \(s.project == current ? "" : s.project + " · ")\(s.cwd.split(separator: "/").last.map(String.init) ?? s.cwd)")
                .font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary).lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 20).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
    }
  }

  struct NoticeList: View {
    let log: NotificationLog
    /// `notice.mutePane` addresses panes of the active Project only.
    let current: String
    let agentTitle: (WorkbenchNotice) -> String?
    let run: (String, CommandInput) -> Void

    var body: some View {
      HStack(spacing: 12) {
        Text("通知").font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textTertiary)
        Spacer()
        Button("すべて既読") { run("notice.markRead", [:]) }.disabled(log.unread() == 0)
        Button("消去") { run("notice.clear", [:]) }.disabled(log.items.isEmpty)
      }
      .buttonStyle(.plain).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
      .padding(.horizontal, 20).frame(height: 26)
      if log.items.isEmpty {
        Text("通知はありません").font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textSecondary)
          .frame(maxWidth: .infinity).padding(16)
      }
      ForEach(log.items) { n in
        let key = NotificationLog.paneKey(n.project, n.pane)
        HStack(alignment: .top, spacing: 8) {
          Circle().fill(n.read ? .clear : dot(n)).frame(width: 6, height: 6).padding(.top, 6)
          VStack(alignment: .leading, spacing: 2) {
            Text([agentTitle(n), n.title].compactMap { $0 }.joined(separator: " · "))
              .font(Typography.font(Typography.chromeStrong)).foregroundStyle(n.read ? C.textTertiary : C.textPrimary)
            Text("\(n.project) · \(n.at.formatted(.relative(presentation: .named)))")
              .font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary)
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 4).contentShape(Rectangle())
        .contextMenu {
          if n.project == current {
            let muted = log.mutedPanes.contains(key)
            Button(muted ? "このターミナルのミュートを解除" : "このターミナルをミュート") {
              run("notice.mutePane", ["id": .int(n.pane), "muted": .bool(!muted)])
            }
          }
        }
      }
    }

    private func dot(_ n: WorkbenchNotice) -> Color { n.kind == .exited && n.exitCode != 0 ? C.danger : n.kind == .exited ? C.success : C.attention }
  }
#endif
