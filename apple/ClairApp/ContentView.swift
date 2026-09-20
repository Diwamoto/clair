import AppKit
import CoreImage
import SwiftUI

enum WorkspaceOverlayKind: String, Identifiable {
  case command
  case settings
  case agents

  var id: String {
    rawValue
  }
}

private enum WorkspacePaletteMode: String, Equatable {
  case command
  case quickOpen
}

struct ContentView: View {
  let state: BootstrapState
  @ObservedObject var workspace: ProjectWorkspaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  @ObservedObject var worktreeCoordinator: ProjectWorktreeCoordinator
  @ObservedObject var mobileBridge: MobileControlRuntimeBridge
  @ObservedObject var updater: ClairUpdateCoordinator
  @ObservedObject var commandSurface: CommandSurfaceModel
  @ObservedObject var agentRateLimits: AgentRateLimitCoordinator

  @State private var overlay: WorkspaceOverlayKind?
  @State private var commandPaletteMode: WorkspacePaletteMode = .command
  @State private var pendingTabClose: ProjectTabCloseRequest?
  @State private var isLineJumpPresented = false
  @State private var lineJumpValue = ""
  @State private var renameProjectID: UUID?
  @State private var renameValue = ""
  @AppStorage("clair.workspace.sidebar-visible-v1") private var isSidebarVisible = true
  @AppStorage("clair.editor.font-size-v2") private var editorFontSize = 13.0
  @AppStorage("clair.editor.word-wrap-v1") private var editorWordWrap = false
  @AppStorage("clair.workspace.status-footer-v1") private var showStatusFooter = true
  @FocusState private var lineJumpFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      workspaceTitlebar

      contentBody
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(
      minWidth: 640,
      maxWidth: .infinity,
      minHeight: 520,
      maxHeight: .infinity,
      alignment: .topLeading
    )
    .ignoresSafeArea(.container, edges: .top)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if showStatusFooter,
        let project = workspace.activeProject,
        let surface = workspace.activeSurface
      {
        WorkspaceStatusBar(
          workspace: workspace,
          project: project,
          surface: surface,
          agentWorkflow: agentWorkflow,
          agentRateLimits: agentRateLimits,
          onOpenAgents: { openOverlay(.agents) }
        )
      }
    }
    .background(WorkspaceChrome.canvas)
    .background {
      ThinScrollbarsInstaller()
    }
    .preferredColorScheme(.dark)
    .alert("Project名を変更", isPresented: renameAlertIsPresented) {
      TextField("Project名", text: $renameValue)
      Button("キャンセル", role: .cancel) {
        cancelRename()
      }
      Button("変更") {
        confirmRename()
      }
    } message: {
      Text("Clairで表示する名前だけを変更します。ディスク上のフォルダ名は変わりません。")
    }
    .alert("Projectの操作に失敗しました", isPresented: errorAlertIsPresented) {
      Button("OK") {
        workspace.dismissError()
      }
    } message: {
      Text(workspace.lastErrorMessage ?? "Projectで不明なエラーが発生しました。")
    }
    .onAppear {
      migrateEditorFontSizePreference()
      workspace.materializeOpenSurfacesForTabBar()
      workspace.reattachRuntimeSessions()
      (NSApp.delegate as? ClairApplicationDelegate)?.disableWindowCloseShortcut()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .clairRequestCloseActiveTab)
    ) { _ in
      requestCloseActiveTab()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .clairKeyboardShortcut)
    ) { notification in
      guard
        let rawAction = notification.userInfo?["action"] as? String,
        let action = ClairKeyboardShortcutAction(rawValue: rawAction)
      else {
        return
      }
      handleKeyboardShortcut(
        action,
        value: notification.userInfo?["value"] as? String
      )
    }
    .onChange(of: workspace.requestedTabClose) { _, _ in
      guard let request = workspace.consumeRequestedTabClose() else {
        return
      }
      handleTabCloseRequest(request)
    }
    .alert("未保存の変更を破棄しますか？", isPresented: pendingTabCloseIsPresented) {
      Button("キャンセル", role: .cancel) {
        pendingTabClose = nil
      }
      Button("破棄", role: .destructive) {
        guard let request = pendingTabClose else {
          return
        }
        pendingTabClose = nil
        workspace.surface(for: request.projectID)?.closeTab(id: request.tabID)
      }
    } message: {
      Text("エディタバッファにディスクへ保存していない変更があります。")
    }
    .overlay {
      if overlay == .command {
        commandOverlay
      }
    }
    .overlay {
      if isLineJumpPresented {
        lineJumpOverlay
      }
    }
    .sheet(
      isPresented: Binding(
        get: { overlay == .agents },
        set: { isPresented in
          if !isPresented {
            overlay = nil
          }
        }
      )
    ) {
      if let project = workspace.activeProject, let surface = workspace.activeSurface {
        ProjectAgentView(
          project: project,
          workspace: workspace,
          surface: surface,
          agentWorkflow: agentWorkflow,
          worktreeCoordinator: worktreeCoordinator
        )
      }
    }
    .overlay(alignment: .bottomTrailing) {
      ClairUpdateNotice(updater: updater)
        .padding(12)
    }
  }

  // MARK: Titlebar, Activity Bar & Body

  private var workspaceTitlebar: some View {
    WorkspaceTitlebar(
      workspace: workspace,
      activeProjectID: workspace.activeProjectID,
      onOpenProject: openProject,
      onRenameProject: beginRename,
      onOpenCommand: { openCommandPalette(mode: .command) },
      onOpenSearch: {
        guard workspace.activeSurface != nil else {
          openProject()
          return
        }
        openCommandPalette(mode: .quickOpen)
      },
      onOpenSettings: {
        if overlay == .settings {
          dismissOverlay()
        } else {
          openOverlay(.settings)
        }
      },
      isSettingsActive: overlay == .settings
    )
  }

  private var activityBar: some View {
    WorkspaceActivityBar(
      selected: workspace.activeSurface?.workspaceActivity.navigationEntry,
      onSelect: { selection in
        if workspace.activeSurface != nil {
          workspace.activeSurface?.workspaceActivity = selection
          overlay = nil
        }
      },
      onQuickOpen: {
        guard workspace.activeSurface != nil else {
          openProject()
          return
        }
        openCommandPalette(mode: .quickOpen)
      }
    )
  }

  private var contentBody: some View {
    Group {
      if overlay == .settings {
        WorkspaceSettingsView(
          workspace: workspace,
          agentWorkflow: agentWorkflow,
          mobileBridge: mobileBridge,
          updater: updater,
          onDismiss: dismissOverlay
        )
      } else if let project = workspace.activeProject, let surface = workspace.activeSurface {
        workspaceSurface(project: project, surface: surface)
      } else {
        welcomeView
      }
    }
  }

  // The activity bar (navigation icon column) is mounted once here, outside
  // the per-tab `sidebarContent`/`mainContent` switches below. Switching
  // between tabs whose content views have different concrete types forces
  // SwiftUI to tear down and rebuild whatever is inside the switch; keeping
  // the nav column outside it means it is never rebuilt, so it can't
  // visibly jump when a tab (e.g. the bell/Activity tab) is selected. It
  // also sits outside `isSidebarVisible`: hiding the sidebar panel hides the
  // file tree etc., not the way to switch between them.
  private func workspaceSurface(project: Project, surface: ProjectSurfaceModel) -> some View {
    HStack(spacing: 0) {
      activityBar

      if isSidebarVisible {
        sidebarContent(project: project, surface: surface)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .frame(
            minWidth: 160,
            idealWidth: WorkspaceChrome.Metrics.sidebarWidth,
            maxWidth: 296,
            maxHeight: .infinity,
            alignment: .topLeading
          )
          .background(WorkspaceChrome.chrome)
          .overlay(alignment: .trailing) {
            Rectangle()
              .fill(WorkspaceChrome.chromeLine)
              .frame(width: 1)
          }
      }

      mainContent(project: project, surface: surface)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WorkspaceChrome.canvas)
    .alert("エディタの操作に失敗しました", isPresented: editorErrorIsPresented(surface)) {
      Button("OK") {
        surface.dismissEditorError()
      }
    } message: {
      Text(surface.lastEditorErrorMessage ?? "エディタで不明なエラーが発生しました。")
    }
    .alert("Projectの移動に失敗しました", isPresented: navigationErrorIsPresented(surface)) {
      Button("OK") {
        surface.dismissNavigationError()
      }
    } message: {
      Text(surface.lastNavigationErrorMessage ?? "Projectの移動で不明なエラーが発生しました。")
    }
    .alert("Git操作に失敗しました", isPresented: gitErrorIsPresented(surface)) {
      Button("OK") {
        surface.dismissGitError()
      }
    } message: {
      Text(surface.lastGitErrorMessage ?? "Gitで不明なエラーが発生しました。")
    }
    .alert("Agentワークフローに失敗しました", isPresented: agentErrorIsPresented) {
      Button("OK") {
        agentWorkflow.clearError()
      }
    } message: {
      Text(agentWorkflow.lastErrorMessage ?? "Agentワークフローで不明なエラーが発生しました。")
    }
  }

  @ViewBuilder
  private func sidebarContent(project: Project, surface: ProjectSurfaceModel) -> some View {
    switch surface.workspaceActivity {
    case .files:
      ProjectFileTreeView(surface: surface, onOpenProject: openProject)
    case .search:
      ProjectSearchView(surface: surface, onDismiss: selectFilesActivity)
    case .git:
      ProjectGitView(
        workspace: workspace,
        projectID: project.id,
        surface: surface,
        onDismiss: selectFilesActivity
      )
    case .review:
      ProjectBranchReviewView(
        project: project,
        surface: surface,
        agentWorkflow: agentWorkflow,
        worktreeCoordinator: worktreeCoordinator,
        onDismiss: selectFilesActivity
      )
    case .debug:
      ProjectDebugSidebarView(session: surface.debugSession)
    case .activity:
      ProjectActivityView(
        project: project,
        workspace: workspace,
        surface: surface,
        agentWorkflow: agentWorkflow,
        onOpenAgents: { openOverlay(.agents) }
      )
    }
  }

  @ViewBuilder
  private func mainContent(project: Project, surface: ProjectSurfaceModel) -> some View {
    switch surface.workspaceActivity {
    case .files, .search:
      editorPane(project: project, surface: surface)
    case .git, .review:
      // 変更を確認 is one tool with two modes, the way a git GUI keeps history
      // inside its source-control tool rather than beside it. The switch lives
      // in the tool's own header, not in the sidebar strip.
      VStack(spacing: 0) {
        MainHeader {
          ChromeModeTabs(
            modes: [(.git, "変更"), (.review, "レビュー")],
            selection: sourceControlMode(surface)
          )
          if surface.workspaceActivity == .git, let status = surface.gitStatus,
            status.isRepository
          {
            Text("\(status.stagedCount) / \(status.changes.count) files staged")
              .font(WorkspaceChrome.chromeFont(size: 10))
              .monospaced()
              .foregroundStyle(WorkspaceChrome.textMuted)
          }
          Spacer(minLength: 0)
        }
        if surface.workspaceActivity == .git {
          ProjectDiffPreview(surface: surface, onOpenInEditor: selectFilesActivity)
        } else {
          editorPane(project: project, surface: surface)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .debug:
      VStack(spacing: 0) {
        MainHeader {
          DebugControlToolbar(session: surface.debugSession)
          Spacer(minLength: 0)
        }
        ZStack {
          editorPane(project: project, surface: surface)
          if !surface.debugSession.state.isActive,
            surface.debugSession.currentLocation == nil
          {
            DebugStartCard(session: surface.debugSession)
          }
        }
        DebugConsoleView(session: surface.debugSession)
          .frame(minHeight: 120, idealHeight: 164, maxHeight: 260)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear {
        if let location = surface.debugSession.currentLocation {
          surface.revealDebugLocation(location)
        }
      }
      .onChange(of: surface.debugSession.currentLocation) { _, location in
        guard let location else { return }
        surface.revealDebugLocation(location)
      }
    case .activity:
      ProjectActivityDetailView(
        project: project,
        workspace: workspace,
        surface: surface,
        agentWorkflow: agentWorkflow,
        onOpenAgents: { openOverlay(.agents) }
      )
    }
  }

  private func sourceControlMode(_ surface: ProjectSurfaceModel) -> Binding<WorkspaceActivity> {
    Binding(
      get: { surface.workspaceActivity == .review ? .review : .git },
      set: { surface.workspaceActivity = $0 }
    )
  }

  private func editorErrorIsPresented(_ surface: ProjectSurfaceModel) -> Binding<Bool> {
    Binding(
      get: { surface.lastEditorErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          surface.dismissEditorError()
        }
      }
    )
  }

  private func navigationErrorIsPresented(_ surface: ProjectSurfaceModel) -> Binding<Bool> {
    Binding(
      get: { surface.lastNavigationErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          surface.dismissNavigationError()
        }
      }
    )
  }

  private func gitErrorIsPresented(_ surface: ProjectSurfaceModel) -> Binding<Bool> {
    Binding(
      get: { surface.lastGitErrorMessage != nil && workspace.lastErrorMessage == nil },
      set: { isPresented in
        if !isPresented {
          surface.dismissGitError()
        }
      }
    )
  }

  private var agentErrorIsPresented: Binding<Bool> {
    Binding(
      get: { agentWorkflow.lastErrorMessage != nil && workspace.lastErrorMessage == nil },
      set: { isPresented in
        if !isPresented {
          agentWorkflow.clearError()
        }
      }
    )
  }

  private func editorPane(project: Project, surface: ProjectSurfaceModel) -> some View {
    ProjectPaneLayoutView(
      state: state,
      project: project,
      surface: surface,
      node: surface.visibleLayout,
      fontSize: editorFontSize,
      wordWrap: editorWordWrap
    )
  }

  private func selectFilesActivity() {
    workspace.activeSurface?.workspaceActivity = .files
  }

  /// The scrim the AddAgent artboard defines for an overlay over the
  /// workspace: the window hangs from the top rather than sitting centred, so
  /// the list can grow downward without the panel jumping.
  private var commandOverlay: some View {
    WorkspaceChrome.overlayGround.opacity(0.68)
      .ignoresSafeArea()
      .onTapGesture {
        overlay = nil
      }
      .overlay(alignment: .top) {
        WorkspaceCommandPalette(
          surface: commandSurface,
          mode: $commandPaletteMode,
          onDismiss: dismissOverlay
        )
        .frame(maxWidth: 560, maxHeight: 520)
        .background(WorkspaceChrome.chromeRaised)
        .clipShape(
          RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.overlay, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.overlay, style: .continuous)
            .stroke(WorkspaceChrome.borderStrong, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.62), radius: 24, y: 18)
        .padding(.horizontal, 12)
        .padding(.top, WorkspaceChrome.Metrics.mainHeader)
      }
  }

  private var lineJumpOverlay: some View {
    WorkspaceChrome.overlayGround.opacity(0.68)
      .ignoresSafeArea()
      .onTapGesture {
        dismissLineJump()
      }
      .overlay {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 4) {
            Text("行へ移動")
              .font(WorkspaceChrome.chromeFont(size: 15, weight: .semibold))
            Text("行番号、または行番号:列番号を入力")
              .font(WorkspaceChrome.chromeFont(size: 10))
              .foregroundStyle(WorkspaceChrome.textTertiary)
          }

          TextField("例: 42 または 42:8", text: $lineJumpValue)
            .textFieldStyle(.roundedBorder)
            .focused($lineJumpFocused)
            .onSubmit {
              jumpToLine()
            }

          HStack {
            Spacer()
            Button("キャンセル") {
              dismissLineJump()
            }
            .buttonStyle(.bordered)
            Button("移動") {
              jumpToLine()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
          }
        }
        .padding(18)
        .frame(width: 340)
        .background(WorkspaceChrome.chromeRaised)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(WorkspaceChrome.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
      }
      .onAppear {
        lineJumpFocused = true
      }
  }

  // MARK: Helpers

  private func openCommandPalette(mode: WorkspacePaletteMode) {
    commandPaletteMode = mode
    overlay = .command
  }

  private func openOverlay(_ kind: WorkspaceOverlayKind) {
    overlay = kind
  }

  private func dismissOverlay() {
    overlay = nil
  }

  private func handleKeyboardShortcut(
    _ action: ClairKeyboardShortcutAction,
    value: String?
  ) {
    switch action {
    case .quickOpen:
      guard workspace.activeSurface != nil else {
        openProject()
        return
      }
      openCommandPalette(mode: .quickOpen)
    case .commandPalette:
      openCommandPalette(mode: .command)
    case .find, .replace, .showSearch:
      guard let surface = workspace.activeSurface else {
        return
      }
      overlay = nil
      surface.workspaceActivity = .search
    case .goToLine:
      guard workspace.activeSurface?.activeTab != nil else {
        return
      }
      lineJumpValue = ""
      isLineJumpPresented = true
    case .toggleSidebar:
      isSidebarVisible.toggle()
    case .toggleTerminal:
      guard let surface = workspace.activeSurface else {
        return
      }
      if surface.isTerminalVisible {
        surface.hideTerminal()
      } else {
        surface.showTerminal()
      }
    case .splitEditor:
      workspace.activeSurface?.splitFocusedPane(orientation: .horizontal)
    case .previousTab:
      workspace.activeSurface?.activateAdjacentTab(direction: -1)
    case .nextTab:
      workspace.activeSurface?.activateAdjacentTab(direction: 1)
    case .focusGroup:
      guard let value, let group = Int(value), group > 0 else {
        return
      }
      workspace.activeSurface?.focusPane(at: group - 1)
    case .showExplorer:
      workspace.activeSurface?.workspaceActivity = .files
      overlay = nil
    case .showSourceControl:
      workspace.activeSurface?.workspaceActivity = .git
      overlay = nil
    case .toggleWordWrap:
      editorWordWrap.toggle()
    case .saveAll:
      workspace.saveAll()
    case .zoomIn:
      editorFontSize = min(editorFontSize + 1, 48)
    case .zoomOut:
      editorFontSize = max(editorFontSize - 1, 8)
    case .resetZoom:
      editorFontSize = 13
    case .openSettings:
      openOverlay(.settings)
    case .copyActiveFilePath:
      guard let fileURL = workspace.activeSurface?.activeTab?.url else {
        return
      }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(fileURL.path, forType: .string)
    case .revealActiveFile:
      guard let fileURL = workspace.activeSurface?.activeTab?.url else {
        return
      }
      NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
  }

  private func jumpToLine() {
    let value = lineJumpValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard
      let line = components.first.flatMap({ Int($0) }),
      line > 0,
      components.count <= 2
    else {
      return
    }
    let column = components.count == 2 ? Int(components[1]) ?? 0 : 1
    guard column > 0, let document = workspace.activeSurface?.activeTab else {
      return
    }
    document.requestSelection(line: line, column: column, length: 0)
    dismissLineJump()
  }

  private func dismissLineJump() {
    lineJumpFocused = false
    isLineJumpPresented = false
    lineJumpValue = ""
  }

  private func migrateEditorFontSizePreference() {
    let defaults = UserDefaults.standard
    let newKey = "clair.editor.font-size-v2"
    guard defaults.object(forKey: newKey) == nil,
      let legacyValue = defaults.object(forKey: "clair.editor.font-size-v1") as? NSNumber
    else {
      return
    }

    let value = legacyValue.doubleValue
    editorFontSize = abs(value - 14.5) < 0.001 ? 13.0 : value
  }

  private var pendingTabCloseIsPresented: Binding<Bool> {
    Binding(
      get: { pendingTabClose != nil },
      set: { isPresented in
        if !isPresented {
          pendingTabClose = nil
        }
      }
    )
  }

  private func requestCloseActiveTab() {
    workspace.requestCloseActiveTab()
  }

  private func handleTabCloseRequest(_ request: ProjectTabCloseRequest) {
    guard
      let surface = workspace.surface(for: request.projectID),
      let tab = surface.workspaceTabs.first(where: { $0.tab.id == request.tabID })?.tab
    else {
      return
    }

    if tab.kind == .editor, surface.editorDocument(tabID: tab.id)?.isDirty == true {
      pendingTabClose = request
    } else {
      surface.closeTab(id: tab.id)
    }
  }

  private var welcomeView: some View {
    VStack(spacing: 12) {
      ChromeEmptyState(
        symbol: "folder.badge.plus",
        title: "Projectフォルダを開く",
        message: "Gitリポジトリと通常のローカルフォルダに対応しています。"
      )
      Button(action: openProject) {
        Text("フォルダを開く…")
          .font(WorkspaceChrome.chromeFont(size: 11, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
          .padding(.horizontal, 14)
          .frame(height: 26)
          .background(
            WorkspaceChrome.surfaceActive,
            in: RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.control, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.control, style: .continuous)
              .stroke(WorkspaceChrome.borderStronger, lineWidth: 1)
          }
      }
      .buttonStyle(.plain)
      .keyboardShortcut("o", modifiers: [.command])
    }
    .frame(maxWidth: 320)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WorkspaceChrome.canvas)
  }

  private func openProject() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Projectを開く"

    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }

    _ = workspace.execute(.openProject(OpenProjectCommand(rootURL: url)))
  }

  private var renameAlertIsPresented: Binding<Bool> {
    Binding(
      get: { renameProjectID != nil },
      set: { isPresented in
        if !isPresented {
          cancelRename()
        }
      }
    )
  }

  private var errorAlertIsPresented: Binding<Bool> {
    Binding(
      get: { workspace.lastErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          workspace.dismissError()
        }
      }
    )
  }

  private func beginRename(_ project: Project) {
    renameProjectID = project.id
    renameValue = project.name
  }

  private func cancelRename() {
    renameProjectID = nil
    renameValue = ""
  }

  private func confirmRename() {
    guard let projectID = renameProjectID else {
      return
    }
    _ = workspace.execute(
      .renameProject(
        RenameProjectCommand(projectID: projectID, name: renameValue)
      )
    )
    cancelRename()
  }
}
private struct ProjectActivityDetailView: View {
  let project: Project
  @ObservedObject var workspace: ProjectWorkspaceModel
  @ObservedObject var surface: ProjectSurfaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  let onOpenAgents: () -> Void

  private var latestActivity: AgentActivity? {
    agentWorkflow.activities(for: project.id).max { $0.occurredAt < $1.occurredAt }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Agents")
            .font(WorkspaceChrome.chromeFont(size: 14, weight: .semibold))
          Text("ターミナルの通知とプロセスの状態")
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.textTertiary)
        }
        Spacer()
        Button("Agentを追加", action: onOpenAgents)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
      }
      .padding(16)

      Divider()
        .background(WorkspaceChrome.border)

      if let latestActivity {
        activityDetail(latestActivity)
      } else {
        VStack(spacing: 10) {
          Image(systemName: "bell")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
          Text("アクティビティはまだありません")
            .font(WorkspaceChrome.chromeFont(size: 13, weight: .semibold))
          Text("ターミナルのシグナルがここに表示されます。")
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.textTertiary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
      }
    }
    .foregroundStyle(WorkspaceChrome.textPrimary)
    .background(WorkspaceChrome.canvas)
  }

  private func activityDetail(_ activity: AgentActivity) -> some View {
    let session = activity.sessionID.flatMap { sessionID in
      agentWorkflow.sessions.first { $0.id == sessionID }
    }
    return ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 12) {
          Image(systemName: activityIcon(for: activity))
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(
              activity.shouldNotify ? WorkspaceChrome.attention : WorkspaceChrome.success
            )
            .frame(width: 38, height: 38)
            .background(WorkspaceChrome.surfaceActive, in: RoundedRectangle(cornerRadius: 8))
          VStack(alignment: .leading, spacing: 3) {
            Text(activityState(for: activity))
              .font(WorkspaceChrome.chromeFont(size: 9, weight: .bold))
              .foregroundStyle(WorkspaceChrome.textTertiary)
            Text(activityTitle(for: activity))
              .font(WorkspaceChrome.chromeFont(size: 14, weight: .semibold))
          }
        }

        if let summary = activity.summary {
          Text(summary)
            .font(WorkspaceChrome.chromeFont(size: 12))
            .foregroundStyle(WorkspaceChrome.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 0) {
          detailRow(label: "Project", value: project.name)
          detailRow(label: "シグナル", value: activity.source.displayName)
          detailRow(label: "種類", value: activity.kind.displayName)
          detailRow(
            label: "発生時刻",
            value: activity.occurredAt.formatted(date: .abbreviated, time: .shortened)
          )
          detailRow(label: "トランスクリプト", value: "保存していません")
          if let session {
            detailRow(label: "ターミナル", value: session.agent.cwd)
          }
        }
        .padding(12)
        .background(WorkspaceChrome.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .stroke(WorkspaceChrome.border, lineWidth: 1)
        }

        if let session {
          Button {
            workspace.revealTerminal(
              projectID: session.projectID,
              tabID: session.terminalTabID
            )
            surface.workspaceActivity = .files
          } label: {
            Label("ターミナルを開く", systemImage: "terminal")
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .frame(maxWidth: 620, alignment: .leading)
      .padding(24)
    }
  }

  private func detailRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(WorkspaceChrome.chromeFont(size: 10, weight: .medium))
        .foregroundStyle(WorkspaceChrome.textTertiary)
        .frame(width: 72, alignment: .leading)
      Text(value)
        .font(WorkspaceChrome.chromeFont(size: 10))
        .foregroundStyle(WorkspaceChrome.textSecondary)
        .lineLimit(2)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
  }

  private func activityState(for activity: AgentActivity) -> String {
    activity.shouldNotify ? "入力待ち" : "記録済み"
  }

  private func activityTitle(for activity: AgentActivity) -> String {
    switch activity.source {
    case .bell:
      "ターミナルの注意ベル"
    case .exit:
      activity.exitStatus == 0 ? "Agentが正常終了" : "Agentがエラー終了"
    case .officialHook:
      "公式フック: \(activity.kind.rawValue)"
    }
  }

  private func activityIcon(for activity: AgentActivity) -> String {
    switch activity.source {
    case .bell:
      "bell"
    case .exit:
      activity.exitStatus == 0 ? "checkmark.circle" : "xmark.circle"
    case .officialHook:
      "link"
    }
  }
}

// MARK: - Workspace Titlebar

private enum WorkspaceTitlebarMetrics {
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
private struct WorkspaceTitlebar: View {
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
private struct WindowZoomDoubleClickHandler: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowZoomDoubleClickView {
    WindowZoomDoubleClickView()
  }

  func updateNSView(_ nsView: WindowZoomDoubleClickView, context: Context) {}

  static func dismantleNSView(_ nsView: WindowZoomDoubleClickView, coordinator: ()) {
    nsView.stopMonitoring()
  }
}

@MainActor
private final class WindowZoomDoubleClickView: NSView {
  private var eventMonitor: Any?
  private var windowObservers: [NSObjectProtocol] = []
  private var trafficLightLayoutPending = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopMonitoring()

    guard let window else { return }
    startWindowObservers(window)
    scheduleTrafficLightLayout()
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
    scheduleTrafficLightLayout()
  }

  func stopMonitoring() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    windowObservers.forEach(NotificationCenter.default.removeObserver)
    windowObservers = []
    trafficLightLayoutPending = false
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
          self?.scheduleTrafficLightLayout()
        }
      }
    }
  }

  private func scheduleTrafficLightLayout() {
    guard window != nil, !trafficLightLayoutPending else {
      return
    }

    trafficLightLayoutPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }
      self.trafficLightLayoutPending = false
      guard let window = self.window else {
        return
      }
      self.layoutTrafficLights(in: window)
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
      let targetOrigin = NSPoint(
        x: button.frame.origin.x,
        y: originInSuper.y - button.frame.height / 2
      )
      guard abs(button.frame.minY - targetOrigin.y) > 0.25 else {
        continue
      }
      button.setFrameOrigin(targetOrigin)
    }
  }
}

private struct WorkspaceCommandPalette: View {
  @ObservedObject var surface: CommandSurfaceModel
  @Binding var mode: WorkspacePaletteMode
  let onDismiss: () -> Void

  @State private var query = ""
  @State private var selectedIndex = 0
  @FocusState private var searchFocused: Bool

  private var commandMatches: [CommandSurfaceMatch] {
    surface.matches(for: query)
  }

  private var quickOpenItems: [ProjectQuickOpenItem] {
    surface.workspace.activeSurface?.quickOpenResults ?? []
  }

  private var resultCount: Int {
    mode == .command ? commandMatches.count : quickOpenItems.count
  }

  var body: some View {
    VStack(spacing: 0) {
      // The overlay header: title and hint on one line, so the window opens at
      // 44px rather than spending a second row on the subtitle.
      HStack(spacing: 9) {
        Image(systemName: mode == .command ? "command" : "doc.text")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(WorkspaceChrome.textTertiary)
        Text(mode == .command ? "コマンド" : "ファイルへ移動")
          .font(WorkspaceChrome.chromeFont(size: 13, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
        Text(mode == .command ? "Command Registryの全操作" : "Project内のファイル")
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)
        Spacer(minLength: 0)
        Button(action: onDismiss) {
          Text("esc")
            .font(WorkspaceChrome.chromeFont(size: 9, weight: .semibold))
            .monospaced()
            .foregroundStyle(WorkspaceChrome.textQuaternary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(WorkspaceChrome.panel, in: RoundedRectangle(cornerRadius: 3))
            .overlay {
              RoundedRectangle(cornerRadius: 3)
                .stroke(WorkspaceChrome.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 14)
      .frame(height: WorkspaceChrome.Metrics.mainHeader)
      .overlay(alignment: .bottom) {
        Rectangle().fill(WorkspaceChrome.hairline).frame(height: 1)
      }

      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(WorkspaceChrome.textTertiary)
        TextField(
          mode == .command ? "コマンドを検索" : "ファイル名で検索",
          text: $query
        )
        .textFieldStyle(.plain)
        .font(WorkspaceChrome.chromeFont(size: 14))
        .focused($searchFocused)
        .onSubmit {
          runSelected()
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .return]) { keyPress in
          guard keyPress.modifiers.isEmpty else {
            return .ignored
          }
          if keyPress.key == .upArrow {
            moveSelection(.up)
          } else if keyPress.key == .downArrow {
            moveSelection(.down)
          } else if keyPress.key == .return {
            runSelected()
          } else {
            return .ignored
          }
          return .handled
        }
        Text("\(resultCount) 件")
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)
      }
      .padding(.horizontal, 11)
      .frame(height: 40)
      .background(WorkspaceChrome.canvas, in: RoundedRectangle(cornerRadius: 5))
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .stroke(WorkspaceChrome.borderStronger, lineWidth: 1)
      }
      .padding(.horizontal, 12)
      .padding(.top, 10)
      .padding(.bottom, 8)

      ScrollView {
        LazyVStack(spacing: 2) {
          resultList
        }
        .id(mode.rawValue)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
      }
      .frame(maxHeight: .infinity)

      Rectangle().fill(WorkspaceChrome.hairline).frame(height: 1)

      HStack(spacing: 12) {
        Button("コマンド") {
          switchMode(.command)
        }
        .buttonStyle(.tactile)
        .foregroundStyle(
          mode == .command ? WorkspaceChrome.textPrimary : WorkspaceChrome.textTertiary
        )
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(
          mode == .command ? WorkspaceChrome.surfaceActive : Color.clear,
          in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )

        Button("ファイルへ移動") {
          switchMode(.quickOpen)
        }
        .buttonStyle(.tactile)
        .foregroundStyle(
          mode == .quickOpen ? WorkspaceChrome.textPrimary : WorkspaceChrome.textTertiary
        )
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(
          mode == .quickOpen ? WorkspaceChrome.surfaceActive : Color.clear,
          in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )

        Rectangle()
          .fill(WorkspaceChrome.border)
          .frame(width: 1, height: 14)

        Button("↑") {
          moveSelection(.up)
        }
        .buttonStyle(.tactile)
        .frame(width: 22, height: 20)
        .background(
          WorkspaceChrome.canvas,
          in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(WorkspaceChrome.border, lineWidth: 1)
        }

        Button("↓") {
          moveSelection(.down)
        }
        .buttonStyle(.tactile)
        .frame(width: 22, height: 20)
        .background(
          WorkspaceChrome.canvas,
          in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(WorkspaceChrome.border, lineWidth: 1)
        }

        Text("↵ 選択中を実行")
      }
      .font(WorkspaceChrome.chromeFont(size: 9))
      .foregroundStyle(WorkspaceChrome.textQuaternary)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .trailing) {
        Text("⌘P")
          .font(WorkspaceChrome.chromeFont(size: 9))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .padding(.trailing, 14)
      }
    }
    .foregroundStyle(WorkspaceChrome.textPrimary)
    .frame(minWidth: 420, minHeight: 360)
    .onExitCommand(perform: onDismiss)
    .onMoveCommand { direction in
      moveSelection(direction)
    }
    .onAppear {
      searchFocused = true
      refreshQuickOpenResults()
    }
    .onChange(of: query) { _, _ in
      selectedIndex = 0
      refreshQuickOpenResults()
    }
    .onChange(of: mode) { _, _ in
      query = ""
      selectedIndex = 0
      searchFocused = true
      refreshQuickOpenResults()
    }
  }

  @ViewBuilder
  private var resultList: some View {
    if mode == .command {
      if commandMatches.isEmpty {
        emptyResult(message: "コマンドが見つかりません")
      } else {
        ForEach(Array(commandMatches.enumerated()), id: \.offset) { index, match in
          commandRow(match, index: index)
        }
      }
    } else if surface.workspace.activeSurface?.quickOpenIsLoading == true {
      ProgressView("ファイルを検索中…")
        .font(WorkspaceChrome.chromeFont(size: 11))
        .frame(maxWidth: .infinity, minHeight: 82)
    } else if quickOpenItems.isEmpty {
      emptyResult(message: "ファイルが見つかりません")
    } else {
      ForEach(Array(quickOpenItems.enumerated()), id: \.offset) { index, item in
        quickOpenRow(item, index: index)
      }
    }
  }

  private func emptyResult(message: String) -> some View {
    Text(message)
      .font(WorkspaceChrome.chromeFont(size: 11))
      .foregroundStyle(WorkspaceChrome.textTertiary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(18)
  }

  private func commandRow(_ match: CommandSurfaceMatch, index: Int) -> some View {
    Button {
      run(match)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: symbol(for: match.descriptor.risk))
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(color(for: match.descriptor.risk))
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(match.descriptor.title)
            .font(WorkspaceChrome.chromeFont(size: 12, weight: .medium))
            .lineLimit(1)
          Text(match.availability.isAvailable ? match.descriptor.id.rawValue : match.statusText)
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if let shortcut = match.shortcut {
          Text(shortcut.displayName)
            .font(WorkspaceChrome.chromeFont(size: 9, weight: .medium))
            .foregroundStyle(WorkspaceChrome.textTertiary)
        }
      }
      .padding(.horizontal, 9)
      .frame(height: 40)
      .contentShape(Rectangle())
    }
    .buttonStyle(.tactile)
    .foregroundStyle(
      match.availability.isAvailable
        ? WorkspaceChrome.textSecondary : WorkspaceChrome.textQuaternary
    )
    .disabled(!match.availability.isAvailable)
    .help(match.statusText)
    .background(
      selectedIndex == index ? WorkspaceChrome.surfaceActive : Color.clear,
      in: RoundedRectangle(cornerRadius: 5, style: .continuous)
    )
    .overlay {
      if selectedIndex == index {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(WorkspaceChrome.borderStronger, lineWidth: 1)
      }
    }
    .onHover {
      if $0 {
        selectedIndex = index
      }
    }
  }

  private func quickOpenRow(_ item: ProjectQuickOpenItem, index: Int) -> some View {
    Button {
      run(item)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "doc.text")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(WorkspaceChrome.textTertiary)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.title)
            .font(WorkspaceChrome.chromeFont(size: 12, weight: .medium))
            .lineLimit(1)
          Text(item.relativePath)
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
      }
      .padding(.horizontal, 9)
      .frame(height: 40)
      .contentShape(Rectangle())
    }
    .buttonStyle(.tactile)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(
      selectedIndex == index ? WorkspaceChrome.surfaceActive : Color.clear,
      in: RoundedRectangle(cornerRadius: 5, style: .continuous)
    )
    .overlay {
      if selectedIndex == index {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(WorkspaceChrome.borderStronger, lineWidth: 1)
      }
    }
    .onHover {
      if $0 {
        selectedIndex = index
      }
    }
  }

  private func moveSelection(_ direction: MoveCommandDirection) {
    guard resultCount > 0 else {
      return
    }
    switch direction {
    case .up:
      selectedIndex = max(0, selectedIndex - 1)
    case .down:
      selectedIndex = min(resultCount - 1, selectedIndex + 1)
    default:
      break
    }
  }

  private func runSelected() {
    guard selectedIndex >= 0, selectedIndex < resultCount else {
      return
    }
    if mode == .command {
      run(commandMatches[selectedIndex])
    } else {
      run(quickOpenItems[selectedIndex])
    }
  }

  private func run(_ match: CommandSurfaceMatch) {
    guard match.availability.isAvailable else {
      return
    }
    _ = surface.invoke(commandID: match.id, source: .commandWindow)
    onDismiss()
  }

  private func run(_ item: ProjectQuickOpenItem) {
    guard let activeSurface = surface.workspace.activeSurface else {
      return
    }
    activeSurface.openQuickOpenItem(item)
    if activeSurface.lastNavigationErrorMessage == nil {
      onDismiss()
    }
  }

  private func switchMode(_ nextMode: WorkspacePaletteMode) {
    guard mode != nextMode else {
      return
    }
    mode = nextMode
  }

  private func refreshQuickOpenResults() {
    guard mode == .quickOpen, let activeSurface = surface.workspace.activeSurface else {
      return
    }
    activeSurface.requestQuickOpenItems(matching: query)
  }

  private func symbol(for risk: CommandRisk) -> String {
    switch risk {
    case .read:
      "eye"
    case .additive:
      "plus"
    case .write:
      "pencil"
    case .destructive:
      "trash"
    case .external:
      "arrow.up.right"
    }
  }

  private func color(for risk: CommandRisk) -> Color {
    switch risk {
    case .read:
      WorkspaceChrome.textTertiary
    case .additive:
      WorkspaceChrome.success
    case .write:
      WorkspaceChrome.attention
    case .destructive:
      WorkspaceChrome.danger
    case .external:
      WorkspaceChrome.accent
    }
  }
}

// MARK: - Project Groups and Tabs

/// Every open Project's tab group, laid out left to right the way Chrome lays
/// out tab groups: each Project owns a chip carrying the group's colour, its
/// own row of tabs, and a 2px underline in that colour running the width of
/// both — so it reads at a glance where one Project's tabs end and the next
/// begins, which the vertical dividers alone do not make obvious.
private struct ProjectGroupStrip: View {
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

private struct ProjectTabGroup: View {
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
    Button(action: activateOrToggle) {
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
    .help(
      isActive
        ? "\(project.name) タブグループを\(isCollapsed ? "展開" : "折りたたむ")"
        : "\(project.name) Projectに切り替える"
    )
    .accessibilityLabel("Project \(project.name)")
    .accessibilityValue(isCollapsed ? "折りたたみ" : "展開")
    .contextMenu { menu }
  }

  private func activateOrToggle() {
    if isActive {
      onToggleCollapsed()
    } else {
      onSelectProject(project.id)
    }
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
    Menu("グループカラー") {
      ForEach(ProjectColor.allCases, id: \.self) { color in
        Button {
          _ = workspace.execute(
            .setProjectColor(
              SetProjectColorCommand(projectID: project.id, color: color)
            )
          )
        } label: {
          Label(
            color.displayName,
            systemImage: project.color == color ? "checkmark" : "circle.fill"
          )
        }
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
private struct WorkspaceTabStrip: View {
  @ObservedObject var surface: ProjectSurfaceModel
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
    .hoverableRow(isSelected: isActive, selectedColor: WorkspaceChrome.canvas, cornerRadius: 8)
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

private struct WorkspaceSurfaceIcon: View {
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
/// field, so putting it here too would give one job two entry points. A
/// full-height column to the left of the sidebar panel, not a row nested
/// inside it — icons read bigger (20pt) now that they own a whole column
/// instead of sharing a 34px-tall strip with the "その他" action.
private struct WorkspaceActivityBar: View {
  let selected: WorkspaceActivity?
  let onSelect: (WorkspaceActivity) -> Void
  let onQuickOpen: () -> Void

  var body: some View {
    VStack(spacing: 2) {
      ForEach(WorkspaceActivity.navigationCases) { activity in
        navButton(activity)
      }

      Spacer(minLength: 0)

      ChromeActionButton(
        width: 36,
        height: 36,
        help: "その他",
        action: onQuickOpen,
        label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 14, weight: .medium))
        }
      )
    }
    .padding(.vertical, 8)
    .frame(
      width: WorkspaceChrome.Metrics.activityBarWidth,
      maxHeight: .infinity
    )
    .background(WorkspaceChrome.chrome)
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(WorkspaceChrome.chromeLineSoft)
        .frame(width: 1)
    }
  }

  private func navButton(_ activity: WorkspaceActivity) -> some View {
    ChromeActionButton(
      width: 36,
      height: 36,
      isActive: selected == activity,
      help: activity.accessibilityHint,
      action: { onSelect(activity) },
      label: {
        Image(systemName: activity.symbolName)
          .font(.system(size: 18, weight: .medium))
      }
    )
  }

}

// MARK: - Status Bar

/// The one status bar, 26px tall. Branch and working-tree state on the left,
/// then the screen's own context, then the tightest agent's quota — which the
/// Settings artboard makes a preference — and the session count.
private struct WorkspaceStatusBar: View {
  let workspace: ProjectWorkspaceModel
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  @ObservedObject var agentRateLimits: AgentRateLimitCoordinator
  let onOpenAgents: () -> Void
  @AppStorage("clair.agents.show-rate-limits-v1") private var showRateLimits = true

  var body: some View {
    HStack(spacing: 10) {
      branchState
      screenContext

      Spacer(minLength: 8)

      if showRateLimits {
        AgentRateLimitStrip(coordinator: agentRateLimits)
        separator
      }
      sessionCount
    }
    .padding(.horizontal, 12)
    .frame(
      maxWidth: .infinity,
      minHeight: WorkspaceChrome.Metrics.statusBar,
      maxHeight: WorkspaceChrome.Metrics.statusBar,
      alignment: .leading
    )
    .font(WorkspaceChrome.chromeFont(size: 11))
    .foregroundStyle(WorkspaceChrome.textTertiary)
    .background(WorkspaceChrome.chrome)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(WorkspaceChrome.chromeLine)
        .frame(height: 1)
    }
    .onAppear {
      if showRateLimits {
        agentRateLimits.start()
      }
    }
    .onChange(of: showRateLimits) { _, isEnabled in
      if isEnabled {
        agentRateLimits.start()
      } else {
        agentRateLimits.stop()
      }
    }
    .onDisappear {
      agentRateLimits.stop()
    }
  }

  private var separator: some View {
    Text("·").foregroundStyle(WorkspaceChrome.divider)
  }

  @ViewBuilder
  private var branchState: some View {
    if let gitStatus = surface.gitStatus, gitStatus.isRepository {
      Menu {
        if gitStatus.branches.isEmpty {
          Text("ブランチがありません")
        } else {
          Section("ブランチ") {
            ForEach(gitStatus.branches, id: \.self) { branch in
              Button {
                switchBranch(branch)
              } label: {
                Label(
                  branch,
                  systemImage: branch == gitStatus.branch
                    ? "checkmark" : "arrow.triangle.branch"
                )
              }
              .disabled(branch == gitStatus.branch)
            }
          }
        }
        Divider()
        Button("Gitを開く") {
          surface.workspaceActivity = .git
        }
        Button("Gitを更新") {
          refreshGit()
        }
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 11, weight: .medium))
          Text(gitStatus.branch ?? "HEAD")
            .lineLimit(1)
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(WorkspaceChrome.textTertiary)
        .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .help("ブランチを切り替える")
      .accessibilityLabel("ブランチ \(gitStatus.branch ?? "HEAD")")

      Button {
        surface.workspaceActivity = .git
      } label: {
        Text("↓\(gitStatus.behind) ↑\(gitStatus.ahead)")
          .monospaced()
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)
      }
      .buttonStyle(.plain)
      .help("Gitを開く")

      Button {
        surface.workspaceActivity = .git
      } label: {
        Text("\(gitStatus.changes.count) 変更")
      }
      .buttonStyle(.plain)
      .foregroundStyle(WorkspaceChrome.textTertiary)
      .help("変更を開く")
    } else {
      Text(project.rootURL.path)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(WorkspaceChrome.textQuaternary)
    }
  }

  /// What the current screen contributes: the file in the focused pane, the
  /// file under review in source control, the running agents in activity.
  @ViewBuilder
  private var screenContext: some View {
    switch surface.workspaceActivity {
    case .files, .search, .review:
      if let tab = surface.activeTab(in: surface.focusedPaneID), tab.kind == .editor {
        separator
        Text(tab.title).lineLimit(1).truncationMode(.middle)
      }
    case .git:
      if let diff = surface.selectedGitDiff {
        separator
        Text(diff.change.path)
          .monospaced()
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    case .debug:
      separator
      if let location = surface.debugSession.currentLocation {
        Text("\(URL(fileURLWithPath: location.path).lastPathComponent):\(location.line)")
          .lineLimit(1)
          .truncationMode(.middle)
      } else {
        Text("Debug")
          .lineLimit(1)
      }
    case .activity:
      let live = agentWorkflow.sessions.filter { $0.projectID == project.id && $0.isActive }
        .count
      if live > 0 {
        separator
        Text("\(live) 実行中").foregroundStyle(WorkspaceChrome.success)
      }
    }
  }

  private var sessionCount: some View {
    let sessions = agentWorkflow.sessions.filter { $0.projectID == project.id }
    return Button(action: onOpenAgents) {
      Text("\(sessions.count) セッション")
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(WorkspaceChrome.textTertiary)
    .help("Agent追加画面を開く")
  }

  private func switchBranch(_ branch: String) {
    guard branch != surface.gitStatus?.branch else {
      return
    }
    _ = workspace.execute(
      .gitSwitchBranch(
        GitSwitchBranchCommand(projectID: project.id, branch: branch)
      )
    )
  }

  private func refreshGit() {
    _ = workspace.execute(.gitRefresh(GitRefreshCommand(projectID: project.id)))
  }
}

private struct AgentRateLimitStrip: View {
  @ObservedObject var coordinator: AgentRateLimitCoordinator

  var body: some View {
    HStack(spacing: 8) {
      ForEach(AgentRateLimitProvider.allCases) { provider in
        AgentRateLimitChip(provider: provider, coordinator: coordinator)
      }
    }
  }
}

private struct AgentRateLimitChip: View {
  let provider: AgentRateLimitProvider
  @ObservedObject var coordinator: AgentRateLimitCoordinator
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      // The Tokens artboard's QUOTA METER: one line — label, a 34x4 bar, the
      // remaining figure. The full per-window breakdown is in the popover, so
      // the status bar can stay 26px tall.
      HStack(spacing: 6) {
        AgentVendorIcon(provider: provider)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .frame(width: 13)

        Text(summaryTitle)
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)

        if let window = snapshot?.primaryWindow {
          AgentRateLimitMeter(usedPercent: window.usedPercent)
            .frame(width: 34, height: 4)
          Text("残り\(window.remainingPercent)%")
            .font(WorkspaceChrome.chromeFont(size: 10, weight: .semibold))
            .monospaced()
            .foregroundStyle(meterTint(remaining: window.remainingPercent))
        } else if coordinator.phase == .loading, snapshot == nil {
          ProgressView()
            .controlSize(.mini)
            .scaleEffect(0.6)
            .frame(width: 14, height: 14)
        } else {
          Text("—")
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(summaryDetailColor)
        }
      }
      .padding(.horizontal, 6)
      .frame(height: 20)
      .background(
        isPresented ? WorkspaceChrome.surfaceHover : Color.clear,
        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("\(provider.displayName)の使用量を表示")
    .accessibilityLabel("\(provider.displayName)の使用量")
    .accessibilityValue(summaryDetail)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      AgentRateLimitPopover(coordinator: coordinator, selectedProvider: provider)
    }
  }

  /// The remaining figure is the one number allowed to carry colour here, and
  /// only once the quota is actually tight.
  private func meterTint(remaining: Int) -> Color {
    if remaining <= 10 {
      return WorkspaceChrome.danger
    }
    if remaining <= 25 {
      return WorkspaceChrome.attention
    }
    return WorkspaceChrome.textSecondary
  }

  private var snapshot: AgentRateLimitSnapshot? {
    coordinator.snapshot(for: provider)
  }

  private var summaryTitle: String {
    provider.shortName
  }

  private var summaryDetail: String {
    if let snapshot, !snapshot.windows.isEmpty {
      return snapshot.windows.prefix(2).map { window in
        "\(window.displayName) 残り\(window.remainingPercent)%"
      }.joined(separator: " · ")
    }
    if let detail = snapshot?.detail ?? snapshot?.planType {
      return detail
    }
    if coordinator.failureMessage(for: provider) != nil {
      return "使用量を取得できません"
    }
    switch coordinator.phase {
    case .idle, .loading:
      return "使用量を取得中…"
    case .loaded:
      return "使用量はありません"
    case .failed:
      return "使用量を取得できません"
    }
  }

  private var summaryDetailColor: Color {
    if coordinator.failureMessage(for: provider) != nil {
      return WorkspaceChrome.attention
    }
    return WorkspaceChrome.textQuaternary
  }
}

private struct AgentRateLimitPopover: View {
  @ObservedObject var coordinator: AgentRateLimitCoordinator
  let selectedProvider: AgentRateLimitProvider
  @State private var mode = AgentRateLimitDisplayMode.detail

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("使用量")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
        Spacer()
        Button {
          coordinator.refresh()
        } label: {
          if coordinator.phase == .loading {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .buttonStyle(.plain)
        .frame(width: 26, height: 26)
        .disabled(coordinator.phase == .loading)
        .help("使用量を更新")
        .accessibilityLabel("使用量を更新")
      }
      .padding(.horizontal, 14)
      .frame(height: 44)

      Picker("表示", selection: $mode) {
        ForEach(AgentRateLimitDisplayMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.small)
      .padding(.horizontal, 12)
      .padding(.bottom, 9)

      Divider().overlay(WorkspaceChrome.border)

      if coordinator.snapshots.isEmpty, coordinator.phase == .loading {
        emptyState
      } else {
        ForEach(AgentRateLimitProvider.allCases) { provider in
          if let snapshot = coordinator.snapshot(for: provider) {
            AgentRateLimitRow(
              snapshot: snapshot,
              mode: mode,
              isSelected: provider == selectedProvider
            )
          } else {
            AgentRateLimitUnavailableRow(
              provider: provider,
              message: coordinator.failureMessage(for: provider) ?? "使用量データはありません",
              isSelected: provider == selectedProvider
            )
          }
          if provider != AgentRateLimitProvider.allCases.last {
            Divider().overlay(WorkspaceChrome.border)
          }
        }
      }

      if let fetchedAt = coordinator.snapshots.map(\.fetchedAt).max() {
        Divider().overlay(WorkspaceChrome.border)
        Text("最終更新 \(fetchedAt.formatted(date: .omitted, time: .shortened))")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .frame(height: 34)
      }
    }
    .frame(width: 420)
    .background(WorkspaceChrome.chromeRaised)
    .preferredColorScheme(.dark)
  }

  @ViewBuilder
  private var emptyState: some View {
    VStack(spacing: 10) {
      if coordinator.phase == .loading {
        ProgressView()
          .controlSize(.small)
        Text("Agentから使用量を取得しています…")
          .foregroundStyle(WorkspaceChrome.textTertiary)
      } else if case .failed(let message) = coordinator.phase {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(WorkspaceChrome.attention)
        Text(message)
          .multilineTextAlignment(.center)
          .foregroundStyle(WorkspaceChrome.textTertiary)
        Button("再試行") {
          coordinator.refresh()
        }
        .controlSize(.small)
      } else {
        Text("使用量データはありません")
          .foregroundStyle(WorkspaceChrome.textTertiary)
      }
    }
    .font(.system(size: 11))
    .frame(maxWidth: .infinity, minHeight: 112)
    .padding(16)
  }
}

private enum AgentRateLimitDisplayMode: String, CaseIterable, Identifiable {
  case detail
  case compact

  var id: String { rawValue }

  var title: String {
    switch self {
    case .detail: "詳細"
    case .compact: "コンパクト"
    }
  }
}

private struct AgentRateLimitRow: View {
  let snapshot: AgentRateLimitSnapshot
  let mode: AgentRateLimitDisplayMode
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 10) {
      ZStack {
        Circle()
          .fill(WorkspaceChrome.surfaceHover)
        Circle()
          .stroke(WorkspaceChrome.border, lineWidth: 1)
        AgentVendorIcon(provider: provider)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textSecondary)
      }
      .frame(width: 21, height: 21)

      VStack(alignment: .leading, spacing: 4) {
        Text(snapshot.displayName)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
          .lineLimit(1)
        if let secondaryText {
          Text(secondaryText)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(WorkspaceChrome.textTertiary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if snapshot.windows.isEmpty {
        Text(snapshot.planType ?? "—")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
      } else {
        VStack(spacing: 6) {
          ForEach(snapshot.windows) { window in
            HStack(spacing: 6) {
              Text(window.displayName)
                .frame(width: 34, alignment: .leading)
                .foregroundStyle(WorkspaceChrome.textQuaternary)
              AgentRateLimitMeter(usedPercent: window.usedPercent)
                .frame(width: 64, height: 5)
              Text(valueText(for: window))
                .frame(width: 54, alignment: .trailing)
                .foregroundStyle(WorkspaceChrome.textTertiary)
            }
            .font(.system(size: 10, design: .monospaced))
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 11)
    .frame(minHeight: 72)
    .background(isSelected ? WorkspaceChrome.surfaceHover : Color.clear)
  }

  private var provider: AgentRateLimitProvider? {
    AgentRateLimitProvider(rawValue: snapshot.id)
  }

  private var secondaryText: String? {
    snapshot.detail ?? snapshot.primaryWindow?.resetDescription() ?? snapshot.planType
  }

  private func valueText(for window: AgentRateLimitWindow) -> String {
    switch mode {
    case .detail:
      "残り \(window.remainingPercent)%"
    case .compact:
      "\(Int(window.usedPercent.rounded()))%"
    }
  }
}

private struct AgentRateLimitUnavailableRow: View {
  let provider: AgentRateLimitProvider
  let message: String
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 10) {
      ZStack {
        Circle()
          .fill(WorkspaceChrome.surfaceHover)
        Circle()
          .stroke(WorkspaceChrome.border, lineWidth: 1)
        AgentVendorIcon(provider: provider)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textSecondary)
      }
      .frame(width: 21, height: 21)

      VStack(alignment: .leading, spacing: 4) {
        Text(provider.displayName)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
        Text(message)
          .font(.system(size: 10))
          .foregroundStyle(WorkspaceChrome.attention)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 11)
    .frame(minHeight: 72)
    .background(isSelected ? WorkspaceChrome.surfaceHover : Color.clear)
  }
}

private struct AgentRateLimitMeter: View {
  let usedPercent: Double

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(WorkspaceChrome.borderStrong)
        Capsule()
          .fill(meterColor)
          .frame(width: geometry.size.width * usedPercent / 100)
      }
    }
    .accessibilityHidden(true)
  }

  private var meterColor: Color {
    switch usedPercent {
    case 90...:
      WorkspaceChrome.danger
    case 75...:
      WorkspaceChrome.attention
    default:
      WorkspaceChrome.textTertiary
    }
  }
}

private struct ProjectAgentView: View {
  let project: Project
  @ObservedObject var workspace: ProjectWorkspaceModel
  @ObservedObject var surface: ProjectSurfaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  @ObservedObject var worktreeCoordinator: ProjectWorktreeCoordinator
  @Environment(\.dismiss) private var dismiss
  @State private var selectedWorktreeID: WorktreeID?
  @State private var selectedProfile: AgentLaunchProfile = .codex
  @State private var selectedModelChoice = Self.defaultModelChoice
  @State private var customModelID = ""
  @State private var newWorktreeBranch = ""
  @State private var newWorktreeTargetName = ""
  @State private var cleanupPlan: ManagedWorktreeCleanupPlan?

  private static let defaultModelChoice = "__default"
  private static let customModelChoice = "__custom"

  private var projectSessions: [AgentWorkflowSession] {
    agentWorkflow.sessions.filter { $0.projectID == project.id }
  }

  private var projectActivities: [AgentActivity] {
    agentWorkflow.activities(for: project.id)
  }

  private var projectWorktrees: [ManagedWorktree] {
    worktreeCoordinator.worktrees(for: project.id)
  }

  private var selectedWorktree: ManagedWorktree? {
    guard let selectedWorktreeID else {
      return nil
    }
    return projectWorktrees.first { $0.id == selectedWorktreeID }
  }

  private var selectedExecutionRoot: URL {
    guard let selectedWorktree, selectedWorktree.state == .available else {
      return project.rootURL
    }
    return selectedWorktree.rootURL
  }

  private var selectedModelID: String? {
    switch selectedModelChoice {
    case Self.defaultModelChoice:
      return nil
    case Self.customModelChoice:
      let value = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    default:
      return selectedModelChoice
    }
  }

  private var hasValidModelSelection: Bool {
    selectedModelChoice != Self.customModelChoice || selectedModelID != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      MainHeader {
        Image(systemName: "person.2")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.accent)
        Text("Agents")
          .font(WorkspaceChrome.chromeFont(size: 14, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
        Text(project.name)
          .font(WorkspaceChrome.chromeFont(size: 11))
          .foregroundStyle(WorkspaceChrome.textTertiary)
          .lineLimit(1)
        Spacer(minLength: 0)
        ChromeActionButton(
          width: 24,
          height: 24,
          help: "Agentsを閉じる",
          action: dismiss.callAsFunction
        ) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
        }
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          launchSection
          worktreeSection
          projectMuteSection
          sessionsSection
          activitySection
          hookSection
        }
        .padding(16)
      }
    }
    .frame(minWidth: 680, minHeight: 560)
    .foregroundStyle(WorkspaceChrome.textPrimary)
    .background(WorkspaceChrome.canvas)
    .background {
      ThinScrollbarsInstaller()
    }
    .onAppear {
      worktreeCoordinator.refresh(project: project)
    }
    .alert("管理対象worktreeの操作に失敗しました", isPresented: worktreeErrorIsPresented) {
      Button("OK") {
        worktreeCoordinator.clearError()
      }
    } message: {
      Text(worktreeCoordinator.lastErrorMessage ?? "管理対象worktreeで不明なエラーが発生しました。")
    }
    .alert("管理対象worktreeを削除", isPresented: cleanupAlertIsPresented) {
      Button("キャンセル", role: .cancel) {
        cleanupPlan = nil
      }
      if cleanupPlan?.canConfirm == true {
        Button("削除", role: .destructive) {
          confirmCleanup()
        }
      }
    } message: {
      if let cleanupPlan {
        if cleanupPlan.canConfirm {
          Text(
            "\(cleanupPlan.rootURL.path) のブランチ \(cleanupPlan.branch) を削除しますか？ブランチ自体は保持されます。"
          )
        } else {
          Text(
            "次の理由によりクリーンアップできません: \(cleanupPlan.blockers.map { $0.displayName }.joined(separator: ", "))。"
          )
        }
      }
    }
  }

  private var launchSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Agentを追加")
          .font(.headline)
        Text("Agent、起動モデル、セッションの場所を選択します。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Picker("Agent", selection: $selectedProfile) {
        ForEach(AgentLaunchProfile.all) { profile in
          Text(profile.displayName)
            .tag(profile)
        }
      }
      .pickerStyle(.menu)

      Picker("モデル", selection: $selectedModelChoice) {
        Text("設定済みのデフォルト")
          .tag(Self.defaultModelChoice)
        ForEach(selectedProfile.suggestedModels) { model in
          Text(model.title)
            .tag(model.id)
        }
        Text("カスタムmodel ID…")
          .tag(Self.customModelChoice)
      }
      .pickerStyle(.menu)

      if selectedModelChoice == Self.customModelChoice {
        TextField(
          selectedProfile == .openCode ? "provider/model" : "model ID",
          text: $customModelID
        )
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
      }

      Picker("起動場所", selection: $selectedWorktreeID) {
        Text("Projectルート")
          .tag(nil as WorktreeID?)
        ForEach(projectWorktrees.filter { $0.state == .available }) { worktree in
          Text("\(worktree.branch) — \(worktree.state.displayName)")
            .tag(worktree.id as WorktreeID?)
        }
      }
      .pickerStyle(.menu)

      Text(selectedExecutionRoot.path)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      Button {
        launch(profile: selectedProfile, modelID: selectedModelID)
      } label: {
        Label("Agentを起動", systemImage: "play.fill")
      }
      .buttonStyle(.borderedProminent)
      .disabled(!hasValidModelSelection)
    }
    .agentWorkflowCard()
  }

  private var worktreeSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("管理対象worktree")
          .font(.headline)
        Spacer()
        Button("更新") {
          worktreeCoordinator.refresh(project: project)
        }
        .buttonStyle(.tactile)
      }

      if surface.gitStatus?.isRepository != true {
        Text("管理対象worktreeを使うには、ProjectルートにGitリポジトリが必要です。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text(
          "Clairはこれらのworktreeをリポジトリ外の \(worktreeCoordinator.managementRootURL?.path ?? "利用できません") に保存します。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

        HStack(spacing: 8) {
          TextField("ブランチ", text: $newWorktreeBranch)
          TextField("フォルダ名", text: $newWorktreeTargetName)
          Button("作成") {
            createWorktree()
          }
          .buttonStyle(.bordered)
          .disabled(
            newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || newWorktreeTargetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        }

        if projectWorktrees.isEmpty {
          Text("このProjectには管理対象worktreeがまだありません。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(projectWorktrees) { worktree in
            managedWorktreeRow(worktree)
          }
        }
      }
    }
    .agentWorkflowCard()
  }

  private func managedWorktreeRow(_ worktree: ManagedWorktree) -> some View {
    HStack(spacing: 8) {
      Image(
        systemName: worktree.state == .available
          ? "arrow.triangle.branch" : "exclamationmark.triangle"
      )
      .foregroundStyle(worktree.state == .available ? .green : .orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(worktree.branch)
          .font(.body.weight(.medium))
        Text(worktree.rootURL.path)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(worktreeStatusDescription(worktree))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if worktree.state == .available {
        Button("使う") {
          selectedWorktreeID = worktree.id
        }
        .buttonStyle(.tactile)
      }
      Button("クリーンアップ", role: .destructive) {
        cleanupPlan = worktreeCoordinator.prepareCleanup(
          project: project,
          worktreeID: worktree.id,
          activeSessionIDs: sessionIDsInUse(for: worktree.id),
          expectedRootURL: worktree.rootURL
        )
      }
      .buttonStyle(.tactile)
    }
    .padding(8)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
  }

  private var worktreeErrorIsPresented: Binding<Bool> {
    Binding(
      get: { worktreeCoordinator.lastErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          worktreeCoordinator.clearError()
        }
      }
    )
  }

  private var cleanupAlertIsPresented: Binding<Bool> {
    Binding(
      get: { cleanupPlan != nil },
      set: { isPresented in
        if !isPresented {
          cleanupPlan = nil
        }
      }
    )
  }

  private func createWorktree() {
    let branch = newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let targetName = newWorktreeTargetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !branch.isEmpty,
      !targetName.isEmpty,
      let worktree = worktreeCoordinator.create(
        project: project,
        branch: branch,
        targetName: targetName
      )
    else {
      return
    }
    selectedWorktreeID = worktree.id
    newWorktreeBranch = ""
    newWorktreeTargetName = ""
  }

  private func confirmCleanup() {
    guard let cleanupPlan else {
      return
    }
    let didRemove = worktreeCoordinator.confirmCleanup(
      project: project,
      plan: cleanupPlan,
      activeSessionIDs: sessionIDsInUse(for: cleanupPlan.worktreeID)
    )
    if didRemove, selectedWorktreeID == cleanupPlan.worktreeID {
      selectedWorktreeID = nil
    }
    self.cleanupPlan = nil
  }

  private func sessionIDsInUse(for worktreeID: WorktreeID) -> Set<UUID> {
    agentWorkflow.activeSessionIDs(for: worktreeID)
      .union(surface.sessionIDsInUse(for: worktreeID))
  }

  private func worktreeStatusDescription(_ worktree: ManagedWorktree) -> String {
    switch worktree.state {
    case .available:
      if worktree.isDirty {
        return "利用可能 — 未コミットの変更あり"
      }
      return "利用可能 — クリーン"
    case .missing:
      return "見つかりません — 実行できません"
    case .detached:
      return "切り離し — Git登録がないかHEADが切り離されています"
    }
  }

  private func launch(profile: AgentLaunchProfile, modelID: String?) {
    let worktree: ManagedWorktree?
    if let selectedWorktreeID {
      guard
        let resolved = worktreeCoordinator.availableWorktree(
          project: project,
          id: selectedWorktreeID
        )
      else {
        return
      }
      worktree = resolved
    } else {
      worktree = nil
    }

    _ = agentWorkflow.launch(
      profile: profile,
      modelID: modelID,
      projectID: project.id,
      projectRoot: worktree?.rootURL ?? project.rootURL,
      surface: surface,
      worktree: worktree
    )
  }

  private var projectMuteSection: some View {
    HStack(spacing: 10) {
      Image(systemName: agentWorkflow.isMuted(projectID: project.id) ? "bell.slash" : "bell")
        .foregroundStyle(.secondary)
      Text("Projectの通知")
      Spacer()
      Button(
        agentWorkflow.isMuted(projectID: project.id) ? "Projectのミュートを解除" : "Projectをミュート"
      ) {
        agentWorkflow.setMuted(
          !agentWorkflow.isMuted(projectID: project.id),
          projectID: project.id
        )
      }
      .buttonStyle(.bordered)
    }
    .agentWorkflowCard()
  }

  @ViewBuilder
  private var sessionsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("セッション")
        .font(.headline)
      if projectSessions.isEmpty {
        Text("このProjectではAgentがまだ起動されていません。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(projectSessions) { session in
          agentSessionRow(session)
        }
      }
    }
    .agentWorkflowCard()
  }

  private func agentSessionRow(_ session: AgentWorkflowSession) -> some View {
    HStack(spacing: 10) {
      Image(systemName: session.isActive ? "circle.fill" : "circle")
        .foregroundStyle(session.isActive ? .green : .secondary)
        .font(.caption)
      VStack(alignment: .leading, spacing: 2) {
        Text(session.profile?.displayName ?? "不明なAgent")
          .font(.body.weight(.medium))
        Text(
          [lifecycleDescription(for: session), session.agent.modelID]
            .compactMap { $0 }
            .joined(separator: " · ")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button("表示") {
        workspace.revealTerminal(
          projectID: session.projectID,
          tabID: session.terminalTabID
        )
        surface.workspaceActivity = .files
        dismiss()
      }
      .buttonStyle(.tactile)
      Button(
        agentWorkflow.isMuted(projectID: session.projectID, sessionID: session.id)
          ? "ミュート解除"
          : "ミュート"
      ) {
        agentWorkflow.setMuted(
          !agentWorkflow.isMuted(projectID: session.projectID, sessionID: session.id),
          projectID: session.projectID,
          sessionID: session.id
        )
      }
      .buttonStyle(.tactile)
    }
    .padding(8)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
  }

  @ViewBuilder
  private var activitySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("アクティビティ履歴")
        .font(.headline)
      if projectActivities.isEmpty {
        Text("ベル、終了、公式フックのアクティビティがここに表示されます。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(projectActivities.reversed())) { activity in
          HStack(spacing: 8) {
            Image(systemName: activityIcon(for: activity))
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(activityTitle(for: activity))
              Text(activity.occurredAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
              if let summary = activity.summary {
                Text(summary)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
            Spacer()
            if let session = projectSessions.first(where: { $0.id == activity.sessionID }) {
              Button("表示") {
                workspace.revealTerminal(
                  projectID: session.projectID,
                  tabID: session.terminalTabID
                )
                surface.workspaceActivity = .files
                dismiss()
              }
              .buttonStyle(.tactile)
            }
          }
          .padding(.vertical, 3)
        }
      }
    }
    .agentWorkflowCard()
  }

  @ViewBuilder
  private var hookSection: some View {
    if let hookReceiverURL = agentWorkflow.hookReceiverURL {
      VStack(alignment: .leading, spacing: 4) {
        Text("公式フックの受信先")
          .font(.headline)
        Text("Agentのドキュメントに記載されたフックコマンドを次のように設定します:")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("sh \"$CLAIR_AGENT_HOOK_RECEIVER\"")
          .font(.caption.monospaced())
        Text(hookReceiverURL.path)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .agentWorkflowCard()
    }
  }

  private func lifecycleDescription(for session: AgentWorkflowSession) -> String {
    switch session.lifecycle {
    case .starting:
      "\(session.agent.cwd) で起動中"
    case .running:
      "\(session.agent.cwd) で実行中"
    case .exited(let code):
      "ステータス \(code) で終了"
    }
  }

  private func activityTitle(for activity: AgentActivity) -> String {
    switch activity.source {
    case .bell:
      "ターミナルの注意ベル"
    case .exit:
      activity.exitStatus == 0 ? "Agentが正常終了" : "Agentがエラー終了"
    case .officialHook:
      "公式フック: \(activity.kind.rawValue)"
    }
  }

  private func activityIcon(for activity: AgentActivity) -> String {
    switch activity.source {
    case .bell:
      "bell"
    case .exit:
      activity.exitStatus == 0 ? "checkmark.circle" : "xmark.circle"
    case .officialHook:
      "link"
    }
  }
}

extension View {
  /// Agent surfaces use the same quiet raised panel as the workspace settings
  /// instead of falling back to AppKit's default sheet styling.
  fileprivate func agentWorkflowCard() -> some View {
    padding(14)
      .background(
        WorkspaceChrome.surface.opacity(0.72),
        in: RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.card, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.card, style: .continuous)
          .stroke(WorkspaceChrome.borderStrong, lineWidth: 1)
      }
  }
}

private struct ProjectTerminalPanel: View {
  @ObservedObject var session: TerminalSession
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

private struct ProjectPaneLayoutView: View {
  let state: BootstrapState
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel
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
private struct PathBreadcrumb<Trailing: View>: View {
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
private struct ProjectEditorBreadcrumbActions: View {
  @ObservedObject var tab: ProjectEditorTab

  var body: some View {
    HStack(spacing: 6) {
      if tab.loadError != nil {
        marker("開けません", tint: WorkspaceChrome.danger)
      } else if tab.isMissing {
        marker("見つかりません", tint: WorkspaceChrome.attention)
      } else if tab.isDirty {
        marker("未保存", tint: WorkspaceChrome.attention)
      }
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

private struct ProjectPaneView: View {
  let state: BootstrapState
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel
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
              ProjectEditorBreadcrumbActions(tab: document)
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
            session: session,
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

private struct ProjectRestoredTerminalView: View {
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

/// The source-control panel, shaped like VSCode's: the raw `git status`
/// split of「ステージ済みの変更」against「変更」, a commit box above it, and a
/// per-row "+"/"−" that actually stages and unstages. Untracked files are
/// marked inside 変更 rather than given a third section of their own — that is
/// what the working tree is.
private struct ProjectGitView: View {
  @ObservedObject var workspace: ProjectWorkspaceModel
  let projectID: UUID
  @ObservedObject var surface: ProjectSurfaceModel
  let onDismiss: () -> Void
  @State private var commitMessage = ""
  @State private var showsGraph = false
  @State private var graphSnapshot: ProjectGitGraphSnapshot?
  @State private var graphErrorMessage: String?
  @State private var isGraphLoading = false
  @State private var graphTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      SidebarPanelHeader(title: WorkspaceActivity.git.title) {
        HStack(spacing: 3) {
          ChromeActionButton(
            width: 20,
            height: 20,
            help: showsGraph ? "変更一覧を表示" : "Git Graphを表示",
            action: toggleGraph
          ) {
            Image(systemName: showsGraph ? "list.bullet" : "arrow.triangle.branch")
              .font(.system(size: 11, weight: .medium))
          }
          ChromeActionButton(width: 20, height: 20, help: "更新", action: refresh) {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 11, weight: .medium))
          }
        }
      }

      if showsGraph {
        ProjectGitGraphView(
          snapshot: graphSnapshot,
          isLoading: isGraphLoading,
          errorMessage: graphErrorMessage,
          onReload: loadGraph
        )
      } else if let status = surface.gitStatus, status.isRepository {
        commitBox(status)
        if status.changes.isEmpty {
          ChromeEmptyState(
            symbol: "checkmark.shield",
            title: "変更はありません",
            message: "working tree はきれいです。"
          )
          Spacer(minLength: 0)
        } else {
          changeList(status)
        }
      } else if let status = surface.gitStatus {
        ChromeEmptyState(
          symbol: "arrow.triangle.branch",
          title: "Gitを利用できません",
          message: status.message ?? "このProjectはGitリポジトリではありません。"
        )
        Spacer(minLength: 0)
      } else {
        ChromeEmptyState(
          symbol: "arrow.triangle.branch",
          title: "Gitの状態を取得できません",
          message: "Gitの状態を更新してProjectを確認してください。"
        )
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(WorkspaceChrome.chrome)
    .onAppear {
      refresh()
    }
    .onDisappear {
      graphTask?.cancel()
    }
  }

  // MARK: Commit

  private func commitBox(_ status: ProjectGitSnapshot) -> some View {
    let canCommit =
      !status.stagedChanges.isEmpty
      && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    return VStack(spacing: 6) {
      TextEditor(text: $commitMessage)
        .font(WorkspaceChrome.chromeFont(size: 11))
        .foregroundStyle(WorkspaceChrome.textPrimary)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .background(HiddenScrollbarsInstaller())
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(height: 42)
        .background(
          WorkspaceChrome.panel,
          in: RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.control, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.control, style: .continuous)
            .stroke(WorkspaceChrome.hairline, lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
          if commitMessage.isEmpty {
            Text("コミットメッセージ")
              .font(WorkspaceChrome.chromeFont(size: 11))
              .foregroundStyle(WorkspaceChrome.textQuaternary)
              .padding(.horizontal, 9)
              .padding(.vertical, 7)
              .allowsHitTesting(false)
          }
        }

      Button(action: commit) {
        Text("コミット\(status.stagedCount > 0 ? "（\(status.stagedCount)）" : "")")
          .font(WorkspaceChrome.chromeFont(size: 11, weight: .semibold))
          .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!canCommit)
      .foregroundStyle(canCommit ? WorkspaceChrome.textPrimary : WorkspaceChrome.textQuaternary)
      .background(
        canCommit ? WorkspaceChrome.surfaceActive : WorkspaceChrome.panel,
        in: RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.control, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.control, style: .continuous)
          .stroke(
            canCommit ? WorkspaceChrome.borderStronger : WorkspaceChrome.hairline,
            lineWidth: 1
          )
      }
    }
    .padding(10)
  }

  // MARK: Changes

  private func changeList(_ status: ProjectGitSnapshot) -> some View {
    // Untracked files belong with the rest of the working tree, marked, not
    // in a section of their own.
    let unstaged = status.unstagedChanges + status.untrackedChanges

    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
        sectionHeading(
          "ステージ済みの変更",
          count: status.stagedCount,
          bulkGlyph: "−",
          bulkTitle: "すべてステージを取り消す",
          onBulk: { status.stagedChanges.forEach(unstage) }
        )
        ForEach(status.stagedChanges) { change in
          ProjectGitChangeRow(
            change: change,
            isStaged: true,
            isSelected: surface.selectedGitDiff?.change.path == change.path,
            onSelect: { showDiff(change, basis: .staged) },
            onToggleStage: { unstage(change) }
          )
        }

        sectionHeading(
          "変更",
          count: unstaged.count,
          bulkGlyph: "+",
          bulkTitle: "すべてステージ",
          onBulk: { unstaged.forEach(stage) }
        )
        ForEach(unstaged) { change in
          ProjectGitChangeRow(
            change: change,
            isStaged: false,
            isSelected: surface.selectedGitDiff?.change.path == change.path,
            onSelect: { showDiff(change, basis: .workingTree) },
            onToggleStage: { stage(change) }
          )
        }
      }
      .padding(.vertical, 2)
    }
    .scrollIndicators(.automatic)
  }

  private func sectionHeading(
    _ label: String,
    count: Int,
    bulkGlyph: String,
    bulkTitle: String,
    onBulk: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 6) {
      HStack(spacing: 5) {
        Text(label)
          .font(WorkspaceChrome.chromeFont(size: 10, weight: .bold))
          .kerning(0.3)
          .foregroundStyle(WorkspaceChrome.textTertiary)
        Text(String(count))
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)
      }
      Spacer(minLength: 0)
      if count > 0 {
        ChromeActionButton(width: 18, height: 18, help: bulkTitle, action: onBulk) {
          Text(bulkGlyph)
            .font(.system(size: 12, weight: .bold))
        }
      }
    }
    .padding(.leading, 20)
    .padding(.trailing, 12)
    .frame(height: 26)
  }

  // MARK: Commands

  private func refresh() {
    _ = workspace.execute(.gitRefresh(GitRefreshCommand(projectID: projectID)))
    if showsGraph {
      loadGraph()
    }
  }

  private func toggleGraph() {
    showsGraph.toggle()
    if showsGraph {
      loadGraph()
    }
  }

  private func loadGraph() {
    graphTask?.cancel()
    isGraphLoading = true
    graphErrorMessage = nil
    let rootURL = surface.rootURL
    graphTask = Task { @MainActor in
      let snapshot = await Task.detached(priority: .utility) {
        try? ProjectGitService(rootURL: rootURL).graph()
      }.value
      guard !Task.isCancelled else {
        return
      }
      graphSnapshot = snapshot
      graphErrorMessage = snapshot == nil ? "Git履歴を取得できませんでした。" : nil
      isGraphLoading = false
      graphTask = nil
    }
  }

  private func commit() {
    _ = workspace.execute(
      .gitCommit(GitCommitCommand(projectID: projectID, message: commitMessage))
    )
    if workspace.lastErrorMessage == nil {
      commitMessage = ""
    }
  }

  private func showDiff(_ change: ProjectGitChange, basis: ProjectGitDiffBasis) {
    _ = workspace.execute(
      .gitShowDiff(
        GitShowDiffCommand(projectID: projectID, relativePath: change.path, basis: basis)
      )
    )
  }

  private func stage(_ change: ProjectGitChange) {
    _ = workspace.execute(
      .gitStage(GitStageCommand(projectID: projectID, relativePath: change.path))
    )
  }

  private func unstage(_ change: ProjectGitChange) {
    _ = workspace.execute(
      .gitUnstage(GitUnstageCommand(projectID: projectID, relativePath: change.path))
    )
  }
}

private struct ProjectGitGraphView: View {
  let snapshot: ProjectGitGraphSnapshot?
  let isLoading: Bool
  let errorMessage: String?
  let onReload: () -> Void

  var body: some View {
    Group {
      if let snapshot, snapshot.isRepository {
        VStack(alignment: .leading, spacing: 0) {
          graphSummary(snapshot)
          if snapshot.commits.isEmpty {
            ChromeEmptyState(
              symbol: "point.3.connected.trianglepath.dotted",
              title: "コミット履歴はありません",
              message: "このProjectにはまだ表示できるコミットがありません。"
            )
            Spacer(minLength: 0)
          } else {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(snapshot.commits.enumerated()), id: \.element.id) { index, commit in
                  ProjectGitGraphCommitRow(
                    commit: commit,
                    hasFollowingCommit: index + 1 < snapshot.commits.count
                  )
                }
              }
              .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic)
            if snapshot.isTruncated {
              Text("表示上限 (snapshot.commits.count)件に達しています")
                .font(WorkspaceChrome.chromeFont(size: 10))
                .foregroundStyle(WorkspaceChrome.textQuaternary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
          }
        }
      } else if let snapshot {
        ChromeEmptyState(
          symbol: "arrow.triangle.branch",
          title: "Git Graphを利用できません",
          message: snapshot.message ?? "このProjectはGitリポジトリではありません。"
        )
        Spacer(minLength: 0)
      } else if isLoading {
        ChromeEmptyState(
          symbol: "arrow.triangle.2.circlepath",
          title: "Git Graphを読み込み中",
          message: "履歴を取得しています。"
        )
        Spacer(minLength: 0)
      } else if let errorMessage {
        VStack(spacing: 10) {
          ChromeEmptyState(
            symbol: "exclamationmark.triangle",
            title: "Git Graphを開けません",
            message: errorMessage
          )
          Button("再読み込み", action: onReload)
            .buttonStyle(.tactile)
            .font(WorkspaceChrome.chromeFont(size: 11))
        }
        Spacer(minLength: 0)
      } else {
        ChromeEmptyState(
          symbol: "arrow.triangle.branch",
          title: "Git Graphを読み込み中",
          message: "履歴を取得しています。"
        )
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(WorkspaceChrome.chrome)
  }

  private func graphSummary(_ snapshot: ProjectGitGraphSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(WorkspaceChrome.accent)
        Text(snapshot.branch ?? "detached HEAD")
          .font(WorkspaceChrome.chromeFont(size: 11, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textPrimary)
          .lineLimit(1)
        Spacer(minLength: 4)
        Text("(snapshot.commits.count) commits")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
      }
      if !snapshot.refs.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 5) {
            ForEach(snapshot.refs) { ref in
              Text(ref.name)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(
                  ref.isCurrent ? WorkspaceChrome.textPrimary : WorkspaceChrome.textTertiary
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                  ref.isCurrent ? WorkspaceChrome.washSelected : WorkspaceChrome.washFaint,
                  in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                )
            }
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(WorkspaceChrome.border)
        .frame(height: 1)
    }
  }
}

private struct ProjectGitGraphCommitRow: View {
  let commit: ProjectGitGraphCommit
  let hasFollowingCommit: Bool

  private var laneColor: Color {
    commit.parentRevisions.count > 1 ? WorkspaceChrome.attention : WorkspaceChrome.accent
  }

  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      ZStack(alignment: .top) {
        if hasFollowingCommit {
          Rectangle()
            .fill(laneColor.opacity(0.56))
            .frame(width: 2)
            .padding(.top, 10)
        }
        Circle()
          .fill(WorkspaceChrome.chrome)
          .frame(width: 10, height: 10)
          .overlay {
            Circle()
              .stroke(laneColor, lineWidth: 2)
          }
          .padding(.top, 4)
      }
      .frame(minWidth: 18, maxWidth: 18, minHeight: 58)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text(commit.subject)
            .font(WorkspaceChrome.chromeFont(size: 11, weight: .medium))
            .foregroundStyle(WorkspaceChrome.textPrimary)
            .lineLimit(2)
          Spacer(minLength: 3)
          Text(commit.shortRevision)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
        }
        HStack(spacing: 6) {
          Text(commit.author)
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.textTertiary)
            .lineLimit(1)
          Text(commit.authoredAt.prefix(10))
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
        }
        if !commit.refs.isEmpty {
          HStack(spacing: 4) {
            ForEach(commit.refs) { ref in
              Text(ref.name)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(
                  ref.isCurrent ? WorkspaceChrome.textPrimary : WorkspaceChrome.textTertiary
                )
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                  ref.isCurrent ? WorkspaceChrome.accent.opacity(0.18) : WorkspaceChrome.washFaint,
                  in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                )
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 7)
    .contentShape(Rectangle())
  }
}

/// One changed file. The stage toggle is a plain "+"/"−" glyph rather than an
/// icon, matching how the explorer already uses bare "M"/"A" letters instead
/// of drawn badges.
private struct ProjectGitChangeRow: View {
  let change: ProjectGitChange
  let isStaged: Bool
  let isSelected: Bool
  let onSelect: () -> Void
  let onToggleStage: () -> Void

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "doc.text")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(
          change.isUntracked ? WorkspaceChrome.success : WorkspaceChrome.textTertiary
        )
      Text(name)
        .font(WorkspaceChrome.chromeFont(size: 11))
        .foregroundStyle(nameTint)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      Text(change.isUntracked ? "未追跡" : marker)
        .font(
          WorkspaceChrome.chromeFont(
            size: 10,
            weight: change.isUntracked ? .regular : .semibold
          )
        )
        .monospaced()
        .foregroundStyle(markerTint)
      ChromeActionButton(
        width: 18,
        height: 18,
        help: isStaged ? "ステージを取り消す" : "ステージに追加",
        action: onToggleStage
      ) {
        Text(isStaged ? "−" : "+")
          .font(.system(size: 12, weight: .bold))
      }
    }
    .padding(.leading, isSelected ? 20 : 22)
    .padding(.trailing, 8)
    .frame(height: 24)
    .hoverableRow(isSelected: isSelected)
    .overlay(alignment: .leading) {
      if isSelected {
        Rectangle()
          .fill(WorkspaceChrome.textSecondary)
          .frame(width: 2)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onSelect)
    .help(change.displayPath)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(change.displayPath), \(change.kind.displayName)")
  }

  private var name: String {
    (change.path as NSString).lastPathComponent
  }

  private var nameTint: Color {
    if change.isUntracked {
      return WorkspaceChrome.success
    }
    return isSelected ? WorkspaceChrome.textPrimary : WorkspaceChrome.textTertiary
  }

  /// The single-letter status the explorer already uses. Git's own per-file
  /// line counts are not in the status snapshot, so the letter is what the
  /// row can honestly show.
  private var marker: String {
    switch change.kind {
    case .added:
      "A"
    case .modified:
      "M"
    case .deleted:
      "D"
    case .renamed:
      "R"
    case .copied:
      "C"
    case .typeChanged:
      "T"
    case .conflicted:
      "U"
    case .untracked:
      "?"
    }
  }

  private var markerTint: Color {
    switch change.kind {
    case .added:
      WorkspaceChrome.success
    case .deleted, .conflicted:
      WorkspaceChrome.danger
    case .untracked:
      WorkspaceChrome.textMuted
    default:
      WorkspaceChrome.attention
    }
  }
}

private struct ProjectBranchReviewView: View {
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  @ObservedObject var worktreeCoordinator: ProjectWorktreeCoordinator
  let onDismiss: () -> Void

  @State private var selectedWorktreeID: WorktreeID?
  @State private var reviewService: ProjectBranchReviewService?
  @State private var branchReview: ProjectBranchReviewSnapshot?
  @State private var adoptionPlan: ProjectBranchAdoptionPlan?
  @State private var conflict: ProjectBranchConflict?
  @State private var statusMessage: String?
  @State private var errorMessage: String?
  @State private var cleanupPlan: ManagedWorktreeCleanupPlan?

  private var projectWorktrees: [ManagedWorktree] {
    worktreeCoordinator.worktrees(for: project.id)
  }

  private var availableWorktrees: [ManagedWorktree] {
    projectWorktrees.filter { $0.state == .available }
  }

  private var selectedWorktree: ManagedWorktree? {
    guard let selectedWorktreeID else {
      return nil
    }
    return availableWorktrees.first { $0.id == selectedWorktreeID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SidebarPanelHeader(title: "レビュー") {
        Text(project.name)
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)
          .lineLimit(1)
      }

      Divider()
        .background(WorkspaceChrome.border)

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          sourceSection
          if let branchReview {
            reviewSection(branchReview)
          }
          if let adoptionPlan {
            adoptionSection(adoptionPlan)
          }
          if let conflict {
            conflictSection(conflict)
          }
          if let statusMessage {
            Label(statusMessage, systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.green)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(16)
      }
    }
    .frame(minWidth: 0, minHeight: 0)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(WorkspaceChrome.chrome)
    .onAppear {
      worktreeCoordinator.refresh(project: project)
      if selectedWorktreeID == nil, let first = availableWorktrees.first {
        selectedWorktreeID = first.id
        reviewService = makeReviewService(for: first)
      }
    }
    .onChange(of: selectedWorktreeID) { _, worktreeID in
      reviewService = worktreeID.flatMap { id in
        availableWorktrees.first { $0.id == id }
      }.map { makeReviewService(for: $0) }
      branchReview = nil
      adoptionPlan = nil
      conflict = nil
      statusMessage = nil
    }
    .alert("変更の確認に失敗しました", isPresented: errorAlertIsPresented) {
      Button("OK") {
        errorMessage = nil
      }
    } message: {
      Text(errorMessage ?? "変更の確認で不明なエラーが発生しました。")
    }
    .alert("管理対象worktreeを削除", isPresented: cleanupAlertIsPresented) {
      Button("キャンセル", role: .cancel) {
        cleanupPlan = nil
      }
      if cleanupPlan?.canConfirm == true {
        Button("削除", role: .destructive) {
          confirmCleanup()
        }
      }
    } message: {
      if let cleanupPlan {
        if cleanupPlan.canConfirm {
          Text(
            "\(cleanupPlan.rootURL.path) のブランチ \(cleanupPlan.branch) を削除しますか？ブランチ自体は保持されます。"
          )
        } else {
          Text(
            "次の理由によりクリーンアップできません: \(cleanupPlan.blockers.map { $0.displayName }.joined(separator: ", "))。"
          )
        }
      }
    }
  }

  private var sourceSection: some View {
    GroupBox("ソースworktree") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("ブランチ", selection: $selectedWorktreeID) {
          Text("管理対象worktreeを選択").tag(nil as WorktreeID?)
          ForEach(projectWorktrees) { worktree in
            Text("\(worktree.branch) — \(worktree.state.displayName)")
              .tag(worktree.id as WorktreeID?)
          }
        }
        .pickerStyle(.menu)

        if let selectedWorktree {
          Text(selectedWorktree.rootURL.path)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
          Text(
            "ベース \(selectedWorktree.baseRevision.prefix(8)) · 現在 \(selectedWorktree.headRevision?.prefix(8) ?? "不明")"
          )
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        } else {
          Text(
            projectWorktrees.isEmpty
              ? "ブランチを確認する前に、Agent画面から管理対象worktreeを作成してください。"
              : "利用可能な管理対象worktreeだけを確認できます。"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Text("対象Projectのルート: \(project.rootURL.path)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        HStack(spacing: 8) {
          Button("ブランチを確認") {
            reviewBranch()
          }
          .buttonStyle(.borderedProminent)
          .disabled(reviewService == nil)

          Button("取り込みを準備") {
            prepareAdoption()
          }
          .buttonStyle(.bordered)
          .disabled(reviewService == nil)

          Spacer()

          if let selectedWorktree {
            Button("クリーンアップ", role: .destructive) {
              prepareCleanup(for: selectedWorktree)
            }
            .buttonStyle(.tactile)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func reviewSection(_ review: ProjectBranchReviewSnapshot) -> some View {
    GroupBox("ブランチ全体の確認") {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label(review.sourceBranch ?? "HEAD", systemImage: "arrow.triangle.branch")
            .font(.headline)
          Spacer()
          Text("\(review.commits.count)件のコミット")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(
          "ベース \(review.baseRevision.prefix(8)) → HEAD \(review.headRevision.prefix(8))"
        )
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)

        if review.sourceStatus.changes.isEmpty {
          Label("ソースworktreeはクリーンです", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.green)
        } else {
          Label(
            "ソースに未コミットの変更が\(review.uncommittedChanges.count)件あります",
            systemImage: "exclamationmark.triangle"
          )
          .font(.caption)
          .foregroundStyle(.orange)
          ForEach(review.uncommittedChanges) { change in
            Text("• \(change.displayPath)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if review.committedChanges.isEmpty {
          Text("ベースリビジョン以降にコミットされたファイル変更はありません。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("コミット済みの変更")
            .font(.subheadline.weight(.semibold))
          ForEach(review.committedChanges) { change in
            HStack(spacing: 8) {
              Text(change.displayPath)
                .lineLimit(1)
              Spacer()
              Text(change.kind.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        if !review.commits.isEmpty {
          Text("コミット")
            .font(.subheadline.weight(.semibold))
          ForEach(review.commits) { commit in
            HStack(alignment: .top, spacing: 8) {
              Text(commit.shortRevision)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                Text("\(commit.author) · \(commit.authoredAt)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        DisclosureGroup("コミット済みの差分") {
          Text(
            review.committedDiff.isEmpty
              ? "このベースとHEADではコミット済みの差分を利用できません。"
              : review.committedDiff
          )
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(.background.secondary, in: RoundedRectangle(cornerRadius: 5))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func adoptionSection(_ plan: ProjectBranchAdoptionPlan) -> some View {
    GroupBox("取り込みの確認") {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "\(plan.review.expectedSourceBranch) を \(plan.targetBranch ?? "HEAD") にマージコミットとして取り込みます。"
        )
        .font(.subheadline)

        if plan.blockers.isEmpty {
          Label(
            "ソースと対象はクリーンで、取り込みの準備ができています。",
            systemImage: "checkmark.circle.fill"
          )
          .foregroundStyle(.green)
          Button("マージコミットで取り込む") {
            adopt(plan)
          }
          .buttonStyle(.borderedProminent)
        } else {
          Label(
            "次の確認が完了するまで取り込めません:",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.orange)
          ForEach(plan.blockers, id: \.self) { blocker in
            Text("• \(blocker.displayName)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func conflictSection(_ conflict: ProjectBranchConflict) -> some View {
    GroupBox("コンフリクトの解決が必要です") {
      VStack(alignment: .leading, spacing: 8) {
        Label(
          "Gitは対象をマージ状態のままにしています。担当Agentまたはネイティブのマージ画面で解決してください。",
          systemImage: "exclamationmark.octagon"
        )
        .foregroundStyle(.orange)
        Text("対象: \(conflict.targetRootURL.path)")
          .font(.caption.monospaced())
          .textSelection(.enabled)
        ForEach(conflict.paths, id: \.self) { path in
          Text("• \(path)")
            .font(.caption)
        }
        Text("これらのパスを解決してから、ProjectのGit状態を更新して続行してください。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var errorAlertIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { isPresented in
        if !isPresented {
          errorMessage = nil
        }
      }
    )
  }

  private var cleanupAlertIsPresented: Binding<Bool> {
    Binding(
      get: { cleanupPlan != nil },
      set: { isPresented in
        if !isPresented {
          cleanupPlan = nil
        }
      }
    )
  }

  private func makeReviewService(for worktree: ManagedWorktree) -> ProjectBranchReviewService {
    ProjectBranchReviewService(
      source: worktree,
      targetRootURL: project.rootURL
    )
  }

  private func reviewBranch() {
    guard let reviewService else {
      return
    }
    do {
      branchReview = try reviewService.review()
      adoptionPlan = nil
      conflict = nil
      statusMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func prepareAdoption() {
    guard let reviewService else {
      return
    }
    do {
      let plan = try reviewService.prepareAdoption()
      branchReview = plan.review
      adoptionPlan = plan
      conflict = nil
      statusMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func adopt(_ plan: ProjectBranchAdoptionPlan) {
    guard let reviewService else {
      return
    }
    do {
      switch try reviewService.adopt(plan) {
      case .adopted(let mergeRevision):
        adoptionPlan = nil
        conflict = nil
        statusMessage = "マージコミット \(mergeRevision.prefix(8)) で取り込みました。"
        surface.reload()
        worktreeCoordinator.refresh(project: project)
      case .conflict(let conflict):
        adoptionPlan = nil
        self.conflict = conflict
        statusMessage = nil
      }
    } catch {
      adoptionPlan = nil
      errorMessage = error.localizedDescription
    }
  }

  private func prepareCleanup(for worktree: ManagedWorktree) {
    let activeSessionIDs = agentWorkflow.activeSessionIDs(for: worktree.id)
      .union(surface.sessionIDsInUse(for: worktree.id))
    cleanupPlan = worktreeCoordinator.prepareCleanup(
      project: project,
      worktreeID: worktree.id,
      activeSessionIDs: activeSessionIDs,
      expectedRootURL: worktree.rootURL
    )
  }

  private func confirmCleanup() {
    guard let cleanupPlan else {
      return
    }
    let activeSessionIDs = agentWorkflow.activeSessionIDs(for: cleanupPlan.worktreeID)
      .union(surface.sessionIDsInUse(for: cleanupPlan.worktreeID))
    let didRemove = worktreeCoordinator.confirmCleanup(
      project: project,
      plan: cleanupPlan,
      activeSessionIDs: activeSessionIDs
    )
    if didRemove, selectedWorktreeID == cleanupPlan.worktreeID {
      selectedWorktreeID = nil
      reviewService = nil
      branchReview = nil
      adoptionPlan = nil
    }
    self.cleanupPlan = nil
  }
}

/// The full-width diff for whichever file source control has selected.
///
/// A 30px file row sits between the tool's own `MainHeader` and the diff: the
/// path, and a pill saying whether that file is staged, untracked, or just
/// changed. It is deliberately on the deeper panel ground so the diff below it
/// reads as the canvas.
private struct ProjectDiffPreview: View {
  @ObservedObject var surface: ProjectSurfaceModel
  let onOpenInEditor: (() -> Void)?

  init(
    surface: ProjectSurfaceModel,
    onOpenInEditor: (() -> Void)? = nil
  ) {
    _surface = ObservedObject(wrappedValue: surface)
    self.onOpenInEditor = onOpenInEditor
  }

  var body: some View {
    Group {
      if let diff = surface.selectedGitDiff {
        VStack(alignment: .leading, spacing: 0) {
          fileRow(diff)
          if diff.text.isEmpty {
            Text("この状態では差分を利用できません。")
              .font(WorkspaceChrome.chromeFont(size: 12))
              .foregroundStyle(WorkspaceChrome.textTertiary)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
          } else {
            CodeMirrorDiffView(path: diff.change.path, patch: diff.text)
          }
        }
        .background(WorkspaceChrome.canvas)
      } else {
        ChromeEmptyState(
          symbol: "doc.on.doc",
          title: "差分を選択してください",
          message: "パネルでファイルを選ぶと、その変更がここに出ます。"
        )
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceChrome.canvas)
      }
    }
    .background(WorkspaceChrome.canvas)
  }

  /// The same breadcrumb row the editor pane draws, so a diff and a file read
  /// as the same kind of surface rather than two different ones.
  private func fileRow(_ diff: ProjectGitDiff) -> some View {
    PathBreadcrumb(path: diff.change.path, rootURL: surface.rootURL) {
      Button("エディタで開く") {
        surface.revealGitChange(relativePath: diff.change.path)
        if surface.lastNavigationErrorMessage == nil {
          onOpenInEditor?()
        }
      }
      .buttonStyle(.plain)
      .font(WorkspaceChrome.chromeFont(size: 10))
      .foregroundStyle(WorkspaceChrome.textQuaternary)
      statusPill(diff)
    }
  }

  private func statusPill(_ diff: ProjectGitDiff) -> some View {
    let untracked = diff.change.isUntracked
    let staged = diff.basis == .staged
    let tint: Color =
      untracked
      ? WorkspaceChrome.attention : staged ? WorkspaceChrome.success : WorkspaceChrome.textTertiary
    let ground: Color =
      untracked
      ? WorkspaceChrome.attention.opacity(0.14)
      : staged ? WorkspaceChrome.success.opacity(0.14) : WorkspaceChrome.washRaised

    return Text(untracked ? "未追跡" : staged ? "ステージ済み" : "変更あり")
      .font(WorkspaceChrome.chromeFont(size: 9, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 6)
      .frame(height: 16)
      .background(ground, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
  }
}

private struct ProjectFileTreeView: View {
  @ObservedObject var surface: ProjectSurfaceModel
  let onOpenProject: () -> Void
  @State private var isProjectsExpanded = true

  var body: some View {
    VStack(spacing: 0) {
      SidebarPanelHeader(title: WorkspaceActivity.files.title) {
        if surface.fileTree.isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(WorkspaceChrome.textTertiary)
            .scaleEffect(0.7)
            .frame(width: 16, height: 16)
            .accessibilityLabel("ファイルを読み込み中")
        }
        ChromeActionButton(width: 20, height: 20, help: "Projectフォルダを開く", action: onOpenProject) {
          Image(systemName: "folder.badge.plus")
            .font(.system(size: 11, weight: .medium))
        }
        ChromeActionButton(width: 20, height: 20, help: "ファイルツリーを更新", action: surface.reload) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 11, weight: .medium))
        }
      }

      if isProjectsExpanded {
        if let root = surface.fileTree.root, surface.fileTree.isAvailable {
          ScrollViewReader { proxy in
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleRows(from: root)) { row in
                  switch row.kind {
                  case .node:
                    ProjectFileTreeRow(
                      node: row.node,
                      surface: surface,
                      depth: row.depth,
                      isSelected: surface.selectedNodeID == row.node.id,
                      isExpanded: surface.isExpanded(row.node.id)
                    )
                  case .loadMore:
                    Button {
                      surface.loadMoreChildren(for: row.node.id)
                    } label: {
                      Label("さらに読み込む…", systemImage: "ellipsis")
                        .font(WorkspaceChrome.chromeFont(size: 10))
                        .foregroundStyle(WorkspaceChrome.textQuaternary)
                        .padding(.leading, CGFloat(row.depth * 14) + 10)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                  case .loading:
                    ProgressView()
                      .controlSize(.small)
                      .tint(WorkspaceChrome.textTertiary)
                      .scaleEffect(0.7)
                      .padding(.leading, CGFloat(row.depth * 14) + 10)
                      .frame(height: 24)
                  }
                }
              }
              .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            .onChange(of: surface.selectedNodeID, initial: false) { _, nodeID in
              guard let nodeID else { return }
              withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(nodeID, anchor: .center)
              }
            }
          }
        } else if surface.fileTree.isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(WorkspaceChrome.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ChromeEmptyState(
            symbol: fileTreeSystemImage,
            title: fileTreeTitle,
            message: fileTreeMessage
          )
          Spacer(minLength: 0)
        }
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(WorkspaceChrome.chrome)
  }

  /// The tree as the flat row list the `LazyVStack` can page through: a node
  /// contributes its own row, then its children's only while it is expanded.
  private func visibleRows(from root: ProjectFileTreeNode) -> [ProjectFileTreeVisibleRow] {
    var rows: [ProjectFileTreeVisibleRow] = []
    appendRows(of: root, depth: 0, into: &rows)
    return rows
  }

  private func appendRows(
    of node: ProjectFileTreeNode,
    depth: Int,
    into rows: inout [ProjectFileTreeVisibleRow]
  ) {
    rows.append(ProjectFileTreeVisibleRow(node: node, depth: depth))
    guard node.isDirectory, surface.isExpanded(node.id) else {
      return
    }
    if let children = node.children {
      for child in children {
        appendRows(of: child, depth: depth + 1, into: &rows)
      }
      if node.hasMoreChildren {
        rows.append(
          ProjectFileTreeVisibleRow(node: node, depth: depth + 1, kind: .loadMore)
        )
      }
    } else {
      rows.append(ProjectFileTreeVisibleRow(node: node, depth: depth + 1, kind: .loading))
    }
  }

  private var fileTreeTitle: String {
    switch surface.fileTree.availability {
    case .available:
      "ファイルがありません"
    case .missing:
      "フォルダが見つかりません"
    case .notDirectory:
      "フォルダではありません"
    case .unreadable:
      "フォルダを利用できません"
    }
  }

  private var fileTreeSystemImage: String {
    surface.fileTree.availability == .available
      ? "doc"
      : "exclamationmark.triangle"
  }

  private var fileTreeMessage: String {
    switch surface.fileTree.availability {
    case .available:
      "このProjectフォルダは空です。"
    case .missing:
      "フォルダが移動または削除された可能性があります。戻ってくるとClairが更新します。"
    case .notDirectory:
      "Projectのルートがフォルダではなくなっています。"
    case .unreadable:
      "ClairはこのProjectフォルダを読み込めません。"
    }
  }
}

private struct ProjectQuickOpenView: View {
  @ObservedObject var surface: ProjectSurfaceModel
  let onDismiss: () -> Void
  @State private var query = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("ファイル名またはパスで検索", text: $query)
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            openFirstResult()
          }
        Button("閉じる", action: onDismiss)
          .buttonStyle(.tactile)
          .foregroundStyle(WorkspaceChrome.textTertiary)
      }
      .padding(12)

      Divider()

      if surface.quickOpenIsLoading {
        ProgressView("ファイルを検索中…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if items.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "ファイルがありません" : "一致するファイルがありません",
          systemImage: "doc.text.magnifyingglass",
          description: Text(
            query.isEmpty
              ? "このProjectには開けるファイルがありません。"
              : "別のファイル名またはパスを試してください。"
          )
        )
      } else {
        List(items) { item in
          Button {
            surface.openQuickOpenItem(item)
            if surface.lastNavigationErrorMessage == nil {
              onDismiss()
            }
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(item.title)
                .font(.body.weight(.medium))
              Text(item.relativePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.tactile)
        }
        .listStyle(.inset)
      }
    }
    .frame(minWidth: 480, minHeight: 360)
    .onChange(of: query, initial: true) { _, newValue in
      surface.requestQuickOpenItems(matching: newValue)
    }
  }

  private var items: [ProjectQuickOpenItem] {
    surface.quickOpenResults
  }

  private func openFirstResult() {
    guard let item = items.first else {
      return
    }
    surface.openQuickOpenItem(item)
    if surface.lastNavigationErrorMessage == nil {
      onDismiss()
    }
  }
}

private struct ProjectSearchView: View {
  @ObservedObject var surface: ProjectSurfaceModel
  let onDismiss: () -> Void
  @State private var query = ""
  @State private var replacement = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SidebarPanelHeader(title: WorkspaceActivity.search.title) {
        Text("⌘⇧F")
          .font(WorkspaceChrome.chromeFont(size: 9, weight: .semibold))
          .monospaced()
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .padding(.horizontal, 6)
          .frame(height: 18)
          .background(WorkspaceChrome.panel, in: RoundedRectangle(cornerRadius: 3))
      }

      Divider()
        .background(WorkspaceChrome.border)

      VStack(spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "text.magnifyingglass")
            .foregroundStyle(WorkspaceChrome.textTertiary)
          TextField("フォルダ内を検索…", text: $query)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              surface.requestSearch(query: query)
            }
        }

        HStack(spacing: 8) {
          TextField("置換後の文字列", text: $replacement)
            .textFieldStyle(.roundedBorder)
          Button("検索") {
            surface.requestSearch(query: query)
          }
          .disabled(query.isEmpty)
          Button("置換プレビュー") {
            surface.requestReplacementPreview(query: query, replacement: replacement)
          }
          .disabled(query.isEmpty)
        }

        HStack {
          Text(
            query.isEmpty
              ? "UTF-8のテキストファイルを検索し、Projectの監視結果を更新します。"
              : "\(surface.searchResults.count)件の結果"
          )
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textTertiary)
          Spacer()
        }
      }
      .padding(12)

      if let status = surface.lastNavigationStatusMessage {
        Label(status, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12)
          .padding(.bottom, 8)
      }

      if let preview = surface.replacementPreview {
        GroupBox("置換プレビュー") {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "\(preview.matchCount)件の結果 · \(preview.files.count)ファイル"
            )
            .font(.caption.weight(.semibold))

            ForEach(preview.files) { file in
              HStack {
                Text(file.relativePath)
                  .lineLimit(1)
                Spacer()
                Text("\(file.matchCount)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }

            HStack {
              Spacer()
              Button("エディタバッファに適用") {
                surface.applyReplacement(preview)
              }
              .buttonStyle(.borderedProminent)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      }

      Divider()

      if query.isEmpty {
        ContentUnavailableView(
          "このProjectを検索",
          systemImage: "text.magnifyingglass",
          description: Text("上の入力欄にテキストを入力して置換をプレビューします。")
        )
      } else if surface.searchIsLoading || surface.replacementIsLoading {
        ProgressView("ファイルを検索中…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if surface.searchResults.isEmpty {
        ContentUnavailableView(
          "結果はありません",
          systemImage: "magnifyingglass",
          description: Text("そのテキストを含むUTF-8ファイルはありません。")
        )
      } else {
        List(surface.searchResults) { match in
          Button {
            surface.openSearchMatch(match)
            if surface.lastNavigationErrorMessage == nil {
              onDismiss()
            }
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 6) {
                Text(match.relativePath)
                  .font(.body.weight(.medium))
                  .lineLimit(1)
                Spacer()
                Text("\(match.line):\(match.column)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              Text(match.lineText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.tactile)
        }
        .listStyle(.inset)
      }
    }
    .frame(minWidth: 0, minHeight: 0)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(WorkspaceChrome.chrome)
    .onChange(of: query, initial: true) { _, newValue in
      surface.requestSearch(query: newValue)
    }
  }
}

private enum ProjectActivityFilter: String, CaseIterable, Identifiable {
  case all
  case attention
  case agents

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .all:
      "すべて"
    case .attention:
      "注意"
    case .agents:
      "Agent"
    }
  }
}

private struct ProjectActivityView: View {
  let project: Project
  @ObservedObject var workspace: ProjectWorkspaceModel
  @ObservedObject var surface: ProjectSurfaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  let onOpenAgents: () -> Void

  @State private var filter: ProjectActivityFilter = .all
  @State private var query = ""

  private var projectActivities: [AgentActivity] {
    agentWorkflow.activities(for: project.id)
  }

  private var items: [AgentActivity] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    return projectActivities.filter { activity in
      guard matchesFilter(activity) else {
        return false
      }
      guard !normalizedQuery.isEmpty else {
        return true
      }
      let searchText = [
        activity.source.rawValue,
        activity.kind.rawValue,
        activity.summary ?? "",
      ].joined(separator: " ")
      return searchText.localizedCaseInsensitiveContains(normalizedQuery)
    }
    .sorted { $0.occurredAt > $1.occurredAt }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SidebarPanelHeader(title: WorkspaceActivity.activity.title) {
        Text("\(items.count)")
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textMuted)
        ChromeActionButton(
          width: 20,
          height: 20,
          isActive: agentWorkflow.isMuted(projectID: project.id),
          help: agentWorkflow.isMuted(projectID: project.id)
            ? "Projectの通知をミュート解除" : "Projectの通知をミュート",
          action: {
            agentWorkflow.setMuted(
              !agentWorkflow.isMuted(projectID: project.id),
              projectID: project.id
            )
          },
          label: {
            Image(
              systemName: agentWorkflow.isMuted(projectID: project.id)
                ? "bell.slash" : "bell"
            )
            .font(.system(size: 11, weight: .medium))
          }
        )
      }

      Divider()
        .background(WorkspaceChrome.border)

      HStack(spacing: 8) {
        Picker("絞り込み", selection: $filter) {
          ForEach(ProjectActivityFilter.allCases) { filter in
            Text(filter.title).tag(filter)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(WorkspaceChrome.accent)

        TextField("Agentsを絞り込み", text: $query)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 120, idealWidth: 220)
          .accessibilityLabel("Agentsを絞り込み")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()
        .background(WorkspaceChrome.border)

      if items.isEmpty {
        ContentUnavailableView(
          query.isEmpty && filter == .all ? "アクティビティはまだありません" : "該当するアクティビティはありません",
          systemImage: "bell",
          description: Text(
            query.isEmpty && filter == .all
              ? "このProjectのシグナルがここに表示されます。"
              : "別の絞り込みまたは検索語を試してください。"
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 1) {
            ForEach(items) { activity in
              agentRow(activity)
            }
          }
          .padding(8)
        }
        .background(WorkspaceChrome.canvas)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(WorkspaceChrome.chrome)
  }

  private func agentRow(_ activity: AgentActivity) -> some View {
    let session = activity.sessionID.flatMap { sessionID in
      agentWorkflow.sessions.first { $0.id == sessionID }
    }
    let isMuted = agentWorkflow.isMuted(
      projectID: activity.projectID,
      sessionID: activity.sessionID
    )

    return HStack(alignment: .top, spacing: 10) {
      Image(systemName: activityIcon(for: activity))
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(activityColor(for: activity))
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(activityTitle(for: activity))
            .font(WorkspaceChrome.chromeFont(size: 11, weight: .medium))
          Text(activity.kind.displayName)
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
        }
        Text(activity.occurredAt.formatted(date: .omitted, time: .shortened))
          .font(WorkspaceChrome.chromeFont(size: 9))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
        if let summary = activity.summary {
          Text(summary)
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.textTertiary)
            .lineLimit(2)
        }
        if let session {
          Text(sessionDescription(session))
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
            .lineLimit(1)
        } else if activity.sessionID != nil {
          Text("セッションのメタデータを保持しています。ターミナルは接続されていません")
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
        } else {
          Text("Projectに紐づくシグナル")
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
        }
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 5) {
        if let session {
          Button("ターミナルを表示") {
            workspace.revealTerminal(
              projectID: session.projectID,
              tabID: session.terminalTabID
            )
            surface.workspaceActivity = .files
          }
          .buttonStyle(.tactile)
          .foregroundStyle(WorkspaceChrome.accent)
        } else if activity.sessionID != nil {
          Button("Agentを開く", action: onOpenAgents)
            .buttonStyle(.tactile)
            .foregroundStyle(WorkspaceChrome.textTertiary)
        }

        if let sessionID = activity.sessionID {
          Button(isMuted ? "ミュート解除" : "ミュート") {
            agentWorkflow.setMuted(
              !isMuted,
              projectID: activity.projectID,
              sessionID: sessionID
            )
          }
          .buttonStyle(.tactile)
          .foregroundStyle(isMuted ? WorkspaceChrome.attention : WorkspaceChrome.textQuaternary)
        }
      }
    }
    .padding(9)
    .background(
      activity.shouldNotify
        ? WorkspaceChrome.attention.opacity(0.07) : WorkspaceChrome.surface,
      in: RoundedRectangle(cornerRadius: 5)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 5)
        .stroke(
          activity.shouldNotify
            ? WorkspaceChrome.attention.opacity(0.18) : WorkspaceChrome.border,
          lineWidth: 1
        )
    }
  }

  private func matchesFilter(_ activity: AgentActivity) -> Bool {
    switch filter {
    case .all:
      true
    case .attention:
      activity.shouldNotify
    case .agents:
      true
    }
  }

  private func activityTitle(for activity: AgentActivity) -> String {
    switch activity.source {
    case .bell:
      "ターミナルの注意ベル"
    case .exit:
      activity.exitStatus == 0 ? "Agentが正常終了" : "Agentがエラー終了"
    case .officialHook:
      "公式フック: \(activity.kind.rawValue)"
    }
  }

  private func activityIcon(for activity: AgentActivity) -> String {
    switch activity.source {
    case .bell:
      "bell"
    case .exit:
      activity.exitStatus == 0 ? "checkmark.circle" : "xmark.circle"
    case .officialHook:
      "link"
    }
  }

  private func activityColor(for activity: AgentActivity) -> Color {
    activity.shouldNotify ? WorkspaceChrome.attention : WorkspaceChrome.textTertiary
  }

  private func sessionDescription(_ session: AgentWorkflowSession) -> String {
    switch session.lifecycle {
    case .starting:
      "起動中 · raw terminal · \(session.agent.cwd)"
    case .running:
      "実行中 · raw terminal · \(session.agent.cwd)"
    case .exited(let code):
      "終了 \(code) · raw terminal · \(session.agent.cwd)"
    }
  }
}

/// One row in the flattened tree: a node, plus the two placeholder rows a
/// directory can contribute while its children are still coming.
private struct ProjectFileTreeVisibleRow: Identifiable {
  enum Kind {
    case node
    case loadMore
    case loading
  }

  let node: ProjectFileTreeNode
  let depth: Int
  var kind: Kind = .node

  var id: String {
    switch kind {
    case .node:
      node.id
    case .loadMore:
      "\(node.id)#more"
    case .loading:
      "\(node.id)#loading"
    }
  }
}

private struct ProjectFileTreeRow: View {
  let node: ProjectFileTreeNode
  /// Deliberately *not* `@ObservedObject`: the row only calls into the surface
  /// on tap, and everything it draws is passed in. Observing it here meant one
  /// subscription per row — hundreds of them in a wide tree, every one woken
  /// by any surface publish, including a plain selection change.
  let surface: ProjectSurfaceModel
  let depth: Int
  let isSelected: Bool
  let isExpanded: Bool

  var body: some View {
    // A selected row is a rounded pill inset from the panel's edges, not a
    // full-bleed band: the inset is what makes it read as one object rather
    // than a stripe across the sidebar.
    HStack(spacing: 6) {
      if node.isDirectory {
        Text(isExpanded ? "▾" : "▸")
          .font(.system(size: 9))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .frame(width: 10)
      } else {
        Color.clear.frame(width: 10, height: 1)
      }

      Image(systemName: fileIconSymbol)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(
          isSelected ? WorkspaceChrome.codeBright : WorkspaceChrome.textTertiary
        )
        .frame(width: 12)
        .accessibilityHidden(true)
      Text(node.name)
        .font(WorkspaceChrome.chromeFont(size: 11, weight: isSelected ? .medium : .regular))
        .foregroundStyle(
          isSelected ? WorkspaceChrome.textPrimary : WorkspaceChrome.textTertiary
        )
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .padding(.leading, CGFloat(depth * 14) + 10)
    .padding(.trailing, 10)
    .frame(height: isSelected ? 28 : 26)
    .hoverableRow(
      isSelected: isSelected,
      selectedColor: WorkspaceChrome.washSelected,
      cornerRadius: isSelected ? 7 : 0
    )
    .padding(.horizontal, 8)
    .contentShape(Rectangle())
    .onTapGesture {
      if node.isDirectory {
        surface.toggleExpansion(for: node.id)
      }
      surface.select(nodeID: node.id)
    }
    .id(node.id)
  }

  private var fileIconSymbol: String {
    guard !node.isDirectory else {
      return "folder"
    }

    let fileName = node.name.lowercased()
    switch fileName {
    case "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb":
      return "cube"
    case "dockerfile", "compose.yaml", "compose.yml", "makefile", "cmakelists.txt":
      return "shippingbox"
    case ".env", ".env.local", ".env.development", ".env.production":
      return "gearshape"
    default:
      break
    }

    switch node.url.pathExtension.lowercased() {
    case "jsx", "tsx":
      return "atom"
    case "html", "htm", "xml", "svg", "vue", "svelte", "astro":
      return "chevron.left.forwardslash.chevron.right"
    case "css", "scss", "sass", "less":
      return "paintbrush"
    case "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd":
      return "terminal"
    case "sql":
      return "cylinder"
    case "r":
      return "chart.xyaxis.line"
    case "js", "mjs", "cjs", "ts", "mts", "cts", "swift", "rs", "py", "pyw",
      "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "m", "mm", "java", "kt", "kts",
      "go", "dart", "php", "rb", "rake", "ex", "exs", "erl", "hrl", "fs", "fsx",
      "cs", "vb", "scala", "clj", "cljs", "groovy", "lua", "hs", "lhs", "sol", "zig",
      "nim", "pl", "pm", "asm", "s", "json", "graphql", "gql", "proto":
      return "curlybraces"
    case "md", "markdown", "txt":
      return "doc.plaintext"
    case "yaml", "yml", "toml", "ini", "conf", "config", "properties", "env":
      return "gearshape"
    case "lock":
      return "lock"
    default:
      return "doc.text"
    }
  }
}

private struct ProjectEditorTabHost: View {
  let state: BootstrapState
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel
  @State private var pendingCloseTabID: String?

  var body: some View {
    VStack(spacing: 0) {
      if surface.editorTabs.isEmpty {
        ProjectWorkspaceOverview(state: state, project: project, surface: surface)
      } else {
        tabBar
        Divider()
        if let tab = surface.activeTab {
          ProjectNativeEditorTab(
            tab: tab,
            surface: surface,
            debugSession: surface.debugSession,
            showsDebugGutter: false,
            fontSize: 13,
            wordWrap: false
          )
        } else {
          ContentUnavailableView(
            "アクティブなタブはありません",
            systemImage: "rectangle.on.rectangle",
            description: Text("ファイルタブを選択して続行してください。")
          )
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
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

  private var tabBar: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 2) {
        ForEach(surface.editorTabs) { tab in
          HStack(spacing: 5) {
            Button(tab.displayTitle) {
              surface.activateTab(id: tab.id)
            }
            .buttonStyle(.tactile)
            .lineLimit(1)

            Button {
              requestClose(tab)
            } label: {
              Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
            }
            .buttonStyle(.tactile)
            .accessibilityLabel("\(tab.title)を閉じる")
          }
          .padding(.horizontal, 9)
          .padding(.vertical, 6)
          .background(
            surface.activeTabID == tab.id
              ? Color.accentColor.opacity(0.16)
              : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
          )
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
    }
    .scrollIndicators(.hidden)
  }

  private func requestClose(_ tab: ProjectEditorTab) {
    if tab.isDirty {
      pendingCloseTabID = tab.id
    } else {
      surface.closeTab(id: tab.id)
    }
  }
}

private struct ProjectNativeEditorTab: View {
  @ObservedObject var tab: ProjectEditorTab
  @ObservedObject var surface: ProjectSurfaceModel
  @ObservedObject var debugSession: DebugSessionModel
  let showsDebugGutter: Bool
  let fontSize: Double
  let wordWrap: Bool

  init(
    tab: ProjectEditorTab,
    surface: ProjectSurfaceModel,
    debugSession: DebugSessionModel,
    showsDebugGutter: Bool = false,
    fontSize: Double = 13,
    wordWrap: Bool = false
  ) {
    _tab = ObservedObject(wrappedValue: tab)
    _surface = ObservedObject(wrappedValue: surface)
    _debugSession = ObservedObject(wrappedValue: debugSession)
    self.showsDebugGutter = showsDebugGutter
    self.fontSize = fontSize
    self.wordWrap = wordWrap
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let loadError = tab.loadError {
        VStack(spacing: 20) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 48))
            .foregroundStyle(.orange)
          Text("ファイルを開けませんでした。")
            .font(.title3.weight(.semibold))
          Text(loadError.errorDescription ?? "Unknown error.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        if ProjectEditorEngine.usesAppKitNativeEditor() {
          ProjectSourceEditorView(
            document: tab,
            selection: tab.selectionRequest,
            fontSize: CGFloat(fontSize),
            wordWrap: wordWrap
          ) {
            surface.save(tabID: tab.id)
          }
        } else {
          CodeMirrorEditorView(
            document: tab,
            selection: tab.selectionRequest,
            fontSize: CGFloat(fontSize),
            wordWrap: wordWrap,
            breakpoints: showsDebugGutter
              ? debugSession.breakpoints
                .filter { $0.sourcePath == tab.url.standardizedFileURL.path }
                .map(\.line)
              : [],
            onToggleBreakpoint: showsDebugGutter
              ? { line in
                debugSession.toggleBreakpoint(
                  sourcePath: tab.url.standardizedFileURL.path,
                  line: line
                )
              }
              : nil
          ) {
            surface.save(tabID: tab.id)
          }
        }
      }
    }
    .background(WorkspaceChrome.canvas)
    .alert("エディタの更新に失敗しました", isPresented: editorErrorIsPresented) {
      Button("OK") {
        tab.dismissError()
      }
    } message: {
      Text(tab.lastErrorMessage ?? "エディタで不明なエラーが発生しました。")
    }
  }

  private var editorErrorIsPresented: Binding<Bool> {
    Binding(
      get: { tab.lastErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          tab.dismissError()
        }
      }
    )
  }
}

private struct ProjectWorkspaceOverview: View {
  let state: BootstrapState
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 5) {
          Text("ワークスペース")
            .font(.largeTitle.weight(.semibold))
          Text("ツリーからファイルを選択すると、ネイティブエディタのタブが開きます。")
            .foregroundStyle(.secondary)
        }

        GroupBox("Project") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            detailRow(label: "ID", value: project.id.uuidString)
            detailRow(label: "Root", value: project.rootURL.path)
            detailRow(label: "Color", value: project.color.displayName)
            detailRow(label: "Tree", value: surface.fileTree.availability.displayName)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
          .padding(.vertical, 4)
        }

        GroupBox("ランタイム") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            detailRow(label: "Channel", value: state.profile.channel.rawValue.uppercased())
            detailRow(label: "Bundle", value: state.profile.bundleIdentifier)
            detailRow(label: "Preferences", value: state.profile.preferencesDomain)
            detailRow(label: "データ", value: state.applicationSupportURL?.path ?? "利用できません")
            detailRow(label: "Rustコア", value: rustStatus)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
          .padding(.vertical, 4)
        }

        if let errorMessage = state.errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Label("Swift → Rustのスモークパスは準備完了", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }
      .padding(28)
    }
  }

  private var rustStatus: String {
    let value = String(format: "0x%08X", state.rustSmokeValue)
    return state.rustSmokeSucceeded ? "ready (\(value))" : "failed (\(value))"
  }

  @ViewBuilder
  private func detailRow(label: String, value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.body, design: .monospaced))
    }
  }
}

// MARK: - Workspace Settings Panel

private struct WorkspaceSettingsPanel: View {
  @Binding var fontSize: Double
  @Binding var wordWrap: Bool
  @ObservedObject var mobileBridge: MobileControlRuntimeBridge
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("設定")
            .font(WorkspaceChrome.chromeFont(size: 15, weight: .semibold))
          Text("エディタの設定")
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.textTertiary)
        }
        Spacer()
        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.tactile)
        .foregroundStyle(WorkspaceChrome.textTertiary)
        .background(WorkspaceChrome.surface, in: RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("設定を閉じる")
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 68)

      Divider()
        .background(WorkspaceChrome.border)

      VStack(alignment: .leading, spacing: 14) {
        settingRow(
          title: "フォントサイズ",
          subtitle: "エディタの文字"
        ) {
          Picker("フォントサイズ", selection: $fontSize) {
            Text("11 px").tag(11.0)
            Text("12 px").tag(12.0)
            Text("13 px").tag(13.0)
            Text("14 px").tag(14.0)
            Text("14.5 px").tag(14.5)
            Text("15 px").tag(15.0)
            Text("16 px").tag(16.0)
            Text("17 px").tag(17.0)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
        }

        settingRow(
          title: "行の折り返し",
          subtitle: "長い行をエディタの幅に合わせて折り返します。"
        ) {
          Toggle("行の折り返し", isOn: $wordWrap)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
      }
      .padding(16)

      Divider()
        .background(WorkspaceChrome.border)

      MobileControlSettingsSection(mobileBridge: mobileBridge)
        .padding(16)

      Divider()
        .background(WorkspaceChrome.border)

      HStack {
        Text("変更はすぐに反映されます")
          .font(WorkspaceChrome.chromeFont(size: 9))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
        Spacer()
        Button("完了", action: onDismiss)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .foregroundStyle(WorkspaceChrome.textPrimary)
    .frame(width: 410)
  }

  private func settingRow<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder control: () -> Content
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(WorkspaceChrome.chromeFont(size: 11, weight: .medium))
        Text(subtitle)
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
      }
      Spacer()
      control()
    }
    .frame(minHeight: 58)
  }
}

private struct MobileControlSettingsSection: View {
  @ObservedObject var mobileBridge: MobileControlRuntimeBridge
  @State private var didCopyPairingLink = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Circle()
          .fill(mobileBridge.isEnabled ? Color.green : WorkspaceChrome.textQuaternary)
          .frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 2) {
          Text("モバイル操作")
            .font(WorkspaceChrome.chromeFont(size: 12, weight: .semibold))
          Text(
            mobileBridge.isEnabled
              ? "このMacの作業をプライベート接続から操作できます。"
              : "Macを閉じてもセッションを残す接続を準備します。"
          )
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textTertiary)
        }
        Spacer()
        Button(mobileBridge.isEnabled ? "無効化" : "有効化") {
          mobileBridge.setEnabled(!mobileBridge.isEnabled)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      if mobileBridge.isEnabled {
        VStack(alignment: .leading, spacing: 8) {
          settingValueRow(title: "ローカル endpoint", value: mobileBridge.endpointDescription)
          settingValueRow(
            title: "ホスト fingerprint",
            value: mobileBridge.hostIdentity?.fingerprint ?? "未生成"
          )

          Text("Cloudflare / Tailscale の private route をこの endpoint に向けてから、モバイルと接続してください。")
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)

          HStack(spacing: 8) {
            Button("QRリンクを生成") {
              mobileBridge.createPairingLink()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            if mobileBridge.pairingLink != nil {
              Button("閉じる") {
                mobileBridge.clearPairingLink()
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }
          }

          if let pairingURL = mobileBridge.pairingURLString {
            HStack(alignment: .top, spacing: 12) {
              MobilePairingCodeView(payload: pairingURL)
                .frame(width: 116, height: 116)
                .background(.white, in: RoundedRectangle(cornerRadius: 6))

              VStack(alignment: .leading, spacing: 7) {
                Text("1回限りのペアリングリンク")
                  .font(WorkspaceChrome.chromeFont(size: 10, weight: .medium))
                Text(pairingURL)
                  .font(.system(size: 8, design: .monospaced))
                  .foregroundStyle(WorkspaceChrome.textTertiary)
                  .lineLimit(4)
                  .truncationMode(.middle)
                  .textSelection(.enabled)
                Button(didCopyPairingLink ? "コピーしました" : "リンクをコピー") {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(pairingURL, forType: .string)
                  didCopyPairingLink = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(WorkspaceChrome.surface, in: RoundedRectangle(cornerRadius: 7))
          }

          if !mobileBridge.devices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text("ペアリング済み端末")
                .font(WorkspaceChrome.chromeFont(size: 10, weight: .medium))
              ForEach(mobileBridge.devices) { device in
                HStack(spacing: 8) {
                  Image(systemName: "iphone")
                    .foregroundStyle(WorkspaceChrome.textTertiary)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName)
                      .font(WorkspaceChrome.chromeFont(size: 10))
                    Text(device.scopes.map(\.rawValue).sorted().joined(separator: " / "))
                      .font(WorkspaceChrome.chromeFont(size: 8))
                      .foregroundStyle(WorkspaceChrome.textQuaternary)
                  }
                  Spacer()
                  Button("解除") {
                    mobileBridge.revoke(device)
                  }
                  .buttonStyle(.tactile)
                  .controlSize(.small)
                  .foregroundStyle(.red.opacity(0.8))
                }
              }
            }
            .padding(.top, 2)
          }
        }
      }

      if let error = mobileBridge.lastErrorMessage {
        Text(error)
          .font(WorkspaceChrome.chromeFont(size: 9))
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onChange(of: mobileBridge.pairingLink) { _, newValue in
      if newValue == nil {
        didCopyPairingLink = false
      }
    }
  }

  private func settingValueRow(title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(WorkspaceChrome.chromeFont(size: 9))
        .foregroundStyle(WorkspaceChrome.textQuaternary)
      Spacer(minLength: 8)
      Text(value)
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(WorkspaceChrome.textTertiary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

private struct MobilePairingCodeView: View {
  let payload: String

  var body: some View {
    if let image = Self.makeImage(payload: payload) {
      Image(nsImage: image)
        .resizable()
        .interpolation(.none)
        .antialiased(false)
        .scaledToFit()
        .padding(8)
    } else {
      Image(systemName: "qrcode")
        .font(.system(size: 42))
        .foregroundStyle(.black)
    }
  }

  private static func makeImage(payload: String) -> NSImage? {
    guard
      let data = payload.data(using: .utf8),
      let filter = CIFilter(name: "CIQRCodeGenerator")
    else {
      return nil
    }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else {
      return nil
    }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let representation = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: representation.size)
    image.addRepresentation(representation)
    return image
  }
}
