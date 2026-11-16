#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import ClairShared
  import ClairWorkspace
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line
  private typealias W = DesignTokens.Wash

  // The concierge is read like a conversation, not scanned like chrome: one step above the chrome scale.
  private let chatFont = Font.system(size: 15)  // Tokens: title step (15)

  // ADR-0020: the concierge's own screen: its chat beside every Project's agent panes and the board.

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

  /// The first line of a launch prompt, as a pane's title on the concierge screen.
  func conciergeShortTitle(_ prompt: String) -> String {
    String(prompt.split(whereSeparator: \.isNewline).first ?? "").prefix(40).description
  }

  /// The concierge transcript as chat, over the panes (they stay mounted, so the PTY keeps running).
  /// Canvas: `Concierge` (conversation) and `Concierge — 空の状態` (no transcript yet).
  struct ConciergeChatView: View {
    let session: String?
    /// The concierge's daemon shell and launch. Its surface lives here, out of sight, and surfaces only while it is blocked.
    let terminal: (key: String, pane: Int, launch: AgentLaunch)?
    private var pane: Int? { terminal?.pane }
    /// The concierge terminal's own state: `.blocked` is a prompt only the raw terminal can answer,
    /// and a finished turn (`done` / `idle` / `attention`) ends the working indicator.
    let status: AgentSession.Status?
    /// Starts the concierge with `message` as its first request (the one undecided thing is decided on send).
    let start: (String) -> Void
    /// Text put into the composer from outside (a board card's "コンシェルジュに頼む"); cleared once taken.
    @Binding var ask: String?
    /// A request typed into a running concierge (resets its per-request launch cap).
    let onSent: () -> Void
    /// nil until the transcript has been read once, so the empty state never flashes over a loading chat.
    @State private var messages: [AgentHistory.Message]?
    /// Kept across leaving and reopening the chat (the view is rebuilt each time).
    @SceneStorage("concierge.draft") private var draft = ""
    /// Shown until the transcript catches up with what was just sent.
    @State private var pending: String?
    /// The first request of a new chat has not reached the transcript a few seconds after sending: Claude Code is
    /// stuck before its hooks run (folder trust dialog, login, a startup error), so its terminal must be seen.
    @State private var stalled = false
    @FocusState private var focused: Bool
    @State private var dropTarget = false
    /// The conversation's API-equivalent cost and latest model, and its context size / window (`agent.list`'s numbers).
    @State private var chat: (cost: Double?, model: String?) = (nil, nil)
    @State private var context: (tokens: Int?, limit: Int?) = (nil, nil)
    /// Files under the concierge's folder for `@` completion, scanned on the first `@`.
    @State private var files: [WorkbenchFile]?
    @State private var mentionIndex = 0
    @State private var pasteMonitor: Any?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let column: CGFloat = 760
    /// Each chat's last transcript read and unanswered request, by session: the view is rebuilt on every tab switch
    /// and every return to the screen, and starting blank (or dropping what was just sent) read as a lost conversation.
    // ponytail: process-lifetime caches, never pruned; a closed chat's entry lingers until quit.
    @MainActor private static var read: [String: [AgentHistory.Message]] = [:]
    @MainActor private static var sent: [String: String] = [:]

    init(session: String?, terminal: (key: String, pane: Int, launch: AgentLaunch)?, status: AgentSession.Status?,
         start: @escaping (String) -> Void, ask: Binding<String?>, onSent: @escaping () -> Void = {}) {
      self.session = session; self.terminal = terminal; self.status = status; self.start = start; _ask = ask; self.onSent = onSent
      _messages = State(initialValue: session.flatMap { Self.read[$0] })
      _pending = State(initialValue: session.flatMap { Self.sent[$0] })
    }

    /// Whether `chat` has a request sent but not yet in its transcript (the shell keeps such a new chat's tab).
    static func isSending(_ chat: String) -> Bool { sent[chat] != nil }
    /// The start was refused (approval denied): forget the request; the shell puts it back through `ask`.
    static func unsend(_ chat: String) { sent[chat] = nil }

    /// The terminal must be answered: a permission or question, or a new chat stuck before its hooks run.
    private var blocked: Bool { terminal != nil && (status == .blocked || stalled) }

    var body: some View {
      Group {
        if messages?.isEmpty == true && pending == nil {
          emptyState
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
              let all = messages ?? []
              ForEach(Array(all.enumerated()), id: \.element.id) { i, m in
                let header = i == 0 || all[i - 1].role == "user"
                if m.role != "tool" {
                  row(m, header: header).transition(appear)
                } else if i == 0 || all[i - 1].role != "tool" {
                  // A run of tool calls folds into one row, drawn at its first call.
                  ToolGroup(lines: all[i...].prefix { $0.role == "tool" }.map(\.text), date: m.date, header: header)
                    .padding(.top, header ? 0 : -10).transition(appear)
                }
              }
              if let pending { userBubble(pending).opacity(0.6).transition(appear) }
              if blocked {
                blockedRow.transition(appear)
                // Room to scroll the latest turn above the terminal docked over the composer.
                Color.clear.frame(height: Self.terminalHeight - 100)
              } else if working {
                WorkingRow().transition(appear)
              }
            }
            .padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 8)
            .frame(maxWidth: Self.column).frame(maxWidth: .infinity)
          }.defaultScrollAnchor(.bottom).clairScroller()
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        composer
          .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
          .frame(maxWidth: Self.column).frame(maxWidth: .infinity)
          // The conversation scrolls under the composer and fades out above it.
          .background(LinearGradient(stops: [.init(color: C.canvas.opacity(0), location: 0), .init(color: C.canvas, location: 0.3)],
                                     startPoint: .top, endPoint: .bottom))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity).background(C.canvas)
      .overlay { hiddenTerminal }
      .task(id: session) { await follow() }
      .task(id: pending) {
        stalled = false
        guard pending != nil, messages?.contains(where: { $0.role == "user" }) != true else { return }
        try? await Task.sleep(for: .seconds(5))
        if !Task.isCancelled, pending != nil, messages?.contains(where: { $0.role == "user" }) != true { stalled = true }
      }
      .onChange(of: pending) { _, text in if let session { Self.sent[session] = text } }
      // The keyboard goes where the answer is: the terminal while it waits, the composer once it is done.
      .onChange(of: blocked) { _, now in focused = !now }
      .animation(reduceMotion ? nil : .easeOut(duration: Motion.screenDuration), value: blocked)
      .onChange(of: ask, initial: true) { _, text in
        guard let text else { return }
        // A refused start hands its request back: it was never sent.
        if pending.map({ text.hasPrefix($0) }) == true { pending = nil }
        draft = text; focused = true; ask = nil
      }
    }

    /// The concierge's raw terminal: mounted (so the composer can type into it) but invisible, except while it waits
    /// on a permission or question only the terminal can answer. It then docks over the composer with the keyboard,
    /// leaving the conversation readable above it. Always this size, so showing it never resizes the PTY.
    @ViewBuilder private var hiddenTerminal: some View {
      if let terminal {
        ClairGhosttySurface(launch: (terminal.launch.command, terminal.launch.cwd), pane: terminal.pane, sessionKey: terminal.key, focused: blocked)
          .id(terminal.key)
          .clipShape(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(blocked ? L.ring : L.strong))
          .overlayShadow()
          .frame(height: Self.terminalHeight)
          .padding(.horizontal, 24).padding(.bottom, 16)
          .frame(maxHeight: .infinity, alignment: .bottom)
          .opacity(blocked ? 1 : 0).offset(y: blocked || reduceMotion ? 0 : 12)
          .allowsHitTesting(blocked).accessibilityHidden(!blocked)
      }
    }

    private static let terminalHeight: CGFloat = 380

    /// Waiting on a reply: something was just sent, or the current turn (since the last user line) has not reported finishing.
    /// Narration mid-turn ("let me look…") is not the end of the turn, so it must not drop the spinner or Esc.
    private var working: Bool {
      if pending != nil { return true }
      guard pane != nil, let last = messages?.last(where: { $0.role == "user" }), !last.text.hasPrefix(Self.interrupted) else { return false }
      // The hook reports the turn finished before the transcript poll shows the reply, so keep spinning until a reply is the
      // last line. ponytail: a turn that ends on a tool line spins until the next send; add a timeout if that shows up.
      return status == .running || messages?.last?.role != "assistant"
    }

    /// What Claude Code writes to the transcript as a user turn when Esc stops it.
    private static let interrupted = "[Request interrupted by user"

    private var appear: AnyTransition {
      reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8))
    }

    @ViewBuilder private func row(_ m: AgentHistory.Message, header: Bool) -> some View {
      if m.role != "user" {
        Reply(message: m, header: header).equatable().padding(.top, header ? 0 : -10)
      } else if m.text.hasPrefix(Self.interrupted) {
        Label(tr("中断しました"), systemImage: "stop.circle")
          .font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 10).padding(.vertical, 4).background(W.medium, in: Capsule())
          .frame(maxWidth: .infinity)
      } else if m.text.hasPrefix("[Skill loaded") {
        Label(String(m.text.dropFirst().dropLast()).replacing("Skill loaded", with: tr("スキル読込")), systemImage: "wand.and.stars")
          .font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 10).padding(.vertical, 4).background(W.medium, in: Capsule())
          .frame(maxWidth: .infinity)
      } else {
        userBubble(m.text)
      }
    }

    private func userBubble(_ body: String) -> some View {
      HStack {
        Spacer(minLength: 120)
        Text(inline(body)).font(chatFont).lineSpacing(3).foregroundStyle(C.textPrimary).textSelection(.enabled)
          .padding(.horizontal, 16).padding(.vertical, 10)
          .background(C.surfaceActive, in: RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
      }
    }

    /// The concierge waits on a permission or question in its raw terminal; the chat cannot answer it.
    private var blockedRow: some View {
      HStack(spacing: 10) {
        ConciergeAvatar()
        Circle().fill(C.attention).frame(width: 6, height: 6)
        Text(tr("下のターミナルで答えてください")).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textSecondary)
      }
    }

    /// Built on the Tokens EMPTY STATE vocabulary: glyph, title, one line, then starters that only fill the composer.
    private var emptyState: some View {
      VStack(spacing: 12) {
        Image(systemName: "brain.head.profile").font(.system(size: 26)).foregroundStyle(C.textSecondary)
          .frame(width: 56, height: 56)
          .background(W.raised, in: RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(L.strong.opacity(0.6)))
        Text(tr("何をお任せしますか?")).font(Typography.font(Typography.title)).foregroundStyle(C.textPrimary).padding(.top, 6)
        Text(tr("依頼を子エージェントに割り振り、進み具合をここにまとめます。")).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textTertiary)
          .multilineTextAlignment(.center)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
          ForEach(Self.starters, id: \.text) { s in
            Button { draft = tr(s.text); focused = true } label: {
              HStack(spacing: 10) {
                Image(systemName: s.icon).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).frame(width: 16)
                Text(tr(s.text)).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 12).frame(height: RowHeight.control)
              .background(W.faint, in: RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
              .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(L.hairline))
              .contentShape(Rectangle())
            }.buttonStyle(HoverWashStyle(radius: Radius.overlay))
          }
        }.frame(maxWidth: 560).padding(.top, 16)
      }
      .padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Claude Code's aliases, then every model id it has run (`~/.claude/stats-cache.json` → `modelUsage`), newest first.
    /// ponytail: the CLI can't list models; a model never run yet is reached by its alias until Claude Code can.
    static func models(statsCache: URL = URL.homeDirectory.appending(path: ".claude/stats-cache.json")) -> [String] {
      let used = (try? Data(contentsOf: statsCache))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["modelUsage"] as? [String: Any]
      let ids = (used?.keys.filter { $0.hasPrefix("claude-") } ?? []).sorted { $0.localizedStandardCompare($1) == .orderedDescending }
      return ["default", "opus", "opus[1m]", "sonnet", "sonnet[1m]", "haiku"] + ids
    }
    private static let efforts = ["low", "medium", "high", "xhigh", "max"]

    private static let starters: [(icon: String, text: String)] = [
      ("checkmark.seal", "未コミットの変更をレビューして"), ("testtube.2", "テストを実行して、失敗を直して"),
      ("map", "この Project の構成を説明して"), ("checklist", "看板のカードを片付けて"),
    ]

    private var composer: some View {
      let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      return VStack(alignment: .leading, spacing: 12) {
        TextField("", text: $draft, prompt: Text(tr("コンシェルジュに頼む…")).foregroundStyle(C.textMuted), axis: .vertical)
          .textFieldStyle(.plain).lineLimit(1...10).font(chatFont)
          .focused($focused)
          .onSubmit(send)
          // Esc / ⌃C stop the running turn. The PTY gets Escape, never ⌃C: twice on an idle Claude Code quits it.
          .onKeyPress(.escape) { mentionHits.isEmpty ? interrupt() : { draft += " "; return .handled }() }  // a space ends the `@` word, closing the list
          .onKeyPress(keys: ["c"]) { $0.modifiers == .control ? interrupt() : .ignored }
          // `@` completion: ↑↓ moves, ⏎ / ⇥ inserts the highlighted path.
          .onKeyPress(keys: [.upArrow, .downArrow, .return, .tab]) { key in
            if Self.composing { return .ignored }  // the IME owns ⏎ / ↑↓ while converting
            if key.key == .return, key.modifiers.contains(.shift) {
              (NSApp.keyWindow?.firstResponder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
              return .handled
            }
            let hits = mentionHits
            guard !hits.isEmpty else { return .ignored }
            switch key.key {
            case .upArrow: mentionIndex = max(mentionIndex - 1, 0)
            case .downArrow: mentionIndex = min(mentionIndex + 1, hits.count - 1)
            default: insertMention(hits[min(mentionIndex, hits.count - 1)].path)
            }
            return .handled
          }
          .onChange(of: mention) { mentionIndex = 0; if mention != nil, files == nil { loadFiles() } }
          .onAppear(perform: watchPaste).onDisappear(perform: unwatchPaste)
        HStack(spacing: 8) {
          HStack(spacing: 6) {
            Circle().fill(pane == nil ? C.textMuted : C.success).frame(width: 6, height: 6)
            Text(verbatim: "Claude Code")
          }
          .font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 8).frame(height: RowHeight.default).background(W.medium, in: Capsule())
          // Switches the running concierge's model with Claude Code's own `/model <alias>`.
          if let pane {
            Menu {
              ForEach(Self.models(), id: \.self) { m in Button(m) { command("/model \(m)", pane) } }
            } label: {
              Text(chat.model.map(Self.shortModel) ?? tr("モデル")).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
            }.menuStyle(.borderlessButton).fixedSize().help(tr("コンシェルジュのモデルを切り替え"))
            // Claude Code's own `/effort <level>`; the transcript doesn't record the level, so the label stays generic.
            Menu {
              ForEach(Self.efforts, id: \.self) { e in Button(e) { command("/effort \(e)", pane) } }
            } label: {
              Text(tr("エフォート")).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
            }.menuStyle(.borderlessButton).fixedSize().help(tr("コンシェルジュのエフォートを切り替え"))
            Menu {
              Button(tr("圧縮 (/compact)")) { command("/compact", pane) }
            } label: {
              contextLabel
            }.menuStyle(.borderlessButton).fixedSize().help(tr("コンテキスト"))
          }
          Spacer(minLength: 0)
          if let cost = chat.cost {
            Text(cost, format: .currency(code: "USD").precision(.fractionLength(2))).font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted)
              .help(tr("この会話の API 換算の推定額"))
          }
          Text(pane == nil ? tr("⏎ 送信 · 最初の送信で起動") : working ? tr("⏎ 送信 · esc 中断") : tr("⏎ 送信")).font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted)
          Button(action: send) {
            Image(systemName: "arrow.up").font(Typography.font(Typography.title)).foregroundStyle(empty ? C.textMuted : C.canvas)
              .frame(width: RowHeight.control, height: RowHeight.control).background(empty ? W.strongest : C.textPrimary, in: Circle())
          }
          .buttonStyle(.plain).disabled(empty).help(tr("送信")).accessibilityLabel(tr("送信"))
          .animation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration), value: empty)
        }
      }
      .padding(.leading, 16).padding(.trailing, 12).padding(.top, 12).padding(.bottom, 10)
      .background(C.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(focused || dropTarget ? L.ring : L.strong))
      // Dropped files go in as paths, escaped like a Terminal drop: Claude Code attaches an image path as an image
      // and reads any other file (PDF, text) itself, so the chat stays plain text.
      // ponytail: file drops only; a pasted clipboard image would need a temp PNG, add if asked.
      .dropDestination(for: URL.self) { urls, _ in
        // A TODO card goes in as `TODO「<title>」(<path>)`: the path is its unique id (todo.update takes it),
        // the title tells the concierge which one we mean.
        let todoDir = ClairTodo.dir().standardizedFileURL.path + "/"
        let paths = urls.filter(\.isFileURL).map { url -> String in
          let path = url.standardizedFileURL.path
          if path.hasPrefix(todoDir), path.hasSuffix(".md"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
            return tr("TODO「%@」(%@)", ClairTodo.parse(path: path, text: text).title, path)
          }
          return path.replacing(" ", with: "\\ ")
        }
        guard !paths.isEmpty else { return false }
        draft += (draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " ") + paths.joined(separator: " ") + " "
        focused = true
        return true
      } isTargeted: { dropTarget = $0 }
      .overlayShadow()
      .contentShape(RoundedRectangle(cornerRadius: Radius.overlay))
      .onTapGesture { focused = true }  // the whole card is the input, not just the text line
      .overlay(alignment: .topLeading) { mentionPopover }
      .animation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration), value: focused)
    }

    /// "42k / 200k" beside a ring filled to the share used (warning ink from 80 %); "コンテキスト" while unknown.
    @ViewBuilder private var contextLabel: some View {
      if let tokens = context.tokens {
        let share = context.limit.map { min(Double(tokens) / Double(max($0, 1)), 1) }
        HStack(spacing: 6) {
          if let share {
            ZStack {
              Circle().stroke(W.strongest, lineWidth: 1.6)
              Circle().trim(from: 0, to: share).stroke(share >= 0.8 ? C.attention : C.textTertiary, lineWidth: 1.6).rotationEffect(.degrees(-90))
            }.frame(width: 10, height: 10)
          }
          Text(verbatim: ([tokens] + (context.limit.map { [$0] } ?? [])).map(Self.kilo).joined(separator: " / "))
        }
        .font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
        .accessibilityLabel(tr("コンテキスト") + " " + (share.map { "\(Int($0 * 100))%" } ?? Self.kilo(tokens)))
      } else {
        Text(tr("コンテキスト")).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
      }
    }

    static func kilo(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }
    /// `claude-opus-4-5-20251101` → `opus-4-5`.
    static func shortModel(_ m: String) -> String {
      m.replacing(/^claude-/, with: "").replacing(/-\d{8}$/, with: "")
    }

    /// A Claude Code slash command typed into the concierge, then a real Return.
    private func command(_ text: String, _ pane: Int) {
      guard ClairGhosttySurfaceView.send(text, toPane: pane) else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ClairGhosttySurfaceView.pressReturn(inPane: pane) }
    }

    /// The `@word` being typed at the end of the draft, or nil.
    private var mention: String? {
      draft.firstMatch(of: /(?:^|\s)@([^\s@]*)$/).map { String($0.1) }
    }

    private var mentionHits: [WorkbenchFile] {
      guard let mention, let files else { return [] }
      return QuickOpen.rank(mention, files, limit: 8)
    }

    @ViewBuilder private var mentionPopover: some View {
      let hits = mentionHits
      if !hits.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(hits.enumerated()), id: \.element.path) { i, f in
            Button { insertMention(f.path) } label: { MentionRow(path: f.path, selected: i == mentionIndex) }.buttonStyle(.plain)
          }
        }
        .padding(4).frame(width: 360)
        .background(C.surfaceHover, in: RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(L.strong))
        .overlayShadow()
        .alignmentGuide(.top) { $0[.bottom] + 8 }
      }
    }

    private func insertMention(_ path: String) {
      guard let range = draft.firstRange(of: /@[^\s@]*$/) else { return }
      draft.replaceSubrange(range, with: "@" + path.replacing(" ", with: "\\ ") + " ")
    }

    private func loadFiles() {
      let root = terminal?.launch.cwd ?? ""
      guard !root.isEmpty else { files = []; return }
      Task { files = await Task.detached { WorkbenchFiles.scan(root).filter { $0.status != "D" && $0.status != "!" } }.value }
    }

    /// ⌘V with an image (a screenshot) or copied Finder files on the pasteboard: the text field would paste nothing
    /// or only a name, so the image is saved as a temporary PNG and the paths go into the draft instead.
    private func watchPaste() {
      guard pasteMonitor == nil else { return }
      pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard focused, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "v", let paths = Self.pastedPaths() else { return event }
        draft += (draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " ") + paths.joined(separator: " ") + " "
        return nil
      }
    }

    private func unwatchPaste() {
      if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
      pasteMonitor = nil
    }

    // ponytail: pasted images pile up in the temp folder until macOS cleans it; prune them if that ever matters.
    static func pastedPaths(_ pb: NSPasteboard = .general) -> [String]? {
      if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
        return urls.map { $0.path.replacing(" ", with: "\\ ") }
      }
      guard pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
      let dir = FileManager.default.temporaryDirectory.appending(path: "clair-concierge")
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let file = dir.appending(path: "paste-\(UUID().uuidString.prefix(8)).png")
      guard (try? png.write(to: file)) != nil else { return nil }
      return [file.path]
    }

    /// Types the text into the concierge PTY, then a real Return key press so the TUI reads it as a submit, not a pasted newline.
    private func send() {
      // ⏎ that commits an IME conversion is not a submit: `draft` lacks the uncommitted text (a trailing 「？」 was lost).
      guard !Self.composing else { return }
      let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      guard let pane else { draft = ""; show(text); return start(text) }
      guard ClairGhosttySurfaceView.send(text, toPane: pane) else { return }
      onSent()
      draft = ""; show(text)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ClairGhosttySurfaceView.pressReturn(inPane: pane) }
    }

    /// The focused field editor holds uncommitted IME text.
    private static var composing: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false }

    private func interrupt() -> KeyPress.Result {
      guard working, let pane, ClairGhosttySurfaceView.pressEscape(inPane: pane) else { return .ignored }
      pending = nil
      return .handled
    }

    private func show(_ text: String) {
      withAnimation(reduceMotion ? nil : .easeOut(duration: Motion.screenDuration)) { pending = text }
    }

    /// Re-reads the transcript whenever the session file changes.
    // ponytail: 1 s mtime poll; a DispatchSource file watch if the latency shows.
    private func follow() async {
      guard let session else { messages = []; return }
      var seen: Date?
      while !Task.isCancelled {
        if let file = Concierge.transcriptFile(session: session) {
          let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
          if modified != seen {
            seen = modified
            let cwd = terminal?.launch.cwd ?? ""
            let (chat, read, context) = await Task.detached {
              let h = AgentHistoryReader.chat(file: file)
              let read = (h?.messages ?? []).filter { $0.role != "thinking" }
              return ((h?.estimatedUSD, h?.model), read, AgentContext.claude(session: session, cwd: cwd))
            }.value
            self.chat = chat; self.context = context
            Self.read[session] = read
            // A rewrite with no new turn (Claude Code touches the file often) must not re-lay out the whole chat.
            // The first read lands as is; later ones slide new turns in.
            if read != messages { withAnimation(messages == nil || reduceMotion ? nil : .easeOut(duration: Motion.screenDuration)) {
              messages = read
              if read.last?.role == "user" || read.contains(where: { $0.role == "user" && $0.text == pending }) { pending = nil }
            } }
          }
        } else if messages == nil { messages = [] }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  /// The concierge's chats as a vertical list at the screen's left edge. Folded to a thin rail (list toggle, ＋) and
  /// opened only to switch: picking a chat folds it again.
  struct ConciergeTabs: View {
    /// Each chat by its session id, with its terminal's state while it runs.
    let chats: [(id: String, status: AgentSession.Status?)]
    /// Closed chats, oldest first: picking one shows it, and sending resumes it.
    let history: [String]
    let selected: String
    let select: (String) -> Void
    let close: (String) -> Void
    let new: () -> Void
    @State private var titles: [String: String] = [:]
    @State private var open = false

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          railButton(open ? "sidebar.left" : "list.bullet", tr("会話の一覧")) { withAnimation(.easeOut(duration: Motion.screenDuration)) { open.toggle() } }
          if open { Spacer() }
          if open { railButton("plus", tr("新しい会話")) { new(); open = false } }
        }.frame(height: 52)
        if open {
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(chats.reversed(), id: \.id) { tab($0.id, $0.status) }
              if !history.isEmpty {
                Text(tr("履歴")).font(.system(size: 11, weight: .semibold)).foregroundStyle(C.textTertiary).padding(.top, 10).padding(.leading, 6)
                ForEach(history.reversed(), id: \.self) { tab($0, nil, closable: false) }
              }
            }
          }
        } else {
          railButton("plus", tr("新しい会話"), action: new)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 7).frame(width: open ? 240 : 40, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
      // A chat's title is its first request, so it is read once its transcript exists and never changes.
      .task(id: chats.map(\.id) + history) {
        while !Task.isCancelled {
          let missing = (chats.map(\.id) + history).filter { titles[$0] == nil }
          let found = await Task.detached {
            missing.compactMap { id in
              Concierge.transcriptFile(session: id).flatMap { AgentHistoryReader.chat(file: $0)?.title }.map { (id, $0) }
            }
          }.value
          for (id, title) in found { titles[id] = conciergeShortTitle(title) }
          try? await Task.sleep(for: .seconds(3))
        }
      }
    }

    private func railButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Image(systemName: icon).font(.system(size: 12)).foregroundStyle(C.textSecondary).frame(width: 26, height: 26)
      }.buttonStyle(HoverWashStyle(radius: Radius.card)).help(label).accessibilityLabel(label)
    }

    private func tab(_ id: String, _ status: AgentSession.Status?, closable: Bool = true) -> some View {
      let on = id == selected
      return HStack(spacing: 6) {
        Button { select(id); withAnimation(.easeOut(duration: Motion.screenDuration)) { open = false } } label: {
          HStack(spacing: 6) {
            Circle().fill(status.map { statusLabel($0).1 } ?? C.textMuted).frame(width: 6, height: 6)
            Text(titles[id] ?? tr("新しい会話")).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
          }.contentShape(Rectangle())
        }.buttonStyle(.plain)
        if on && closable && chats.count > 1 {
          Button { close(id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(C.textTertiary) }
            .buttonStyle(.plain).help(tr("会話を閉じる")).accessibilityLabel(tr("会話を閉じる"))
        }
      }
      .modifier(TodoBoardView.Chip(on: on))
      .accessibilityAddTraits(on ? .isSelected : [])
    }
  }

  /// Inline Markdown (bold, code, links) for a chat line; falls back to the raw text.
  func inline(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
  }

  func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
  }

  /// The concierge's mark: its activity-bar glyph on a raised tile.
  private struct ConciergeAvatar: View {
    var body: some View {
      Image(systemName: "brain.head.profile").font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary)
        .frame(width: 24, height: 24)
        .background(W.strong, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(L.strong.opacity(0.6)))
    }
  }

  /// The reply is pending: a comet orbits the avatar (still under Reduce Motion); the label stays still.
  private struct WorkingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
        let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
        HStack(spacing: 10) {
          ConciergeAvatar().overlay {
            RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous)
              .strokeBorder(AngularGradient(colors: [C.textSecondary.opacity(0), C.textSecondary], center: .center,
                                            angle: .degrees(t * 300)), lineWidth: 1.5)
              .padding(-4)
          }
          Text(tr("考えています…")).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textTertiary)
        }
      }
      .accessibilityElement(children: .combine)
    }
  }

  private struct MentionRow: View {
    let path: String
    let selected: Bool
    var body: some View {
      let name = (path as NSString).lastPathComponent
      let dir = (path as NSString).deletingLastPathComponent
      HStack(spacing: 8) {
        Text(verbatim: name).font(Typography.font(Typography.chrome, family: .mono)).foregroundStyle(selected ? C.textPrimary : C.textSecondary)
        Text(verbatim: dir).font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted).lineLimit(1).truncationMode(.head)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8).frame(height: RowHeight.default)
      .background(selected ? C.surfaceActive : Color.clear, in: RoundedRectangle(cornerRadius: Radius.card))
      .contentShape(Rectangle())
    }
  }

  private struct ReplyHeader: View {
    let date: Date
    var body: some View {
      HStack(spacing: 8) {
        ConciergeAvatar()
        Text(tr("コンシェルジュ")).font(Typography.font(Typography.title)).foregroundStyle(C.textPrimary)
        Text(date.formatted(date: .omitted, time: .shortened)).font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted)
      }
    }
  }

  /// A run of tool calls (canvas `Concierge`): "ツールを N 回実行" and the distinct names, folded by default;
  /// open, one line per call — name and main argument (`AgentHistoryReader.toolLine`).
  private struct ToolGroup: View {
    let lines: [String]
    let date: Date
    let header: Bool
    @State private var open = false

    var body: some View {
      let calls = lines.map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }
      VStack(alignment: .leading, spacing: 6) {
        if header { ReplyHeader(date: date).padding(.bottom, 4) }
        Button { open.toggle() } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right").font(.system(size: Typography.chromeSize(9), weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
            Text(tr("ツールを %@ 回実行", lines.count))
            if !open {
              Text(verbatim: "· " + calls.map { $0[0] }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(3).joined(separator: ", "))
                .lineLimit(1).foregroundStyle(C.textMuted)
            }
          }.contentShape(Rectangle())
        }.buttonStyle(.plain).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
        if open {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(calls.enumerated()), id: \.offset) { _, c in
              HStack(spacing: 8) {
                Text(verbatim: c[0]).foregroundStyle(C.textSecondary)
                if c.count > 1 { Text(verbatim: c[1]).foregroundStyle(C.textTertiary).lineLimit(1).truncationMode(.middle) }
              }.font(Typography.font(Typography.chrome, family: .mono)).textSelection(.enabled)
            }
          }.padding(.leading, 16)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// One assistant message: bubble-less Markdown under the avatar header (once per run), copy on hover.
  private struct Reply: View, @MainActor Equatable {
    let message: AgentHistory.Message
    let header: Bool
    @State private var hovered = false

    // Only a changed message re-renders (and re-parses its Markdown); a new turn below leaves earlier replies alone.
    static func == (a: Self, b: Self) -> Bool { a.message == b.message && a.header == b.header }

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        if header { ReplyHeader(date: message.date) }
        ForEach(Array(MarkdownPreview.parse(message.text).enumerated()), id: \.offset) { _, b in ChatBlock(block: b.block, size: 15) }
        Button { copyToPasteboard(message.text) } label: { Image(systemName: "doc.on.doc").frame(width: 24, height: 22) }
          .buttonStyle(.hoverWash).font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted)
          .help(tr("返答をコピー")).accessibilityLabel(tr("返答をコピー"))
          .opacity(hovered ? 1 : 0).padding(.leading, -5)
      }
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onHover { hovered = $0 }
    }
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
            .frame(height: agent == nil ? nil : 156, alignment: .bottomLeading)
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

    static let lines = 14
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

  /// #78 / ADR-0028: the kanban. Five columns (Inbox, Plan, Impl, Review, Done) of every Project's cards; a drag moves a card
  /// and the model starts the column's agent. Drawn flat like the chat beside it: one ground, hairline boxes, mono heads,
  /// colour only on the status dots.
  struct TodoBoardView: View {
    let cards: [TodoBoardCard]
    /// Done cards past the display window; reached from the end of the Done column and by search.
    let archived: [TodoBoardCard]
    /// Agent panes on no card (started by hand in a Project).
    let others: [BoardAgent]
    let agent: (TodoBoardCard) -> BoardAgent?
    /// Project names, most recent first.
    let projects: [String]
    let run: (String, CommandInput) -> Result<CommandResult, CommandError>
    let confirm: (ClairDialog) -> Void
    let reload: () -> Void
    /// Adds an Inbox card with this title.
    let newCard: (String) -> Void
    let openAgent: (AgentSession) -> Void
    let openPane: (TodoBoardCard) -> Void
    let openFile: (String) -> Void
    let ask: (TodoBoardCard) -> Void
    let makePR: (TodoBoardCard) -> Void
    /// The worktree Project of the card's branch, if Clair has it open; nil hides "diff を開く".
    let diffProject: (TodoBoardCard) -> String?
    let openDiff: (String) -> Void
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
    @State private var dropTarget: String?
    @State private var draft = ""
    @FocusState private var draftFocused: Bool
    @State private var picking: (card: TodoBoardCard, stage: String)?
    @State private var pickQuery = ""
    @FocusState private var pickFocused: Bool
    /// The agent pane in quick look, by session id, and whether its terminal can be shown (a live shell).
    @State private var peeked: String?
    @State private var peekLive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gap: CGFloat = 8
    private static let pad: CGFloat = 24

    private func needsYou(_ c: TodoBoardCard) -> Bool { c.state == .blocked || c.state == .failed }

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
        Rectangle().fill(L.hairline).frame(height: 1)
        GeometryReader { geo in
          // Five columns share the width; below the minimum the columns scroll sideways instead of squeezing.
          let count = CGFloat(ClairTodo.columns.count + (others.isEmpty ? 0 : 1))
          let width = max(220, (geo.size.width - Self.pad * 2 - Self.gap * (count - 1)) / count)
          ScrollViewReader { proxy in
            ScrollView(.horizontal) {
              HStack(alignment: .top, spacing: Self.gap) {
                ForEach(ClairTodo.columns, id: \.self) { column($0, shown: shown, past: past, width: width) }
                if !others.isEmpty { othersColumn(width: width) }
              }
              .padding(.horizontal, Self.pad).padding(.vertical, 16).frame(height: geo.size.height, alignment: .top)
              // A card moving columns or changing state slides in place instead of jumping.
              .animation(reduceMotion ? nil : .easeOut(duration: Motion.screenDuration),
                         value: (shown + past).map { "\($0.todo.path)\($0.column)\($0.state)" })
            }.clairScroller()
            .onChange(of: selected) { _, path in
              guard let path else { return }
              withAnimation(reduceMotion ? nil : .easeOut(duration: Motion.screenDuration)) { proxy.scrollTo(path) }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(C.canvas)
      .overlay { quickLook }
      .overlay { projectPicker }
      // An exited agent leaves the list, and its quick look with it.
      .onChange(of: agents.map(\.session.id)) { _, ids in if let peeked, !ids.contains(peeked) { self.peeked = nil } }
    }

    // MARK: Header

    private var header: some View {
      let waiting = cards.filter(needsYou).count
      return HStack(spacing: 8) {
        Text(tr("ボード")).font(Typography.font(Typography.title)).foregroundStyle(C.textPrimary)
        Text(tr("%@ 件", cards.count)).font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted)
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").font(Typography.font(Typography.chrome)).foregroundStyle(C.textMuted)
          TextField(tr("カードを検索"), text: $query).textFieldStyle(.plain)
            .font(Typography.font(Typography.chrome)).foregroundStyle(C.textPrimary)
            .accessibilityLabel(tr("カードを検索"))
        }
        .padding(.horizontal, 8).frame(width: 180, height: RowHeight.default).modifier(Boxed())
        Button { waitingOnly.toggle() } label: {
          HStack(spacing: 6) {
            Circle().fill(waiting == 0 ? C.textMuted : C.attention).frame(width: 6, height: 6)
            Text(tr("あなた待ち"))
            Text(verbatim: "\(waiting)").font(Typography.font(Typography.chrome, family: .mono)).foregroundStyle(C.textMuted)
          }.modifier(Chip(on: waitingOnly))
        }
        .buttonStyle(HoverWashStyle(radius: Radius.card)).help(tr("あなた待ちだけ表示"))
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

    // MARK: Columns

    private func column(_ stage: String, shown: [TodoBoardCard], past: [TodoBoardCard], width: CGFloat) -> some View {
      let items = shown.filter { $0.column == stage }
      let targeted = dropTarget == stage
      return VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          BoardHead(title: stage.capitalized, count: items.count)
          Spacer(minLength: 0)
          if stage == "inbox" {
            Button { draftFocused = true } label: {
              Image(systemName: "plus").font(Typography.font(Typography.sidebarMicro)).foregroundStyle(C.textTertiary).frame(width: 22, height: 22)
            }.buttonStyle(HoverWashStyle(radius: Radius.control)).help(tr("カードを追加")).accessibilityLabel(tr("カードを追加"))
          }
        }.frame(height: 22).padding(.leading, 6)  // the Inbox "+" is 22pt: every header takes its height so the rows line up
        ScrollView {
          VStack(spacing: 6) {
            if stage == "inbox" { quickAdd }
            ForEach(capped(items, stage), id: \.todo.path) { card($0).transition(.opacity) }
            more(items.count, stage)
            if stage == "done", !past.isEmpty { pastSection(past) }
          }.padding(6)
        }.clairScroller()
        .frame(maxHeight: .infinity, alignment: .top)
        .background(W.soft, in: RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(targeted ? L.ring : Color.clear))
        .dropDestination(for: URL.self) { urls, _ in
          guard let path = urls.first?.path, let c = (cards + archived).first(where: { $0.todo.path == path }), c.column != stage else { return false }
          requestMove(c, stage)
          return true
        } isTargeted: { on in
          if on { dropTarget = stage } else if dropTarget == stage { dropTarget = nil }
        }
      }
      .frame(width: width)
    }

    /// Type a title and press Return: the card lands in Inbox and the field stays ready for the next one.
    private var quickAdd: some View {
      TextField(tr("TODO を追加…"), text: $draft)
        .focused($draftFocused).textFieldStyle(.plain).font(Typography.font(Typography.sidebar)).foregroundStyle(C.textPrimary)
        .padding(.horizontal, 10).frame(height: RowHeight.control)
        .modifier(Boxed(radius: Radius.card))
        .onSubmit {
          let t = draft.trimmingCharacters(in: .whitespaces)
          guard !t.isEmpty else { return }
          newCard(t); draft = ""; draftFocused = true
        }
        .onExitCommand { draft = ""; draftFocused = false }
        .accessibilityLabel(tr("カードを追加"))
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

    private func state(_ s: TodoBoardCard.State) -> (String, Color)? {
      switch s {
      case .idle: nil
      case .running: (tr("実行中"), C.success)
      case .blocked: (tr("入力待ち"), C.attention)
      case .done: (tr("完了"), C.textMuted)
      case .failed: (tr("失敗"), C.danger)
      case .unreported: (tr("完了(結果未報告)"), C.textMuted)
      }
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
      Button(action: run) {
        Text(title).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).lineLimit(1)
          .padding(.horizontal, 8).frame(height: RowHeight.compact).modifier(Boxed(radius: Radius.control))
      }.buttonStyle(HoverWashStyle(radius: Radius.control))
    }

    private func card(_ c: TodoBoardCard) -> some View {
      let a = agent(c)
      let label = state(c.state)
      let on = selected == c.todo.path
      return VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(c.todo.title).font(Typography.font(Typography.sidebar)).foregroundStyle(c.column == "done" ? C.textTertiary : C.textPrimary)
            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          if let a {
            Button { openAgent(a.session) } label: {
              Image(systemName: "arrow.up.right").font(Typography.font(Typography.sidebarMicro)).foregroundStyle(C.textMuted).frame(width: 22, height: 22)
            }.buttonStyle(HoverWashStyle(radius: Radius.control)).help(tr("ターミナルを開く")).accessibilityLabel(tr("ターミナルを開く"))
          }
        }
        HStack(spacing: 6) {
          if let label { Circle().fill(label.1).frame(width: 6, height: 6); Text(label.0).foregroundStyle(c.state == .blocked ? C.attention : C.textTertiary) }
          if let p = c.project { Text(verbatim: label == nil ? p : "· \(p)").lineLimit(1) }
        }.font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
        if let note = c.note, !note.isEmpty {
          Text(note).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        CardScreen(agent: a, path: c.todo.path)
        // A finished Plan card offers its plan.md, so the owner reads it before moving the card to Impl.
        if c.column == "plan", c.state == .done || c.state == .unreported, let plan = c.artifacts.first(where: { $0.hasSuffix("/plan.md") }) {
          action(tr("plan.md を開く")) { openFile(plan) }.accessibilityLabel(tr("plan.md を開く"))
        }
        if c.column == "review" { action(tr("PR を作る")) { makePR(c) }.accessibilityLabel(tr("PR を作る")) }
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
      // A file URL, not a bare string: the concierge chat takes it as a path to ask about, the columns move it.
      .draggable(URL(fileURLWithPath: c.todo.path))
      .onTapGesture {
        selected = c.todo.path
        if let a { peek(a) }
      }
      .contextMenu {
        Button(tr("TODO を開く")) { openFile(c.todo.path) }
        ForEach(c.artifacts, id: \.self) { path in Button((path as NSString).lastPathComponent) { openFile(path) } }
        if c.pane != nil { Button(tr("ペインを開く")) { openPane(c) } }
        if let p = diffProject(c) { Button(tr("diff を開く")) { openDiff(p) } }
        if let pr = c.todo.pr, let url = URL(string: pr), url.scheme == "https" { Button(tr("PR を開く")) { NSWorkspace.shared.open(url) } }
        if c.column == "inbox" { Button(tr("調査する")) { requestMove(c, "research") } }
        if c.column != "done" { Button(tr("コンシェルジュに頼む")) { ask(c) } }
      }
      .accessibilityElement(children: .contain)
      .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// The right-edge column: live agents no card holds (manual, concierge children), so every agent in Clair is on the board.
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

    // MARK: Moving

    private func requestMove(_ c: TodoBoardCard, _ stage: String) {
      // Any live agent, an input-waiting one included: the move closes its pane.
      guard c.pane != nil, c.state == .running || c.state == .blocked else { return move(c, stage) }
      confirm(ClairDialog(title: tr("実行中の agent を終了して移しますか"), message: tr("「%@」の agent は実行中です。", c.todo.title),
                          confirm: tr("終了して移す"), destructive: true) { _ in move(c, stage) })
    }

    private func move(_ c: TodoBoardCard, _ stage: String, force: Bool = false) {
      var input: CommandInput = ["path": .string(c.todo.path), "stage": .string(stage)]
      if force { input["force"] = .bool(true) }
      guard case .failure(let e) = run("todo.move", input) else { return reload() }
      if e.message.contains("needsProject") {
        pickQuery = ""; picking = (c, stage)
      } else if e.message.contains("dirtyWorktree") {
        confirm(ClairDialog(title: tr("変更を破棄して Done に移しますか"), message: e.message, confirm: tr("破棄して移す"), destructive: true) { _ in
          move(c, stage, force: true)
        })
      } else {
        confirm(ClairDialog(title: tr("カードを移せません"), message: e.message) { _ in })
      }
    }

    private func choose(_ name: String?) {
      guard let p = picking else { return }
      picking = nil
      if case .failure(let e) = run("todo.update", ["path": .string(p.card.todo.path), "project": .string(name ?? "none")]) {
        return confirm(ClairDialog(title: tr("Project を設定できません"), message: e.message) { _ in })
      }
      move(p.card, p.stage)
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
