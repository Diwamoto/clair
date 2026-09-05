import AppKit
import CoreImage
import SwiftUI

enum WorkspaceOverlayKind: String, Identifiable {
  case quickOpen
  case command
  case settings
  case agents

  var id: String {
    rawValue
  }
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
      if overlay == .quickOpen, let surface = workspace.activeSurface {
        quickOpenOverlay(surface)
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
      agentWorkflow: agentWorkflow,
      onOpenProject: openProject,
      onRenameProject: beginRename,
      onOpenCommand: { openOverlay(.command) },
      onOpenSettings: { openOverlay(.settings) }
    )
  }

  private var activityBar: some View {
    WorkspaceActivityBar(
      workspace: workspace,
      selected: workspace.activeSurface?.workspaceActivity,
      gitChangeCount: workspace.activeSurface?.gitStatus?.changes.count ?? 0,
      agentCount: activeAgentAttentionCount,
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
        openOverlay(.quickOpen)
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
        switch surface.workspaceActivity {
        case .files:
          workspacePane(project: project, surface: surface)
        case .search:
          WorkspaceActivityLayout(
            project: project,
            surface: surface,
            navigation: activityBar,
            showsNavigation: isSidebarVisible,
            context: ProjectSearchView(surface: surface, onDismiss: selectFilesActivity),
            main: editorPane(project: project, surface: surface),
          )
        case .git:
          WorkspaceActivityLayout(
            project: project,
            surface: surface,
            navigation: activityBar,
            showsNavigation: isSidebarVisible,
            context: ProjectGitView(
              workspace: workspace,
              projectID: project.id,
              surface: surface,
              onDismiss: selectFilesActivity
            ),
            main: ProjectDiffPreview(
              surface: surface,
              onOpenInEditor: selectFilesActivity
            )
          )
        case .review:
          WorkspaceActivityLayout(
            project: project,
            surface: surface,
            navigation: activityBar,
            showsNavigation: isSidebarVisible,
            context: ProjectBranchReviewView(
              project: project,
              surface: surface,
              agentWorkflow: agentWorkflow,
              worktreeCoordinator: worktreeCoordinator,
              onDismiss: selectFilesActivity
            ),
            main: editorPane(project: project, surface: surface),
          )
        case .activity:
          WorkspaceActivityLayout(
            project: project,
            surface: surface,
            navigation: activityBar,
            showsNavigation: isSidebarVisible,
            context: ProjectActivityView(
              project: project,
              workspace: workspace,
              surface: surface,
              agentWorkflow: agentWorkflow,
              onOpenAgents: { openOverlay(.agents) }
            ),
            main: ProjectActivityDetailView(
              project: project,
              workspace: workspace,
              surface: surface,
              agentWorkflow: agentWorkflow,
              onOpenAgents: { openOverlay(.agents) }
            ),
          )
        }
      } else {
        welcomeView
      }
    }
  }

  private func workspacePane(project: Project, surface: ProjectSurfaceModel) -> some View {
    ProjectWorkspaceDetail(
      state: state,
      project: project,
      workspace: workspace,
      agentWorkflow: agentWorkflow,
      surface: surface,
      navigation: activityBar,
      showsNavigation: isSidebarVisible,
      fontSize: editorFontSize,
      wordWrap: editorWordWrap,
      onOpenProject: openProject
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

  private var activeAgentAttentionCount: Int {
    guard let projectID = workspace.activeProjectID else {
      return 0
    }
    return agentWorkflow.activities(for: projectID).filter { activity in
      activity.shouldNotify
        && !agentWorkflow.isMuted(projectID: activity.projectID, sessionID: activity.sessionID)
    }.count
  }

  private func selectFilesActivity() {
    workspace.activeSurface?.workspaceActivity = .files
  }

  // MARK: Quick Open Floating Overlay

  private func quickOpenOverlay(_ surface: ProjectSurfaceModel) -> some View {
    Color.black.opacity(0.45)
      .ignoresSafeArea()
      .onTapGesture {
        overlay = nil
      }
      .overlay {
        ProjectQuickOpenView(surface: surface, onDismiss: dismissOverlay)
          .frame(maxWidth: 560, maxHeight: 420)
          .background(WorkspaceChrome.chromeRaised)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
          .padding(.top, 90)
      }
  }

  private var commandOverlay: some View {
    Color.black.opacity(0.45)
      .ignoresSafeArea()
      .onTapGesture {
        overlay = nil
      }
      .overlay {
        WorkspaceCommandPalette(
          surface: commandSurface,
          onDismiss: dismissOverlay
        )
        .frame(maxWidth: 500, maxHeight: 520)
        .background(WorkspaceChrome.chromeRaised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .padding(.top, 36)
      }
  }

  private var lineJumpOverlay: some View {
    Color.black.opacity(0.45)
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
      openOverlay(.quickOpen)
    case .commandPalette:
      openOverlay(.command)
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
      Image(systemName: "folder.badge.plus")
        .font(.system(size: 42))
        .foregroundStyle(.secondary)
      Text("Projectフォルダを開く")
        .font(.title2.weight(.semibold))
      Text("Gitリポジトリと通常のローカルフォルダに対応しています。")
        .foregroundStyle(.secondary)
      Button("フォルダを開く…", action: openProject)
        .keyboardShortcut("o", modifiers: [.command])
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
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
private struct WorkspaceActivityLayout<Context: View, Main: View, Navigation: View>: View {
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel
  let navigation: Navigation
  let showsNavigation: Bool
  let context: Context
  let main: Main

  var body: some View {
    HStack(spacing: 0) {
      if showsNavigation {
        VStack(spacing: 0) {
          navigation
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)

          context
            .frame(
              maxWidth: .infinity,
              maxHeight: .infinity,
              alignment: .topLeading
            )
        }
        .frame(
          minWidth: 204,
          idealWidth: 286,
          maxWidth: 340,
          maxHeight: .infinity,
          alignment: .topLeading
        )
        .background(WorkspaceChrome.surface)

        Divider()
          .background(WorkspaceChrome.border)
      }

      main
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WorkspaceChrome.canvas)
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

  private var latestHistory: ProjectLocalHistoryEntry? {
    surface.historyEntries.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text("アクティビティ")
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
      } else if let latestHistory {
        historyDetail(latestHistory)
      } else {
        VStack(spacing: 10) {
          Image(systemName: "bell")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
          Text("アクティビティはまだありません")
            .font(WorkspaceChrome.chromeFont(size: 13, weight: .semibold))
          Text("ターミナルのシグナルと復元スナップショットがここに表示されます。")
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

  private func historyDetail(_ entry: ProjectLocalHistoryEntry) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("エディタの復元スナップショット", systemImage: "clock.arrow.circlepath")
        .font(WorkspaceChrome.chromeFont(size: 14, weight: .semibold))
        .foregroundStyle(WorkspaceChrome.accent)
      Text(entry.filePath)
        .font(WorkspaceChrome.chromeFont(size: 12, weight: .medium))
      Text(entry.displayLabel)
        .font(WorkspaceChrome.chromeFont(size: 10))
        .foregroundStyle(WorkspaceChrome.textTertiary)
      Text("スナップショットはローカルに保持され、エディタバッファへ復元できます。")
        .font(WorkspaceChrome.chromeFont(size: 11))
        .foregroundStyle(WorkspaceChrome.textSecondary)
      Button("エディタで復元") {
        surface.restoreHistoryEntry(entry)
        surface.workspaceActivity = .files
      }
      .buttonStyle(.borderedProminent)
      Spacer()
    }
    .frame(maxWidth: 620, maxHeight: .infinity, alignment: .topLeading)
    .padding(24)
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

// MARK: - Project Workspace Detail

private struct ProjectWorkspaceDetail<Navigation: View>: View {
  let state: BootstrapState
  let project: Project
  @ObservedObject var workspace: ProjectWorkspaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  @ObservedObject var surface: ProjectSurfaceModel
  let navigation: Navigation
  let showsNavigation: Bool
  let fontSize: Double
  let wordWrap: Bool
  let onOpenProject: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      if showsNavigation {
        VStack(spacing: 0) {
          navigation
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)

          ProjectFileTreeView(surface: surface, onOpenProject: onOpenProject)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 204, idealWidth: 286, maxWidth: 340, maxHeight: .infinity)
        .background(WorkspaceChrome.surface)

        Divider()
          .background(WorkspaceChrome.border)
      }

      ProjectPaneLayoutView(
        state: state,
        project: project,
        surface: surface,
        node: surface.visibleLayout,
        fontSize: fontSize,
        wordWrap: wordWrap
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WorkspaceChrome.canvas)
    .alert("エディタの操作に失敗しました", isPresented: editorErrorIsPresented) {
      Button("OK") {
        surface.dismissEditorError()
      }
    } message: {
      Text(surface.lastEditorErrorMessage ?? "エディタで不明なエラーが発生しました。")
    }
    .alert("Projectの移動に失敗しました", isPresented: navigationErrorIsPresented) {
      Button("OK") {
        surface.dismissNavigationError()
      }
    } message: {
      Text(surface.lastNavigationErrorMessage ?? "Projectの移動で不明なエラーが発生しました。")
    }
    .alert("Git操作に失敗しました", isPresented: gitErrorIsPresented) {
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

  private var editorErrorIsPresented: Binding<Bool> {
    Binding(
      get: { surface.lastEditorErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          surface.dismissEditorError()
        }
      }
    )
  }

  private var navigationErrorIsPresented: Binding<Bool> {
    Binding(
      get: { surface.lastNavigationErrorMessage != nil },
      set: { isPresented in
        if !isPresented {
          surface.dismissNavigationError()
        }
      }
    )
  }

  private var gitErrorIsPresented: Binding<Bool> {
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
}

// MARK: - Workspace Titlebar

private enum WorkspaceTitlebarMetrics {
  static let height: CGFloat = 48
  static let trafficLightTopPadding: CGFloat = 6
  static let trafficLightGutterWidth: CGFloat = 76
  static let projectLabelHeight: CGFloat = 22
  static let projectLabelBottomPadding: CGFloat = 7
  static let projectGroupHeight: CGFloat = 46
  static let surfaceTabHeight: CGFloat = 40
}

private struct WorkspaceTitlebar: View {
  @ObservedObject var workspace: ProjectWorkspaceModel
  let activeProjectID: UUID?
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  let onOpenProject: () -> Void
  let onRenameProject: (Project) -> Void
  let onOpenCommand: () -> Void
  let onOpenSettings: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      // The hidden titlebar leaves the native traffic lights over the leading
      // content. Reserve the same compact gutter as the Interaction Lab.
      Color.clear
        .frame(
          width: WorkspaceTitlebarMetrics.trafficLightGutterWidth,
          height: WorkspaceTitlebarMetrics.height
            - WorkspaceTitlebarMetrics.trafficLightTopPadding
        )
        .padding(.top, WorkspaceTitlebarMetrics.trafficLightTopPadding)

      ProjectGroupStrip(
        workspace: workspace,
        activeProjectID: activeProjectID,
        agentWorkflow: agentWorkflow,
        onSelectProject: selectProject,
        onOpenProject: onOpenProject,
        onRenameProject: onRenameProject
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      HStack(spacing: 6) {
        titlebarAction(
          symbol: "command",
          title: "コマンドウィンドウ",
          action: onOpenCommand
        )
        titlebarAction(
          symbol: "gearshape",
          title: "設定",
          action: onOpenSettings
        )
      }
      .padding(.horizontal, 12)
    }
    .frame(maxWidth: .infinity)
    .frame(height: WorkspaceTitlebarMetrics.height)
    .background {
      WindowZoomDoubleClickHandler()
    }
    .background(WorkspaceChrome.chromeRaised)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(WorkspaceChrome.border)
        .frame(height: 1)
    }
    .accessibilityElement(children: .contain)
  }

  private func selectProject(_ projectID: UUID) {
    _ = workspace.execute(.switchProject(SwitchProjectCommand(projectID: projectID)))
  }

  private func titlebarAction(
    symbol: String,
    title: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(WorkspaceChrome.chromeFont(size: 12, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 34)
        .contentShape(Rectangle())
    }
    .buttonStyle(.tactile)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(WorkspaceChrome.surface, in: RoundedRectangle(cornerRadius: 4))
    .overlay {
      RoundedRectangle(cornerRadius: 4)
        .stroke(WorkspaceChrome.border, lineWidth: 1)
    }
    .help(title)
    .accessibilityLabel(title)
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

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopMonitoring()

    guard window != nil else { return }
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

  func stopMonitoring() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }
}

private struct WorkspaceCommandPalette: View {
  @ObservedObject var surface: CommandSurfaceModel
  let onDismiss: () -> Void

  @State private var query = ""
  @FocusState private var searchFocused: Bool

  private var matches: [CommandSurfaceMatch] {
    surface.matches(for: query)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "command")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.accent)
        VStack(alignment: .leading, spacing: 2) {
          Text("コマンドウィンドウ")
            .font(WorkspaceChrome.chromeFont(size: 15, weight: .semibold))
          Text("エディタ操作を実行")
            .font(WorkspaceChrome.chromeFont(size: 11))
            .foregroundStyle(WorkspaceChrome.textTertiary)
        }
        Spacer()
        Text("Esc")
          .font(WorkspaceChrome.chromeFont(size: 10, weight: .medium))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(WorkspaceChrome.surface, in: RoundedRectangle(cornerRadius: 3))
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 68)

      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(WorkspaceChrome.textTertiary)
        TextField("コマンドを検索", text: $query)
          .textFieldStyle(.plain)
          .font(WorkspaceChrome.chromeFont(size: 14))
          .focused($searchFocused)
          .onSubmit {
            runFirstAvailableMatch()
          }
      }
      .padding(.horizontal, 10)
      .frame(height: 54)
      .background(WorkspaceChrome.canvas, in: RoundedRectangle(cornerRadius: 5))
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .stroke(WorkspaceChrome.borderStrong, lineWidth: 1)
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 8)

      Divider()
        .background(WorkspaceChrome.border)

      ScrollView {
        LazyVStack(spacing: 2) {
          if matches.isEmpty {
            Text("コマンドが見つかりません")
              .font(WorkspaceChrome.chromeFont(size: 11))
              .foregroundStyle(WorkspaceChrome.textTertiary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(18)
          } else {
            ForEach(matches) { match in
              commandRow(match)
            }
          }
        }
        .padding(8)
      }
      .frame(maxHeight: .infinity)

      Divider()
        .background(WorkspaceChrome.border)

      HStack(spacing: 12) {
        Text("↑↓で移動")
        Text("↵で実行")
      }
      .font(WorkspaceChrome.chromeFont(size: 9))
      .foregroundStyle(WorkspaceChrome.textQuaternary)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
    }
    .foregroundStyle(WorkspaceChrome.textPrimary)
    .frame(minWidth: 420, minHeight: 360)
    .onExitCommand(perform: onDismiss)
    .onAppear {
      searchFocused = true
    }
  }

  private func commandRow(_ match: CommandSurfaceMatch) -> some View {
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
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.tactile)
    .foregroundStyle(
      match.availability.isAvailable
        ? WorkspaceChrome.textSecondary : WorkspaceChrome.textQuaternary
    )
    .disabled(!match.availability.isAvailable)
    .help(match.statusText)
  }

  private func runFirstAvailableMatch() {
    guard let match = matches.first(where: { $0.availability.isAvailable }) else {
      return
    }
    run(match)
  }

  private func run(_ match: CommandSurfaceMatch) {
    guard match.availability.isAvailable else {
      return
    }
    _ = surface.invoke(commandID: match.id, source: .commandWindow)
    onDismiss()
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

private struct ProjectGroupStrip: View {
  @ObservedObject var workspace: ProjectWorkspaceModel
  let activeProjectID: UUID?
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  let onSelectProject: (UUID) -> Void
  let onOpenProject: () -> Void
  let onRenameProject: (Project) -> Void

  var body: some View {
    ScrollView(.horizontal) {
      HStack(alignment: .bottom, spacing: 5) {
        ForEach(workspace.projects) { project in
          groupView(project)
        }

        Button(action: onOpenProject) {
          Image(systemName: "plus")
            .font(.system(size: 10, weight: .semibold))
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.tactile)
        .foregroundStyle(WorkspaceChrome.textTertiary)
        .padding(.bottom, WorkspaceTitlebarMetrics.projectLabelBottomPadding)
        .help("Projectフォルダを開く")
        .accessibilityLabel("Projectを開く")
      }
      .frame(maxHeight: .infinity, alignment: .bottom)
    }
    .padding(.trailing, 8)
    .scrollIndicators(.hidden)
    .background(HiddenScrollbarsInstaller())
    .frame(maxHeight: .infinity)
  }

  private func groupView(_ project: Project) -> some View {
    let isActive = project.id == activeProjectID
    let projectSurface = workspace.surface(for: project.id)
    let attentionCount = agentWorkflow.activities(for: project.id).filter { activity in
      activity.shouldNotify
        && !agentWorkflow.isMuted(projectID: activity.projectID, sessionID: activity.sessionID)
    }.count
    let isMuted = agentWorkflow.isMuted(projectID: project.id)
    let isFirstProject = workspace.projects.first?.id == project.id

    return HStack(alignment: .bottom, spacing: 5) {
      Button {
        if !isActive {
          onSelectProject(project.id)
        }
      } label: {
        HStack(spacing: 6) {
          Text(project.name)
            .font(WorkspaceChrome.chromeFont(size: 12, weight: .semibold))
            .frame(maxWidth: 150, alignment: .leading)
            .lineLimit(1)
          if attentionCount > 0 {
            Text(String(attentionCount))
              .font(WorkspaceChrome.chromeFont(size: 8, weight: .bold))
              .foregroundStyle(WorkspaceChrome.canvas)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(WorkspaceChrome.attention, in: Capsule())
          } else if isMuted {
            Image(systemName: "bell.slash")
              .font(.system(size: 8, weight: .medium))
              .foregroundStyle(WorkspaceChrome.textQuaternary)
          }
        }
        .padding(.horizontal, 9)
        .frame(height: WorkspaceTitlebarMetrics.projectLabelHeight)
        .background(
          project.color.workspaceAccent.opacity(isActive ? 0.22 : 0.12),
          in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(
              project.color.workspaceAccent.opacity(isActive ? 0.72 : 0.45),
              lineWidth: 1
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      .buttonStyle(.tactile)
      .foregroundStyle(isActive ? WorkspaceChrome.textPrimary : WorkspaceChrome.textTertiary)
      .padding(.bottom, WorkspaceTitlebarMetrics.projectLabelBottomPadding)
      .help(
        isActive
          ? "\(project.name)（現在のProject）"
          : "\(project.name)（\(project.rootURL.path)）に切り替え"
      )
      .accessibilityLabel("Project \(project.name)")
      .accessibilityValue(
        isActive ? "アクティブ" : "非アクティブ"
      )

      if let projectSurface {
        WorkspaceTabStrip(
          surface: projectSurface,
          accent: project.color.workspaceAccent,
          isProjectActive: isActive,
          onActivateProject: {
            if !isActive {
              onSelectProject(project.id)
            }
          }
        )
        .frame(maxWidth: 360, maxHeight: .infinity)
      }
    }
    .padding(.leading, isFirstProject ? 0 : 10)
    .overlay(alignment: .leading) {
      if !isFirstProject {
        Rectangle()
          .fill(WorkspaceChrome.border.opacity(0.65))
          .frame(width: 1, height: 26)
          .offset(x: 4)
      }
    }
    .frame(height: WorkspaceTitlebarMetrics.projectGroupHeight, alignment: .bottom)
    .contextMenu {
      Button("Project名を変更") {
        onRenameProject(project)
      }
      Menu("Projectカラー") {
        ForEach(ProjectColor.allCases, id: \.self) { color in
          Button {
            _ = workspace.execute(
              .setProjectColor(
                SetProjectColorCommand(projectID: project.id, color: color)
              )
            )
          } label: {
            HStack {
              Circle()
                .fill(color.workspaceAccent)
              Text(color.displayName)
              if color == project.color {
                Image(systemName: "checkmark")
              }
            }
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
        _ = workspace.execute(
          .closeProject(CloseProjectCommand(projectID: project.id))
        )
      }
    }
  }
}

private struct WorkspaceTabStrip: View {
  @ObservedObject var surface: ProjectSurfaceModel
  let accent: Color
  let isProjectActive: Bool
  let onActivateProject: () -> Void
  @State private var pendingCloseTabID: String?

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 2) {
        ForEach(surface.visibleWorkspaceTabs) { item in
          tabView(item)
        }
      }
      .frame(maxHeight: .infinity)
    }
    .scrollIndicators(.hidden)
    .background(HiddenScrollbarsInstaller())
    .frame(maxHeight: WorkspaceTitlebarMetrics.surfaceTabHeight)
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
    let paneNumber = (surface.paneIDs.firstIndex(of: item.paneID) ?? 0) + 1

    return HStack(spacing: 8) {
      Button {
        onActivateProject()
        surface.activateTab(id: tab.id)
      } label: {
        HStack(spacing: 4) {
          WorkspaceSurfaceIcon(kind: tab.kind)
          if surface.paneIDs.count > 1 {
            Text("P\(paneNumber)")
              .font(WorkspaceChrome.chromeFont(size: 9, weight: .semibold))
              .foregroundStyle(WorkspaceChrome.textQuaternary)
          }
          Text(displayTitle(for: tab))
            .font(WorkspaceChrome.chromeFont(size: 11))
            .lineLimit(1)
        }
        .frame(maxWidth: 150, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.tactile)

      statusMark(for: tab)
    }
    .padding(.horizontal, 11)
    .frame(
      minWidth: 124,
      maxWidth: 220,
      minHeight: WorkspaceTitlebarMetrics.surfaceTabHeight,
      maxHeight: WorkspaceTitlebarMetrics.surfaceTabHeight,
      alignment: .leading
    )
    .background(
      isActive ? WorkspaceChrome.canvas : Color.white.opacity(0.012)
    )
    .foregroundStyle(isActive ? WorkspaceChrome.textPrimary : WorkspaceChrome.textTertiary)
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(isActive ? WorkspaceChrome.border : Color.clear, lineWidth: 1)
    }
    .overlay(alignment: .top) {
      Rectangle()
        .fill(isActive ? accent : Color.clear)
        .frame(height: 2)
    }
    .contextMenu {
      Button("タブを閉じる", role: .destructive) {
        requestClose(tab)
      }
    }
    .help("\(tab.title) · \(kindTitle(tab.kind)) · Project-owned pane \(paneNumber)")
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(tab.title), \(kindTitle(tab.kind)), pane \(paneNumber)")
    .accessibilityValue(isActive ? "アクティブ" : "非アクティブ")
  }

  @ViewBuilder
  private func statusMark(for tab: ProjectPaneTab) -> some View {
    if tab.kind == .editor, surface.editorDocument(tabID: tab.id)?.isDirty == true {
      Circle()
        .fill(WorkspaceChrome.attention)
        .frame(width: 6, height: 6)
        .accessibilityLabel("未保存")
    } else if let session = surface.terminalSession(tabID: tab.id) {
      Image(systemName: sessionNeedsAttention(session) ? "bell.fill" : "circle.fill")
        .font(.system(size: 7, weight: .bold))
        .foregroundStyle(
          sessionNeedsAttention(session)
            ? WorkspaceChrome.attention : WorkspaceChrome.terminalState(session.state)
        )
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

  private func displayTitle(for tab: ProjectPaneTab) -> String {
    guard tab.kind == .editor,
      surface.editorDocument(tabID: tab.id)?.isDirty == true
    else {
      return tab.title
    }
    return "\(tab.title) •"
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

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: kind == .terminal ? 13 : 12, weight: .medium))
      .foregroundStyle(color)
      .frame(width: 16, height: 17)
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

  private var color: Color {
    switch kind {
    case .editor:
      WorkspaceChrome.attention
    case .terminal:
      WorkspaceChrome.accent
    case .diff:
      WorkspaceChrome.textTertiary
    }
  }
}

// MARK: - Activity Bar

private struct WorkspaceActivityBar: View {
  @ObservedObject var workspace: ProjectWorkspaceModel
  let selected: WorkspaceActivity?
  let gitChangeCount: Int
  let agentCount: Int
  let onSelect: (WorkspaceActivity) -> Void
  let onQuickOpen: () -> Void

  var body: some View {
    HStack(spacing: 2) {
      ForEach(WorkspaceActivity.allCases) { activity in
        activityButton(activity, badge: badge(for: activity), isActive: selected == activity)
      }

      Spacer(minLength: 4)

      actionButton(
        symbol: "ellipsis",
        hint: "クイックオープンを開く",
        title: "クイックオープン",
        action: onQuickOpen
      )
    }
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
    .background(WorkspaceChrome.chrome)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(WorkspaceChrome.border)
        .frame(height: 1)
    }
  }

  private func activityButton(
    _ activity: WorkspaceActivity,
    badge: Int,
    isActive: Bool
  ) -> some View {
    Button {
      onSelect(activity)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: activity.symbolName)
          .font(.system(size: 13, weight: .medium))
        if badge > 0 {
          Text("\(badge)")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(WorkspaceChrome.canvas)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(WorkspaceChrome.accent, in: Capsule())
        }
      }
      .frame(minWidth: 28, minHeight: 26)
      .padding(.horizontal, 3)
      .contentShape(Rectangle())
    }
    .buttonStyle(.tactile)
    .foregroundStyle(
      isActive ? WorkspaceChrome.accent : WorkspaceChrome.textQuaternary
    )
    .background(
      isActive ? WorkspaceChrome.surfaceActive : Color.clear,
      in: RoundedRectangle(cornerRadius: 4, style: .continuous)
    )
    .overlay(alignment: .bottom) {
      if isActive {
        Rectangle()
          .fill(WorkspaceChrome.accent)
          .frame(width: 18, height: 2)
      }
    }
    .help(activity.accessibilityHint)
    .accessibilityLabel(activity.title)
  }

  private func actionButton(
    symbol: String,
    hint: String,
    title: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .frame(width: 28, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.tactile)
    .foregroundStyle(WorkspaceChrome.textQuaternary)
    .help(hint)
    .accessibilityLabel(title)
  }

  private func badge(for activity: WorkspaceActivity) -> Int {
    switch activity {
    case .files:
      0
    case .search:
      0
    case .git:
      gitChangeCount
    case .review:
      0
    case .activity:
      agentCount
    }
  }
}

// MARK: - Status Bar

private struct WorkspaceStatusBar: View {
  let workspace: ProjectWorkspaceModel
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  @ObservedObject var agentRateLimits: AgentRateLimitCoordinator
  let onOpenAgents: () -> Void
  @AppStorage("clair.agents.show-rate-limits-v1") private var showRateLimits = true

  var body: some View {
    HStack(spacing: 12) {
      statusContent
      Spacer(minLength: 8)
      if showRateLimits {
        AgentRateLimitStrip(coordinator: agentRateLimits)
      }
      Spacer(minLength: 8)
      surfaceMetadata
      agentSummary
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    .font(WorkspaceChrome.chromeFont(size: 11))
    .foregroundStyle(WorkspaceChrome.textTertiary)
    .background(WorkspaceChrome.chrome)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(WorkspaceChrome.border)
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

  @ViewBuilder
  private var statusContent: some View {
    if let gitStatus = surface.gitStatus, gitStatus.isRepository {
      Label(gitStatus.branch ?? "HEAD", systemImage: "arrow.triangle.branch")
      if let upstream = gitStatus.upstream {
        Text(upstream)
          .foregroundStyle(WorkspaceChrome.textQuaternary)
      }
      if gitStatus.ahead != 0 || gitStatus.behind != 0 {
        Text("↓\(gitStatus.behind) ↑\(gitStatus.ahead)")
          .foregroundStyle(WorkspaceChrome.textQuaternary)
      }
      if let session = surface.focusedPaneSession {
        Text("·")
          .foregroundStyle(WorkspaceChrome.textQuaternary)
        terminalInfo(session)
      }
    } else {
      if let session = surface.focusedPaneSession {
        terminalInfo(session)
      } else {
        Text(project.rootURL.path)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(WorkspaceChrome.textQuaternary)
      }
    }
  }

  private func terminalInfo(_ session: TerminalSession) -> some View {
    HStack(spacing: 6) {
      Label(session.statusDescription, systemImage: "terminal")
      Text("\(session.dimensions.columns)×\(session.dimensions.rows)")
        .monospacedDigit()
        .foregroundStyle(WorkspaceChrome.textQuaternary)
    }
  }

  private var agentSummary: some View {
    let sessions = agentWorkflow.sessions.filter { $0.projectID == project.id }
    let liveCount = sessions.filter(\.isActive).count
    return HStack(spacing: 8) {
      if liveCount > 0 {
        Label("\(liveCount) 実行中", systemImage: "terminal.fill")
          .foregroundStyle(WorkspaceChrome.success)
      }
      Button {
        onOpenAgents()
      } label: {
        Label("Agentを追加", systemImage: "person.2")
      }
      .buttonStyle(.tactile)
      .help("Agent追加画面を開く")
    }
  }

  @ViewBuilder
  private var surfaceMetadata: some View {
    if let tab = surface.activeTab(in: surface.focusedPaneID) {
      switch tab.kind {
      case .editor:
        Text(
          surface.editorDocument(tabID: tab.id)?.isDirty == true
            ? "未保存の変更" : "保存済み"
        )
        .foregroundStyle(
          surface.editorDocument(tabID: tab.id)?.isDirty == true
            ? WorkspaceChrome.attention : WorkspaceChrome.textQuaternary
        )
        Text(tab.title)
          .lineLimit(1)
          .truncationMode(.middle)
        if let filePath = tab.filePath {
          Text(languageName(for: filePath))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
        }
      case .terminal:
        if let session = surface.terminalSession(tabID: tab.id) {
          Text(session.statusDescription)
            .foregroundStyle(WorkspaceChrome.terminalState(session.state))
        }
        Text(tab.title)
          .lineLimit(1)
        Text("ターミナル")
          .foregroundStyle(WorkspaceChrome.textQuaternary)
      case .diff:
        Text("差分")
          .foregroundStyle(WorkspaceChrome.textQuaternary)
        Text(tab.title)
          .lineLimit(1)
      }
    }
  }

  private func languageName(for path: String) -> String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "swift":
      "Swift"
    case "md", "markdown":
      "Markdown"
    case "json":
      "JSON"
    case "yaml", "yml":
      "YAML"
    case "toml":
      "TOML"
    case "rs":
      "Rust"
    default:
      "Plain text"
    }
  }
}

private struct AgentRateLimitStrip: View {
  @ObservedObject var coordinator: AgentRateLimitCoordinator

  var body: some View {
    HStack(spacing: 3) {
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
      HStack(spacing: 8) {
        ZStack {
          Circle()
            .fill(WorkspaceChrome.surfaceHover)
          Circle()
            .stroke(WorkspaceChrome.border, lineWidth: 1)
          Image(systemName: provider.systemImage)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(WorkspaceChrome.textSecondary)
        }
        .frame(width: 19, height: 19)

        VStack(alignment: .leading, spacing: 1) {
          Text(summaryTitle)
            .font(WorkspaceChrome.chromeFont(size: 11, weight: .semibold))
            .foregroundStyle(WorkspaceChrome.textSecondary)
          Text(summaryDetail)
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(summaryDetailColor)
            .lineLimit(1)
        }

        if let usedPercent = snapshot?.primaryWindow?.usedPercent {
          AgentRateLimitMeter(usedPercent: usedPercent)
            .frame(width: 34, height: 4)
        } else if coordinator.phase == .loading, snapshot == nil {
          ProgressView()
            .controlSize(.mini)
            .frame(width: 18, height: 18)
        }
      }
      .padding(.horizontal, 7)
      .frame(height: 28)
      .background(
        isPresented ? WorkspaceChrome.surfaceHover : Color.clear,
        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(isPresented ? WorkspaceChrome.border : Color.clear, lineWidth: 1)
      }
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
        Image(systemName: provider?.systemImage ?? "sparkles")
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
    snapshot.primaryWindow?.resetDescription() ?? snapshot.detail ?? snapshot.planType
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
        Image(systemName: provider.systemImage)
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
  @State private var newWorktreeBranch = ""
  @State private var newWorktreeTargetName = ""
  @State private var cleanupPlan: ManagedWorktreeCleanupPlan?

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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Label("Agentワークフロー", systemImage: "person.2")
          .font(.title3.weight(.semibold))
        Text(project.name)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Button("閉じる", action: dismiss.callAsFunction)
          .buttonStyle(.tactile)
      }
      .padding(12)

      Divider()

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
      Text(selectedWorktree == nil ? "Projectルートで起動" : "管理対象worktreeで起動")
        .font(.headline)
      Text(selectedExecutionRoot.path)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      Picker("起動場所", selection: $selectedWorktreeID) {
        Text("Projectルート").tag(nil as WorktreeID?)
        ForEach(projectWorktrees.filter { $0.state == .available }) { worktree in
          Text(
            "\(worktree.branch) — \(worktree.state.displayName)"
          )
          .tag(worktree.id as WorktreeID?)
        }
      }
      .pickerStyle(.menu)

      HStack(spacing: 8) {
        ForEach(AgentLaunchProfile.all) { profile in
          Button {
            launch(profile: profile)
          } label: {
            Label(profile.displayName, systemImage: "terminal")
          }
          .buttonStyle(.borderedProminent)
        }
      }
    }
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

  private func launch(profile: AgentLaunchProfile) {
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
  }

  private func agentSessionRow(_ session: AgentWorkflowSession) -> some View {
    HStack(spacing: 10) {
      Image(systemName: session.isActive ? "circle.fill" : "circle")
        .foregroundStyle(session.isActive ? .green : .secondary)
        .font(.caption)
      VStack(alignment: .leading, spacing: 2) {
        Text(session.profile?.displayName ?? "不明なAgent")
          .font(.body.weight(.medium))
        Text(lifecycleDescription(for: session))
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

private struct ProjectTerminalPanel: View {
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
                Divider()
                nodeView(second)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
              }
            } else {
              VStack(spacing: 0) {
                nodeView(first)
                  .frame(height: proxy.size.height * fraction)
                Divider()
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
    .overlay {
      RoundedRectangle(cornerRadius: 4)
        .stroke(
          surface.isFocusedPane(paneID)
            ? WorkspaceChrome.accent.opacity(0.7) : Color.clear,
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
          ProjectNativeEditorTab(
            tab: document,
            surface: surface,
            fontSize: fontSize,
            wordWrap: wordWrap
          )
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
      VStack(spacing: 8) {
        Image(systemName: "rectangle.split.3x1")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text("空のペイン")
          .font(.headline)
        Text("エディタ、ターミナル、または差分タブを開いてください。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
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
          WorkspaceChrome.chromeRaised.opacity(0.9),
          in: RoundedRectangle(cornerRadius: 4)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 4)
            .stroke(WorkspaceChrome.border, lineWidth: 1)
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

private struct ProjectGitView: View {
  @ObservedObject var workspace: ProjectWorkspaceModel
  let projectID: UUID
  @ObservedObject var surface: ProjectSurfaceModel
  let onDismiss: () -> Void
  @State private var commitMessage = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()

      if let status = surface.gitStatus, status.isRepository {
        branchSummary(status)
        Divider()
        changeList(status)
        Divider()
        commitBar(status)
      } else if let status = surface.gitStatus {
        ContentUnavailableView(
          "Gitを利用できません",
          systemImage: "arrow.triangle.branch",
          description: Text(status.message ?? "このProjectはGitリポジトリではありません。")
        )
      } else {
        ContentUnavailableView(
          "Gitの状態を取得できません",
          systemImage: "arrow.triangle.branch",
          description: Text("Gitの状態を更新してProjectを確認してください。")
        )
      }
    }
    .frame(minWidth: 0, minHeight: 0)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(WorkspaceChrome.surface)
    .onAppear {
      refresh()
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Label("ソース管理", systemImage: "arrow.triangle.branch")
        .font(WorkspaceChrome.chromeFont(size: 15, weight: .semibold))
        .foregroundStyle(WorkspaceChrome.textSecondary)
      Spacer()
      if let status = surface.gitStatus, status.isRepository {
        Text("\(status.changes.count)")
          .font(WorkspaceChrome.chromeFont(size: 10, weight: .bold))
          .foregroundStyle(WorkspaceChrome.textSecondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(WorkspaceChrome.surfaceActive, in: Capsule())
      }
      Button {
        refresh()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.tactile)
      .foregroundStyle(WorkspaceChrome.textTertiary)
      .help("Gitの状態を更新")
    }
    .padding(.horizontal, 20)
    .frame(height: 64)
    .background(WorkspaceChrome.surface)
  }

  private func branchSummary(_ status: ProjectGitSnapshot) -> some View {
    HStack(spacing: 12) {
      Menu {
        if status.branches.isEmpty {
          Text("ローカルブランチはありません")
        } else {
          ForEach(status.branches, id: \.self) { branch in
            Button {
              switchBranch(branch)
            } label: {
              HStack {
                Text(branch)
                if branch == status.branch {
                  Image(systemName: "checkmark")
                }
              }
            }
          }
        }
      } label: {
        Label(status.branch ?? "HEAD", systemImage: "arrow.triangle.branch")
      }
      .buttonStyle(.bordered)

      if let upstream = status.upstream {
        Text(upstream)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if status.ahead != 0 || status.behind != 0 {
        Text("↓\(status.behind) ↑\(status.ahead)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text("\(status.changes.count)件の変更")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .background(WorkspaceChrome.surface)
  }

  @ViewBuilder
  private func changeList(_ status: ProjectGitSnapshot) -> some View {
    if status.changes.isEmpty {
      ContentUnavailableView(
        "ワークツリーはクリーンです",
        systemImage: "checkmark.circle",
        description: Text("ステージ済み、未ステージ、未追跡の変更はありません。")
      )
    } else {
      List {
        if !status.stagedChanges.isEmpty {
          Section("ステージ済みの変更 (\(status.stagedCount))") {
            ForEach(status.stagedChanges) { change in
              changeRow(change, basis: .staged, mutationTitle: "ステージ解除") {
                unstage(change)
              }
            }
          }
        }
        if !status.unstagedChanges.isEmpty {
          Section("変更 (\(status.unstagedCount))") {
            ForEach(status.unstagedChanges) { change in
              changeRow(change, basis: .workingTree, mutationTitle: "ステージ") {
                stage(change)
              }
            }
          }
        }
        if !status.untrackedChanges.isEmpty {
          Section("未追跡の変更 (\(status.untrackedCount))") {
            ForEach(status.untrackedChanges) { change in
              changeRow(change, basis: .workingTree, mutationTitle: "ステージ") {
                stage(change)
              }
            }
          }
        }
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
      .background(WorkspaceChrome.surface)
    }
  }

  private func changeRow(
    _ change: ProjectGitChange,
    basis: ProjectGitDiffBasis,
    mutationTitle: String,
    mutation: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 8) {
      Button {
        surface.revealGitChange(relativePath: change.path)
        if surface.lastNavigationErrorMessage == nil {
          onDismiss()
        }
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(change.displayPath)
            .lineLimit(1)
          Text(change.kind.displayName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.tactile)

      Button("差分") {
        _ = workspace.execute(
          .gitShowDiff(
            GitShowDiffCommand(
              projectID: projectID,
              relativePath: change.path,
              basis: basis
            )
          )
        )
      }
      .buttonStyle(.tactile)

      Button(mutationTitle, action: mutation)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .padding(.vertical, 2)
  }

  private func commitBar(_ status: ProjectGitSnapshot) -> some View {
    HStack(spacing: 8) {
      TextField("コミットメッセージ", text: $commitMessage)
        .textFieldStyle(.roundedBorder)
      Button("コミット") {
        _ = workspace.execute(
          .gitCommit(
            GitCommitCommand(projectID: projectID, message: commitMessage)
          )
        )
        if workspace.lastErrorMessage == nil {
          commitMessage = ""
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(
        status.stagedChanges.isEmpty
          || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
    }
    .padding(12)
    .background(WorkspaceChrome.surface)
  }

  private func refresh() {
    _ = workspace.execute(.gitRefresh(GitRefreshCommand(projectID: projectID)))
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

  private func switchBranch(_ branch: String) {
    _ = workspace.execute(
      .gitSwitchBranch(
        GitSwitchBranchCommand(projectID: projectID, branch: branch)
      )
    )
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
      HStack(spacing: 10) {
        Label("変更を確認", systemImage: "checkmark.shield")
          .font(WorkspaceChrome.chromeFont(size: 15, weight: .semibold))
          .foregroundStyle(WorkspaceChrome.textSecondary)
        Text(project.name)
          .font(WorkspaceChrome.chromeFont(size: 11))
          .foregroundStyle(WorkspaceChrome.textTertiary)
          .lineLimit(1)
        Spacer()
        Button("閉じる", action: onDismiss)
          .buttonStyle(.tactile)
          .foregroundStyle(WorkspaceChrome.textTertiary)
      }
      .padding(.horizontal, 20)
      .frame(height: 64)
      .background(WorkspaceChrome.surface)

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
    .background(WorkspaceChrome.surface)
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
          HStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
              .foregroundStyle(WorkspaceChrome.accent)
            Text(diff.change.displayPath)
              .font(WorkspaceChrome.chromeFont(size: 13, weight: .semibold))
              .lineLimit(1)
            Text(diff.basis.displayName)
              .font(WorkspaceChrome.chromeFont(size: 10))
              .foregroundStyle(WorkspaceChrome.textTertiary)
            Spacer()
            Button("エディタで開く") {
              surface.revealGitChange(relativePath: diff.change.path)
              if surface.lastNavigationErrorMessage == nil {
                onOpenInEditor?()
              }
            }
            .buttonStyle(.tactile)
            .foregroundStyle(WorkspaceChrome.accent)
          }
          .padding(.horizontal, 20)
          .frame(minHeight: 76)
          .background(WorkspaceChrome.surface)
          Divider().background(WorkspaceChrome.border)
          ScrollView {
            Text(diff.text.isEmpty ? "この状態では差分を利用できません。" : diff.text)
              .font(.system(.body, design: .monospaced))
              .foregroundStyle(WorkspaceChrome.textSecondary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(16)
          }
        }
        .background(WorkspaceChrome.canvas)
      } else {
        VStack(spacing: 12) {
          Image(systemName: "doc.on.doc")
            .font(.system(size: 34))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
          Text("Git差分")
            .font(WorkspaceChrome.chromeFont(size: 14, weight: .semibold))
          Text(
            "Gitパネルから差分を選択すると、ステージ済み、ワークツリー、未追跡の変更を確認できます。"
          )
          .font(WorkspaceChrome.chromeFont(size: 11))
          .foregroundStyle(WorkspaceChrome.textTertiary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .foregroundStyle(WorkspaceChrome.textPrimary)
        .background(WorkspaceChrome.canvas)
      }
    }
    .background(WorkspaceChrome.canvas)
  }
}

private struct ProjectFileTreeView: View {
  @ObservedObject var surface: ProjectSurfaceModel
  let onOpenProject: () -> Void
  @State private var isProjectsExpanded = true

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 5) {
        Button {
          withAnimation(.easeOut(duration: 0.12)) {
            isProjectsExpanded.toggle()
          }
        } label: {
          Image(systemName: isProjectsExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .frame(width: 14, height: 20)
        }
        .buttonStyle(.tactile)
        .foregroundStyle(WorkspaceChrome.textQuaternary)
        .help(isProjectsExpanded ? "Project一覧を折りたたむ" : "Project一覧を展開")
        .accessibilityLabel("Project一覧")
        .accessibilityValue(isProjectsExpanded ? "展開" : "折りたたみ")

        Text("PROJECTS")
          .font(WorkspaceChrome.chromeFont(size: 10, weight: .semibold))
          .kerning(0.7)
          .foregroundStyle(WorkspaceChrome.textTertiary)

        Spacer()
        if surface.fileTree.isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(WorkspaceChrome.accent)
            .accessibilityLabel("ファイルを読み込み中")
        }
        navigatorAction(
          symbol: "folder.badge.plus",
          title: "Projectフォルダを開く",
          action: onOpenProject
        )
        navigatorAction(
          symbol: "arrow.clockwise",
          title: "ファイルツリーを更新",
          action: surface.reload
        )
      }
      .padding(.horizontal, 10)
      .frame(height: 34)
      .background(WorkspaceChrome.surface)

      Divider()
        .background(WorkspaceChrome.border)

      if isProjectsExpanded {
        if let root = surface.fileTree.root, surface.fileTree.isAvailable {
          ScrollViewReader { proxy in
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 0) {
                ProjectFileTreeRow(node: root, surface: surface, depth: 0)
              }
              .padding(.vertical, 4)
            }
            .onChange(of: surface.selectedNodeID, initial: false) { _, nodeID in
              guard let nodeID else { return }
              withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(nodeID, anchor: .center)
              }
            }
          }
        } else if surface.fileTree.isLoading {
          ProgressView("ファイルを読み込み中…")
            .tint(WorkspaceChrome.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView(
            fileTreeTitle,
            systemImage: fileTreeSystemImage,
            description: Text(fileTreeMessage)
          )
          .padding(16)
        }
      }
    }
    .frame(maxHeight: .infinity)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(WorkspaceChrome.surface)
  }

  private func navigatorAction(
    symbol: String,
    title: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .medium))
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.tactile)
    .foregroundStyle(WorkspaceChrome.textTertiary)
    .help(title)
    .accessibilityLabel(title)
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
      HStack {
        Text("検索")
          .font(WorkspaceChrome.chromeFont(size: 15, weight: .semibold))
        Spacer()
        Text("⌘⇧F")
          .font(WorkspaceChrome.chromeFont(size: 10, weight: .medium))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(WorkspaceChrome.surfaceActive, in: RoundedRectangle(cornerRadius: 3))
      }
      .padding(.horizontal, 20)
      .frame(height: 64)
      .background(WorkspaceChrome.surface)

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
    .background(WorkspaceChrome.surface)
    .onChange(of: query, initial: true) { _, newValue in
      surface.requestSearch(query: newValue)
    }
  }
}

private enum ProjectActivityFilter: String, CaseIterable, Identifiable {
  case all
  case attention
  case agents
  case files

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
    case .files:
      "ファイル"
    }
  }
}

private enum ProjectActivityItem: Identifiable {
  case agent(AgentActivity)
  case history(ProjectLocalHistoryEntry)

  var id: String {
    switch self {
    case .agent(let activity):
      "agent:\(activity.id.uuidString)"
    case .history(let entry):
      "history:\(entry.id.uuidString)"
    }
  }

  var occurredAt: Date {
    switch self {
    case .agent(let activity):
      activity.occurredAt
    case .history(let entry):
      entry.createdAt
    }
  }

  var searchText: String {
    switch self {
    case .agent(let activity):
      [
        activity.source.rawValue,
        activity.kind.rawValue,
        activity.summary ?? "",
      ].joined(separator: " ")
    case .history(let entry):
      [entry.filePath, entry.reason.displayName, entry.displayLabel].joined(separator: " ")
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

  private var items: [ProjectActivityItem] {
    let all =
      projectActivities.map(ProjectActivityItem.agent)
      + surface.historyEntries.map(ProjectActivityItem.history)
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    return all.filter { item in
      guard matchesFilter(item) else {
        return false
      }
      guard !normalizedQuery.isEmpty else {
        return true
      }
      return item.searchText.localizedCaseInsensitiveContains(normalizedQuery)
    }
    .sorted { $0.occurredAt > $1.occurredAt }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("アクティビティ")
            .font(WorkspaceChrome.chromeFont(size: 15, weight: .semibold))
          Text("通知、Agent、復元履歴")
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.textQuaternary)
        }
        Spacer(minLength: 8)
        Text("\(items.count)")
          .font(WorkspaceChrome.chromeFont(size: 10, weight: .bold))
          .foregroundStyle(WorkspaceChrome.textSecondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(WorkspaceChrome.surfaceActive, in: Capsule())
        Button {
          agentWorkflow.setMuted(
            !agentWorkflow.isMuted(projectID: project.id),
            projectID: project.id
          )
        } label: {
          Label(
            agentWorkflow.isMuted(projectID: project.id) ? "ミュート解除" : "ミュート",
            systemImage: agentWorkflow.isMuted(projectID: project.id)
              ? "bell.slash" : "bell"
          )
        }
        .buttonStyle(.tactile)
        .foregroundStyle(
          agentWorkflow.isMuted(projectID: project.id)
            ? WorkspaceChrome.attention : WorkspaceChrome.textTertiary
        )
        .help("ProjectのAgent通知をミュート/ミュート解除")
        .accessibilityLabel(
          agentWorkflow.isMuted(projectID: project.id)
            ? "Projectの通知をミュート解除" : "Projectの通知をミュート"
        )
      }
      .padding(.horizontal, 20)
      .frame(height: 64)
      .background(WorkspaceChrome.surface)

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

        TextField("アクティビティを絞り込み", text: $query)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 120, idealWidth: 220)
          .accessibilityLabel("アクティビティを絞り込み")
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
              ? "このProjectのシグナルとファイル復元スナップショットがここに表示されます。"
              : "別の絞り込みまたは検索語を試してください。"
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 1) {
            ForEach(items) { item in
              activityRow(item)
            }
          }
          .padding(8)
        }
        .background(WorkspaceChrome.canvas)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .foregroundStyle(WorkspaceChrome.textSecondary)
    .background(WorkspaceChrome.surface)
    .onAppear {
      surface.refreshHistoryEntries()
    }
  }

  @ViewBuilder
  private func activityRow(_ item: ProjectActivityItem) -> some View {
    switch item {
    case .agent(let activity):
      agentRow(activity)
    case .history(let entry):
      historyRow(entry)
    }
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

  private func historyRow(_ entry: ProjectLocalHistoryEntry) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(WorkspaceChrome.textTertiary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 3) {
        Text(entry.filePath)
          .font(WorkspaceChrome.chromeFont(size: 11, weight: .medium))
          .lineLimit(1)
        Text(entry.reason.displayName)
          .font(WorkspaceChrome.chromeFont(size: 9))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
        Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
          .font(WorkspaceChrome.chromeFont(size: 9))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
      }
      Spacer(minLength: 8)
      Button("復元") {
        surface.restoreHistoryEntry(entry)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(9)
    .background(WorkspaceChrome.surface, in: RoundedRectangle(cornerRadius: 5))
    .overlay {
      RoundedRectangle(cornerRadius: 5)
        .stroke(WorkspaceChrome.border, lineWidth: 1)
    }
  }

  private func matchesFilter(_ item: ProjectActivityItem) -> Bool {
    switch filter {
    case .all:
      return true
    case .attention:
      if case .agent(let activity) = item {
        return activity.shouldNotify
      }
      return false
    case .agents:
      if case .agent = item {
        return true
      }
      return false
    case .files:
      if case .history = item {
        return true
      }
      return false
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

private struct ProjectHistoryView: View {
  @ObservedObject var surface: ProjectSurfaceModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Projectの履歴")
            .font(.title3.weight(.semibold))
          Text("スナップショットをエディタバッファに復元します。ディスクへの書き込みは明示的に保存してください。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("閉じる", action: dismiss.callAsFunction)
          .buttonStyle(.tactile)
      }
      .padding(12)

      Divider()

      if surface.historyEntries.isEmpty {
        ContentUnavailableView(
          "履歴スナップショットはありません",
          systemImage: "clock.arrow.circlepath",
          description: Text("ファイルを保存または再読み込みするとClairが復元スナップショットを保持します。")
        )
      } else {
        List(surface.historyEntries) { entry in
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
              Text(entry.filePath)
                .font(.body.weight(.medium))
                .lineLimit(1)
              Text(entry.displayLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("復元") {
              surface.restoreHistoryEntry(entry)
              if surface.lastNavigationErrorMessage == nil {
                dismiss()
              }
            }
            .buttonStyle(.bordered)
          }
        }
        .listStyle(.inset)
      }
    }
    .frame(minWidth: 560, minHeight: 360)
    .onAppear {
      surface.refreshHistoryEntries()
    }
  }
}

private struct ProjectFileTreeRow: View {
  let node: ProjectFileTreeNode
  @ObservedObject var surface: ProjectSurfaceModel
  let depth: Int

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 5) {
        if node.isDirectory {
          Button {
            surface.toggleExpansion(for: node.id)
          } label: {
            Image(
              systemName: surface.isExpanded(node.id)
                ? "chevron.down"
                : "chevron.right"
            )
            .font(.caption2.weight(.bold))
            .frame(width: 14, height: 18)
          }
          .buttonStyle(.tactile)
          .foregroundStyle(WorkspaceChrome.textQuaternary)
        } else {
          Color.clear
            .frame(width: 14, height: 18)
        }

        Image(systemName: fileIconSymbol)
          .foregroundStyle(WorkspaceChrome.textTertiary)
          .accessibilityHidden(true)
        Text(node.name)
          .font(WorkspaceChrome.chromeFont(size: 12))
          .foregroundStyle(WorkspaceChrome.textSecondary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.leading, CGFloat(depth * 14) + 8)
      .padding(.trailing, 8)
      .padding(.vertical, 4)
      .background(
        surface.selectedNodeID == node.id
          ? WorkspaceChrome.surfaceActive
          : Color.clear
      )
      .contentShape(Rectangle())
      .onTapGesture {
        surface.select(nodeID: node.id)
      }
      .id(node.id)

      if node.isDirectory && surface.isExpanded(node.id) {
        if let children = node.children {
          ForEach(children) { child in
            ProjectFileTreeRow(node: child, surface: surface, depth: depth + 1)
          }
          if node.hasMoreChildren {
            Button {
              surface.loadMoreChildren(for: node.id)
            } label: {
              Label("さらに読み込む…", systemImage: "ellipsis")
                .font(WorkspaceChrome.chromeFont(size: 10))
                .foregroundStyle(WorkspaceChrome.textTertiary)
            }
            .buttonStyle(.tactile)
            .padding(.leading, CGFloat((depth + 1) * 14) + 8)
            .padding(.vertical, 4)
          }
        } else {
          ProgressView("読み込み中…")
            .controlSize(.small)
            .tint(WorkspaceChrome.accent)
            .font(WorkspaceChrome.chromeFont(size: 10))
            .padding(.leading, CGFloat((depth + 1) * 14) + 8)
            .padding(.vertical, 4)
        }
      }
    }
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
  let fontSize: Double
  let wordWrap: Bool

  init(
    tab: ProjectEditorTab,
    surface: ProjectSurfaceModel,
    fontSize: Double = 13,
    wordWrap: Bool = false
  ) {
    _tab = ObservedObject(wrappedValue: tab)
    _surface = ObservedObject(wrappedValue: surface)
    self.fontSize = fontSize
    self.wordWrap = wordWrap
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "doc.text")
          .foregroundStyle(WorkspaceChrome.accent)
        Text(breadcrumbPath)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(WorkspaceChrome.textTertiary)
          .lineLimit(1)
        Spacer()
        if tab.loadError != nil {
          Label("開くのに失敗しました", systemImage: "exclamationmark.triangle")
            .font(WorkspaceChrome.chromeFont(size: 10, weight: .medium))
            .foregroundStyle(WorkspaceChrome.danger)
        } else if tab.isMissing {
          Label("見つかりません", systemImage: "exclamationmark.triangle")
            .font(WorkspaceChrome.chromeFont(size: 10, weight: .medium))
            .foregroundStyle(WorkspaceChrome.attention)
        } else if tab.isDirty {
          Text("未保存")
            .font(WorkspaceChrome.chromeFont(size: 10, weight: .medium))
            .foregroundStyle(WorkspaceChrome.attention)
        }
        Menu {
          Menu("履歴") {
            if tab.historyEntries.isEmpty {
              Text("復元スナップショットはありません")
            } else {
              ForEach(tab.historyEntries) { entry in
                Button(entry.displayLabel) {
                  surface.restoreHistoryEntry(entry.id, tabID: tab.id)
                }
              }
            }
          }
          Divider()
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
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WorkspaceChrome.textTertiary)
            .frame(width: 26, height: 28)
            .background(WorkspaceChrome.surface, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
              RoundedRectangle(cornerRadius: 4)
                .stroke(WorkspaceChrome.border, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .help("エディタの操作")
        .accessibilityLabel("エディタの操作")
        Button("保存") {
          surface.save(tabID: tab.id)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!tab.isDirty || tab.isMissing || tab.isReadOnly)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(minHeight: 58)
      .background(WorkspaceChrome.chromeRaised)

      Divider()
        .background(WorkspaceChrome.border)
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
        CodeMirrorEditorView(
          document: tab,
          selection: tab.selectionRequest,
          fontSize: CGFloat(fontSize),
          wordWrap: wordWrap
        ) {
          surface.save(tabID: tab.id)
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

  private var breadcrumbPath: String {
    let rootName =
      surface.rootURL.lastPathComponent.isEmpty ? "Project" : surface.rootURL.lastPathComponent
    let rootPath = surface.rootURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
    let relativePath =
      tab.url.path.hasPrefix(prefix) ? String(tab.url.path.dropFirst(prefix.count)) : tab.url.path
    return "\(rootName) / \(relativePath)"
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
