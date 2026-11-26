#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import ClairShared
  import ClairWorkspace
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line
  private typealias W = DesignTokens.Wash

  // The board screen (ADR-0031, #82): the TODO board, one agent per card.

  func statusLabel(_ s: AgentSession.Status) -> (String, Color) {
    switch s {
    case .running: (tr("実行中"), C.success)
    case .attention: (tr("入力待ち"), C.attention)
    case .blocked: (tr("承認・回答待ち"), C.attention)
    case .done: (tr("完了"), C.success)
    case .idle: (tr("待機中"), C.textMuted)
    case .exited(let c): (tr("終了 %@", c.map(String.init) ?? "?"), c == 0 ? C.textMuted : C.danger)
    }
  }

  /// Inline Markdown (bold, code, links) for a chat line; falls back to the raw text.
  func inline(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
  }

  func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
  }

  /// A Markdown block in chat (concierge and history): headings sized for a conversation, code as a card,
  /// images never loaded; everything else is the Markdown preview's own block view. `size` is the body size.
  struct ChatBlock: View {
    let block: MarkdownBlock
    let size: CGFloat

    var body: some View {
      switch block {
      case .heading(let level, let text):
        Text(inline(text)).font(.system(size: size * [1.33, 1.2, 1.07, 1, 1, 1][level - 1], weight: .semibold))
          .foregroundStyle(C.textPrimary).padding(.top, 6)
      case .code(let language, let text) where !(language.lowercased() == "mermaid" && MermaidDiagram.parse(text) != nil):
        CodeCard(language: language, text: text, size: size - 2)
      case .image(let alt, let source):
        // The chat has no Project file to resolve against, so images stay what they are.
        Label(alt.isEmpty ? source : alt, systemImage: "photo").font(.system(size: size - 2)).foregroundStyle(C.textMuted)
      default:
        MarkdownBlockView(block: block, root: "", path: "", scale: size / 13).lineSpacing(4)
      }
    }
  }

  private struct CodeCard: View {
    let language: String
    let text: String
    /// Code size; the header is chrome type.
    let size: CGFloat
    @State private var copied = false

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text(verbatim: language.isEmpty ? "code" : language).font(Typography.font(Typography.chrome, family: .mono)).foregroundStyle(C.textTertiary)
          Spacer(minLength: 0)
          Button {
            copyToPasteboard(text); copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
          } label: {
            Label(copied ? tr("コピーしました") : tr("コピー"), systemImage: copied ? "checkmark" : "doc.on.doc")
              .padding(.horizontal, 6).frame(height: 22)
          }.buttonStyle(.hoverWash).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: RowHeight.control).background(W.soft)
        Rectangle().fill(L.hairline).frame(height: 1)
        ScrollView(.horizontal, showsIndicators: false) {
          Text(verbatim: text).font(.system(size: size, design: .monospaced)).lineSpacing(3).foregroundStyle(C.code)
            .padding(.horizontal, 12).padding(.vertical, 12)
        }
      }
      .background(C.panel)
      .clipShape(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(L.hairline))
    }
  }

  /// A hairline box: the board's one surface (cards, chips, action buttons). Flat, no shadow, no tint.
  private struct Boxed: ViewModifier {
    var fill: Color = .clear
    var line: Color = L.strong
    var radius: CGFloat = Radius.card
    func body(content: Content) -> some View {
      content
        .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(line))
        .contentShape(Rectangle())
    }
  }

  /// The board's section and column heads: a small mono label and its count.
  private struct BoardHead: View {
    let title: String
    let count: Int
    var body: some View {
      HStack(spacing: 6) {
        Text(verbatim: title).font(Typography.font(Typography.sidebarMicro, family: .mono)).foregroundStyle(C.textTertiary)
        Text(verbatim: "\(count)").font(Typography.font(Typography.chrome, family: .mono)).foregroundStyle(C.textMuted)
      }
      .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
  }

  /// An agent pane with its title and the daemon session key that reads its screen.
  typealias BoardAgent = (session: AgentSession, title: String, key: String)

  /// Mounts a pane's surface once, out of sight, so its screen can be read before any Project showed the pane
  /// (a kept surface stays live off-window, and the tile only reads kept ones).
  // ponytail: the PTY takes this host's fixed size until the pane's own host resizes it; read the daemon journal into a headless VT to avoid that.
  private struct WarmSurface: NSViewRepresentable {
    let key: String
    let cwd: String
    final class Coordinator { weak var host: NSView? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ClairGhosttySurfaceView { ClairGhosttySurfaceView.borrow(key: key, cwd: cwd).view }
    func updateNSView(_ nsView: ClairGhosttySurfaceView, context: Context) { context.coordinator.host = nsView.superview }
    static func dismantleNSView(_ nsView: ClairGhosttySurfaceView, coordinator: Coordinator) {
      // A pane or the quick look may have taken the surface meanwhile; only our own host lets go of it.
      guard nsView.superview == nil || nsView.superview === coordinator.host else { return }
      nsView.removeFromSuperview()
    }
  }

  /// A card's window onto its agent: the last lines of the pane's screen, read once a second (no colour, read-only).
  /// A card without an agent shows the start of its TODO body.
  private struct CardScreen: View {
    let agent: BoardAgent?
    let path: String
    @State private var screen = ""
    @State private var head = ""
    @State private var warm = false

    var body: some View {
      let text = agent == nil ? head : screen
      Group {
        if !text.isEmpty || agent != nil {
          Text(verbatim: text).font(.system(size: 9, design: .monospaced)).foregroundStyle(C.textSecondary)
            .lineLimit(agent == nil ? 4 : Self.lines)
            .frame(maxWidth: .infinity, alignment: agent == nil ? .topLeading : .bottomLeading)
            .frame(height: agent == nil ? nil : 72, alignment: .bottomLeading)
            .padding(8).clipped()
            .modifier(Boxed(fill: W.soft, line: L.hairline, radius: Radius.control))
        }
      }
      .background {
        if warm, let agent {
          WarmSurface(key: agent.key, cwd: agent.session.cwd).frame(width: 720, height: 420).opacity(0).allowsHitTesting(false)
            .frame(width: 0, height: 0)
        }
      }
      .accessibilityLabel(text)
      .task(id: agent?.key) {
        guard let agent else { return }
        while !Task.isCancelled {
          let read = ClairGhosttySurfaceView.screenText(key: agent.key)
          screen = read.map(Self.tail) ?? ""
          warm = read == nil && ClairGhosttySurfaceView.canBorrow(key: agent.key)
          try? await Task.sleep(for: .seconds(1))
        }
      }
      .task(id: path) { if agent == nil { head = await Task.detached { Self.bodyStart(path) }.value } }
    }

    static let lines = 6
    /// The last `lines` rows of a screen read, trailing blanks dropped.
    static func tail(_ text: String) -> String {
      var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.replacing(/\s+$/, with: "") }
      while rows.last?.isEmpty == true { rows.removeLast() }
      return rows.suffix(lines).joined(separator: "\n")
    }

    /// The first lines of a TODO file after its front matter.
    nonisolated static func bodyStart(_ path: String) -> String {
      let rows = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
      var body = rows[...]
      if rows.first?.trimmingCharacters(in: .whitespaces) == "---",
         let end = rows.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) { body = rows[(end + 1)...] }
      return body.prefix(4).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  /// ⌥⌘Y / ⌥⌘N answer the Claude Code permission prompt of the oldest card waiting on you, from either screen;
  /// ⌘] selects the next waiting card on the board. Lives in the titlebar so both screens have it.
  /// What the first ⌥⌘Y shows before anything is sent: whose prompt it is and the end of its screen (the question itself).
  /// A second ⌥⌘Y answers it; untouched for 15 seconds, it goes away and the next ⌥⌘Y shows it again.
  struct AgentApprovalPreview: View {
    let title: String
    let project: String
    let screen: String
    let dismiss: () -> Void

    var body: some View {
      let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(12)
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Text(tr("入力待ち")).font(Typography.font(Typography.title)).foregroundStyle(C.attention)
          Text("\(project) · \(title)").font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).lineLimit(1)
          Spacer(minLength: 0)
          Button(action: dismiss) { Image(systemName: "xmark").font(Typography.font(Typography.chrome)) }
            .buttonStyle(.hoverWash).foregroundStyle(C.textMuted).accessibilityLabel(tr("閉じる"))
        }
        Text(lines.isEmpty ? tr("画面を読めませんでした。カードを開いて確認してください。") : lines.joined(separator: "\n"))
          .font(Typography.font(Typography.chrome, family: .mono)).foregroundStyle(C.textPrimary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(8)
          .background(C.canvas, in: RoundedRectangle(cornerRadius: Radius.card))
        Text(tr("もう一度 ⌥⌘Y で許可、⌥⌘N で拒否")).font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted)
      }
      .padding(12).frame(width: 420)
      .background(W.faint).background(C.canvas, in: RoundedRectangle(cornerRadius: Radius.card))
      .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(L.stronger))
      .task { try? await Task.sleep(for: .seconds(15)); dismiss() }
    }
  }

  struct BoardApprovalKeys: View {
    /// Paths of the cards whose agent is blocked.
    let blocked: [String]
    let onBoard: Bool
    @Binding var selected: String?
    let answer: (String, Bool) -> Void
    @State private var since: [String: Date] = [:]

    // ponytail: "oldest" is first-seen blocked on this screen's clock, not the agent's own report time.
    private var target: String? {
      if onBoard, let s = selected, blocked.contains(s) { return s }
      return blocked.min { (since[$0] ?? .distantFuture) < (since[$1] ?? .distantFuture) }
    }

    var body: some View {
      ZStack {
        Button("") { if let p = target { answer(p, true) } }.keyboardShortcut("y", modifiers: [.option, .command])
        Button("") { if let p = target { answer(p, false) } }.keyboardShortcut("n", modifiers: [.option, .command])
        Button("") {
          guard !blocked.isEmpty else { return }
          let at = selected.flatMap { blocked.firstIndex(of: $0) } ?? -1
          selected = blocked[(at + 1) % blocked.count]
        }.keyboardShortcut("]", modifiers: .command).disabled(!onBoard)
      }
      .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
      .onChange(of: blocked, initial: true) { _, now in
        since = Dictionary(uniqueKeysWithValues: now.map { ($0, since[$0] ?? Date()) })
      }
    }
  }

  /// #82: the board. One card is one agent; the columns are states (Inbox, 実行中, 判断待ち, 完了, 未完了) of every Project's
  /// cards, so nothing is dragged. A one-line request with a Project makes a card and starts its agent. Drawn flat: one
  /// ground, hairline boxes, mono heads, colour only on the status dots.
  struct TodoBoardView: View {
    let cards: [TodoBoardCard]
    /// Done cards past the display window; reached from the end of the 完了 column and by search.
    let archived: [TodoBoardCard]
    /// Agent panes on no card (started by hand in a Project).
    let others: [BoardAgent]
    let agent: (TodoBoardCard) -> BoardAgent?
    /// Project names, most recent first.
    let projects: [String]
    let run: (String, CommandInput) -> Result<CommandResult, CommandError>
    let confirm: (ClairDialog) -> Void
    let reload: () -> Void
    /// Makes a card from a one-line request in a Project (nil = Project なし); `start` also runs its agent.
    let request: (_ title: String, _ project: String?, _ start: Bool) -> Void
    let openAgent: (AgentSession) -> Void
    let openPane: (TodoBoardCard) -> Void
    let openFile: (String) -> Void
    @Binding var selected: String?
    /// The card an approval key just answered.
    let flash: String?
    @State private var waitingOnly = false
    @State private var project = ""
    @State private var query = ""
    @State private var pastOpen = false
    /// Columns the owner opened past the first `limit` cards.
    @State private var expanded: Set<String> = []
    private static let limit = 10
    @State private var draft = ""
    @FocusState private var draftFocused: Bool
    /// The request field's Project, kept across launches ("" = Project なし).
    @AppStorage("clair.boardRequestProject") private var requestProject = ""
    @State private var picking: TodoBoardCard?
    @State private var pickQuery = ""
    @FocusState private var pickFocused: Bool
    /// The agent pane in quick look, by session id, and whether its terminal can be shown (a live shell).
    @State private var peeked: String?
    @State private var peekLive = false
    /// A card just run: its quick look opens once its agent's pane shows up.
    @State private var peekWhenLive: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gap: CGFloat = 8
    private static let pad: CGFloat = 24
    private static let titles = ["inbox": "Inbox", "running": "実行中", "blocked": "判断待ち", "done": "完了", "failed": "未完了"]

    private func needsYou(_ c: TodoBoardCard) -> Bool { c.column == "blocked" || c.column == "failed" }

    private func visible(_ list: [TodoBoardCard]) -> [TodoBoardCard] {
      (query.isEmpty ? list : TodoBoardCard.search(list, query))
        .filter { (!waitingOnly || needsYou($0)) && (project.isEmpty || $0.project == project) }
    }

    private var agents: [BoardAgent] { cards.compactMap(agent) + others }

    var body: some View {
      let shown = visible(cards)
      let past = visible(archived)
      return VStack(alignment: .leading, spacing: 0) {
        header
        requestRow
        Rectangle().fill(L.hairline).frame(height: 1)
        GeometryReader { geo in
          // The columns share the width; below the minimum they scroll sideways instead of squeezing.
          let count = CGFloat(TodoBoardCard.columns.count + (others.isEmpty ? 0 : 1))
          let width = max(220, (geo.size.width - Self.pad * 2 - Self.gap * (count - 1)) / count)
          ScrollViewReader { proxy in
            ScrollView(.horizontal) {
              HStack(alignment: .top, spacing: Self.gap) {
                ForEach(TodoBoardCard.columns, id: \.self) { column($0, shown: shown, past: past, width: width) }
                if !others.isEmpty { othersColumn(width: width) }
              }
              .padding(.horizontal, Self.pad).padding(.vertical, 16).frame(height: geo.size.height, alignment: .top)
              // A card changing state slides in place instead of jumping.
              .animation(reduceMotion ? nil : .easeOut(duration: Motion.screenDuration),
                         value: (shown + past).map { "\($0.todo.path)\($0.state)" })
            }.clairScroller()
            .onChange(of: selected) { _, path in
              guard let path else { return }
              withAnimation(reduceMotion ? nil : .easeOut(duration: Motion.screenDuration)) { proxy.scrollTo(path) }
            }
          }
        }
      }
      // minWidth 0: the header's fixed chips must not floor the board's width; the columns already scroll sideways,
      // so the editor column can squeeze the board as far as the owner drags it. The header clips at its end.
      .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped().background(C.canvas)
      .overlay { quickLook }
      .overlay { projectPicker }
      // An exited agent leaves the list, and its quick look with it.
      .onChange(of: agents.map(\.session.id)) { _, ids in if let peeked, !ids.contains(peeked) { self.peeked = nil } }
      .onChange(of: cards) { _, now in
        guard let path = peekWhenLive, let a = now.first(where: { $0.todo.path == path }).flatMap(agent) else { return }
        peekWhenLive = nil; peek(a)
      }
    }

    // MARK: Header

    private var header: some View {
      let waiting = cards.filter(needsYou).count
      return HStack(spacing: 8) {
        Text(tr("ボード")).font(Typography.font(Typography.title)).foregroundStyle(C.textPrimary).fixedSize()
        Text(tr("%@ 件", cards.count)).font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted).fixedSize()
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted)
          TextField(tr("カードを検索"), text: $query).textFieldStyle(.plain)
            .font(Typography.font(Typography.chrome)).foregroundStyle(C.textPrimary)
            .accessibilityLabel(tr("カードを検索"))
        }
        .padding(.horizontal, 8).frame(minWidth: 80, maxWidth: 180).frame(height: RowHeight.default).modifier(Boxed())
        Button { waitingOnly.toggle() } label: {
          HStack(spacing: 6) {
            Circle().fill(waiting == 0 ? C.textMuted : C.attention).frame(width: 6, height: 6)
            Text(tr("あなた待ち"))
            Text(verbatim: "\(waiting)").font(Typography.font(Typography.chrome, family: .mono)).foregroundStyle(C.textMuted)
          }.modifier(Chip(on: waitingOnly))
        }
        .buttonStyle(HoverWashStyle(radius: Radius.card)).help(tr("あなた待ちだけ表示")).fixedSize()
        .accessibilityAddTraits(waitingOnly ? .isSelected : [])
        Menu {
          Picker(tr("Project"), selection: $project) {
            Text(tr("すべての Project")).tag("")
            ForEach(projects, id: \.self) { Text($0).tag($0) }
          }.pickerStyle(.inline).labelsHidden()
        } label: {
          HStack(spacing: 6) {
            Text(project.isEmpty ? tr("すべての Project") : project).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: Typography.chromeSize(9), weight: .semibold)).foregroundStyle(C.textMuted)
          }.modifier(Chip(on: !project.isEmpty))
        }
        .menuStyle(.button).buttonStyle(HoverWashStyle(radius: Radius.card)).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(tr("Project"))
      }
      .padding(.horizontal, Self.pad).frame(height: 52)
    }

    /// A header filter: a hairline chip, filled while it narrows the board.
    fileprivate struct Chip: ViewModifier {
      let on: Bool
      func body(content: Content) -> some View {
        content.font(Typography.font(Typography.chrome)).foregroundStyle(on ? C.textPrimary : C.textSecondary)
          .padding(.horizontal, 10).frame(height: RowHeight.default)
          .modifier(Boxed(fill: on ? W.strongest : .clear, line: on ? L.ring : L.strong))
      }
    }

    // MARK: Request

    /// Return makes the card and starts its agent in the chosen Project without switching to it; ⌘Return only files it
    /// in Inbox. The field empties and keeps the focus for the next request.
    private var requestRow: some View {
      let target = projects.contains(requestProject) ? requestProject : ""
      func submit(_ start: Bool) {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        request(t, target.isEmpty ? nil : target, start); draft = ""; draftFocused = true
      }
      return HStack(spacing: 8) {
        TextField(tr("依頼を1行で…"), text: $draft)
          .focused($draftFocused).textFieldStyle(.plain).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textPrimary)
          .padding(.horizontal, 12).frame(height: RowHeight.control)
          .modifier(Boxed(line: draftFocused ? L.ring : L.strong, radius: Radius.card))
          .onSubmit { submit(true) }
          .onExitCommand { draft = ""; draftFocused = false }
          .accessibilityLabel(tr("依頼"))
        Menu {
          Picker(tr("Project"), selection: $requestProject) {
            Text(tr("Project なし")).tag("")
            ForEach(projects, id: \.self) { Text($0).tag($0) }
          }.pickerStyle(.inline).labelsHidden()
        } label: {
          HStack(spacing: 6) {
            Text(target.isEmpty ? tr("Project なし") : target).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: Typography.chromeSize(9), weight: .semibold)).foregroundStyle(C.textMuted)
          }.modifier(Chip(on: false))
        }
        .menuStyle(.button).buttonStyle(HoverWashStyle(radius: Radius.card)).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(tr("依頼する Project"))
        Button { submit(true) } label: {
          HStack(spacing: 6) {
            Text(tr("依頼する"))
            Text(verbatim: "⏎").font(Typography.font(Typography.chrome, family: .mono)).foregroundStyle(C.textMuted)
          }.modifier(Chip(on: true))
        }
        .buttonStyle(HoverWashStyle(radius: Radius.card)).fixedSize().disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        // ⌘Return: file the request in Inbox without starting an agent.
        Button("") { submit(false) }.keyboardShortcut(.return, modifiers: .command).opacity(0).frame(width: 0, height: 0)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, Self.pad).padding(.bottom, 12)
    }

    // MARK: Columns

    private func column(_ name: String, shown: [TodoBoardCard], past: [TodoBoardCard], width: CGFloat) -> some View {
      let items = shown.filter { $0.column == name }
      return VStack(alignment: .leading, spacing: 8) {
        BoardHead(title: Self.titles[name].map { tr($0) } ?? name, count: items.count).frame(height: 22).padding(.leading, 6)
        ScrollView {
          VStack(spacing: 6) {
            ForEach(capped(items, name), id: \.todo.path) { card($0).transition(.opacity) }
            more(items.count, name)
            if name == "done", !past.isEmpty { pastSection(past) }
          }.padding(6).frame(maxWidth: .infinity)
        }.clairScroller()
        .frame(maxHeight: .infinity, alignment: .top)
        .background(W.soft, in: RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
      }
      .frame(width: width)
    }

    /// The first `limit` items unless the column is opened (a search shows everything it matched).
    private func capped<T>(_ items: [T], _ key: String) -> [T] {
      expanded.contains(key) || !query.isEmpty ? items : Array(items.prefix(Self.limit))
    }

    @ViewBuilder private func more(_ total: Int, _ key: String) -> some View {
      if total > Self.limit, !expanded.contains(key), query.isEmpty {
        Button { expanded.insert(key) } label: {
          Text(tr("さらに表示（残り %@ 件）", total - Self.limit)).frame(maxWidth: .infinity).frame(height: RowHeight.default).contentShape(Rectangle())
        }.buttonStyle(HoverWashStyle(radius: Radius.card)).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
      }
    }

    private func pastSection(_ past: [TodoBoardCard]) -> some View {
      VStack(spacing: 6) {
        Button { withAnimation(reduceMotion ? nil : .easeOut(duration: Motion.screenDuration)) { pastOpen.toggle() } } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right").font(.system(size: Typography.chromeSize(9), weight: .semibold))
              .rotationEffect(.degrees(pastOpen || !query.isEmpty ? 90 : 0))
            Text(tr("過去の完了 %@ 件", past.count))
            Spacer(minLength: 0)
          }.padding(.horizontal, 6).frame(height: RowHeight.default).contentShape(Rectangle())
        }.buttonStyle(.plain).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
        if pastOpen || !query.isEmpty {
          ForEach(past, id: \.todo.path) { card($0).transition(.opacity) }
        }
      }
    }

    // MARK: Cards

    private func state(_ c: TodoBoardCard) -> (String, Color)? {
      switch c.state {
      case .idle: nil
      case .running: (tr("実行中"), C.success)
      case .blocked: (c.asking > 0 ? tr("判断待ち") : tr("承認待ち"), C.attention)
      case .done: (tr("完了"), C.textMuted)
      case .failed, .unreported: (tr("未完了"), C.danger)
      }
    }

    private func openSheet(_ c: TodoBoardCard) { _ = run("ask.open", ["card": .string(c.todo.path)]) }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
      Button(action: run) {
        Text(title).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).lineLimit(1)
          .padding(.horizontal, 8).frame(height: RowHeight.compact).modifier(Boxed(radius: Radius.control))
      }.buttonStyle(HoverWashStyle(radius: Radius.control))
    }

    /// A finished card's three answers: done or not, why (`note`), and whether the owner has to decide something.
    private func result(_ c: TodoBoardCard) -> some View {
      let ok = c.state == .done
      let why = c.note.flatMap { $0.isEmpty ? nil : $0 } ?? (c.state == .unreported ? tr("報告せずに止まった") : nil)
      return Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 3) {
        GridRow {
          Text(tr("結果")).foregroundStyle(C.textTertiary)
          Text(ok ? tr("完了") : tr("未完了")).foregroundStyle(ok ? C.textSecondary : C.danger)
        }
        GridRow {
          Text(tr("理由")).foregroundStyle(C.textTertiary)
          Text(why ?? "—").foregroundStyle(why == nil ? C.textMuted : C.textSecondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        GridRow {
          Text(tr("判断")).foregroundStyle(C.textTertiary)
          Text(c.asking > 0 ? tr("要(%@ 問)", c.asking) : tr("不要")).foregroundStyle(c.asking > 0 ? C.attention : C.textMuted)
        }
      }
      .font(Typography.font(Typography.chrome)).frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8).padding(.vertical, 6).modifier(Boxed(fill: W.soft, line: L.hairline, radius: Radius.control))
      .accessibilityElement(children: .combine)
    }

    private func card(_ c: TodoBoardCard) -> some View {
      let a = agent(c)
      let label = state(c)
      let on = selected == c.todo.path
      return VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(c.todo.title).font(Typography.font(Typography.sidebar)).foregroundStyle(c.state == .done ? C.textTertiary : C.textPrimary)
            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          if let a {
            Button { openAgent(a.session) } label: {
              Image(systemName: "arrow.up.right").font(Typography.font(Typography.sidebarMicro)).foregroundStyle(C.textMuted).frame(width: 22, height: 22)
            }.buttonStyle(HoverWashStyle(radius: Radius.control)).help(tr("ターミナルを開く")).accessibilityLabel(tr("ターミナルを開く"))
          }
        }
        HStack(spacing: 6) {
          if let label { Circle().fill(label.1).frame(width: 6, height: 6); Text(label.0).foregroundStyle(label.1 == C.textMuted ? C.textTertiary : label.1) }
          if let p = c.project { Text(verbatim: label == nil ? p : "· \(p)").lineLimit(1) }
        }.font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
        switch c.column {
        case "done", "failed": result(c)
        case "inbox": CardScreen(agent: nil, path: c.todo.path)
        default: CardScreen(agent: a, path: c.todo.path)
        }
        // ADR-0030: the agent's questions wait here; the sheet opens in a floating panel.
        if c.asking > 0 { action(tr("判断する(%@ 問)", c.asking)) { openSheet(c) }.accessibilityLabel(tr("判断シートを開く")) }
        if c.state == .idle { action(tr("実行")) { runCard(c) }.accessibilityLabel(tr("agent を起動")) }
      }
      .padding(10).frame(maxWidth: .infinity, alignment: .leading)
      .modifier(Boxed(fill: on ? C.surfaceActive : C.canvas, line: on ? L.ring : L.strong))
      .overlay {
        // A card waiting on the owner wears the same attention ring as a flashed card.
        if flash == c.todo.path || c.state == .blocked {
          RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(C.attention, lineWidth: 2).transition(.opacity)
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration), value: flash == c.todo.path)
      .id(c.todo.path)
      .onTapGesture { open(c) }
      .contextMenu {
        Button(tr("TODO を開く")) { openFile(c.todo.path) }
        ForEach(c.artifacts, id: \.self) { path in Button((path as NSString).lastPathComponent) { openFile(path) } }
        if c.pane != nil { Button(tr("ペインを開く")) { openPane(c) } }
        if let pr = c.todo.pr, let url = URL(string: pr), url.scheme == "https" { Button(tr("PR を開く")) { NSWorkspace.shared.open(url) } }
        if a == nil { Button(c.state == .idle ? tr("実行") : tr("会話を再開")) { runCard(c) } }
      }
      .accessibilityElement(children: .contain)
      .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// A click opens the card's conversation: its sheet when it asks, its live terminal, or — once its agent's pane is
    /// gone — the agent again on the card's own conversation (`todo.run` resumes it). An Inbox card only selects.
    private func open(_ c: TodoBoardCard) {
      selected = c.todo.path
      if c.asking > 0 { return openSheet(c) }
      if let a = agent(c) { return peek(a) }
      if c.state != .idle { runCard(c) }
    }

    /// The right-edge column: live agents no card holds (started by hand), so every agent in Clair is on the board.
    private func othersColumn(width: CGFloat) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        BoardHead(title: tr("その他のエージェント"), count: others.count).frame(height: 22).padding(.leading, 6)
        ScrollView {
          VStack(spacing: 6) {
            ForEach(capped(others, "others"), id: \.session.id) { a in
              let (text, color) = statusLabel(a.session.status)
              HStack(alignment: .top, spacing: 0) {
                Button { peek(a) } label: {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(a.title).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textPrimary).lineLimit(2)
                    HStack(spacing: 6) {
                      Circle().fill(color).frame(width: 6, height: 6)
                      Text(verbatim: "\(text) · \(a.session.project)").lineLimit(1)
                    }.font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
                    CardScreen(agent: a, path: "")
                  }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
                }.buttonStyle(.plain).help(tr("クイックルック"))
                Button { openAgent(a.session) } label: {
                  Image(systemName: "arrow.up.right").font(Typography.font(Typography.sidebarMicro)).foregroundStyle(C.textMuted).frame(width: 22, height: 22)
                }.buttonStyle(HoverWashStyle(radius: Radius.control)).padding(6)
                  .help(tr("ターミナルを開く")).accessibilityLabel(tr("ターミナルを開く"))
              }.modifier(Boxed(fill: C.surfaceHover))
            }
            more(others.count, "others")
          }.padding(6)
        }.clairScroller()
        .frame(maxHeight: .infinity, alignment: .top)
        .background(W.soft, in: RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
      }
      .frame(width: width)
    }

    // MARK: Running

    /// `todo.run`: starts (or resumes) the card's one agent, then shows its terminal. A card without a Project asks for one.
    private func runCard(_ c: TodoBoardCard) {
      switch run("todo.run", ["path": .string(c.todo.path)]) {
      case .success:
        peekWhenLive = c.todo.path; reload()
      case .failure(let e) where e.message.contains("needsProject"):
        pickQuery = ""; picking = c
      case .failure(let e) where e.message.contains("agentOpen"):
        if let a = agent(c) { peek(a) }
      case .failure(let e):
        confirm(ClairDialog(title: tr("agent を起動できません"), message: e.message) { _ in })
      }
    }

    private func choose(_ name: String?) {
      guard let c = picking else { return }
      picking = nil
      if case .failure(let e) = run("todo.update", ["path": .string(c.todo.path), "project": .string(name ?? "none")]) {
        return confirm(ClairDialog(title: tr("Project を設定できません"), message: e.message) { _ in })
      }
      runCard(c)
    }

    /// The Project palette for a card that has none: "Project なし" first, then the Projects, most recent first.
    @ViewBuilder private var projectPicker: some View {
      if picking != nil {
        let rows: [(name: String?, title: String)] = [(nil, tr("Project なし"))]
          + projects.filter { pickQuery.isEmpty || $0.localizedCaseInsensitiveContains(pickQuery) }.map { ($0, $0) }
        ZStack {
          Color.black.opacity(0.32).contentShape(Rectangle()).onTapGesture { picking = nil }
          Button("") { picking = nil }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
          VStack(spacing: 0) {
            TextField(tr("Project を選ぶ"), text: $pickQuery).textFieldStyle(.plain).focused($pickFocused)
              .font(Typography.font(Typography.sidebar)).foregroundStyle(C.textPrimary)
              .onSubmit { choose(rows.first?.name) }
              .padding(.horizontal, 12).frame(height: RowHeight.control)
              .accessibilityLabel(tr("Project を選ぶ"))
            Rectangle().fill(L.hairline).frame(height: 1)
            ScrollView {
              VStack(spacing: 0) {
                ForEach(rows, id: \.title) { row in
                  Button { choose(row.name) } label: {
                    Text(verbatim: row.title).font(Typography.font(Typography.sidebar))
                      .foregroundStyle(row.name == nil ? C.textTertiary : C.textPrimary)
                      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                      .frame(height: RowHeight.default).contentShape(Rectangle())
                  }.buttonStyle(HoverWashStyle(radius: Radius.control))
                }
              }.padding(4)
            }
          }
          .frame(width: 360).frame(maxHeight: 360)
          .background(C.canvas)
          .clipShape(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(L.strong))
          .overlayShadow()
        }
        .task { pickFocused = true }
        .transition(.asymmetric(insertion: reduceMotion ? .identity : .opacity.combined(with: .scale(scale: Motion.overlayOpenScale)), removal: .identity))
      }
    }

    // MARK: Quick look

    private func peek(_ a: BoardAgent) {
      peekLive = ClairGhosttySurfaceView.canBorrow(key: a.key)
      withAnimation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration)) { peeked = a.session.id }
    }

    /// A pane's live terminal over the board: type to the agent or answer its prompt without leaving the concierge.
    /// Opens like every overlay (0.97 → 1, overlay duration); closing is not animated.
    @ViewBuilder private var quickLook: some View {
      if let a = agents.first(where: { $0.session.id == peeked }) {
        let (text, color) = statusLabel(a.session.status)
        ZStack {
          Color.black.opacity(0.32).contentShape(Rectangle()).onTapGesture { peeked = nil }
          VStack(spacing: 0) {
            HStack(spacing: 10) {
              Circle().fill(color).frame(width: 7, height: 7)
              Text(a.title).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textPrimary).lineLimit(1)
              Text(verbatim: "\(text) · \(a.session.project)").font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).lineLimit(1)
              Spacer(minLength: 0)
              Button { peeked = nil; openAgent(a.session) } label: {
                Label(tr("ターミナルを開く"), systemImage: "arrow.up.right").padding(.horizontal, 8).frame(height: RowHeight.compact)
              }.buttonStyle(HoverWashStyle(radius: Radius.control)).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary)
              Button { peeked = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24)
              }.buttonStyle(HoverWashStyle(radius: Radius.control)).foregroundStyle(C.textTertiary)
                .help(tr("閉じる")).accessibilityLabel(tr("閉じる"))
            }
            .padding(.horizontal, 12).frame(height: 40)
            Rectangle().fill(L.hairline).frame(height: 1)
            if peekLive {
              BorrowedGhosttySurface(key: a.key, cwd: a.session.cwd).id(a.key)
            } else {
              Text(tr("このペインのターミナルはもう動いていません")).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
          .background(C.canvas)
          .clipShape(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(L.strong))
          .overlayShadow()
          .padding(Self.pad)
        }
        .transition(.asymmetric(insertion: reduceMotion ? .identity : .opacity.combined(with: .scale(scale: Motion.overlayOpenScale)), removal: .identity))
      }
    }
  }
#endif
