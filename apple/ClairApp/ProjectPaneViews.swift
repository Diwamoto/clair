import AppKit
import SwiftUI

struct ProjectTerminalPanel: View {
  let project: Project
  @ObservedObject var session: TerminalSession
  let onHide: () -> Void
  let onEnd: () -> Void
  let onRecover: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "terminal")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textTertiary)
        Text(session.statusDescription)
          .font(WorkspaceChrome.chromeFont(size: 11))
          .foregroundStyle(statusColor)
        Text("\(session.dimensions.columns) × \(session.dimensions.rows)")
          .font(WorkspaceChrome.chromeFont(size: 10))
          .monospacedDigit()
          .foregroundStyle(WorkspaceChrome.textQuaternary)
        Spacer()
        if case .missing = session.state {
          Button("新しいセッションを開始", action: onRecover)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        Button("エディタ", action: onHide)
          .buttonStyle(.tactile)
          .font(WorkspaceChrome.chromeFont(size: 11))
          .foregroundStyle(WorkspaceChrome.textTertiary)
        Button("終了", action: onEnd)
          .buttonStyle(.tactile)
          .font(WorkspaceChrome.chromeFont(size: 11))
          .foregroundStyle(WorkspaceChrome.danger)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(minHeight: 42)
      .background(WorkspaceChrome.chromeRaised)

      Divider()
        .background(WorkspaceChrome.border)

      TerminalSurfaceView(session: session)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceChrome.canvas)
        .onAppear {
          session.start()
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WorkspaceChrome.canvas)
  }

  private var statusColor: Color {
    switch session.state {
    case .running, .starting:
      WorkspaceChrome.success
    case .idle, .stopping:
      WorkspaceChrome.textTertiary
    case .exited:
      WorkspaceChrome.attention
    case .missing:
      WorkspaceChrome.danger
    case .failed:
      WorkspaceChrome.danger
    }
  }
}

struct ProjectPaneLayoutView: View {
  let state: BootstrapState
  let project: Project
  let surface: ProjectSurfaceModel
  let node: ProjectPaneNode
  let fontSize: Double
  let wordWrap: Bool

  var body: some View {
    nodeView(node)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func nodeView(_ node: ProjectPaneNode) -> AnyView {
    switch node {
    case .leaf(let leaf):
      return AnyView(
        ProjectPaneView(
          state: state,
          project: project,
          surface: surface,
          paneID: leaf.id,
          fontSize: fontSize,
          wordWrap: wordWrap
        )
      )
    case .split(_, let orientation, let ratio, let first, let second):
      return AnyView(
        GeometryReader { proxy in
          let fraction = CGFloat(min(max(ratio, 0.05), 0.95))
          Group {
            if orientation == .horizontal {
              HStack(spacing: 0) {
                nodeView(first)
                  .frame(width: proxy.size.width * fraction)
                Rectangle()
                  .fill(WorkspaceChrome.paneDivider)
                  .frame(width: 1)
                nodeView(second)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
              }
            } else {
              VStack(spacing: 0) {
                nodeView(first)
                  .frame(height: proxy.size.height * fraction)
                Rectangle()
                  .fill(WorkspaceChrome.borderStronger)
                  .frame(height: 1)
                nodeView(second)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
              }
            }
          }
        }
      )
    }
  }
}

/// The open file's path at the top of the pane it belongs to, one segment per
/// directory plus the filename.
///
/// A deliberate exception to the Tokens artboard's chrome budget: that note
/// originally put the breadcrumb in the status bar so splitting a pane would
/// not grow the vertical chrome. Putting it literally at the top of the editor
/// won instead, and the trade-off — 24px per pane once an editor is split — is
/// accepted.
struct PathBreadcrumb<Trailing: View>: View {
  let path: String
  let rootURL: URL
  @ViewBuilder var trailing: () -> Trailing

  init(
    path: String,
    rootURL: URL,
    @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
  ) {
    self.path = path
    self.rootURL = rootURL
    self.trailing = trailing
  }

  var body: some View {
    HStack(spacing: 5) {
      ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
        if index > 0 {
          Text("›")
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
        }
        Text(segment)
          .font(
            WorkspaceChrome.chromeFont(
              size: 11,
              weight: index == segments.count - 1 ? .semibold : .regular
            )
          )
          .monospaced()
          .foregroundStyle(
            index == segments.count - 1
              ? WorkspaceChrome.textSecondary : WorkspaceChrome.textQuaternary
          )
          .lineLimit(1)
          .layoutPriority(index == segments.count - 1 ? 1 : 0)
      }
      Spacer(minLength: 8)
      trailing()
    }
    .padding(.leading, 12)
    .padding(.trailing, 8)
    .frame(
      maxWidth: .infinity,
      minHeight: WorkspaceChrome.Metrics.breadcrumb,
      maxHeight: WorkspaceChrome.Metrics.breadcrumb
    )
    .clipped()
    .background(WorkspaceChrome.canvas)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(segments.joined(separator: "、"))
  }

  /// Relative to the Project root when the file is inside it, so the crumb
  /// says where the file sits in the Project rather than on the disk.
  private var segments: [String] {
    let root = rootURL.standardizedFileURL.path
    var relative = path
    if relative.hasPrefix(root) {
      relative = String(relative.dropFirst(root.count))
    }
    let parts = relative.split(separator: "/").map(String.init)
    return parts.isEmpty ? [(path as NSString).lastPathComponent] : parts
  }
}

/// What used to be the editor's own 58px header: the file's unsaved state, an
/// overflow menu, and Save — folded into the breadcrumb row so a pane spends
/// 24px on its file, not 82.
struct ProjectEditorBreadcrumbActions: View {
  @ObservedObject var tab: ProjectEditorTab
  let surface: ProjectSurfaceModel

  var body: some View {
    HStack(spacing: 6) {
      if tab.loadError != nil {
        marker("開けません", tint: WorkspaceChrome.danger)
      } else if tab.isMissing {
        marker("見つかりません", tint: WorkspaceChrome.attention)
      } else if tab.isDirty {
        marker("未保存", tint: WorkspaceChrome.attention)
      }

      Menu {
        Button("元に戻す") {
          surface.undoActiveTab()
        }
        .disabled(!tab.canUndo)
        Button("やり直す") {
          surface.redoActiveTab()
        }
        .disabled(!tab.canRedo)
        Button("ツリーで表示") {
          surface.reveal(nodeID: tab.id)
        }
        Divider()
        Button("保存") {
          surface.save(tabID: tab.id)
        }
        .disabled(!tab.isDirty || tab.isMissing || tab.isReadOnly)
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .frame(width: 20, height: 18)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("エディタの操作")
      .accessibilityLabel("エディタの操作")
    }
  }

  private func marker(_ text: String, tint: Color) -> some View {
    Text(text)
      .font(WorkspaceChrome.chromeFont(size: 9, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 6)
      .frame(height: 16)
      .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
  }
}

struct ProjectPaneView: View {
  let state: BootstrapState
  let project: Project
  let surface: ProjectSurfaceModel
  let paneID: UUID
  let fontSize: Double
  let wordWrap: Bool

  var body: some View {
    VStack(spacing: 0) {
      tabContent
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WorkspaceChrome.canvas)
    .overlay {
      // The focused pane is marked by the quietest ring the Tokens artboard
      // defines, not a coloured border: only diff and debug carry colour.
      Rectangle()
        .stroke(
          surface.isFocusedPane(paneID) ? WorkspaceChrome.borderStronger : Color.clear,
          lineWidth: 1
        )
        .allowsHitTesting(false)
    }
    .overlay(alignment: .topTrailing) {
      paneActions
        .padding(8)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      surface.focusPane(id: paneID)
    }
  }

  @ViewBuilder
  private var tabContent: some View {
    if let tab = surface.activeTab(in: paneID) {
      switch tab.kind {
      case .editor:
        if let document = surface.editorDocument(tabID: tab.id) {
          VStack(spacing: 0) {
            PathBreadcrumb(
              path: tab.filePath ?? tab.title,
              rootURL: project.rootURL
            ) {
              ProjectEditorBreadcrumbActions(tab: document, surface: surface)
            }
            ProjectNativeEditorTab(
              tab: document,
              surface: surface,
              debugSession: surface.debugSession,
              showsDebugGutter: surface.workspaceActivity == .debug,
              fontSize: fontSize,
              wordWrap: wordWrap
            )
          }
        } else {
          ContentUnavailableView(
            "エディタを利用できません",
            systemImage: "doc.text.magnifyingglass",
            description: Text("このProjectではファイルを復元できませんでした。")
          )
        }
      case .terminal:
        if let session = surface.terminalSession(tabID: tab.id) {
          ProjectTerminalPanel(
            project: project,
            session: session,
            onHide: surface.hideTerminal,
            onEnd: surface.endTerminal,
            onRecover: { surface.recoverTerminal(tabID: tab.id) }
          )
        } else {
          ProjectRestoredTerminalView {
            surface.startTerminal(tabID: tab.id)
          }
        }
      case .diff:
        ProjectDiffPreview(surface: surface)
      }
    } else {
      ChromeEmptyState(
        symbol: "rectangle.split.3x1",
        title: "空のペイン",
        message: "エディタ、ターミナル、または差分タブを開いてください。"
      )
      .frame(maxWidth: 320)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var paneActions: some View {
    Menu {
      Button("右に分割") {
        surface.splitFocusedPane(orientation: .horizontal)
      }
      Button("下に分割") {
        surface.splitFocusedPane(orientation: .vertical)
      }
      Divider()
      Button(
        surface.isFocusedPaneMaximized ? "ペインを復元" : "ペインを最大化"
      ) {
        surface.toggleMaximizeFocusedPane()
      }
      Button("分割を均等化") {
        surface.equalizeSplits()
      }
      Button("差分を開く") {
        surface.openDiff()
      }
      Button("ターミナルを開く") {
        surface.showTerminal()
      }
      if surface.paneIDs.count > 1 {
        Divider()
        Menu("アクティブなタブを移動") {
          ForEach(Array(surface.paneIDs.enumerated()), id: \.element) { index, paneID in
            if paneID != surface.focusedPaneID {
              Button("ペイン \(index + 1)") {
                surface.moveActiveTab(to: paneID)
              }
            }
          }
        }
        Button("ペインを閉じる", role: .destructive) {
          surface.closePane(id: paneID)
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(WorkspaceChrome.textTertiary)
        .frame(width: 24, height: 22)
        .background(
          WorkspaceChrome.panel.opacity(0.9),
          in: RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.control)
        )
        .overlay {
          RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.control)
            .stroke(WorkspaceChrome.hairline, lineWidth: 1)
        }
    }
    .menuStyle(.borderlessButton)
    .help("ペインのレイアウト操作")
    .accessibilityLabel("ペインのレイアウト操作")
  }

}

struct ProjectRestoredTerminalView: View {
  let onStart: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "terminal")
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
      Text("ターミナルセッションは実行されていません")
        .font(.headline)
      Text(
        "ターミナルの配置は復元されましたが、トランスクリプトは意図的に保存していません。新しいローカルセッションを開始してください。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 420)
      Button("ターミナルを開始", action: onStart)
        .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}
