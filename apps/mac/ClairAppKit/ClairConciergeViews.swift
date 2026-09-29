#if os(macOS)
  import ClairDesignSystem
  import ClairWorkspace
  import SwiftUI

  private typealias C = DesignTokens.Color

  // ADR-0020: the concierge's sidebar (itself, its children, its instructions) and its chat panel.

  private func statusLabel(_ s: AgentSession.Status) -> (String, Color) {
    switch s {
    case .running: ("実行中", C.success)
    case .attention: ("入力待ち", C.attention)
    case .exited(let c): ("終了 \(c.map(String.init) ?? "?")", c == 0 ? C.textQuaternary : C.danger)
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
          Circle().fill(color).frame(width: 6, height: 6)
          Image(systemName: "apple.terminal").font(.system(size: 11)).foregroundStyle(C.textTertiary)
          Text(title).lineLimit(1).foregroundStyle(C.textSecondary)
          Spacer(minLength: 0)
          Text(text).foregroundStyle(C.textQuaternary)
          Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(C.textQuaternary)
        }
        .font(Typography.font(Typography.sidebar))
        .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(C.divider.opacity(0.6), lineWidth: 1))
      }.buttonStyle(.hoverWash).help("ペイン \(session.pane) へ移動")
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
          Text("コンシェルジュ").font(Typography.font(Typography.sidebarStrong)).foregroundStyle(C.textPrimary)
          Circle().fill(running ? C.success : C.textQuaternary).frame(width: 6, height: 6)
          Text(running ? "Claude Code · 実行中" : "未起動").font(Typography.font(Typography.sidebar)).foregroundStyle(C.textQuaternary)
          Spacer(minLength: 0)
          if running {
            Button(showingChat ? "ターミナル" : "チャット", action: toggleView).buttonStyle(.hoverWash)
              .help(showingChat ? "コンシェルジュのターミナルを表示" : "チャットに戻る")
          } else {
            Button("起動", action: start).buttonStyle(.hoverWash)
          }
        }.padding(.horizontal, 12).frame(height: 40)
        Divider()
        Button { tasksOpen.toggle() } label: {
          HStack(spacing: 4) {
            Image(systemName: tasksOpen ? "chevron.down" : "chevron.right").font(.system(size: 9))
            Text("担当中のタスク")
            Spacer(minLength: 0)
            Text("\(children.filter { !$0.session.status.isExited }.count) 件実行中").foregroundStyle(C.textQuaternary)
          }.font(Typography.font(Typography.sidebar)).foregroundStyle(C.textTertiary).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 10)
        if tasksOpen {
          VStack(spacing: 4) {
            if children.isEmpty {
              Text("まだありません").font(Typography.font(Typography.sidebar)).foregroundStyle(C.textQuaternary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(children, id: \.session.id) { c in
              ConciergeChildLink(session: c.session, title: c.launch.prompt.map(Self.shortTitle) ?? c.session.title) { focus(c.session) }
            }
          }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        Divider()
        Button(action: editInstructions) {
          Label(".clair/concierge.md を編集", systemImage: "doc.text")
            .font(Typography.font(Typography.sidebar)).foregroundStyle(C.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
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
    let start: () -> Void
    @State private var messages: [AgentHistory.Message] = []
    @State private var draft = ""

    var body: some View {
      VStack(spacing: 0) {
        if session == nil {
          VStack(spacing: 12) {
            Text("コンシェルジュは起動していません").foregroundStyle(C.textTertiary)
            Button("起動", action: start).buttonStyle(.hoverWash)
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
              if messages.isEmpty {
                Text("依頼を送ると、ここに会話が表示されます").foregroundStyle(C.textQuaternary).frame(maxWidth: .infinity).padding(.top, 40)
              }
              ForEach(messages) { m in bubble(m) }
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
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity).background(C.canvas)
      .task(id: session) { await follow() }
    }

    private func bubble(_ m: AgentHistory.Message) -> some View {
      let text = Text((try? AttributedString(markdown: m.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.text))
        .font(Typography.font(Typography.chrome)).textSelection(.enabled)
      return Group {
        if m.role == "user" {
          HStack {
            Spacer(minLength: 60)
            text.foregroundStyle(C.textPrimary).padding(.horizontal, 12).padding(.vertical, 8)
              .background(C.surfaceActive, in: RoundedRectangle(cornerRadius: 10))
          }
        } else {
          text.foregroundStyle(C.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }

    private var composer: some View {
      HStack(alignment: .bottom, spacing: 8) {
        TextField("コンシェルジュに頼む…", text: $draft, axis: .vertical)
          .textFieldStyle(.plain).lineLimit(1...6).font(Typography.font(Typography.chrome))
          .onSubmit(send)
        Button("送信", action: send).buttonStyle(.hoverWash).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(8)
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(C.divider, lineWidth: 1))
    }

    /// Types the text into the concierge PTY, then Return on its own write so the TUI reads it as a submit, not a pasted newline.
    private func send() {
      let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, let pane, ClairGhosttySurfaceView.send(text, toPane: pane) else { return }
      draft = ""
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
          }
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
#endif
