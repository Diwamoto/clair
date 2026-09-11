import AppKit
import SwiftUI

struct ProjectAgentView: View {
  let project: Project
  @ObservedObject var workspace: ProjectWorkspaceModel
  let surface: ProjectSurfaceModel
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
