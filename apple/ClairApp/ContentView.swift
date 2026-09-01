import AppKit
import SwiftUI

struct ContentView: View {
  let state: BootstrapState
  @ObservedObject var workspace: ProjectWorkspaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  @ObservedObject var worktreeCoordinator: ProjectWorktreeCoordinator
  @ObservedObject var updater: ClairUpdateCoordinator

  @State private var renameProjectID: UUID?
  @State private var renameValue = ""

  var body: some View {
    NavigationSplitView {
      projectSidebar
    } detail: {
      projectDetail
    }
    .frame(minWidth: 820, minHeight: 520)
    .alert("Rename Project", isPresented: renameAlertIsPresented) {
      TextField("Project name", text: $renameValue)
      Button("Cancel", role: .cancel) {
        cancelRename()
      }
      Button("Rename") {
        confirmRename()
      }
    } message: {
      Text("This changes the name shown by Clair, not the folder on disk.")
    }
    .alert("Project command failed", isPresented: errorAlertIsPresented) {
      Button("OK") {
        workspace.dismissError()
      }
    } message: {
      Text(workspace.lastErrorMessage ?? "Unknown Project error.")
    }
    .onAppear {
      workspace.reattachRuntimeSessions()
    }
    .overlay(alignment: .bottomTrailing) {
      ClairUpdateNotice(updater: updater)
        .padding(12)
    }
  }

  private var projectSidebar: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Projects")
          .font(.headline)
        Spacer()
        Button(action: openProject) {
          Label("Open Folder", systemImage: "folder.badge.plus")
        }
        .labelStyle(.iconOnly)
        .help("Open Project Folder")
        .keyboardShortcut("o", modifiers: [.command])
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

      if workspace.projects.isEmpty {
        ContentUnavailableView(
          "No Projects",
          systemImage: "folder",
          description: Text("Open a local folder to start a Project.")
        )
      } else {
        List(
          selection: Binding(
            get: { workspace.activeProjectID },
            set: { projectID in
              guard let projectID else { return }
              _ = workspace.execute(
                .switchProject(SwitchProjectCommand(projectID: projectID))
              )
            }
          )
        ) {
          ForEach(workspace.projects) { project in
            projectRow(project)
              .tag(project.id)
          }
        }
        .listStyle(.sidebar)
      }
    }
  }

  private func projectRow(_ project: Project) -> some View {
    HStack(spacing: 9) {
      Circle()
        .fill(project.color.swiftUIColor)
        .frame(width: 9, height: 9)

      VStack(alignment: .leading, spacing: 2) {
        Text(project.name)
          .lineLimit(1)
        Text(project.rootURL.path)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)

      if !project.availability.isAvailable {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .help(project.availability.displayName)
      }
    }
    .contextMenu {
      Button("Rename…") {
        beginRename(project)
      }

      Menu("Color") {
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
                .fill(color.swiftUIColor)
                .frame(width: 9, height: 9)
              Text(color.displayName)
              if color == project.color {
                Image(systemName: "checkmark")
              }
            }
          }
        }
      }

      Divider()

      Button("Move Up") {
        workspace.moveProject(id: project.id, by: -1)
      }
      Button("Move Down") {
        workspace.moveProject(id: project.id, by: 1)
      }
      Button("Close Project", role: .destructive) {
        _ = workspace.execute(
          .closeProject(CloseProjectCommand(projectID: project.id))
        )
      }
    }
  }

  @ViewBuilder
  private var projectDetail: some View {
    if let project = workspace.activeProject, let surface = workspace.activeSurface {
      ProjectWorkspaceDetail(
        state: state,
        project: project,
        workspace: workspace,
        surface: surface,
        agentWorkflow: agentWorkflow,
        worktreeCoordinator: worktreeCoordinator
      )
    } else {
      VStack(spacing: 12) {
        Image(systemName: "folder.badge.plus")
          .font(.system(size: 42))
          .foregroundStyle(.secondary)
        Text("Open a Project folder")
          .font(.title2.weight(.semibold))
        Text("Git repositories and ordinary local folders are supported.")
          .foregroundStyle(.secondary)
        Button("Open Folder…", action: openProject)
          .keyboardShortcut("o", modifiers: [.command])
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(32)
    }
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

  private func openProject() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Open Project"

    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }

    _ = workspace.execute(.openProject(OpenProjectCommand(rootURL: url)))
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

private enum ProjectNavigationSheet: String, Identifiable {
  case quickOpen
  case search
  case history
  case git
  case review
  case agents

  var id: String {
    rawValue
  }
}

private struct ProjectWorkspaceDetail: View {
  let state: BootstrapState
  let project: Project
  @ObservedObject var workspace: ProjectWorkspaceModel
  @ObservedObject var surface: ProjectSurfaceModel
  @ObservedObject var agentWorkflow: AgentWorkflowCoordinator
  @ObservedObject var worktreeCoordinator: ProjectWorktreeCoordinator
  @State private var navigationSheet: ProjectNavigationSheet?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "folder.fill")
          .font(.title2.weight(.semibold))
          .foregroundStyle(project.color.swiftUIColor)

        VStack(alignment: .leading, spacing: 2) {
          Text(project.name)
            .font(.headline)
          Text(project.rootURL.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer()

        Button {
          navigationSheet = .quickOpen
        } label: {
          Label("Quick Open", systemImage: "magnifyingglass")
        }
        .buttonStyle(.bordered)

        Button {
          navigationSheet = .search
        } label: {
          Label("Search", systemImage: "text.magnifyingglass")
        }
        .buttonStyle(.bordered)

        Button {
          navigationSheet = .history
        } label: {
          Label("History", systemImage: "clock.arrow.circlepath")
        }
        .buttonStyle(.bordered)

        Button {
          navigationSheet = .git
        } label: {
          Label("Git", systemImage: "arrow.triangle.branch")
        }
        .buttonStyle(.bordered)

        Button {
          navigationSheet = .review
        } label: {
          Label("Review", systemImage: "checkmark.shield")
        }
        .buttonStyle(.bordered)

        Button {
          navigationSheet = .agents
        } label: {
          Label("Agents", systemImage: "person.2")
        }
        .buttonStyle(.bordered)

        Button(surface.isTerminalVisible ? "Show Editor" : "Open Terminal") {
          if surface.isTerminalVisible {
            surface.hideTerminal()
          } else {
            surface.showTerminal()
          }
        }
        .buttonStyle(.bordered)

        Button(surface.isFocusedPaneMaximized ? "Restore Pane" : "Maximize Pane") {
          surface.toggleMaximizeFocusedPane()
        }
        .buttonStyle(.bordered)

        Button("Equalize") {
          surface.equalizeSplits()
        }
        .buttonStyle(.bordered)

        Button("Diff") {
          surface.openDiff()
        }
        .buttonStyle(.bordered)

        Text(surface.fileTree.availability.displayName)
          .font(.caption.weight(.bold))
          .foregroundStyle(surface.fileTree.isAvailable ? .green : .orange)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(.quaternary, in: Capsule())
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      Divider()

      HStack(spacing: 0) {
        ProjectFileTreeView(surface: surface)
          .frame(minWidth: 220, idealWidth: 270, maxWidth: 360)

        Divider()

        ProjectPaneLayoutView(
          state: state,
          project: project,
          surface: surface,
          node: surface.visibleLayout
        )
      }
    }
    .alert("Editor command failed", isPresented: editorErrorIsPresented) {
      Button("OK") {
        surface.dismissEditorError()
      }
    } message: {
      Text(surface.lastEditorErrorMessage ?? "Unknown editor error.")
    }
    .alert("Project navigation failed", isPresented: navigationErrorIsPresented) {
      Button("OK") {
        surface.dismissNavigationError()
      }
    } message: {
      Text(surface.lastNavigationErrorMessage ?? "Unknown navigation error.")
    }
    .alert("Git operation failed", isPresented: gitErrorIsPresented) {
      Button("OK") {
        surface.dismissGitError()
      }
    } message: {
      Text(surface.lastGitErrorMessage ?? "Unknown Git error.")
    }
    .alert("Agent workflow failed", isPresented: agentErrorIsPresented) {
      Button("OK") {
        agentWorkflow.clearError()
      }
    } message: {
      Text(agentWorkflow.lastErrorMessage ?? "Unknown agent workflow error.")
    }
    .sheet(item: $navigationSheet) { sheet in
      switch sheet {
      case .quickOpen:
        ProjectQuickOpenView(surface: surface)
      case .search:
        ProjectSearchView(surface: surface)
      case .history:
        ProjectHistoryView(surface: surface)
      case .git:
        ProjectGitView(
          workspace: workspace,
          projectID: project.id,
          surface: surface
        )
      case .review:
        ProjectBranchReviewView(
          project: project,
          surface: surface,
          agentWorkflow: agentWorkflow,
          worktreeCoordinator: worktreeCoordinator
        )
      case .agents:
        ProjectAgentView(
          project: project,
          workspace: workspace,
          surface: surface,
          agentWorkflow: agentWorkflow,
          worktreeCoordinator: worktreeCoordinator
        )
      }
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
        Label("Agent Workflow", systemImage: "person.2")
          .font(.title3.weight(.semibold))
        Text(project.name)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Button("Close", action: dismiss.callAsFunction)
          .buttonStyle(.borderless)
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
    .onAppear {
      worktreeCoordinator.refresh(project: project)
    }
    .alert("Managed worktree failed", isPresented: worktreeErrorIsPresented) {
      Button("OK") {
        worktreeCoordinator.clearError()
      }
    } message: {
      Text(worktreeCoordinator.lastErrorMessage ?? "Unknown managed worktree error.")
    }
    .alert("Remove managed worktree", isPresented: cleanupAlertIsPresented) {
      Button("Cancel", role: .cancel) {
        cleanupPlan = nil
      }
      if cleanupPlan?.canConfirm == true {
        Button("Remove", role: .destructive) {
          confirmCleanup()
        }
      }
    } message: {
      if let cleanupPlan {
        if cleanupPlan.canConfirm {
          Text(
            "Remove branch \(cleanupPlan.branch) at \(cleanupPlan.rootURL.path)? The branch itself will be kept."
          )
        } else {
          Text(
            "Cleanup is refused because of \(cleanupPlan.blockers.map { $0.displayName }.joined(separator: ", "))."
          )
        }
      }
    }
  }

  private var launchSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(selectedWorktree == nil ? "Launch in Project root" : "Launch in managed worktree")
        .font(.headline)
      Text(selectedExecutionRoot.path)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      Picker("Execution root", selection: $selectedWorktreeID) {
        Text("Project root").tag(nil as WorktreeID?)
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
        Text("Managed worktrees")
          .font(.headline)
        Spacer()
        Button("Refresh") {
          worktreeCoordinator.refresh(project: project)
        }
        .buttonStyle(.borderless)
      }

      if surface.gitStatus?.isRepository != true {
        Text("Managed worktrees require a Git repository at the Project root.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text(
          "Clair stores these worktrees outside the repository at \(worktreeCoordinator.managementRootURL?.path ?? "Unavailable")."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

        HStack(spacing: 8) {
          TextField("Branch", text: $newWorktreeBranch)
          TextField("Folder name", text: $newWorktreeTargetName)
          Button("Create") {
            createWorktree()
          }
          .buttonStyle(.bordered)
          .disabled(
            newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || newWorktreeTargetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        }

        if projectWorktrees.isEmpty {
          Text("No managed worktrees have been created for this Project.")
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
        Button("Use") {
          selectedWorktreeID = worktree.id
        }
        .buttonStyle(.borderless)
      }
      Button("Clean Up", role: .destructive) {
        cleanupPlan = worktreeCoordinator.prepareCleanup(
          project: project,
          worktreeID: worktree.id,
          activeSessionIDs: sessionIDsInUse(for: worktree.id),
          expectedRootURL: worktree.rootURL
        )
      }
      .buttonStyle(.borderless)
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
        return "Available — uncommitted changes"
      }
      return "Available — clean"
    case .missing:
      return "Missing — execution is unavailable"
    case .detached:
      return "Detached — Git registration is missing or HEAD is detached"
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
      Text("Project notifications")
      Spacer()
      Button(
        agentWorkflow.isMuted(projectID: project.id) ? "Unmute Project" : "Mute Project"
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
      Text("Sessions")
        .font(.headline)
      if projectSessions.isEmpty {
        Text("No agents have been launched in this Project.")
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
        Text(session.profile?.displayName ?? "Unknown agent")
          .font(.body.weight(.medium))
        Text(lifecycleDescription(for: session))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Reveal") {
        workspace.revealTerminal(
          projectID: session.projectID,
          tabID: session.terminalTabID
        )
        dismiss()
      }
      .buttonStyle(.borderless)
      Button(
        agentWorkflow.isMuted(projectID: session.projectID, sessionID: session.id)
          ? "Unmute"
          : "Mute"
      ) {
        agentWorkflow.setMuted(
          !agentWorkflow.isMuted(projectID: session.projectID, sessionID: session.id),
          projectID: session.projectID,
          sessionID: session.id
        )
      }
      .buttonStyle(.borderless)
    }
    .padding(8)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
  }

  @ViewBuilder
  private var activitySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Activity history")
        .font(.headline)
      if projectActivities.isEmpty {
        Text("Bell, exit, and official hook activity will appear here.")
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
              Button("Reveal") {
                workspace.revealTerminal(
                  projectID: session.projectID,
                  tabID: session.terminalTabID
                )
                dismiss()
              }
              .buttonStyle(.borderless)
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
        Text("Official hook receiver")
          .font(.headline)
        Text("Configure the agent's documented hook command as:")
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
      "Starting in \(session.agent.cwd)"
    case .running:
      "Running in \(session.agent.cwd)"
    case .exited(let code):
      "Exited with status \(code)"
    }
  }

  private func activityTitle(for activity: AgentActivity) -> String {
    switch activity.source {
    case .bell:
      "Terminal attention bell"
    case .exit:
      activity.exitStatus == 0 ? "Agent exited normally" : "Agent exited with an error"
    case .officialHook:
      "Official hook: \(activity.kind.rawValue)"
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
        Label("Terminal", systemImage: "terminal")
          .font(.headline)
        Text(project.rootURL.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Text(session.statusDescription)
          .font(.caption)
          .foregroundStyle(statusColor)
        Text("\(session.dimensions.columns) × \(session.dimensions.rows)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        if case .missing = session.state {
          Button("Start New Session", action: onRecover)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        Button("Editor", action: onHide)
          .buttonStyle(.borderless)
        Button("End", action: onEnd)
          .buttonStyle(.borderless)
          .foregroundStyle(.red)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      TerminalSurfaceView(session: session)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
          session.start()
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var statusColor: Color {
    switch session.state {
    case .running, .starting:
      .green
    case .idle, .stopping:
      .secondary
    case .exited:
      .orange
    case .missing:
      .red
    case .failed:
      .red
    }
  }
}

private struct ProjectPaneLayoutView: View {
  let state: BootstrapState
  let project: Project
  @ObservedObject var surface: ProjectSurfaceModel
  let node: ProjectPaneNode

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
          paneID: leaf.id
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

  @State private var pendingCloseTabID: String?

  var body: some View {
    VStack(spacing: 0) {
      paneToolbar
      Divider()
      tabBar
      Divider()
      tabContent
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .overlay {
      RoundedRectangle(cornerRadius: 4)
        .stroke(
          surface.isFocusedPane(paneID) ? Color.accentColor : Color.clear,
          lineWidth: 2
        )
        .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      surface.focusPane(id: paneID)
    }
    .alert("Discard unsaved changes?", isPresented: pendingCloseIsPresented) {
      Button("Cancel", role: .cancel) {
        pendingCloseTabID = nil
      }
      Button("Discard", role: .destructive) {
        guard let pendingCloseTabID else {
          return
        }
        self.pendingCloseTabID = nil
        surface.closeTab(id: pendingCloseTabID)
      }
    } message: {
      Text("The editor buffer has changes that have not been saved to disk.")
    }
  }

  private var paneToolbar: some View {
    HStack(spacing: 6) {
      Button(surface.isFocusedPane(paneID) ? "Focused" : "Focus") {
        surface.focusPane(id: paneID)
      }
      .buttonStyle(.borderless)

      Menu("Split") {
        Button("Split Right") {
          surface.focusPane(id: paneID)
          surface.splitFocusedPane(orientation: .horizontal)
        }
        Button("Split Below") {
          surface.focusPane(id: paneID)
          surface.splitFocusedPane(orientation: .vertical)
        }
      }
      .menuStyle(.borderlessButton)

      Menu("Move Tab") {
        if surface.paneIDs.count == 1 {
          Text("No other panes")
        } else {
          ForEach(surface.paneIDs.filter { $0 != paneID }, id: \.self) { destination in
            Button("Pane \(destination.uuidString.prefix(4))") {
              surface.focusPane(id: paneID)
              surface.moveActiveTab(to: destination)
            }
          }
        }
      }
      .menuStyle(.borderlessButton)

      Button(
        surface.isFocusedPaneMaximized && surface.isFocusedPane(paneID) ? "Restore" : "Maximize"
      ) {
        surface.focusPane(id: paneID)
        surface.toggleMaximizeFocusedPane()
      }
      .buttonStyle(.borderless)

      Button("Close Pane", role: .destructive) {
        surface.closePane(id: paneID)
      }
      .buttonStyle(.borderless)
      .disabled(surface.paneIDs.count == 1)

      Spacer(minLength: 4)

      Button("Editor") {
        surface.focusPane(id: paneID)
        surface.hideTerminal()
      }
      .buttonStyle(.borderless)
      Button("Terminal") {
        surface.showTerminal(in: paneID)
      }
      .buttonStyle(.borderless)
      Button("Diff") {
        surface.openDiff(in: paneID)
      }
      .buttonStyle(.borderless)
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(.background.secondary)
  }

  private var tabBar: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 2) {
        ForEach(surface.tabs(in: paneID)) { tab in
          HStack(spacing: 5) {
            Button(displayTitle(for: tab)) {
              surface.activateTab(id: tab.id)
            }
            .buttonStyle(.plain)
            .lineLimit(1)

            Button {
              requestClose(tab)
            } label: {
              Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)")
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(
            surface.activeTab(in: paneID)?.id == tab.id
              ? Color.accentColor.opacity(0.16)
              : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
          )
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
    }
    .scrollIndicators(.hidden)
    .frame(minHeight: 29)
  }

  @ViewBuilder
  private var tabContent: some View {
    if let tab = surface.activeTab(in: paneID) {
      switch tab.kind {
      case .editor:
        if let document = surface.editorDocument(tabID: tab.id) {
          ProjectNativeEditorTab(tab: document, surface: surface)
        } else {
          ContentUnavailableView(
            "Editor Unavailable",
            systemImage: "doc.text.magnifyingglass",
            description: Text("The file could not be restored in this Project.")
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
        Text("Empty pane")
          .font(.headline)
        Text("Open an editor, terminal, or diff tab.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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

  private func displayTitle(for tab: ProjectPaneTab) -> String {
    guard tab.kind == .editor,
      surface.editorDocument(tabID: tab.id)?.isDirty == true
    else {
      return tab.title
    }
    return "\(tab.title) •"
  }

  private func requestClose(_ tab: ProjectPaneTab) {
    if tab.kind == .editor, surface.editorDocument(tabID: tab.id)?.isDirty == true {
      pendingCloseTabID = tab.id
    } else {
      surface.closeTab(id: tab.id)
    }
  }
}

private struct ProjectRestoredTerminalView: View {
  let onStart: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "terminal")
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
      Text("Terminal session is not running")
        .font(.headline)
      Text(
        "The terminal layout was restored, but its transcript is intentionally not saved. Start a new local session."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 420)
      Button("Start Terminal", action: onStart)
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
  @Environment(\.dismiss) private var dismiss
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
          "Git Unavailable",
          systemImage: "arrow.triangle.branch",
          description: Text(status.message ?? "This Project is not a Git repository.")
        )
      } else {
        ContentUnavailableView(
          "Git Status Unavailable",
          systemImage: "arrow.triangle.branch",
          description: Text("Refresh Git status to inspect this Project.")
        )
      }
    }
    .frame(minWidth: 680, minHeight: 500)
    .onAppear {
      refresh()
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Label("Git Working Tree", systemImage: "arrow.triangle.branch")
        .font(.title3.weight(.semibold))
      Spacer()
      Button {
        refresh()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      Button("Close", action: dismiss.callAsFunction)
        .buttonStyle(.borderless)
    }
    .padding(12)
  }

  private func branchSummary(_ status: ProjectGitSnapshot) -> some View {
    HStack(spacing: 12) {
      Menu {
        if status.branches.isEmpty {
          Text("No local branches")
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
        Label(status.branch ?? "Detached HEAD", systemImage: "arrow.triangle.branch")
      }
      .buttonStyle(.bordered)

      if let upstream = status.upstream {
        Text(upstream)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if status.ahead != 0 || status.behind != 0 {
        Text("ahead \(status.ahead), behind \(status.behind)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text("\(status.changes.count) change\(status.changes.count == 1 ? "" : "s")")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
  }

  @ViewBuilder
  private func changeList(_ status: ProjectGitSnapshot) -> some View {
    if status.changes.isEmpty {
      ContentUnavailableView(
        "Working Tree Clean",
        systemImage: "checkmark.circle",
        description: Text("There are no staged, unstaged, or untracked changes.")
      )
    } else {
      List {
        if !status.stagedChanges.isEmpty {
          Section("Staged (\(status.stagedCount))") {
            ForEach(status.stagedChanges) { change in
              changeRow(change, basis: .staged, mutationTitle: "Unstage") {
                unstage(change)
              }
            }
          }
        }
        if !status.unstagedChanges.isEmpty {
          Section("Unstaged (\(status.unstagedCount))") {
            ForEach(status.unstagedChanges) { change in
              changeRow(change, basis: .workingTree, mutationTitle: "Stage") {
                stage(change)
              }
            }
          }
        }
        if !status.untrackedChanges.isEmpty {
          Section("Untracked (\(status.untrackedCount))") {
            ForEach(status.untrackedChanges) { change in
              changeRow(change, basis: .workingTree, mutationTitle: "Stage") {
                stage(change)
              }
            }
          }
        }
      }
      .listStyle(.inset)
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
      .buttonStyle(.plain)

      Button("Diff") {
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
      .buttonStyle(.borderless)

      Button(mutationTitle, action: mutation)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .padding(.vertical, 2)
  }

  private func commitBar(_ status: ProjectGitSnapshot) -> some View {
    HStack(spacing: 8) {
      TextField("Commit message", text: $commitMessage)
        .textFieldStyle(.roundedBorder)
      Button("Commit") {
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
  @Environment(\.dismiss) private var dismiss

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
        Label("Branch Review", systemImage: "checkmark.shield")
          .font(.title3.weight(.semibold))
        Text(project.name)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Button("Close", action: dismiss.callAsFunction)
          .buttonStyle(.borderless)
      }
      .padding(12)

      Divider()

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
    .frame(minWidth: 720, minHeight: 580)
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
    .alert("Branch review failed", isPresented: errorAlertIsPresented) {
      Button("OK") {
        errorMessage = nil
      }
    } message: {
      Text(errorMessage ?? "Unknown branch review error.")
    }
    .alert("Remove managed worktree", isPresented: cleanupAlertIsPresented) {
      Button("Cancel", role: .cancel) {
        cleanupPlan = nil
      }
      if cleanupPlan?.canConfirm == true {
        Button("Remove", role: .destructive) {
          confirmCleanup()
        }
      }
    } message: {
      if let cleanupPlan {
        if cleanupPlan.canConfirm {
          Text(
            "Remove branch \(cleanupPlan.branch) at \(cleanupPlan.rootURL.path)? The branch itself will be kept."
          )
        } else {
          Text(
            "Cleanup is refused because of \(cleanupPlan.blockers.map { $0.displayName }.joined(separator: ", "))."
          )
        }
      }
    }
  }

  private var sourceSection: some View {
    GroupBox("Source worktree") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Branch", selection: $selectedWorktreeID) {
          Text("Select a managed worktree").tag(nil as WorktreeID?)
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
            "Base \(selectedWorktree.baseRevision.prefix(8)) · current \(selectedWorktree.headRevision?.prefix(8) ?? "unknown")"
          )
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        } else {
          Text(
            projectWorktrees.isEmpty
              ? "Create a managed worktree from the Agents panel before reviewing a branch."
              : "Only an available managed worktree can be reviewed."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Text("Target Project root: \(project.rootURL.path)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        HStack(spacing: 8) {
          Button("Review Branch") {
            reviewBranch()
          }
          .buttonStyle(.borderedProminent)
          .disabled(reviewService == nil)

          Button("Prepare Adoption") {
            prepareAdoption()
          }
          .buttonStyle(.bordered)
          .disabled(reviewService == nil)

          Spacer()

          if let selectedWorktree {
            Button("Clean Up", role: .destructive) {
              prepareCleanup(for: selectedWorktree)
            }
            .buttonStyle(.borderless)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func reviewSection(_ review: ProjectBranchReviewSnapshot) -> some View {
    GroupBox("Branch-wide review") {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label(review.sourceBranch ?? "Detached HEAD", systemImage: "arrow.triangle.branch")
            .font(.headline)
          Spacer()
          Text("\(review.commits.count) commit\(review.commits.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(
          "Base \(review.baseRevision.prefix(8)) → HEAD \(review.headRevision.prefix(8))"
        )
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)

        if review.sourceStatus.changes.isEmpty {
          Label("Source worktree is clean", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.green)
        } else {
          Label(
            "Source has \(review.uncommittedChanges.count) uncommitted change\(review.uncommittedChanges.count == 1 ? "" : "s")",
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
          Text("No committed file changes after the base revision.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Committed changes")
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
          Text("Commits")
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

        DisclosureGroup("Committed diff") {
          Text(
            review.committedDiff.isEmpty
              ? "No committed diff is available for this base and HEAD."
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
    GroupBox("Adoption gate") {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "Merge \(plan.review.expectedSourceBranch) into \(plan.targetBranch ?? "Detached HEAD") with a merge commit."
        )
        .font(.subheadline)

        if plan.blockers.isEmpty {
          Label(
            "Source and target are clean and ready to adopt.",
            systemImage: "checkmark.circle.fill"
          )
          .foregroundStyle(.green)
          Button("Adopt with Merge Commit") {
            adopt(plan)
          }
          .buttonStyle(.borderedProminent)
        } else {
          Label(
            "Adoption is refused until these guards clear:",
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
    GroupBox("Conflict requires resolution") {
      VStack(alignment: .leading, spacing: 8) {
        Label(
          "Git left the target in a merge state for the owning agent or native merge surface.",
          systemImage: "exclamationmark.octagon"
        )
        .foregroundStyle(.orange)
        Text("Target: \(conflict.targetRootURL.path)")
          .font(.caption.monospaced())
          .textSelection(.enabled)
        ForEach(conflict.paths, id: \.self) { path in
          Text("• \(path)")
            .font(.caption)
        }
        Text("Resolve these paths, then refresh the Project Git status before continuing.")
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
        statusMessage = "Adopted with merge commit \(mergeRevision.prefix(8))."
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

  var body: some View {
    Group {
      if let diff = surface.selectedGitDiff {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
              .foregroundStyle(.secondary)
            Text(diff.change.displayPath)
              .font(.headline)
              .lineLimit(1)
            Text(diff.basis.displayName)
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Open in Editor") {
              surface.revealGitChange(relativePath: diff.change.path)
            }
            .buttonStyle(.borderless)
          }
          .padding(12)
          Divider()
          ScrollView {
            Text(diff.text.isEmpty ? "No diff is available for this state." : diff.text)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(16)
          }
        }
      } else {
        VStack(spacing: 12) {
          Image(systemName: "doc.on.doc")
            .font(.system(size: 34))
            .foregroundStyle(.secondary)
          Text("Git diff")
            .font(.headline)
          Text(
            "Select Diff from the Git panel to inspect a staged, working-tree, or untracked change."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
      }
    }
  }
}

private struct ProjectFileTreeView: View {
  @ObservedObject var surface: ProjectSurfaceModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Files", systemImage: "folder")
          .font(.headline)
        Spacer()
        Button {
          surface.reload()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh file tree")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Divider()

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
      } else {
        ContentUnavailableView(
          fileTreeTitle,
          systemImage: fileTreeSystemImage,
          description: Text(fileTreeMessage)
        )
        .padding(16)
      }
    }
    .frame(maxHeight: .infinity)
    .background(.background.secondary)
  }

  private var fileTreeTitle: String {
    switch surface.fileTree.availability {
    case .available:
      "No Files"
    case .missing:
      "Folder Missing"
    case .notDirectory:
      "Not a Folder"
    case .unreadable:
      "Folder Unavailable"
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
      "This Project folder is empty."
    case .missing:
      "The folder may have been moved or deleted. Clair will refresh when it returns."
    case .notDirectory:
      "The Project root is no longer a folder."
    case .unreadable:
      "Clair cannot read this Project folder."
    }
  }
}

private struct ProjectQuickOpenView: View {
  @ObservedObject var surface: ProjectSurfaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search files by name or path", text: $query)
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            openFirstResult()
          }
      }
      .padding(12)

      Divider()

      if items.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "No Files" : "No Matching Files",
          systemImage: "doc.text.magnifyingglass",
          description: Text(
            query.isEmpty
              ? "This Project has no files to open."
              : "Try a different file name or path."
          )
        )
      } else {
        List(items) { item in
          Button {
            surface.openQuickOpenItem(item)
            if surface.lastNavigationErrorMessage == nil {
              dismiss()
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
          .buttonStyle(.plain)
        }
        .listStyle(.inset)
      }
    }
    .frame(minWidth: 480, minHeight: 360)
  }

  private var items: [ProjectQuickOpenItem] {
    surface.quickOpenItems(matching: query)
  }

  private func openFirstResult() {
    guard let item = items.first else {
      return
    }
    surface.openQuickOpenItem(item)
    if surface.lastNavigationErrorMessage == nil {
      dismiss()
    }
  }
}

private struct ProjectSearchView: View {
  @ObservedObject var surface: ProjectSurfaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var replacement = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "text.magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Find text in this Project", text: $query)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              surface.search(query: query)
            }
        }

        HStack(spacing: 8) {
          TextField("Replace with", text: $replacement)
            .textFieldStyle(.roundedBorder)
          Button("Search") {
            surface.search(query: query)
          }
          .disabled(query.isEmpty)
          Button("Preview Replacement") {
            surface.previewReplacement(query: query, replacement: replacement)
          }
          .disabled(query.isEmpty)
        }

        HStack {
          Text(
            query.isEmpty
              ? "Searches UTF-8 text files and refreshes with the Project watcher."
              : "\(surface.searchResults.count) match\(surface.searchResults.count == 1 ? "" : "es")"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Spacer()
          Button("Close", action: dismiss.callAsFunction)
            .buttonStyle(.borderless)
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
        GroupBox("Replacement Preview") {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "\(preview.matchCount) match\(preview.matchCount == 1 ? "" : "es") in \(preview.files.count) file\(preview.files.count == 1 ? "" : "s")"
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
              Button("Apply to Editor Buffers") {
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
          "Search This Project",
          systemImage: "text.magnifyingglass",
          description: Text("Enter text above to search and preview replacements.")
        )
      } else if surface.searchResults.isEmpty {
        ContentUnavailableView(
          "No Matches",
          systemImage: "magnifyingglass",
          description: Text("No UTF-8 text file contains that text.")
        )
      } else {
        List(surface.searchResults) { match in
          Button {
            surface.openSearchMatch(match)
            if surface.lastNavigationErrorMessage == nil {
              dismiss()
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
          .buttonStyle(.plain)
        }
        .listStyle(.inset)
      }
    }
    .frame(minWidth: 620, minHeight: 440)
    .onChange(of: query, initial: true) { _, newValue in
      surface.search(query: newValue)
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
          Text("Project History")
            .font(.title3.weight(.semibold))
          Text("Restore a snapshot into an editor buffer; Save explicitly to write it to disk.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Close", action: dismiss.callAsFunction)
          .buttonStyle(.borderless)
      }
      .padding(12)

      Divider()

      if surface.historyEntries.isEmpty {
        ContentUnavailableView(
          "No History Snapshots",
          systemImage: "clock.arrow.circlepath",
          description: Text("Clair will keep recovery snapshots when files are saved or reloaded.")
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
            Button("Restore") {
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
          .buttonStyle(.plain)
        } else {
          Color.clear
            .frame(width: 14, height: 18)
        }

        Image(systemName: node.isDirectory ? "folder" : "doc.text")
          .foregroundStyle(node.isDirectory ? .secondary : .primary)
        Text(node.name)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.leading, CGFloat(depth * 14) + 8)
      .padding(.trailing, 8)
      .padding(.vertical, 3)
      .background(
        surface.selectedNodeID == node.id
          ? Color.accentColor.opacity(0.2)
          : Color.clear
      )
      .contentShape(Rectangle())
      .onTapGesture {
        surface.select(nodeID: node.id)
      }
      .id(node.id)

      if node.isDirectory && surface.isExpanded(node.id) {
        ForEach(node.children ?? []) { child in
          ProjectFileTreeRow(node: child, surface: surface, depth: depth + 1)
        }
      }
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
          ProjectNativeEditorTab(tab: tab, surface: surface)
        } else {
          ContentUnavailableView(
            "No Active Tab",
            systemImage: "rectangle.on.rectangle",
            description: Text("Select a file tab to continue.")
          )
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .alert("Discard unsaved changes?", isPresented: pendingCloseIsPresented) {
      Button("Cancel", role: .cancel) {
        pendingCloseTabID = nil
      }
      Button("Discard", role: .destructive) {
        guard let pendingCloseTabID else {
          return
        }
        self.pendingCloseTabID = nil
        surface.closeTab(id: pendingCloseTabID)
      }
    } message: {
      Text("The editor buffer has changes that have not been saved to disk.")
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
            .buttonStyle(.plain)
            .lineLimit(1)

            Button {
              requestClose(tab)
            } label: {
              Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)")
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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "doc.text")
          .foregroundStyle(.secondary)
        Text(tab.url.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        if tab.isMissing {
          Label("Missing", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        } else if tab.isDirty {
          Text("Unsaved")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        Menu("History") {
          if tab.historyEntries.isEmpty {
            Text("No recovery snapshots")
          } else {
            ForEach(tab.historyEntries) { entry in
              Button(entry.displayLabel) {
                surface.restoreHistoryEntry(entry.id, tabID: tab.id)
              }
            }
          }
        }
        Button("Undo") {
          surface.undoActiveTab()
        }
        .buttonStyle(.borderless)
        .disabled(!tab.canUndo)
        Button("Redo") {
          surface.redoActiveTab()
        }
        .buttonStyle(.borderless)
        .disabled(!tab.canRedo)
        Button("Save") {
          surface.save(tabID: tab.id)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!tab.isDirty || tab.isMissing)
        Button("Reveal in Tree") {
          surface.reveal(nodeID: tab.id)
        }
        .buttonStyle(.borderless)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 9)

      Divider()

      ProjectSourceEditorView(document: tab, selection: tab.selectionRequest) {
        surface.save(tabID: tab.id)
      }
    }
    .alert("Editor update failed", isPresented: editorErrorIsPresented) {
      Button("OK") {
        tab.dismissError()
      }
    } message: {
      Text(tab.lastErrorMessage ?? "Unknown editor error.")
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
          Text("Workspace shell")
            .font(.largeTitle.weight(.semibold))
          Text("Select a file in the tree to open a native editor tab.")
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

        GroupBox("Runtime") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            detailRow(label: "Channel", value: state.profile.channel.rawValue.uppercased())
            detailRow(label: "Bundle", value: state.profile.bundleIdentifier)
            detailRow(label: "Preferences", value: state.profile.preferencesDomain)
            detailRow(label: "Data", value: state.applicationSupportURL?.path ?? "Unavailable")
            detailRow(label: "Rust core", value: rustStatus)
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
          Label("Swift → Rust smoke path is ready", systemImage: "checkmark.circle.fill")
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

extension ProjectColor {
  fileprivate var swiftUIColor: Color {
    switch self {
    case .blue:
      .blue
    case .purple:
      .purple
    case .orange:
      .orange
    case .green:
      .green
    case .red:
      .red
    case .gray:
      .gray
    }
  }
}
