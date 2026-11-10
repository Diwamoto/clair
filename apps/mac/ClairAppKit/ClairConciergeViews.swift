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
  private let rowFont = Font.system(size: 13)  // Tokens: body step (13)
  private let rowStrong = Font.system(size: 13, weight: .semibold)

  // ADR-0020: the concierge's sidebar (itself, its children, its instructions) and its chat panel.

  func statusLabel(_ s: AgentSession.Status) -> (String, Color) {
    switch s {
    case .running: (tr("実行中"), C.success)
    case .attention: (tr("入力待ち"), C.attention)
    case .blocked: (tr("承認・回答待ち"), C.attention)
    case .done: (tr("完了"), C.success)
    case .idle: (tr("待機中"), C.textQuaternary)
    case .exited(let c): (tr("終了 %@", c.map(String.init) ?? "?"), c == 0 ? C.textQuaternary : C.danger)
    }
  }

  /// A child agent as a link to its own terminal pane; its output is never relayed.
  struct ConciergeChildLink: View {
    let session: AgentSession
    let title: String
    let open: () -> Void

    var body: some View {
      let (text, color) = statusLabel(session.status)
      Button(action: open) {
        HStack(spacing: 8) {
          Circle().fill(color).frame(width: 7, height: 7)
          Image(systemName: "apple.terminal").font(.system(size: 11)).foregroundStyle(C.textTertiary)
          Text(title).lineLimit(1).foregroundStyle(C.textSecondary)
          Spacer(minLength: 0)
          Text(text).foregroundStyle(C.textQuaternary)
          Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(C.textQuaternary)
        }
        .font(rowFont)
        .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(C.divider.opacity(0.6), lineWidth: 1))
      }.buttonStyle(.hoverWash).help(tr("ペイン %@ へ移動", session.pane))
    }
  }

  struct ConciergeSidebar: View {
    let running: Bool
    let children: [(session: AgentSession, launch: AgentLaunch)]
    let start: () -> Void
    let focus: (AgentSession) -> Void
    let editInstructions: () -> Void
    @State private var tasksOpen = true

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
          Text(tr("コンシェルジュ")).font(rowStrong).foregroundStyle(C.textPrimary)
          Circle().fill(running ? C.success : C.textQuaternary).frame(width: 6, height: 6)
          Text(running ? tr("Claude Code · 実行中") : tr("未起動")).font(rowFont).foregroundStyle(C.textQuaternary)
          Spacer(minLength: 0)
          if !running { Button(tr("起動"), action: start).buttonStyle(.hoverWash) }
        }.padding(.horizontal, 14).frame(height: 46)
        Divider()
        Button { tasksOpen.toggle() } label: {
          HStack(spacing: 4) {
            Image(systemName: tasksOpen ? "chevron.down" : "chevron.right").font(.system(size: 9))
            Text(tr("担当中のタスク"))
            Spacer(minLength: 0)
            Text(tr("%@ 件実行中", children.filter { !$0.session.status.isExited }.count)).foregroundStyle(C.textQuaternary)
          }.font(rowFont).foregroundStyle(C.textTertiary).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 10)
        if tasksOpen {
          VStack(spacing: 4) {
            if children.isEmpty {
              Text(tr("まだありません")).font(rowFont).foregroundStyle(C.textQuaternary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(children, id: \.session.id) { c in
              ConciergeChildLink(session: c.session, title: c.launch.prompt.map(Self.shortTitle) ?? c.session.title) { focus(c.session) }
            }
          }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        Divider()
        Button(action: editInstructions) {
          Label(tr("指示と作業フォルダを設定"), systemImage: "gearshape")
            .font(rowFont).foregroundStyle(C.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 36).contentShape(Rectangle())
        }.buttonStyle(.hoverWash)
      }
    }

    static func shortTitle(_ prompt: String) -> String {
      String(prompt.split(whereSeparator: \.isNewline).first ?? "").prefix(40).description
    }
  }

  /// The concierge transcript as chat, over the panes (they stay mounted, so the PTY keeps running).
  /// Canvas: `Concierge` (conversation) and `Concierge — 空の状態` (no transcript yet).
  struct ConciergeChatView: View {
    /// On: the chat sits beside the pane board so both are visible.
    @Binding var split: Bool
    let session: String?
    /// The concierge's daemon shell and launch. Its surface lives here, out of sight, and surfaces only while it is blocked.
    let terminal: (key: String, launch: AgentLaunch)?
    private var pane: Int? { terminal == nil ? nil : Concierge.pane }
    /// The concierge terminal's own state: `.blocked` is a prompt only the raw terminal can answer,
    /// and a finished turn (`done` / `idle` / `attention`) ends the working indicator.
    let status: AgentSession.Status?
    let children: [(session: AgentSession, launch: AgentLaunch)]
    let focus: (AgentSession) -> Void
    /// Starts the concierge with `message` as its first request (the one undecided thing is decided on send).
    let start: (String) -> Void
    /// nil until the transcript has been read once, so the empty state never flashes over a loading chat.
    @State private var messages: [AgentHistory.Message]?
    /// Kept across leaving and reopening the chat (the view is rebuilt each time).
    @SceneStorage("concierge.draft") private var draft = ""
    /// Shown until the transcript catches up with what was just sent.
    @State private var pending: String?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private static let column: CGFloat = 760
    /// Chat surfaces (user bubble, composer) round past the 3-step chrome radius on purpose; canvas `Concierge`.
    private static let bubbleRadius: CGFloat = 16

    var body: some View {
      Group {
        if messages?.isEmpty == true && pending == nil && children.isEmpty {
          emptyState
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
              let all = messages ?? []
              ForEach(Array(all.enumerated()), id: \.element.id) { i, m in
                row(m, header: i == 0 || all[i - 1].role == "user").transition(appear)
              }
              if let pending { userBubble(pending).opacity(0.6).transition(appear) }
              if status == .blocked {
                blockedRow.transition(appear)
              } else if working {
                WorkingRow().transition(appear)
              }
              // Children are shown as links after the conversation, never as relayed output.
              if !children.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                  Text(tr("子エージェント · %@", children.count)).font(.system(size: 12)).foregroundStyle(C.textTertiary)
                  ForEach(children, id: \.session.id) { c in
                    ChildCard(session: c.session, title: c.launch.prompt.map(ConciergeSidebar.shortTitle) ?? c.session.title) { focus(c.session) }
                  }
                }
              }
            }
            .padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 8)
            .frame(maxWidth: Self.column).frame(maxWidth: .infinity)
          }.defaultScrollAnchor(.bottom).clairScroller()
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        composer
          .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 18)
          .frame(maxWidth: Self.column).frame(maxWidth: .infinity)
          // The conversation scrolls under the composer and fades out above it.
          .background(LinearGradient(stops: [.init(color: C.canvas.opacity(0), location: 0), .init(color: C.canvas, location: 0.3)],
                                     startPoint: .top, endPoint: .bottom))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity).background(C.canvas)
      .overlay(alignment: .topTrailing) {
        Button { split.toggle() } label: {
          Image(systemName: split ? "rectangle" : "rectangle.split.2x1").font(.system(size: 13)).foregroundStyle(C.textTertiary)
            .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash).padding(10)
        .help(split ? tr("チャットだけを表示") : tr("ボードと並べて表示"))
        .accessibilityLabel(split ? tr("チャットだけを表示") : tr("ボードと並べて表示"))
      }
      .overlay { hiddenTerminal }
      .task(id: session) { await follow() }
    }

    /// The concierge's raw terminal: mounted (so the composer can type into it) but invisible, except while it waits
    /// on a permission or question only the terminal can answer.
    @ViewBuilder private var hiddenTerminal: some View {
      if let terminal {
        let blocked = status == .blocked
        ClairGhosttySurface(launch: (terminal.launch.command, terminal.launch.cwd), pane: Concierge.pane, sessionKey: terminal.key, focused: blocked)
          .id(terminal.key)
          .clipShape(RoundedRectangle(cornerRadius: Self.bubbleRadius, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: Self.bubbleRadius, style: .continuous).strokeBorder(L.strong))
          .padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 24)
          .opacity(blocked ? 1 : 0).allowsHitTesting(blocked).accessibilityHidden(!blocked)
          .animation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration), value: blocked)
      }
    }

    /// Waiting on a reply: something was just sent, or the last turn is the user's and the agent has not reported finishing.
    private var working: Bool {
      let asked = pending != nil || messages?.last?.role == "user"
      return asked && (status == nil || status == .running)
    }

    private var appear: AnyTransition {
      reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8))
    }

    @ViewBuilder private func row(_ m: AgentHistory.Message, header: Bool) -> some View {
      if m.role != "user" {
        Reply(message: m, header: header).padding(.top, header ? 0 : -10)
      } else if m.text.hasPrefix("[Skill loaded") {
        Label(String(m.text.dropFirst().dropLast()).replacing("Skill loaded", with: tr("スキル読込")), systemImage: "wand.and.stars")
          .font(.system(size: 12)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 10).padding(.vertical, 3).background(W.medium, in: Capsule())
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
          .background(C.surfaceActive, in: RoundedRectangle(cornerRadius: Self.bubbleRadius, style: .continuous))
      }
    }

    /// The concierge waits on a permission or question in its raw terminal; the chat cannot answer it.
    private var blockedRow: some View {
      HStack(spacing: 10) {
        ConciergeAvatar()
        Circle().fill(C.attention).frame(width: 6, height: 6)
        Text(tr("ターミナルで承認を待っています")).font(.system(size: 14)).foregroundStyle(C.textSecondary)
      }
    }

    /// Built on the Tokens EMPTY STATE vocabulary: glyph, title, one line, then starters that only fill the composer.
    private var emptyState: some View {
      VStack(spacing: 12) {
        Image(systemName: "brain.head.profile").font(.system(size: 26)).foregroundStyle(C.textSecondary)
          .frame(width: 56, height: 56)
          .background(W.raised, in: RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(L.strong.opacity(0.6)))
        Text(tr("何をお任せしますか?")).font(.system(size: 22, weight: .semibold)).foregroundStyle(C.textPrimary).padding(.top, 6)
        Text(tr("依頼を子エージェントに割り振り、進み具合をここにまとめます。")).font(.system(size: 14)).foregroundStyle(C.textTertiary)
          .multilineTextAlignment(.center)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
          ForEach(Self.starters, id: \.text) { s in
            Button { draft = tr(s.text); focused = true } label: {
              HStack(spacing: 10) {
                Image(systemName: s.icon).font(.system(size: 12)).foregroundStyle(C.textTertiary).frame(width: 16)
                Text(tr(s.text)).font(.system(size: 13)).foregroundStyle(C.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 14).frame(height: 44)
              .background(W.faint, in: RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
              .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(L.hairline))
              .contentShape(Rectangle())
            }.buttonStyle(HoverWashStyle(radius: Radius.overlay))
          }
        }.frame(maxWidth: 560).padding(.top, 18)
      }
      .padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let starters: [(icon: String, text: String)] = [
      ("checkmark.seal", "未コミットの変更をレビューして"), ("testtube.2", "テストを実行して、失敗を直して"),
      ("map", "この Project の構成を説明して"), ("checklist", "残っている TODO を片付けて"),
    ]

    private var composer: some View {
      let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      return VStack(alignment: .leading, spacing: 12) {
        TextField("", text: $draft, prompt: Text(tr("コンシェルジュに頼む…")).foregroundStyle(C.textQuaternary), axis: .vertical)
          .textFieldStyle(.plain).lineLimit(1...10).font(chatFont)
          .focused($focused)
          .onSubmit(send)
        HStack(spacing: 8) {
          HStack(spacing: 6) {
            Circle().fill(pane == nil ? C.textQuaternary : C.success).frame(width: 6, height: 6)
            Text(verbatim: "Claude Code")
          }
          .font(.system(size: 12)).foregroundStyle(C.textTertiary)
          .padding(.horizontal, 9).frame(height: 24).background(W.medium, in: Capsule())
          Spacer(minLength: 0)
          Text(pane == nil ? tr("⏎ 送信 · 最初の送信で起動") : tr("⏎ 送信")).font(.system(size: 11)).foregroundStyle(C.lineNumber)
          Button(action: send) {
            Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(empty ? C.textQuaternary : C.canvas)
              .frame(width: 32, height: 32).background(empty ? W.strongest : C.textPrimary, in: Circle())
          }
          .buttonStyle(.plain).disabled(empty).help(tr("送信")).accessibilityLabel(tr("送信"))
          .animation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration), value: empty)
        }
      }
      .padding(.leading, 16).padding(.trailing, 12).padding(.top, 14).padding(.bottom, 10)
      .background(C.surfaceHover, in: RoundedRectangle(cornerRadius: Self.bubbleRadius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Self.bubbleRadius, style: .continuous).strokeBorder(focused ? L.ring : L.strong))
      .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.08), radius: 12, y: 6)
      .contentShape(RoundedRectangle(cornerRadius: Self.bubbleRadius))
      .onTapGesture { focused = true }  // the whole card is the input, not just the text line
      .animation(reduceMotion ? nil : .easeOut(duration: Motion.overlayDuration), value: focused)
    }

    /// Types the text into the concierge PTY, then a real Return key press so the TUI reads it as a submit, not a pasted newline.
    private func send() {
      let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      guard let pane else { draft = ""; show(text); return start(text) }
      guard ClairGhosttySurfaceView.send(text, toPane: pane) else { return }
      draft = ""; show(text)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ClairGhosttySurfaceView.pressReturn(inPane: pane) }
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
            let read = await Task.detached { AgentHistoryReader.transcript(file: file, provider: .claude).filter { $0.role != "thinking" } }.value
            // The first read lands as is; later ones slide new turns in.
            withAnimation(messages == nil || reduceMotion ? nil : .easeOut(duration: Motion.screenDuration)) {
              messages = read
              if read.last?.role == "user" || read.contains(where: { $0.role == "user" && $0.text == pending }) { pending = nil }
            }
          }
        } else if messages == nil { messages = [] }
        try? await Task.sleep(for: .seconds(1))
      }
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
      Image(systemName: "brain.head.profile").font(.system(size: 12)).foregroundStyle(C.textSecondary)
        .frame(width: 24, height: 24)
        .background(W.strong, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(L.strong.opacity(0.6)))
    }
  }

  /// The reply is pending: a comet orbits the avatar and the label shimmers (both still under Reduce Motion).
  private struct WorkingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
        let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
        let sweep = (t.truncatingRemainder(dividingBy: 1.8) / 1.8) * 1.6 - 0.3  // -0.3…1.3 so the highlight enters and leaves
        HStack(spacing: 10) {
          ConciergeAvatar().overlay {
            RoundedRectangle(cornerRadius: Radius.card + 3, style: .continuous)
              .strokeBorder(AngularGradient(colors: [C.textSecondary.opacity(0), C.textSecondary], center: .center,
                                            angle: .degrees(t * 300)), lineWidth: 1.5)
              .padding(-3)
          }
          Text(tr("考えています…")).font(.system(size: 14))
            .foregroundStyle(LinearGradient(stops: [
              .init(color: C.textQuaternary, location: min(max(sweep - 0.25, 0), 1)),
              .init(color: C.textPrimary, location: min(max(sweep, 0), 1)),
              .init(color: C.textQuaternary, location: min(max(sweep + 0.25, 0), 1)),
            ], startPoint: .leading, endPoint: .trailing))
        }
      }
      .accessibilityElement(children: .combine)
    }
  }

  /// One assistant message: bubble-less Markdown under the avatar header (once per run), copy on hover.
  private struct Reply: View {
    let message: AgentHistory.Message
    let header: Bool
    @State private var hovered = false

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        if header {
          HStack(spacing: 8) {
            ConciergeAvatar()
            Text(tr("コンシェルジュ")).font(.system(size: 13, weight: .semibold)).foregroundStyle(C.textPrimary)
            Text(message.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 12)).foregroundStyle(C.textQuaternary)
          }
        }
        ForEach(Array(MarkdownPreview.parse(message.text).enumerated()), id: \.offset) { _, b in ChatBlock(block: b.block, size: 15) }
        Button { copyToPasteboard(message.text) } label: { Image(systemName: "doc.on.doc").frame(width: 24, height: 22) }
          .buttonStyle(.hoverWash).font(.system(size: 11)).foregroundStyle(C.textQuaternary)
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
        Label(alt.isEmpty ? source : alt, systemImage: "photo").font(.system(size: size - 2)).foregroundStyle(C.textQuaternary)
      default:
        MarkdownBlockView(block: block, root: "", path: "", scale: size / 13).lineSpacing(4)
      }
    }
  }

  private struct CodeCard: View {
    let language: String
    let text: String
    /// Code size; the header stays one step below it.
    let size: CGFloat
    @State private var copied = false

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text(verbatim: language.isEmpty ? "code" : language).font(.system(size: size - 1, design: .monospaced)).foregroundStyle(C.textTertiary)
          Spacer(minLength: 0)
          Button {
            copyToPasteboard(text); copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
          } label: {
            Label(copied ? tr("コピーしました") : tr("コピー"), systemImage: copied ? "checkmark" : "doc.on.doc")
              .padding(.horizontal, 6).frame(height: 22)
          }.buttonStyle(.hoverWash).font(.system(size: size - 1)).foregroundStyle(C.textTertiary)
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 30).background(W.soft)
        Rectangle().fill(L.hairline).frame(height: 1)
        ScrollView(.horizontal, showsIndicators: false) {
          Text(verbatim: text).font(.system(size: size, design: .monospaced)).lineSpacing(3).foregroundStyle(C.code)
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
      }
      .background(C.panel)
      .clipShape(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(L.hairline))
    }
  }

  /// A child agent in the chat: a card that opens its own terminal pane; its output is never relayed.
  private struct ChildCard: View {
    let session: AgentSession
    let title: String
    let open: () -> Void

    var body: some View {
      let (text, color) = statusLabel(session.status)
      Button(action: open) {
        HStack(spacing: 10) {
          Circle().fill(color).frame(width: 6, height: 6)
          Text(title).lineLimit(1).foregroundStyle(C.textSecondary)
          Spacer(minLength: 0)
          Text(text).foregroundStyle(C.textQuaternary)
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(C.textQuaternary)
        }
        .font(rowFont)
        .padding(.horizontal, 14).frame(height: 40)
        .background(W.faint, in: RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous).strokeBorder(L.hairline))
        .contentShape(Rectangle())
      }.buttonStyle(HoverWashStyle(radius: Radius.overlay)).help(tr("ペイン %@ へ移動", session.pane))
    }
  }
#endif
