import Foundation

enum ProjectGitChangeKind: String, CaseIterable, Codable, Equatable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case copied
  case typeChanged
  case conflicted
  case untracked

  var displayName: String {
    switch self {
    case .added:
      "追加"
    case .modified:
      "変更"
    case .deleted:
      "削除"
    case .renamed:
      "名前変更"
    case .copied:
      "コピー"
    case .typeChanged:
      "種類変更"
    case .conflicted:
      "コンフリクト"
    case .untracked:
      "未追跡"
    }
  }
}

enum ProjectGitDiffBasis: String, CaseIterable, Codable, Equatable, Sendable {
  case workingTree
  case staged

  var displayName: String {
    switch self {
    case .workingTree:
      "ワークツリー"
    case .staged:
      "ステージ済み"
    }
  }
}

struct ProjectGitChange: Identifiable, Equatable, Sendable {
  let id: String
  let path: String
  let originalPath: String?
  let kind: ProjectGitChangeKind
  let indexStatus: Character
  let worktreeStatus: Character

  var isUntracked: Bool {
    kind == .untracked
  }

  var isStaged: Bool {
    !isUntracked && indexStatus != "."
  }

  var isUnstaged: Bool {
    isUntracked || worktreeStatus != "."
  }

  var displayPath: String {
    guard let originalPath else {
      return path
    }
    return "\(originalPath) → \(path)"
  }
}

enum ProjectGitAvailability: Equatable, Sendable {
  case notRepository
  case available
}

struct ProjectGitSnapshot: Equatable, Sendable {
  let availability: ProjectGitAvailability
  let branch: String?
  let upstream: String?
  let ahead: Int
  let behind: Int
  let branches: [String]
  let changes: [ProjectGitChange]
  let message: String?

  var isRepository: Bool {
    availability == .available
  }

  var stagedChanges: [ProjectGitChange] {
    changes.filter(\.isStaged)
  }

  var unstagedChanges: [ProjectGitChange] {
    changes.filter { $0.isUnstaged && !$0.isUntracked }
  }

  var untrackedChanges: [ProjectGitChange] {
    changes.filter(\.isUntracked)
  }

  var stagedCount: Int {
    stagedChanges.count
  }

  var unstagedCount: Int {
    unstagedChanges.count
  }

  var untrackedCount: Int {
    untrackedChanges.count
  }

  static let notRepository = ProjectGitSnapshot(
    availability: .notRepository,
    branch: nil,
    upstream: nil,
    ahead: 0,
    behind: 0,
    branches: [],
    changes: [],
    message: "This Project is not a Git repository."
  )

  func withBranches(_ branches: [String]) -> ProjectGitSnapshot {
    ProjectGitSnapshot(
      availability: availability,
      branch: branch,
      upstream: upstream,
      ahead: ahead,
      behind: behind,
      branches: branches,
      changes: changes,
      message: message
    )
  }
}

struct ProjectGitDiff: Identifiable, Equatable, Sendable {
  let change: ProjectGitChange
  let basis: ProjectGitDiffBasis
  let text: String

  var id: String {
    "\(change.id):\(basis.rawValue)"
  }
}

enum ProjectGitGraphRefKind: String, CaseIterable, Equatable, Sendable {
  case localBranch
  case remoteBranch
  case tag
  case other
}

struct ProjectGitGraphRef: Identifiable, Equatable, Sendable {
  let name: String
  let fullName: String
  let targetRevision: String
  let kind: ProjectGitGraphRefKind
  let isCurrent: Bool

  var id: String {
    fullName
  }
}

struct ProjectGitGraphCommit: Identifiable, Equatable, Sendable {
  let revision: String
  let parentRevisions: [String]
  let author: String
  let authoredAt: String
  let subject: String
  let refs: [ProjectGitGraphRef]

  var id: String {
    revision
  }

  var shortRevision: String {
    String(revision.prefix(8))
  }
}

struct ProjectGitGraphSnapshot: Equatable, Sendable {
  let availability: ProjectGitAvailability
  let branch: String?
  let headRevision: String?
  let refs: [ProjectGitGraphRef]
  let commits: [ProjectGitGraphCommit]
  let isTruncated: Bool
  let message: String?

  var isRepository: Bool {
    availability == .available
  }

  var branches: [ProjectGitGraphRef] {
    refs.filter { $0.kind == .localBranch || $0.kind == .remoteBranch }
  }

  static let notRepository = ProjectGitGraphSnapshot(
    availability: .notRepository,
    branch: nil,
    headRevision: nil,
    refs: [],
    commits: [],
    isTruncated: false,
    message: "This Project is not a Git repository."
  )
}

enum ProjectBranchReviewChangeKind: String, CaseIterable, Codable, Equatable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case copied
  case typeChanged

  var displayName: String {
    switch self {
    case .added:
      "Added"
    case .modified:
      "Modified"
    case .deleted:
      "Deleted"
    case .renamed:
      "Renamed"
    case .copied:
      "Copied"
    case .typeChanged:
      "Type changed"
    }
  }
}

struct ProjectBranchReviewChange: Identifiable, Equatable, Sendable {
  let path: String
  let originalPath: String?
  let kind: ProjectBranchReviewChangeKind

  var id: String {
    "\(kind.rawValue):\(path)"
  }

  var displayPath: String {
    guard let originalPath else {
      return path
    }
    return "\(originalPath) → \(path)"
  }
}

struct ProjectBranchCommit: Identifiable, Equatable, Sendable {
  let revision: String
  let author: String
  let authoredAt: String
  let subject: String

  var id: String {
    revision
  }

  var shortRevision: String {
    String(revision.prefix(8))
  }
}

struct ProjectBranchReviewSnapshot: Equatable, Sendable {
  let projectID: UUID
  let sourceWorktreeID: WorktreeID
  let repositoryRootURL: URL
  let sourceRootURL: URL
  let expectedSourceBranch: String
  let sourceBranch: String?
  let baseRevision: String
  let headRevision: String
  let commits: [ProjectBranchCommit]
  let committedChanges: [ProjectBranchReviewChange]
  let committedDiff: String
  let sourceStatus: ProjectGitSnapshot
  let targetStatus: ProjectGitSnapshot
  let targetHeadRevision: String

  var uncommittedChanges: [ProjectGitChange] {
    sourceStatus.changes
  }

  var isSourceClean: Bool {
    sourceStatus.changes.isEmpty
  }

  var isTargetClean: Bool {
    targetStatus.changes.isEmpty
  }
}

enum ProjectBranchAdoptionBlocker: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
  case sourceDirty
  case targetDirty
  case sourceDetached
  case targetDetached
  case sourceBranchChanged
  case noCommits
  case sourceIsTarget
  case repositoryMismatch
  case mergeInProgress

  var displayName: String {
    switch self {
    case .sourceDirty:
      "the source worktree has uncommitted changes"
    case .targetDirty:
      "the Project root has uncommitted changes"
    case .sourceDetached:
      "the source worktree is detached"
    case .targetDetached:
      "the Project root is detached"
    case .sourceBranchChanged:
      "the source worktree is no longer on its recorded branch"
    case .noCommits:
      "the branch has no commits after its base"
    case .sourceIsTarget:
      "the source and target roots are the same"
    case .repositoryMismatch:
      "the source belongs to a different repository than the target Project"
    case .mergeInProgress:
      "the target already has a merge in progress"
    }
  }
}

struct ProjectBranchAdoptionPlan: Identifiable, Equatable, Sendable {
  let confirmationID: UUID
  let review: ProjectBranchReviewSnapshot
  let targetRootURL: URL
  let targetBranch: String?
  let targetHeadRevision: String
  let blockers: [ProjectBranchAdoptionBlocker]

  var id: UUID {
    confirmationID
  }

  var canAdopt: Bool {
    blockers.isEmpty
  }
}

struct ProjectBranchConflict: Equatable, Sendable {
  let sourceWorktreeID: WorktreeID
  let sourceBranch: String
  let targetBranch: String
  let targetRootURL: URL
  let paths: [String]
  let commandMessage: String
}

enum ProjectBranchAdoptionResult: Equatable, Sendable {
  case adopted(mergeRevision: String)
  case conflict(ProjectBranchConflict)
}

enum ProjectBranchReviewError: Error, Equatable, LocalizedError, Sendable {
  case git(ProjectGitError)
  case invalidRevision(String)
  case baseRevisionNotAncestor(base: String, head: String)
  case confirmationRequired(UUID)
  case adoptionBlocked([ProjectBranchAdoptionBlocker])
  case stalePlan

  var errorDescription: String? {
    switch self {
    case .git(let error):
      return error.localizedDescription
    case .invalidRevision(let revision):
      return "The branch review revision is invalid: \(revision)"
    case .baseRevisionNotAncestor(let base, let head):
      return
        "The recorded branch base \(base.prefix(8)) is not an ancestor of HEAD \(head.prefix(8))."
    case .confirmationRequired(let id):
      return "Branch adoption requires a fresh confirmation (\(id.uuidString))."
    case .adoptionBlocked(let blockers):
      let detail = blockers.map(\.displayName).joined(separator: ", ")
      return "Branch adoption was refused because of \(detail)."
    case .stalePlan:
      return "The branch review changed; prepare adoption again before merging."
    }
  }
}

final class ProjectBranchReviewService {
  let source: ManagedWorktree
  let targetRootURL: URL

  private let fileManager: FileManager
  private let gitURL = URL(fileURLWithPath: "/usr/bin/git")
  private var pendingPlans: [UUID: ProjectBranchAdoptionPlan] = [:]

  init(
    source: ManagedWorktree,
    targetRootURL: URL,
    fileManager: FileManager = .default
  ) {
    self.source = source
    self.targetRootURL = targetRootURL.standardizedFileURL
    self.fileManager = fileManager
  }

  func review() throws -> ProjectBranchReviewSnapshot {
    let sourceRootURL = source.rootURL.standardizedFileURL
    let normalizedTargetRootURL = targetRootURL.standardizedFileURL
    let sourceStatus = try repositoryStatus(at: sourceRootURL)
    let targetStatus = try repositoryStatus(at: normalizedTargetRootURL)
    let baseRevision = try resolveRevision(source.baseRevision, at: sourceRootURL)
    let headRevision = try resolveRevision("HEAD", at: sourceRootURL)
    guard try isAncestor(baseRevision, of: headRevision, at: sourceRootURL) else {
      throw ProjectBranchReviewError.baseRevisionNotAncestor(
        base: baseRevision,
        head: headRevision
      )
    }
    let targetHeadRevision = try resolveRevision("HEAD", at: normalizedTargetRootURL)
    let commits = try branchCommits(
      baseRevision: baseRevision,
      headRevision: headRevision,
      rootURL: sourceRootURL
    )
    let committedChanges = try branchChanges(
      baseRevision: baseRevision,
      headRevision: headRevision,
      rootURL: sourceRootURL
    )
    let committedDiff = try branchDiff(
      baseRevision: baseRevision,
      headRevision: headRevision,
      rootURL: sourceRootURL
    )

    return ProjectBranchReviewSnapshot(
      projectID: source.projectID,
      sourceWorktreeID: source.id,
      repositoryRootURL: source.repositoryRootURL.standardizedFileURL,
      sourceRootURL: sourceRootURL,
      expectedSourceBranch: source.branch,
      sourceBranch: sourceStatus.branch,
      baseRevision: baseRevision,
      headRevision: headRevision,
      commits: commits,
      committedChanges: committedChanges,
      committedDiff: committedDiff,
      sourceStatus: sourceStatus,
      targetStatus: targetStatus,
      targetHeadRevision: targetHeadRevision
    )
  }

  func prepareAdoption() throws -> ProjectBranchAdoptionPlan {
    let review = try review()
    let plan = try makePlan(review: review)
    pendingPlans[plan.confirmationID] = plan
    return plan
  }

  func adopt(_ plan: ProjectBranchAdoptionPlan) throws -> ProjectBranchAdoptionResult {
    guard pendingPlans.removeValue(forKey: plan.confirmationID) == plan else {
      throw ProjectBranchReviewError.confirmationRequired(plan.confirmationID)
    }
    guard plan.canAdopt else {
      throw ProjectBranchReviewError.adoptionBlocked(plan.blockers)
    }

    let currentReview = try review()
    guard matches(plan: plan, currentReview: currentReview) else {
      throw ProjectBranchReviewError.stalePlan
    }
    let currentPlan = try makePlan(review: currentReview, confirmationID: plan.confirmationID)
    guard currentPlan.canAdopt else {
      throw ProjectBranchReviewError.adoptionBlocked(currentPlan.blockers)
    }

    let mergeOutput = try runGit(
      ["merge", "--no-ff", "--no-edit", plan.review.headRevision],
      rootURL: targetRootURL,
      operation: "adopt branch",
      allowedExitStatuses: [0, 1]
    )
    if mergeOutput.status == 0 {
      let mergeRevision = try resolveRevision("HEAD", at: targetRootURL)
      let parents = try revisionParents(at: targetRootURL)
      guard parents.count == 2 else {
        throw ProjectBranchReviewError.git(
          .commandFailed(
            operation: "adopt branch",
            status: mergeOutput.status,
            message: "Git did not create a two-parent merge commit."
          )
        )
      }
      return .adopted(mergeRevision: mergeRevision)
    }

    let targetStatus = try repositoryStatus(at: targetRootURL)
    let conflictPaths = targetStatus.changes
      .filter { $0.kind == .conflicted }
      .map(\.path)
      .sorted()
    guard !conflictPaths.isEmpty else {
      throw ProjectBranchReviewError.git(
        .commandFailed(
          operation: "adopt branch",
          status: mergeOutput.status,
          message: mergeOutput.text
        )
      )
    }

    return .conflict(
      ProjectBranchConflict(
        sourceWorktreeID: plan.review.sourceWorktreeID,
        sourceBranch: plan.review.expectedSourceBranch,
        targetBranch: plan.targetBranch ?? "<detached>",
        targetRootURL: targetRootURL,
        paths: conflictPaths,
        commandMessage: mergeOutput.text
      )
    )
  }

  private func makePlan(
    review: ProjectBranchReviewSnapshot,
    confirmationID: UUID = UUID()
  ) throws -> ProjectBranchAdoptionPlan {
    var blockers: [ProjectBranchAdoptionBlocker] = []
    if review.sourceRootURL.path == targetRootURL.path {
      blockers.append(.sourceIsTarget)
    }
    if review.repositoryRootURL != targetRootURL.standardizedFileURL {
      blockers.append(.repositoryMismatch)
    }
    if review.sourceBranch == nil {
      blockers.append(.sourceDetached)
    } else if review.sourceBranch != review.expectedSourceBranch {
      blockers.append(.sourceBranchChanged)
    }
    if review.targetStatus.branch == nil {
      blockers.append(.targetDetached)
    }
    if !review.sourceStatus.changes.isEmpty {
      blockers.append(.sourceDirty)
    }
    if !review.targetStatus.changes.isEmpty {
      blockers.append(.targetDirty)
    }
    if review.commits.isEmpty {
      blockers.append(.noCommits)
    }
    if try hasMergeInProgress(at: targetRootURL) {
      blockers.append(.mergeInProgress)
    }

    return ProjectBranchAdoptionPlan(
      confirmationID: confirmationID,
      review: review,
      targetRootURL: targetRootURL,
      targetBranch: review.targetStatus.branch,
      targetHeadRevision: review.targetHeadRevision,
      blockers: blockers
    )
  }

  private func revisionParents(at rootURL: URL) throws -> [String] {
    let output = try runGit(
      ["rev-list", "--parents", "-n", "1", "HEAD"],
      rootURL: rootURL,
      operation: "inspect merge revision"
    )
    let revisions = output.text
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard revisions.count >= 1 else {
      throw ProjectBranchReviewError.git(
        .unreadableOutput(operation: "inspect merge revision")
      )
    }
    return Array(revisions.dropFirst())
  }

  private func matches(
    plan: ProjectBranchAdoptionPlan,
    currentReview: ProjectBranchReviewSnapshot
  ) -> Bool {
    plan.review.sourceWorktreeID == currentReview.sourceWorktreeID
      && plan.review.projectID == currentReview.projectID
      && plan.review.repositoryRootURL == currentReview.repositoryRootURL
      && plan.review.sourceRootURL == currentReview.sourceRootURL
      && plan.review.expectedSourceBranch == currentReview.expectedSourceBranch
      && plan.review.sourceBranch == currentReview.sourceBranch
      && plan.review.baseRevision == currentReview.baseRevision
      && plan.review.headRevision == currentReview.headRevision
      && plan.review.sourceStatus == currentReview.sourceStatus
      && plan.review.targetStatus == currentReview.targetStatus
      && plan.targetRootURL == targetRootURL
      && plan.targetBranch == currentReview.targetStatus.branch
      && plan.targetHeadRevision == currentReview.targetHeadRevision
  }

  private func repositoryStatus(at rootURL: URL) throws -> ProjectGitSnapshot {
    let status = try ProjectGitService(rootURL: rootURL, fileManager: fileManager).status()
    guard status.isRepository else {
      throw ProjectBranchReviewError.git(.notRepository(path: rootURL.path))
    }
    return status
  }

  private func resolveRevision(_ revision: String, at rootURL: URL) throws -> String {
    let normalized = revision.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !normalized.isEmpty,
      !normalized.hasPrefix("-"),
      !normalized.contains("\0"),
      !normalized.contains(where: \.isWhitespace)
    else {
      throw ProjectBranchReviewError.invalidRevision(revision)
    }
    do {
      let output = try runGit(
        ["rev-parse", "--verify", "--end-of-options", "\(normalized)^{commit}"],
        rootURL: rootURL,
        operation: "resolve branch revision"
      )
      let resolved = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !resolved.isEmpty else {
        throw ProjectBranchReviewError.invalidRevision(revision)
      }
      return resolved
    } catch let error as ProjectBranchReviewError {
      throw error
    } catch let error as ProjectGitError {
      throw ProjectBranchReviewError.git(error)
    }
  }

  private func branchCommits(
    baseRevision: String,
    headRevision: String,
    rootURL: URL
  ) throws -> [ProjectBranchCommit] {
    let output = try runGit(
      [
        "log",
        "--reverse",
        "--format=%H%x00%an%x00%aI%x00%s",
        "\(baseRevision)..\(headRevision)",
        "--",
      ],
      rootURL: rootURL,
      operation: "list branch commits"
    )
    guard let text = String(data: output.data, encoding: .utf8) else {
      throw ProjectBranchReviewError.git(.unreadableOutput(operation: "list branch commits"))
    }
    let records = text.split(whereSeparator: \.isNewline)
    return try records.map { record in
      let fields =
        record
        .split(separator: "\0", omittingEmptySubsequences: false)
        .map(String.init)
      guard fields.count == 4, fields.allSatisfy({ !$0.isEmpty }) else {
        throw ProjectBranchReviewError.git(.unreadableOutput(operation: "list branch commits"))
      }
      return ProjectBranchCommit(
        revision: fields[0],
        author: fields[1],
        authoredAt: fields[2],
        subject: fields[3]
      )
    }
  }

  private func isAncestor(
    _ ancestorRevision: String,
    of descendantRevision: String,
    at rootURL: URL
  ) throws -> Bool {
    let output = try runGit(
      ["merge-base", "--is-ancestor", ancestorRevision, descendantRevision],
      rootURL: rootURL,
      operation: "validate branch base",
      allowedExitStatuses: [0, 1]
    )
    return output.status == 0
  }

  private func branchChanges(
    baseRevision: String,
    headRevision: String,
    rootURL: URL
  ) throws -> [ProjectBranchReviewChange] {
    let output = try runGit(
      [
        "diff",
        "--name-status",
        "--find-renames",
        "-z",
        "\(baseRevision)...\(headRevision)",
        "--",
      ],
      rootURL: rootURL,
      operation: "list branch changes"
    )
    let fields = try nulFields(output.data, operation: "list branch changes")
    var changes: [ProjectBranchReviewChange] = []
    var index = 0
    while index < fields.count {
      let status = fields[index]
      index += 1
      guard let code = status.first else {
        throw ProjectBranchReviewError.git(.unreadableOutput(operation: "list branch changes"))
      }
      let kind = branchChangeKind(for: code)
      if kind == .renamed || kind == .copied {
        guard index + 1 < fields.count else {
          throw ProjectBranchReviewError.git(.unreadableOutput(operation: "list branch changes"))
        }
        changes.append(
          ProjectBranchReviewChange(
            path: fields[index + 1],
            originalPath: fields[index],
            kind: kind
          )
        )
        index += 2
      } else {
        guard index < fields.count else {
          throw ProjectBranchReviewError.git(.unreadableOutput(operation: "list branch changes"))
        }
        changes.append(
          ProjectBranchReviewChange(
            path: fields[index],
            originalPath: nil,
            kind: kind
          )
        )
        index += 1
      }
    }
    return changes.sorted { $0.id < $1.id }
  }

  private func branchDiff(
    baseRevision: String,
    headRevision: String,
    rootURL: URL
  ) throws -> String {
    let output = try runGit(
      [
        "diff",
        "--no-ext-diff",
        "--no-color",
        "--find-renames",
        "\(baseRevision)...\(headRevision)",
        "--",
      ],
      rootURL: rootURL,
      operation: "read branch diff"
    )
    return output.text
  }

  private func branchChangeKind(for code: Character) -> ProjectBranchReviewChangeKind {
    switch code {
    case "A":
      .added
    case "D":
      .deleted
    case "R":
      .renamed
    case "C":
      .copied
    case "T":
      .typeChanged
    default:
      .modified
    }
  }

  private func nulFields(_ data: Data, operation: String) throws -> [String] {
    guard String(data: data, encoding: .utf8) != nil else {
      throw ProjectBranchReviewError.git(.unreadableOutput(operation: operation))
    }

    return
      data
      .split(separator: 0, omittingEmptySubsequences: true)
      .map { String(decoding: $0, as: UTF8.self) }
  }

  private func hasMergeInProgress(at rootURL: URL) throws -> Bool {
    let output = try runGit(
      ["rev-parse", "--git-path", "MERGE_HEAD"],
      rootURL: rootURL,
      operation: "inspect merge state"
    )
    let path = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
      throw ProjectBranchReviewError.git(.unreadableOutput(operation: "inspect merge state"))
    }
    let mergeHeadURL = URL(fileURLWithPath: path, relativeTo: rootURL).standardizedFileURL
    return fileManager.fileExists(atPath: mergeHeadURL.path)
  }

  private func runGit(
    _ arguments: [String],
    rootURL: URL,
    operation: String,
    allowedExitStatuses: Set<Int32> = [0]
  ) throws -> GitCommandOutput {
    guard fileManager.isExecutableFile(atPath: gitURL.path) else {
      throw ProjectBranchReviewError.git(.gitUnavailable)
    }

    let process = Process()
    let pipe = Pipe()
    process.executableURL = gitURL
    process.arguments = arguments
    process.currentDirectoryURL = rootURL
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["LC_ALL": "C", "LANG": "C"],
      uniquingKeysWith: { _, new in new }
    )
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
    } catch {
      throw ProjectBranchReviewError.git(
        .commandFailed(
          operation: operation,
          status: -1,
          message: error.localizedDescription
        )
      )
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard allowedExitStatuses.contains(process.terminationStatus) else {
      throw ProjectBranchReviewError.git(
        .commandFailed(
          operation: operation,
          status: process.terminationStatus,
          message: String(decoding: data, as: UTF8.self)
        )
      )
    }
    return GitCommandOutput(status: process.terminationStatus, data: data)
  }

  private struct GitCommandOutput {
    let status: Int32
    let data: Data

    var text: String {
      String(decoding: data, as: UTF8.self)
    }
  }
}

enum ProjectGitError: Error, Equatable, LocalizedError, Sendable {
  case gitUnavailable
  case notRepository(path: String)
  case repositoryOutsideProject(projectPath: String, repositoryPath: String)
  case invalidPath(String)
  case invalidGraphLimit(Int)
  case changeNotFound(String)
  case dirtyWorkingTree
  case invalidCommitMessage
  case invalidBranchName
  case commandFailed(operation: String, status: Int32, message: String)
  case unreadableOutput(operation: String)

  var errorDescription: String? {
    switch self {
    case .gitUnavailable:
      return "Git is not available on this Mac."
    case .notRepository(let path):
      return "No Git repository was found for \(path)."
    case .repositoryOutsideProject(let projectPath, let repositoryPath):
      return
        "The Project folder \(projectPath) is inside another repository at \(repositoryPath); Git operations are limited to a repository root."
    case .invalidPath(let path):
      return "The Git path is outside the Project: \(path)"
    case .invalidGraphLimit(let limit):
      return
        "Git graph history limit must be between 1 and \(ProjectGitService.maximumGraphLimit) (got \(limit))."
    case .changeNotFound(let path):
      return "The Git change is no longer present: \(path)"
    case .dirtyWorkingTree:
      return
        "Switch branches only after the working tree is clean; save or stage the current changes first."
    case .invalidCommitMessage:
      return "Commit message cannot be empty."
    case .invalidBranchName:
      return "Branch name cannot be empty or invalid."
    case .commandFailed(let operation, let status, let message):
      let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
      if detail.isEmpty {
        return "Git \(operation) failed (exit status \(status))."
      }
      return "Git \(operation) failed: \(detail)"
    case .unreadableOutput(let operation):
      return "Git \(operation) returned unreadable output."
    }
  }
}

struct ProjectGitService {
  static let maximumGraphLimit = 1_000

  let rootURL: URL
  private let fileManager: FileManager
  private let gitURL = URL(fileURLWithPath: "/usr/bin/git")

  init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
  }

  func status() throws -> ProjectGitSnapshot {
    guard fileManager.isExecutableFile(atPath: gitURL.path) else {
      throw ProjectGitError.gitUnavailable
    }

    guard let repositoryRoot = try repositoryRoot() else {
      return .notRepository
    }
    guard repositoryRoot.path == rootURL.path else {
      throw ProjectGitError.repositoryOutsideProject(
        projectPath: rootURL.path,
        repositoryPath: repositoryRoot.path
      )
    }

    let output = try run(
      ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
      operation: "status"
    )
    let snapshot = try Self.parseStatus(output.data, rootURL: rootURL)
    return snapshot.withBranches(try branchNames())
  }

  func graph(
    limit: Int = 200
  ) throws -> ProjectGitGraphSnapshot {
    guard (1...Self.maximumGraphLimit).contains(limit) else {
      throw ProjectGitError.invalidGraphLimit(limit)
    }
    guard fileManager.isExecutableFile(atPath: gitURL.path) else {
      throw ProjectGitError.gitUnavailable
    }

    guard let repositoryRoot = try repositoryRoot() else {
      return .notRepository
    }
    guard repositoryRoot.path == rootURL.path else {
      throw ProjectGitError.repositoryOutsideProject(
        projectPath: rootURL.path,
        repositoryPath: repositoryRoot.path
      )
    }

    let branch = try currentBranchName()
    let refs = try graphRefs(currentBranch: branch)
    let headRevision = try graphHeadRevision()
    let result = try graphCommits(
      limit: limit,
      refs: refs,
      headRevision: headRevision
    )
    return ProjectGitGraphSnapshot(
      availability: .available,
      branch: branch,
      headRevision: headRevision,
      refs: refs,
      commits: result.commits,
      isTruncated: result.isTruncated,
      message: nil
    )
  }

  func diff(for change: ProjectGitChange, basis: ProjectGitDiffBasis) throws -> ProjectGitDiff {
    try requireRepository()
    let path = try validatedRelativePath(change.path)
    var arguments = ["diff", "--no-ext-diff", "--no-color"]
    let allowedExitStatuses: Set<Int32>

    if change.isUntracked && basis == .workingTree {
      arguments += ["--no-index", "--", "/dev/null", path]
      allowedExitStatuses = [0, 1]
    } else {
      if basis == .staged {
        arguments.append("--cached")
      }
      arguments += ["--", path]
      allowedExitStatuses = [0]
    }

    let output = try run(
      arguments,
      operation: "diff",
      allowedExitStatuses: allowedExitStatuses
    )
    return ProjectGitDiff(change: change, basis: basis, text: output.text)
  }

  func stage(path: String) throws -> ProjectGitSnapshot {
    try requireRepository()
    _ = try run(["add", "--", try validatedRelativePath(path)], operation: "stage")
    return try status()
  }

  func unstage(path: String) throws -> ProjectGitSnapshot {
    try requireRepository()
    _ = try run(
      ["restore", "--staged", "--", try validatedRelativePath(path)],
      operation: "unstage"
    )
    return try status()
  }

  func commit(message: String) throws -> ProjectGitSnapshot {
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ProjectGitError.invalidCommitMessage
    }
    try requireRepository()
    _ = try run(["commit", "-m", message], operation: "commit")
    return try status()
  }

  func switchBranch(_ branch: String) throws -> ProjectGitSnapshot {
    let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedBranch.isEmpty, !normalizedBranch.hasPrefix("-") else {
      throw ProjectGitError.invalidBranchName
    }
    try requireRepository()
    let currentStatus = try status()
    guard currentStatus.changes.isEmpty else {
      throw ProjectGitError.dirtyWorkingTree
    }
    _ = try run(
      ["check-ref-format", "--branch", normalizedBranch],
      operation: "validate branch"
    )
    _ = try run(["switch", "--", normalizedBranch], operation: "switch branch")
    return try status()
  }

  private func requireRepository() throws {
    guard let repositoryRoot = try repositoryRoot() else {
      throw ProjectGitError.notRepository(path: rootURL.path)
    }
    guard repositoryRoot.path == rootURL.path else {
      throw ProjectGitError.repositoryOutsideProject(
        projectPath: rootURL.path,
        repositoryPath: repositoryRoot.path
      )
    }
  }

  private func repositoryRoot() throws -> URL? {
    do {
      let output = try run(["rev-parse", "--show-toplevel"], operation: "locate repository")
      let path = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !path.isEmpty else {
        throw ProjectGitError.unreadableOutput(operation: "locate repository")
      }
      return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    } catch let error as ProjectGitError {
      if case .commandFailed = error {
        return nil
      }
      throw error
    }
  }

  private func branchNames() throws -> [String] {
    let output = try run(
      ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
      operation: "list branches"
    )
    return output.text
      .split(whereSeparator: \.isNewline)
      .map(String.init)
      .filter { !$0.isEmpty }
      .sorted()
  }

  private func currentBranchName() throws -> String? {
    let output = try run(["branch", "--show-current"], operation: "read current branch")
    let branch = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return branch.isEmpty ? nil : branch
  }

  private func graphHeadRevision() throws -> String? {
    let output = try run(
      ["rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD^{commit}"],
      operation: "read graph HEAD",
      allowedExitStatuses: [0, 1, 128]
    )
    guard output.status == 0 else {
      return nil
    }
    let revision = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !revision.isEmpty else {
      throw ProjectGitError.unreadableOutput(operation: "read graph HEAD")
    }
    return revision
  }

  private func graphRefs(currentBranch: String?) throws -> [ProjectGitGraphRef] {
    let output = try run(
      [
        "for-each-ref",
        "--format=%(refname)%00%(refname:short)%00%(objectname)%00%(*objectname)%00%(objecttype)%00%(*objecttype)%1e",
        "refs",
      ],
      operation: "list graph refs"
    )
    guard String(data: output.data, encoding: .utf8) != nil else {
      throw ProjectGitError.unreadableOutput(operation: "list graph refs")
    }

    let records =
      output.data
      .split(separator: 0x1e, omittingEmptySubsequences: true)
      .map { $0.drop(while: { $0 == 0x0a || $0 == 0x0d }) }
      .filter { !$0.isEmpty }
    var refs: [ProjectGitGraphRef] = []
    for record in records {
      let fields =
        record
        .split(separator: 0, omittingEmptySubsequences: false)
        .map { String(decoding: $0, as: UTF8.self) }
      guard fields.count == 6 else {
        throw ProjectGitError.unreadableOutput(operation: "list graph refs")
      }

      let fullName = fields[0]
      let name = fields[1]
      let objectRevision = fields[2]
      let peeledRevision = fields[3]
      let objectType = fields[4]
      let peeledType = fields[5]
      guard fullName.hasPrefix("refs/"), !name.isEmpty else {
        throw ProjectGitError.unreadableOutput(operation: "list graph refs")
      }

      let targetRevision: String?
      if objectType == "commit" {
        targetRevision = objectRevision
      } else if peeledType == "commit" {
        targetRevision = peeledRevision
      } else {
        targetRevision = nil
      }
      guard let targetRevision, !targetRevision.isEmpty else {
        continue
      }

      let kind = graphRefKind(for: fullName)
      refs.append(
        ProjectGitGraphRef(
          name: name,
          fullName: fullName,
          targetRevision: targetRevision,
          kind: kind,
          isCurrent: kind == .localBranch && name == currentBranch
        )
      )
    }
    return refs.sorted { $0.fullName < $1.fullName }
  }

  private func graphCommits(
    limit: Int,
    refs: [ProjectGitGraphRef],
    headRevision: String?
  ) throws -> (commits: [ProjectGitGraphCommit], isTruncated: Bool) {
    var arguments = [
      "log",
      "--all",
      "--topo-order",
      "--no-decorate",
      "--max-count=\(limit + 1)",
      "--format=%H%x00%P%x00%an%x00%aI%x00%s%x1e",
    ]
    if let headRevision {
      // --all does not promise to include an otherwise unreachable detached HEAD.
      // The revision was resolved by Git above, so it is safe to pass as a revision.
      arguments.append(headRevision)
    }
    arguments.append("--")

    let output = try run(
      arguments,
      operation: "list graph commits"
    )
    guard String(data: output.data, encoding: .utf8) != nil else {
      throw ProjectGitError.unreadableOutput(operation: "list graph commits")
    }

    let refsByRevision = Dictionary(grouping: refs, by: \.targetRevision)
    let records =
      output.data
      .split(separator: 0x1e, omittingEmptySubsequences: true)
      .map { $0.drop(while: { $0 == 0x0a || $0 == 0x0d }) }
      .filter { !$0.isEmpty }
    let parsedCommits = try records.map { record -> ProjectGitGraphCommit in
      let fields =
        record
        .split(separator: 0, omittingEmptySubsequences: false)
        .map { String(decoding: $0, as: UTF8.self) }
      guard fields.count == 5 else {
        throw ProjectGitError.unreadableOutput(operation: "list graph commits")
      }

      let revision = fields[0]
      let parentRevisions = fields[1].split(whereSeparator: \.isWhitespace).map(String.init)
      let author = fields[2]
      let authoredAt = fields[3]
      let subject = fields[4]
      guard !revision.isEmpty, !author.isEmpty, !authoredAt.isEmpty else {
        throw ProjectGitError.unreadableOutput(operation: "list graph commits")
      }
      return ProjectGitGraphCommit(
        revision: revision,
        parentRevisions: parentRevisions,
        author: author,
        authoredAt: authoredAt,
        subject: subject,
        refs: refsByRevision[revision, default: []]
      )
    }

    return (
      commits: Array(parsedCommits.prefix(limit)),
      isTruncated: parsedCommits.count > limit
    )
  }

  private func graphRefKind(for fullName: String) -> ProjectGitGraphRefKind {
    if fullName.hasPrefix("refs/heads/") {
      return .localBranch
    }
    if fullName.hasPrefix("refs/remotes/") {
      return .remoteBranch
    }
    if fullName.hasPrefix("refs/tags/") {
      return .tag
    }
    return .other
  }

  private func validatedRelativePath(_ path: String) throws -> String {
    guard !path.isEmpty, !path.hasPrefix("/") else {
      throw ProjectGitError.invalidPath(path)
    }
    guard !path.split(separator: "/").contains(".git") else {
      throw ProjectGitError.invalidPath(path)
    }
    let candidate = rootURL.appendingPathComponent(path).standardizedFileURL
    let rootPath = rootURL.path
    let prefix = rootPath == "/" ? "/" : rootPath + "/"
    guard candidate.path != rootPath, candidate.path.hasPrefix(prefix) else {
      throw ProjectGitError.invalidPath(path)
    }
    return path
  }

  private func run(
    _ arguments: [String],
    operation: String,
    allowedExitStatuses: Set<Int32> = [0]
  ) throws -> GitCommandOutput {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = gitURL
    process.arguments = arguments
    process.currentDirectoryURL = rootURL
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["LC_ALL": "C", "LANG": "C"],
      uniquingKeysWith: { _, new in new }
    )
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
    } catch {
      throw ProjectGitError.commandFailed(
        operation: operation,
        status: -1,
        message: error.localizedDescription
      )
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard allowedExitStatuses.contains(process.terminationStatus) else {
      let message = String(decoding: data, as: UTF8.self)
      throw ProjectGitError.commandFailed(
        operation: operation,
        status: process.terminationStatus,
        message: message
      )
    }
    return GitCommandOutput(status: process.terminationStatus, data: data)
  }

  private struct GitCommandOutput {
    let status: Int32
    let data: Data

    var text: String {
      String(decoding: data, as: UTF8.self)
    }
  }

  static func parseStatus(_ data: Data, rootURL: URL) throws -> ProjectGitSnapshot {
    guard let output = String(data: data, encoding: .utf8) else {
      throw ProjectGitError.unreadableOutput(operation: "status")
    }

    let records = output.split(separator: "\0", omittingEmptySubsequences: true)
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var changes: [ProjectGitChange] = []
    var recordIndex = 0

    while recordIndex < records.count {
      let record = String(records[recordIndex])
      recordIndex += 1

      if record.hasPrefix("# branch.head ") {
        let value = String(record.dropFirst("# branch.head ".count))
        branch = value == "(detached)" ? nil : value
        continue
      }
      if record.hasPrefix("# branch.upstream ") {
        upstream = String(record.dropFirst("# branch.upstream ".count))
        continue
      }
      if record.hasPrefix("# branch.ab ") {
        let fields = record.dropFirst("# branch.ab ".count).split(separator: " ")
        if fields.count == 2 {
          ahead = parseSignedCount(fields[0])
          behind = parseSignedCount(fields[1])
        }
        continue
      }

      if record.hasPrefix("1 ") {
        changes.append(try parseTrackedRecord(record, rootURL: rootURL))
        continue
      }
      if record.hasPrefix("2 ") {
        guard recordIndex < records.count else {
          throw ProjectGitError.unreadableOutput(operation: "status")
        }
        let originalPath = String(records[recordIndex])
        recordIndex += 1
        changes.append(
          try parseTrackedRecord(
            record,
            rootURL: rootURL,
            originalPath: originalPath
          )
        )
        continue
      }
      if record.hasPrefix("u ") {
        changes.append(try parseUnmergedRecord(record, rootURL: rootURL))
        continue
      }
      if record.hasPrefix("? ") {
        let path = String(record.dropFirst(2))
        guard !path.isEmpty else {
          throw ProjectGitError.unreadableOutput(operation: "status")
        }
        changes.append(
          ProjectGitChange(
            id: "untracked:\(path)",
            path: path,
            originalPath: nil,
            kind: .untracked,
            indexStatus: " ",
            worktreeStatus: "?"
          )
        )
      }
    }

    return ProjectGitSnapshot(
      availability: .available,
      branch: branch,
      upstream: upstream,
      ahead: ahead,
      behind: behind,
      branches: [],
      changes: changes.sorted { $0.id < $1.id },
      message: nil
    )
  }

  private static func parseTrackedRecord(
    _ record: String,
    rootURL: URL,
    originalPath: String? = nil
  ) throws -> ProjectGitChange {
    let isRenameOrCopy = record.hasPrefix("2 ")
    let pathFieldIndex = isRenameOrCopy ? 9 : 8
    let fields = record.split(
      separator: " ",
      maxSplits: pathFieldIndex,
      omittingEmptySubsequences: true
    )
    guard fields.count == pathFieldIndex + 1, fields[1].count == 2 else {
      throw ProjectGitError.unreadableOutput(operation: "status")
    }
    let xy = Array(fields[1])
    let path = String(fields[pathFieldIndex])
    guard !path.isEmpty else {
      throw ProjectGitError.unreadableOutput(operation: "status")
    }
    _ = try validateParsedPath(path, rootURL: rootURL)
    if let originalPath {
      _ = try validateParsedPath(originalPath, rootURL: rootURL)
    }
    let kind = changeKind(for: String(fields[1]))
    return ProjectGitChange(
      id: "\(kind.rawValue):\(path)",
      path: path,
      originalPath: originalPath,
      kind: kind,
      indexStatus: xy[0],
      worktreeStatus: xy[1]
    )
  }

  private static func parseUnmergedRecord(
    _ record: String,
    rootURL: URL
  ) throws -> ProjectGitChange {
    let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
    guard fields.count >= 2, fields[1].count == 2, let path = fields.last, !path.isEmpty else {
      throw ProjectGitError.unreadableOutput(operation: "status")
    }
    let pathString = String(path)
    _ = try validateParsedPath(pathString, rootURL: rootURL)
    let xy = Array(fields[1])
    return ProjectGitChange(
      id: "conflicted:\(pathString)",
      path: pathString,
      originalPath: nil,
      kind: .conflicted,
      indexStatus: xy[0],
      worktreeStatus: xy[1]
    )
  }

  private static func validateParsedPath(_ path: String, rootURL: URL) throws -> String {
    guard !path.isEmpty, !path.hasPrefix("/") else {
      throw ProjectGitError.invalidPath(path)
    }
    guard !path.split(separator: "/").contains(".git") else {
      throw ProjectGitError.invalidPath(path)
    }
    let root = rootURL.standardizedFileURL
    let candidate = root.appendingPathComponent(path).standardizedFileURL
    let prefix = root.path == "/" ? "/" : root.path + "/"
    guard candidate.path != root.path, candidate.path.hasPrefix(prefix) else {
      throw ProjectGitError.invalidPath(path)
    }
    return path
  }

  private static func changeKind(for xy: String) -> ProjectGitChangeKind {
    if xy.contains("U") {
      return .conflicted
    }
    if xy.contains("R") {
      return .renamed
    }
    if xy.contains("C") {
      return .copied
    }
    if xy.contains("D") {
      return .deleted
    }
    if xy.contains("A") {
      return .added
    }
    if xy.contains("T") {
      return .typeChanged
    }
    return .modified
  }

  private static func parseSignedCount(_ value: Substring) -> Int {
    Int(value) ?? 0
  }
}
