import AppKit
import SwiftUI

// MARK: - Workspace Titlebar

enum WorkspaceTitlebarMetrics {
  static let height = WorkspaceChrome.Metrics.titlebar
  static let trafficLightGutterWidth: CGFloat = 76
  /// Chrome's tab-group pill.
  static let chipHeight: CGFloat = 26
  static let tabWidth = WorkspaceChrome.Metrics.tabWidth
  static let tabHeight = WorkspaceChrome.Metrics.tabHeight
  static let tabDividerHeight: CGFloat = 18
  static let groupDividerHeight: CGFloat = 22
  static let searchFieldWidth: CGFloat = 200
}

/// The one titlebar, from the Main artboard: traffic lights, every Project's
/// tab group — Chrome-style, each collapsible toward its own chip — then the
/// file/symbol search field and the two window actions.
///
/// Contents sit on the *bottom* edge of the 48px band so the tabs' active
/// underline can meet the titlebar's own hairline.
struct WorkspaceTitlebar: View {
  @ObservedObject var workspace: ProjectWorkspaceModel
  let activeProjectID: UUID?
  let onOpenProject: () -> Void
  let onRenameProject: (Project) -> Void
  let onOpenCommand: () -> Void
  let onOpenSearch: () -> Void
  let onOpenSettings: () -> Void
  let isSettingsActive: Bool

  /// Which Project's tab row is folded away. Purely a titlebar concern —
  /// collapsing a group never touches which Project is active, the same way
  /// collapsing the active group in Chrome leaves the page alone.
  @State private var collapsedProjects: Set<UUID> = []

  var body: some View {
    // Tabs are centred in the bar now that the selected one is a filled shape
    // rather than an underline hanging off the bottom edge.
    HStack(alignment: .center, spacing: 0) {
      // Native traffic lights overlay this gutter; WindowZoomDoubleClickView
      // centres them vertically in this 48px band so they sit with the tabs.
      Color.clear
        .frame(width: WorkspaceTitlebarMetrics.trafficLightGutterWidth)
        .frame(maxHeight: .infinity)

      ProjectGroupStrip(
        workspace: workspace,
        activeProjectID: activeProjectID,
        collapsedProjects: $collapsedProjects,
        onSelectProject: selectProject,
        onOpenProject: onOpenProject,
        onRenameProject: onRenameProject
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

      HStack(spacing: 4) {
        searchField
        ChromeActionButton(help: "コマンドパレット", action: onOpenCommand) {
          Image(systemName: "command")
            .font(.system(size: 13, weight: .medium))
        }
        ChromeActionButton(
          isActive: isSettingsActive,
          help: "設定",
          action: onOpenSettings
        ) {
          Image(systemName: "gearshape")
            .font(.system(size: 13, weight: .medium))
        }
      }
      .padding(.horizontal, 12)
      .fixedSize()
    }
    .frame(maxWidth: .infinity)
    .frame(height: WorkspaceTitlebarMetrics.height)
    .background {
      WindowZoomDoubleClickHandler()
    }
    .background(WorkspaceChrome.chrome)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(WorkspaceChrome.hairline)
        .frame(height: 1)
    }
    .accessibilityElement(children: .contain)
  }

  /// File and symbol search lives here and nowhere else — the sidebar has no
  /// search entry, so one job keeps one entry point.
  ///
  /// Painted like the commit message box in Source Control: `panel` over a
  /// hairline, darker than the chrome around it. Both are the same thing —
  /// somewhere you type — and a text field is a well cut into the frame, not a
  /// button raised out of it.
  private var searchField: some View {
    Button(action: onOpenSearch) {
      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
        Text("ファイル、シンボル")
          .font(WorkspaceChrome.chromeFont(size: 11))
          .foregroundStyle(WorkspaceChrome.chromeInkMuted)
        Spacer(minLength: 0)
        Text("⌘⇧F")
          .font(WorkspaceChrome.monoFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
      }
      .padding(.horizontal, 9)
      .frame(width: WorkspaceTitlebarMetrics.searchFieldWidth, height: 28)
      .background(
        WorkspaceChrome.panel,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(WorkspaceChrome.hairline, lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .help("ファイル・シンボルを検索")
    .accessibilityLabel("ファイル、シンボルを検索")
  }

  private func selectProject(_ projectID: UUID) {
    _ = workspace.execute(.switchProject(SwitchProjectCommand(projectID: projectID)))
  }
}

struct WindowZoomDoubleClickHandler: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowZoomDoubleClickView {
    WindowZoomDoubleClickView()
  }

  func updateNSView(_ nsView: WindowZoomDoubleClickView, context: Context) {}

  static func dismantleNSView(_ nsView: WindowZoomDoubleClickView, coordinator: ()) {
    nsView.stopMonitoring()
  }
}

@MainActor
final class WindowZoomDoubleClickView: NSView {
  private var eventMonitor: Any?
  private var windowObservers: [NSObjectProtocol] = []

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopMonitoring()

    guard let window else { return }
    startWindowObservers(window)
    layoutTrafficLights(in: window)
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
      [weak self] event in
      guard
        let self,
        let window = self.window,
        event.window === window,
        event.clickCount == 2,
        let contentView = window.contentView
      else {
        return event
      }

      let point = contentView.convert(event.locationInWindow, from: nil)
      guard point.y >= contentView.bounds.maxY - WorkspaceTitlebarMetrics.height else {
        return event
      }

      window.zoom(nil)
      return event
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func layout() {
    super.layout()
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else { return }
      self.layoutTrafficLights(in: window)
    }
  }

  func stopMonitoring() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    windowObservers.forEach(NotificationCenter.default.removeObserver)
    windowObservers = []
  }

  private func startWindowObservers(_ window: NSWindow) {
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      NSWindow.didResizeNotification,
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
    ]
    windowObservers = names.map { name in
      center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, let window = self.window else { return }
          self.layoutTrafficLights(in: window)
        }
      }
    }
  }

  /// Hidden-titlebar windows pin the system buttons to a ~28pt titlebar.
  /// Nudge them so their vertical centre matches the 48px tab strip.
  private func layoutTrafficLights(in window: NSWindow) {
    guard
      !window.styleMask.contains(.fullScreen),
      let contentView = window.contentView
    else {
      return
    }

    let buttons: [NSView] = [
      window.standardWindowButton(.closeButton),
      window.standardWindowButton(.miniaturizeButton),
      window.standardWindowButton(.zoomButton),
    ].compactMap { $0 }

    let midYInContent: CGFloat
    if contentView.isFlipped {
      midYInContent = WorkspaceTitlebarMetrics.height / 2
    } else {
      midYInContent = contentView.bounds.maxY - WorkspaceTitlebarMetrics.height / 2
    }

    for button in buttons {
      guard let superview = button.superview else { continue }
      let currentCenter = superview.convert(
        NSPoint(x: button.frame.midX, y: button.frame.midY),
        to: contentView
      )
      let targetCenter = NSPoint(x: currentCenter.x, y: midYInContent)
      let originInSuper = superview.convert(targetCenter, from: contentView)
      button.setFrameOrigin(
        NSPoint(
          x: button.frame.origin.x,
          y: originInSuper.y - button.frame.height / 2
        )
      )
    }
  }
}

// MARK: - Project Groups and Tabs

/// Every open Project's tab group, laid out left to right the way Chrome lays
/// out tab groups: each Project owns a chip carrying the group's colour, its
/// own row of tabs, and a 2px underline in that colour running the width of
/// both — so it reads at a glance where one Project's tabs end and the next
/// begins, which the vertical dividers alone do not make obvious.
struct ProjectGroupStrip: View {
  @ObservedObject var workspace: ProjectWorkspaceModel
  let activeProjectID: UUID?
  @Binding var collapsedProjects: Set<UUID>
  let onSelectProject: (UUID) -> Void
  let onOpenProject: () -> Void
  let onRenameProject: (Project) -> Void

  var body: some View {
    ScrollView(.horizontal) {
      HStack(alignment: .center, spacing: 0) {
        ForEach(Array(workspace.projects.enumerated()), id: \.element.id) { index, project in
          if index > 0 {
            Rectangle()
              .fill(WorkspaceChrome.chromeLineSoft)
              .frame(width: 1, height: WorkspaceTitlebarMetrics.groupDividerHeight)
              .padding(.horizontal, 5)
          }
          ProjectTabGroup(
            workspace: workspace,
            project: project,
            isActive: project.id == activeProjectID,
            isCollapsed: collapsedProjects.contains(project.id),
            onToggleCollapsed: { toggleCollapsed(project.id) },
            onSelectProject: onSelectProject,
            onRenameProject: onRenameProject
          )
        }

        // New tab sits at the end of the strip, where every tabbed app puts
        // it — not among the window actions on the right.
        ChromeActionButton(help: "Projectフォルダを開く", action: onOpenProject) {
          Image(systemName: "plus")
            .font(.system(size: 10, weight: .semibold))
        }
        .padding(.leading, 6)
      }
      .frame(maxHeight: .infinity)
    }
    .scrollIndicators(.never)
    .background(HiddenScrollbarsInstaller())
    .frame(maxHeight: .infinity)
  }

  private func toggleCollapsed(_ projectID: UUID) {
    if collapsedProjects.contains(projectID) {
      collapsedProjects.remove(projectID)
    } else {
      collapsedProjects.insert(projectID)
    }
  }
}

struct ProjectTabGroup: View {
  @ObservedObject var workspace: ProjectWorkspaceModel
  let project: Project
  let isActive: Bool
  let isCollapsed: Bool
  let onToggleCollapsed: () -> Void
  let onSelectProject: (UUID) -> Void
  let onRenameProject: (Project) -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      chip

      if !isCollapsed, let surface = workspace.surface(for: project.id) {
        WorkspaceTabStrip(
          surface: surface,
          isProjectActive: isActive,
          onActivateProject: {
            if !isActive {
              onSelectProject(project.id)
            }
          }
        )
        .padding(.leading, 4)
      }
    }
    .frame(maxHeight: .infinity)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(project.color.workspaceAccent)
        .frame(height: 2)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 1, topTrailingRadius: 1))
    }
    .animation(.easeOut(duration: 0.09), value: isCollapsed)
  }

  /// The group's own pill. Its colour is the chip's fill and border rather
  /// than a separate round swatch, and a left click folds the group toward it
  /// — no disclosure glyph, because the chip itself is the toggle.
  private var chip: some View {
    Button(action: onToggleCollapsed) {
      Text(project.name)
        .font(WorkspaceChrome.chromeFont(size: 12, weight: .semibold))
        .lineLimit(1)
        .frame(maxWidth: 150, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: WorkspaceTitlebarMetrics.chipHeight)
        .background(chipFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(chipBorder, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .foregroundStyle(chipText)
    .help("\(project.name) タブグループを\(isCollapsed ? "展開" : "折りたたむ")")
    .accessibilityLabel("Project \(project.name)")
    .accessibilityValue(isCollapsed ? "折りたたみ" : "展開")
    .contextMenu { menu }
  }

  private var chipFill: Color {
    if project.color.isUncoloured {
      return isActive ? WorkspaceChrome.washSelected : .clear
    }
    return project.color.workspaceAccent.opacity(isActive ? 0.22 : 0.1)
  }

  private var chipBorder: Color {
    if project.color.isUncoloured {
      return isActive ? WorkspaceChrome.washStrongest : .clear
    }
    return project.color.workspaceAccent.opacity(isActive ? 0.55 : 0.28)
  }

  private var chipText: Color {
    if isActive {
      return WorkspaceChrome.chromeInk
    }
    return project.color.isUncoloured
      ? WorkspaceChrome.textQuaternary : WorkspaceChrome.textSecondary
  }

  private var groupColorBinding: Binding<ProjectColor> {
    Binding(
      get: { project.color },
      set: { color in
        _ = workspace.execute(
          .setProjectColor(
            SetProjectColorCommand(projectID: project.id, color: color)
          )
        )
      }
    )
  }

  @ViewBuilder
  private var menu: some View {
    if !isActive {
      Button("このProjectに切り替え") {
        onSelectProject(project.id)
      }
      Divider()
    }
    Button("Project名を変更") {
      onRenameProject(project)
    }
    Picker("グループカラー", selection: groupColorBinding) {
      ForEach(ProjectColor.allCases, id: \.self) { color in
        Text(color.displayName).tag(color)
      }
    }
    Divider()
    Button("Projectを上へ移動") {
      workspace.moveProject(id: project.id, by: -1)
    }
    Button("Projectを下へ移動") {
      workspace.moveProject(id: project.id, by: 1)
    }
    Divider()
    Button("Projectを閉じる", role: .destructive) {
      _ = workspace.execute(.closeProject(CloseProjectCommand(projectID: project.id)))
    }
  }
}

/// One Project's row of tabs. Tabs are a fixed 200px, left to right, and never
/// stretch: the row keeps a steady rhythm however long a file name is and
/// however many siblings are open, and a faint 1px seam — never a box —
/// separates one from the next. The active tab wears the pane's own colour, so
/// it reads as a hole through the chrome onto the surface below rather than a
/// marker painted on top of it. Anything that does not fit scrolls; the widths
/// do not give.
struct WorkspaceTabStrip: View {
  let surface: ProjectSurfaceModel
  let isProjectActive: Bool
  let onActivateProject: () -> Void
  @State private var pendingCloseTabID: String?

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(surface.visibleWorkspaceTabs.enumerated()), id: \.element.id) { index, item in
        if index > 0 {
          Rectangle()
            .fill(WorkspaceChrome.chromeLineSoft)
            .frame(width: 1, height: WorkspaceTitlebarMetrics.tabDividerHeight)
        }
        tabView(item)
      }
    }
    .frame(maxHeight: .infinity)
    .alert("未保存の変更を破棄しますか？", isPresented: pendingCloseIsPresented) {
      Button("キャンセル", role: .cancel) {
        pendingCloseTabID = nil
      }
      Button("破棄", role: .destructive) {
        guard let pendingCloseTabID else {
          return
        }
        self.pendingCloseTabID = nil
        surface.closeTab(id: pendingCloseTabID)
      }
    } message: {
      Text("エディタバッファにディスクへ保存していない変更があります。")
    }
  }

  private func tabView(_ item: ProjectWorkspaceTab) -> some View {
    let tab = item.tab
    let isActive = isProjectActive && surface.activeTabID == tab.id
    let tint = isActive ? WorkspaceChrome.chromeInk : WorkspaceChrome.textTertiary

    return Button {
      onActivateProject()
      surface.activateTab(id: tab.id)
    } label: {
      HStack(spacing: 7) {
        WorkspaceSurfaceIcon(kind: tab.kind, tint: tint)
        FadingLabel(text: tab.title, weight: isActive ? .semibold : .regular)
          .foregroundStyle(tint)
        statusMark(for: tab, isActive: isActive)
        // The close control is overlaid rather than nested — a Button inside
        // another Button's label never receives the click — so the label only
        // reserves the room it will occupy.
        if isActive {
          Color.clear
            .frame(width: 12, height: 12)
        }
      }
      .padding(.horizontal, 11)
      .frame(
        width: WorkspaceTitlebarMetrics.tabWidth,
        height: WorkspaceTitlebarMetrics.tabHeight
      )
      // The selected tab wears the pane's own colour, so it reads as a hole
      // through the chrome onto the surface below rather than a marker painted
      // on top of it.
      .background(
        isActive ? WorkspaceChrome.canvas : Color.clear,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    // Only the selected tab carries a close control. An × on every tab turns
    // the strip into a row of buttons; on one tab it is an action for the
    // thing you are already looking at.
    .overlay(alignment: .trailing) {
      if isActive {
        Button {
          requestClose(tab)
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(WorkspaceChrome.textTertiary)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 10)
        .help("閉じる")
        .accessibilityLabel("\(tab.title) を閉じる")
      }
    }
    .contextMenu {
      Button("タブを閉じる", role: .destructive) {
        requestClose(tab)
      }
    }
    .help("\(tab.title) · \(kindTitle(tab.kind))")
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(tab.title), \(kindTitle(tab.kind))")
    .accessibilityValue(isActive ? "アクティブ" : "非アクティブ")
  }

  /// The unsaved / running marker the Main artboard draws after the label.
  @ViewBuilder
  private func statusMark(for tab: ProjectPaneTab, isActive: Bool) -> some View {
    if tab.kind == .editor, surface.editorDocument(tabID: tab.id)?.isDirty == true {
      Circle()
        .fill(isActive ? WorkspaceChrome.textTertiary : WorkspaceChrome.textQuaternary)
        .frame(width: 6, height: 6)
        .accessibilityLabel("未保存")
    } else if let session = surface.terminalSession(tabID: tab.id) {
      Circle()
        .fill(
          sessionNeedsAttention(session)
            ? WorkspaceChrome.attention : WorkspaceChrome.terminalState(session.state)
        )
        .frame(width: 6, height: 6)
        .accessibilityLabel(session.statusDescription)
    }
  }

  private var pendingCloseIsPresented: Binding<Bool> {
    Binding(
      get: { pendingCloseTabID != nil },
      set: { isPresented in
        if !isPresented {
          pendingCloseTabID = nil
        }
      }
    )
  }

  private func kindTitle(_ kind: ProjectPaneTabKind) -> String {
    switch kind {
    case .editor:
      "エディタ"
    case .terminal:
      "ターミナル"
    case .diff:
      "差分"
    }
  }

  private func sessionNeedsAttention(_ session: TerminalSession) -> Bool {
    switch session.state {
    case .running, .idle:
      false
    case .starting, .stopping, .exited, .missing, .failed:
      true
    }
  }

  private func requestClose(_ tab: ProjectPaneTab) {
    if tab.kind == .editor, surface.editorDocument(tabID: tab.id)?.isDirty == true {
      pendingCloseTabID = tab.id
    } else {
      surface.closeTab(id: tab.id)
    }
  }
}

struct WorkspaceSurfaceIcon: View {
  let kind: ProjectPaneTabKind
  var tint: Color = WorkspaceChrome.textTertiary

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(tint)
      .frame(width: 12, height: 14)
      .accessibilityHidden(true)
  }

  private var symbol: String {
    switch kind {
    case .editor:
      "doc.text"
    case .terminal:
      "terminal"
    case .diff:
      "doc.on.doc"
    }
  }
}

// MARK: - Sidebar Strip

/// The navigation strip lives *inside* the sidebar rather than in a column of
/// its own — the Tokens artboard's chrome budget is what pays for that.
///
/// Search is deliberately absent: file and symbol search is the titlebar
/// field, so putting it here too would give one job two entry points. The
/// explorer, the first entry, has no underline: it is home, not a departure.
struct WorkspaceSidebarStrip: View {
  let selected: WorkspaceActivity?
  let onSelect: (WorkspaceActivity) -> Void
  let onQuickOpen: () -> Void

  var body: some View {
    HStack(spacing: 3) {
      HStack(spacing: 0) {
        ForEach(WorkspaceActivity.navigationCases) { activity in
          navButton(activity)
          if activity != WorkspaceActivity.navigationCases.last {
            Spacer(minLength: 0)
          }
        }
      }
      .frame(maxWidth: .infinity)

      ChromeActionButton(
        help: "その他",
        action: onQuickOpen,
        label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .medium))
        }
      )
    }
    .padding(.horizontal, 8)
    .frame(
      maxWidth: .infinity,
      minHeight: WorkspaceChrome.Metrics.sidebarStrip,
      maxHeight: WorkspaceChrome.Metrics.sidebarStrip
    )
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(WorkspaceChrome.chromeLineSoft)
        .frame(height: 1)
    }
  }

  private func navButton(_ activity: WorkspaceActivity) -> some View {
    ChromeActionButton(
      width: 38,
      height: 32,
      isActive: selected == activity,
      showsUnderline: activity != .files,
      help: activity.accessibilityHint,
      action: { onSelect(activity) },
      label: {
        Image(systemName: activity.symbolName)
          .font(.system(size: 15, weight: .medium))
      }
    )
  }

}
