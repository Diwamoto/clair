import AppKit
import SwiftUI

enum WorkspaceOverlayKind: String, Identifiable {
  case command
  case settings
  case agents

  var id: String {
    rawValue
  }
}

enum WorkspacePaletteMode: String, Equatable {
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

  private var sidebarStrip: some View {
    WorkspaceSidebarStrip(
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

  // The sidebar strip (navigation icon row) is mounted once here, outside the
  // per-tab `sidebarContent`/`mainContent` switches below. Switching between
  // tabs whose content views have different concrete types forces SwiftUI to
  // tear down and rebuild whatever is inside the switch; keeping the nav row
  // outside it means the icon strip itself is never rebuilt, so it can't
  // visibly jump when a tab (e.g. the bell/Activity tab) is selected.
  private func workspaceSurface(project: Project, surface: ProjectSurfaceModel) -> some View {
    HStack(spacing: 0) {
      if isSidebarVisible {
        VStack(spacing: 0) {
          sidebarStrip

          sidebarContent(project: project, surface: surface)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
          minWidth: 204,
          idealWidth: WorkspaceChrome.Metrics.sidebarWidth,
          maxWidth: 340,
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
struct ProjectActivityDetailView: View {
  let project: Project
  @ObservedObject var workspace: ProjectWorkspaceModel
  let surface: ProjectSurfaceModel
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
