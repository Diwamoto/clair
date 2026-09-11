import AppKit
import SwiftUI

/// The source-control panel, shaped like VSCode's: the raw `git status`
/// split of「ステージ済みの変更」against「変更」, a commit box above it, and a
/// per-row "+"/"−" that actually stages and unstages. Untracked files are
/// marked inside 変更 rather than given a third section of their own — that is
/// what the working tree is.
struct ProjectGitView: View {
  @ObservedObject var workspace: ProjectWorkspaceModel
  let projectID: UUID
  let surface: ProjectSurfaceModel
  let onDismiss: () -> Void
  @State private var commitMessage = ""

  var body: some View {
    VStack(spacing: 0) {
      SidebarPanelHeader(title: WorkspaceActivity.git.title) {
        ChromeActionButton(width: 20, height: 20, help: "更新", action: refresh) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 11, weight: .medium))
        }
      }

      if let status = surface.gitStatus, status.isRepository {
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

/// One changed file. The stage toggle is a plain "+"/"−" glyph rather than an
/// icon, matching how the explorer already uses bare "M"/"A" letters instead
/// of drawn badges.
struct ProjectGitChangeRow: View {
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

struct ProjectBranchReviewView: View {
  let project: Project
  let surface: ProjectSurfaceModel
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
struct ProjectDiffPreview: View {
  let surface: ProjectSurfaceModel
  let onOpenInEditor: (() -> Void)?

  init(
    surface: ProjectSurfaceModel,
    onOpenInEditor: (() -> Void)? = nil
  ) {
    self.surface = surface
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
