#if os(macOS)
  import ClairDesignSystem
  import ClairShared
  import ClairWorkspace
  import SwiftUI

  private typealias C = DesignTokens.Color

  // The concierge is read like a conversation, not scanned like chrome: one step above the chrome scale.
  private let chatFont = Font.system(size: 15)  // Tokens: title step (15)
  private let rowFont = Font.system(size: 13)  // Tokens: body step (13)
  private let rowStrong = Font.system(size: 13, weight: .semibold)

  // ADR-0020: the concierge's sidebar (itself, its children, its instructions) and its chat panel.

  private func statusLabel(_ s: AgentSession.Status) -> (String, Color) {
    switch s {
    case .running: (tr("実行中"), C.success)
    case .attention: (tr("入力待ち"), C.attention)
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
    let showingChat: Bool
    let children: [(session: AgentSession, launch: AgentLaunch)]
    let start: () -> Void
    let toggleView: () -> Void
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
          if running {
            Button(showingChat ? tr("ターミナル") : tr("チャット"), action: toggleView).buttonStyle(.hoverWash)
              .help(showingChat ? tr("コンシェルジュのターミナルを表示") : tr("チャットに戻る"))
          } else {
            Button(tr("起動"), action: start).buttonStyle(.hoverWash)
          }
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
          Label(tr("%@ を編集", Concierge.instructionsPath), systemImage: "doc.text")
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
  struct ConciergeChatView: View {
    let session: String?
    let pane: Int?
    let children: [(session: AgentSession, launch: AgentLaunch)]
    let focus: (AgentSession) -> Void
    /// Starts the concierge with `message` as its first request (the one undecided thing is decided on send).
    let start: (String) -> Void
    @State private var messages: [AgentHistory.Message] = []
    @State private var draft = ""
    /// Shown until the transcript catches up with what was just sent.
    @State private var pending: String?
    @FocusState private var focused: Bool

    var body: some View {
      VStack(spacing: 0) {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
              if messages.isEmpty && pending == nil {
                Text(tr("依頼を送ると、ここに会話が表示されます")).foregroundStyle(C.textQuaternary).frame(maxWidth: .infinity).padding(.top, 40)
              }
              ForEach(messages) { m in bubble(m.role, m.text) }
              if let pending { bubble("user", pending).opacity(0.6) }
              // Children are shown as links after the conversation, never as relayed output.
              if !children.isEmpty {
                VStack(spacing: 4) {
                  ForEach(children, id: \.session.id) { c in
                    ConciergeChildLink(session: c.session, title: c.launch.prompt.map(ConciergeSidebar.shortTitle) ?? c.session.title) { focus(c.session) }
                  }
                }
              }
            }.padding(.horizontal, 16).padding(.vertical, 26).frame(maxWidth: 760).frame(maxWidth: .infinity)
          }.defaultScrollAnchor(.bottom).clairScroller()
          composer.frame(maxWidth: 760).frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.bottom, 12)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity).background(C.canvas)
      .task(id: session) { await follow() }
    }

    private func bubble(_ role: String, _ body: String) -> some View {
      let text = Text((try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body))
        .font(chatFont).textSelection(.enabled)
      return Group {
        if role == "user" {
          HStack {
            Spacer(minLength: 60)
            text.foregroundStyle(C.textPrimary).padding(.horizontal, 14).padding(.vertical, 10)
              .background(C.surfaceActive, in: RoundedRectangle(cornerRadius: 10))
          }
        } else {
          text.foregroundStyle(C.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }

    private var composer: some View {
      HStack(alignment: .bottom, spacing: 8) {
        TextField(tr("コンシェルジュに頼む…"), text: $draft, axis: .vertical)
          .textFieldStyle(.plain).lineLimit(2...8).font(chatFont)
          .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
          .focused($focused)
          .onSubmit(send)
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Button(action: send) {
          Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(C.canvas)
            .frame(width: 32, height: 32).background(empty ? C.textQuaternary : C.textPrimary, in: Circle())
        }.buttonStyle(.plain).disabled(empty).help(tr("送信")).accessibilityLabel(tr("送信"))
      }
      .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 10)
      .contentShape(RoundedRectangle(cornerRadius: 10))
      .onTapGesture { focused = true }  // the whole box is the input, not just the text line
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? C.textTertiary : C.divider, lineWidth: 1))
    }

    /// Types the text into the concierge PTY, then Return on its own write so the TUI reads it as a submit, not a pasted newline.
    private func send() {
      let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      guard let pane else { draft = ""; pending = text; return start(text) }
      guard ClairGhosttySurfaceView.send(text, toPane: pane) else { return }
      draft = ""; pending = text
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ClairGhosttySurfaceView.send("\r", toPane: pane) }
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
            messages = await Task.detached { AgentHistoryReader.transcript(file: file, provider: .claude) }.value
            if messages.last?.role == "user" || messages.contains(where: { $0.role == "user" && $0.text == pending }) { pending = nil }
          }
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
#endif
