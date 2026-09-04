import Combine
import Foundation

typealias WorktreeID = UUID

enum ManagedWorktreeState: String, Codable, Equatable, Sendable {
  case available
  case missing
  case detached

  var displayName: String {
    switch self {
    case .available:
      "利用可能"
    case .missing:
      "見つかりません"
    case .detached:
      "切り離し"
    }
  }
}

struct ManagedWorktree: Identifiable, Equatable, Sendable {
  let id: WorktreeID
  let projectID: UUID
  let repositoryRootURL: URL
  let rootURL: URL
  let branch: String
  let baseRevision: String
  let createdAt: Date
  let state: ManagedWorktreeState
  let headRevision: String?
  let currentBranch: String?
  let gitStatus: ProjectGitSnapshot?

  var isDirty: Bool {
    !(gitStatus?.changes.isEmpty ?? true)
  }

  var displayName: String {
    rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
  }
}

struct ManagedWorktreeRecord: Codable, Equatable, Sendable {
  let id: WorktreeID
  let projectID: UUID
  let repositoryRootPath: String
  let rootPath: String
  let branch: String
  let baseRevision: String
  let createdAt: Date
}

struct ManagedWorktreeStoreSnapshot: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  var worktrees: [ManagedWorktreeRecord]

  static var empty: ManagedWorktreeStoreSnapshot {
    ManagedWorktreeStoreSnapshot(
      schemaVersion: currentSchemaVersion,
      worktrees: []
    )
  }
}

enum ManagedWorktreeStoreError: Error, Equatable, LocalizedError, Sendable {
  case unavailable
  case fileTooLarge(Int)
  case io(String)
  case malformed
  case unsupportedVersion(Int)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Clair's managed worktree store is unavailable."
    case .fileTooLarge(let size):
      "Clair's managed worktree store is too large (\(size) bytes)."
    case .io(let message):
      "Clair could not access the managed worktree store: \(message)"
    case .malformed:
      "Clair's managed worktree store is malformed."
    case .unsupportedVersion(let version):
      "Clair does not support managed worktree store version \(version)."
    }
  }
}

final class ManagedWorktreeStore {
  static let maximumFileBytes = 4 * 1024 * 1024

  let fileURL: URL?

  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(fileURL: URL?, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    self.encoder = encoder
    self.decoder = JSONDecoder()
  }

  static func makeDefault(
    for profile: ClairRuntimeProfile,
    fileManager: FileManager = .default
  ) -> ManagedWorktreeStore {
    let baseDirectory = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    let dataDirectory = baseDirectory.map(profile.applicationSupportURL)
    let fileURL = dataDirectory?.appendingPathComponent(
      "worktrees-v1.json",
      isDirectory: false
    )
    return ManagedWorktreeStore(fileURL: fileURL, fileManager: fileManager)
  }

  func load() throws -> ManagedWorktreeStoreSnapshot {
    guard let fileURL else {
      throw ManagedWorktreeStoreError.unavailable
    }
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return .empty
    }

    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw ManagedWorktreeStoreError.io(error.localizedDescription)
    }
    guard data.count <= Self.maximumFileBytes else {
      throw ManagedWorktreeStoreError.fileTooLarge(data.count)
    }

    let snapshot: ManagedWorktreeStoreSnapshot
    do {
      snapshot = try decoder.decode(ManagedWorktreeStoreSnapshot.self, from: data)
    } catch {
      throw ManagedWorktreeStoreError.malformed
    }
    guard snapshot.schemaVersion == ManagedWorktreeStoreSnapshot.currentSchemaVersion else {
      throw ManagedWorktreeStoreError.unsupportedVersion(snapshot.schemaVersion)
    }
    return snapshot
  }

  func save(_ snapshot: ManagedWorktreeStoreSnapshot) throws {
    guard let fileURL else {
      throw ManagedWorktreeStoreError.unavailable
    }
    guard snapshot.schemaVersion == ManagedWorktreeStoreSnapshot.currentSchemaVersion else {
      throw ManagedWorktreeStoreError.unsupportedVersion(snapshot.schemaVersion)
    }

    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let data = try encoder.encode(snapshot)
      guard data.count <= Self.maximumFileBytes else {
        throw ManagedWorktreeStoreError.fileTooLarge(data.count)
      }
      try data.write(to: fileURL, options: [.atomic])
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: fileURL.path
      )
    } catch let error as ManagedWorktreeStoreError {
      throw error
    } catch {
      throw ManagedWorktreeStoreError.io(error.localizedDescription)
    }
  }
}

enum ManagedWorktreeCleanupBlocker: String, Equatable, Sendable {
  case dirtyWorkingTree
  case activeSession
  case missingWorktree
  case detachedWorktree
  case targetMismatch

  var displayName: String {
    switch self {
    case .dirtyWorkingTree:
      "未コミットの変更"
    case .activeSession:
      "実行中のターミナルまたはAgentセッション"
    case .missingWorktree:
      "見つからないworktree"
    case .detachedWorktree:
      "未登録または切り離されたGit worktree"
    case .targetMismatch:
      "別のクリーンアップ対象"
    }
  }
}

struct ManagedWorktreeCleanupPlan: Identifiable, Equatable, Sendable {
  let confirmationID: UUID
  let worktreeID: WorktreeID
  let rootURL: URL
  let branch: String
  let state: ManagedWorktreeState
  let expectedHeadRevision: String?
  let expectedCurrentBranch: String?
  let blockers: [ManagedWorktreeCleanupBlocker]

  var id: UUID {
    confirmationID
  }

  var canConfirm: Bool {
    blockers.isEmpty
  }
}

enum ManagedWorktreeError: Error, Equatable, LocalizedError, Sendable {
  case store(ManagedWorktreeStoreError)
  case git(ProjectGitError)
  case notRepository(path: String)
  case invalidManagementRoot(path: String)
  case invalidBranchName
  case branchAlreadyExists(String)
  case invalidBaseRevision(String)
  case invalidTarget(String)
  case targetExists(String)
  case worktreeNotFound(WorktreeID)
  case cleanupBlocked([ManagedWorktreeCleanupBlocker])
  case confirmationRequired(UUID)
  case targetMismatch(expected: String, actual: String)
  case commandFailed(operation: String, status: Int32, message: String)
  case unreadableOutput(operation: String)

  var errorDescription: String? {
    switch self {
    case .store(let error):
      return error.localizedDescription
    case .git(let error):
      return error.localizedDescription
    case .notRepository(let path):
      return "No Git repository was found at \(path)."
    case .invalidManagementRoot(let path):
      return "Managed worktrees must use a valid repository-external directory: \(path)"
    case .invalidBranchName:
      return "The managed worktree branch name is invalid."
    case .branchAlreadyExists(let branch):
      return "The branch \(branch) already exists or is already checked out."
    case .invalidBaseRevision(let revision):
      return "The base revision could not be resolved: \(revision)"
    case .invalidTarget(let path):
      return "The managed worktree target is outside Clair's managed directory: \(path)"
    case .targetExists(let path):
      return "The managed worktree target already exists: \(path)"
    case .worktreeNotFound(let id):
      return "Managed worktree \(id.uuidString) was not found."
    case .cleanupBlocked(let blockers):
      let detail = blockers.map(\.displayName).joined(separator: ", ")
      return "Managed worktree cleanup was refused because of \(detail)."
    case .confirmationRequired(let id):
      return "Managed worktree cleanup requires a fresh confirmation (\(id.uuidString))."
    case .targetMismatch(let expected, let actual):
      return "Managed worktree cleanup target changed from \(expected) to \(actual)."
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

final class ProjectWorktreeService {
  let projectID: UUID
  let repositoryRootURL: URL
  let managementRootURL: URL

  private let store: ManagedWorktreeStore
  private let fileManager: FileManager
  private let gitURL = URL(fileURLWithPath: "/usr/bin/git")
  private var pendingCleanupPlans: [UUID: ManagedWorktreeCleanupPlan] = [:]

  init(
    projectID: UUID,
    repositoryRootURL: URL,
    managementRootURL: URL,
    store: ManagedWorktreeStore,
    fileManager: FileManager = .default
  ) {
    self.projectID = projectID
    self.repositoryRootURL = Self.canonicalURL(for: repositoryRootURL)
    self.managementRootURL = managementRootURL.standardizedFileURL
    self.store = store
    self.fileManager = fileManager
  }

  func create(
    branch: String,
    baseRevision: String,
    targetName: String
  ) throws -> ManagedWorktree {
    let targetURL = managementRootURL.appendingPathComponent(
      targetName.trimmingCharacters(in: .whitespacesAndNewlines),
      isDirectory: true
    )
    return try create(
      branch: branch,
      baseRevision: baseRevision,
      targetURL: targetURL
    )
  }

  func create(
    branch: String,
    baseRevision: String,
    targetURL: URL
  ) throws -> ManagedWorktree {
    try validateRepository()
    let managedRoot = try prepareManagementRoot()
    let normalizedBranch = try validateBranch(branch)
    let resolvedBase = try resolveBaseRevision(baseRevision)
    let canonicalTarget = try validateTarget(targetURL, managedRoot: managedRoot)

    guard !fileManager.fileExists(atPath: canonicalTarget.path) else {
      throw ManagedWorktreeError.targetExists(canonicalTarget.path)
    }

    let registered = try registeredWorktrees()
    if registered.contains(where: { $0.path == canonicalTarget }) {
      throw ManagedWorktreeError.targetExists(canonicalTarget.path)
    }

    do {
      let snapshot = try store.load()
      if snapshot.worktrees.contains(where: { $0.rootPath == canonicalTarget.path }) {
        throw ManagedWorktreeError.targetExists(canonicalTarget.path)
      }
      if snapshot.worktrees.contains(where: {
        $0.projectID == projectID && $0.branch == normalizedBranch
      }) {
        throw ManagedWorktreeError.branchAlreadyExists(normalizedBranch)
      }
    } catch let error as ManagedWorktreeStoreError {
      throw ManagedWorktreeError.store(error)
    }

    try fileManager.createDirectory(
      at: canonicalTarget.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    do {
      _ = try runGit(
        [
          "worktree",
          "add",
          "-b",
          normalizedBranch,
          canonicalTarget.path,
          resolvedBase,
        ],
        operation: "create worktree"
      )
    } catch {
      throw error
    }

    let record = ManagedWorktreeRecord(
      id: UUID(),
      projectID: projectID,
      repositoryRootPath: repositoryRootURL.path,
      rootPath: canonicalTarget.path,
      branch: normalizedBranch,
      baseRevision: resolvedBase,
      createdAt: Date()
    )

    do {
      var snapshot = try store.load()
      guard
        !snapshot.worktrees.contains(where: {
          $0.rootPath == record.rootPath
            || ($0.projectID == projectID && $0.branch == record.branch)
        })
      else {
        _ = try? runGit(
          ["worktree", "remove", "--force", "--", canonicalTarget.path],
          operation: "rollback worktree creation"
        )
        throw ManagedWorktreeError.branchAlreadyExists(record.branch)
      }
      snapshot.worktrees.append(record)
      try store.save(snapshot)
    } catch let error as ManagedWorktreeStoreError {
      _ = try? runGit(
        ["worktree", "remove", "--force", "--", canonicalTarget.path],
        operation: "rollback worktree creation"
      )
      throw ManagedWorktreeError.store(error)
    }

    return try inspect(record: record)
  }

  func list() throws -> [ManagedWorktree] {
    let records = try recordsForProject()
    return
      try records
      .map { try inspect(record: $0) }
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.createdAt < $1.createdAt
      }
  }

  func inspect(_ id: WorktreeID) throws -> ManagedWorktree {
    guard let record = try recordsForProject().first(where: { $0.id == id }) else {
      throw ManagedWorktreeError.worktreeNotFound(id)
    }
    return try inspect(record: record)
  }

  func prepareCleanup(
    _ id: WorktreeID,
    activeSessionIDs: Set<UUID> = [],
    expectedRootURL: URL? = nil
  ) throws -> ManagedWorktreeCleanupPlan {
    let worktree = try inspect(id)
    let plan = makeCleanupPlan(
      for: worktree,
      activeSessionIDs: activeSessionIDs,
      expectedRootURL: expectedRootURL
    )
    pendingCleanupPlans[plan.confirmationID] = plan
    return plan
  }

  func confirmCleanup(
    _ plan: ManagedWorktreeCleanupPlan,
    activeSessionIDs: Set<UUID> = []
  ) throws {
    guard pendingCleanupPlans.removeValue(forKey: plan.confirmationID) == plan else {
      throw ManagedWorktreeError.confirmationRequired(plan.confirmationID)
    }
    guard plan.blockers.isEmpty else {
      throw ManagedWorktreeError.cleanupBlocked(plan.blockers)
    }

    let current = try inspect(plan.worktreeID)
    guard current.rootURL.path == plan.rootURL.standardizedFileURL.path else {
      throw ManagedWorktreeError.targetMismatch(
        expected: plan.rootURL.path,
        actual: current.rootURL.path
      )
    }
    guard
      current.state == plan.state,
      current.headRevision == plan.expectedHeadRevision,
      current.currentBranch == plan.expectedCurrentBranch
    else {
      throw ManagedWorktreeError.targetMismatch(
        expected: cleanupFingerprint(
          state: plan.state,
          headRevision: plan.expectedHeadRevision,
          currentBranch: plan.expectedCurrentBranch
        ),
        actual: cleanupFingerprint(for: current)
      )
    }

    let currentPlan = makeCleanupPlan(
      for: current,
      activeSessionIDs: activeSessionIDs,
      expectedRootURL: plan.rootURL
    )
    guard currentPlan.blockers.isEmpty else {
      throw ManagedWorktreeError.cleanupBlocked(currentPlan.blockers)
    }

    _ = try runGit(
      ["worktree", "remove", "--", current.rootURL.path],
      operation: "remove worktree"
    )

    do {
      var snapshot = try store.load()
      snapshot.worktrees.removeAll { $0.id == plan.worktreeID }
      try store.save(snapshot)
    } catch let error as ManagedWorktreeStoreError {
      throw ManagedWorktreeError.store(error)
    }
  }

  private func recordsForProject() throws -> [ManagedWorktreeRecord] {
    let managedRoot = try validatedManagementRoot()
    do {
      let records = try store.load().worktrees.filter { record in
        record.projectID == projectID && record.repositoryRootPath == repositoryRootURL.path
      }
      for record in records {
        _ = try validatedRecordRoot(record, managedRoot: managedRoot)
      }
      return records
    } catch let error as ManagedWorktreeStoreError {
      throw ManagedWorktreeError.store(error)
    }
  }

  private func inspect(record: ManagedWorktreeRecord) throws -> ManagedWorktree {
    let rootURL = try validatedRecordRoot(
      record,
      managedRoot: try validatedManagementRoot()
    )
    let repositoryRootURL = Self.canonicalURL(
      for: URL(fileURLWithPath: record.repositoryRootPath, isDirectory: true)
    )

    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return ManagedWorktree(
        id: record.id,
        projectID: record.projectID,
        repositoryRootURL: repositoryRootURL,
        rootURL: URL(fileURLWithPath: record.rootPath, isDirectory: true).standardizedFileURL,
        branch: record.branch,
        baseRevision: record.baseRevision,
        createdAt: record.createdAt,
        state: .missing,
        headRevision: nil,
        currentBranch: nil,
        gitStatus: nil
      )
    }

    guard let registration = try registeredWorktrees().first(where: { $0.path == rootURL }) else {
      return ManagedWorktree(
        id: record.id,
        projectID: record.projectID,
        repositoryRootURL: repositoryRootURL,
        rootURL: rootURL,
        branch: record.branch,
        baseRevision: record.baseRevision,
        createdAt: record.createdAt,
        state: .detached,
        headRevision: nil,
        currentBranch: nil,
        gitStatus: nil
      )
    }

    do {
      let status = try ProjectGitService(rootURL: rootURL, fileManager: fileManager).status()
      guard status.isRepository else {
        return ManagedWorktree(
          id: record.id,
          projectID: record.projectID,
          repositoryRootURL: repositoryRootURL,
          rootURL: rootURL,
          branch: record.branch,
          baseRevision: record.baseRevision,
          createdAt: record.createdAt,
          state: .detached,
          headRevision: registration.headRevision,
          currentBranch: registration.branch,
          gitStatus: status
        )
      }
      if registration.isDetached {
        return ManagedWorktree(
          id: record.id,
          projectID: record.projectID,
          repositoryRootURL: repositoryRootURL,
          rootURL: rootURL,
          branch: record.branch,
          baseRevision: record.baseRevision,
          createdAt: record.createdAt,
          state: .detached,
          headRevision: registration.headRevision,
          currentBranch: nil,
          gitStatus: status
        )
      }
      return ManagedWorktree(
        id: record.id,
        projectID: record.projectID,
        repositoryRootURL: repositoryRootURL,
        rootURL: rootURL,
        branch: record.branch,
        baseRevision: record.baseRevision,
        createdAt: record.createdAt,
        state: .available,
        headRevision: registration.headRevision,
        currentBranch: status.branch ?? registration.branch,
        gitStatus: status
      )
    } catch let error as ProjectGitError {
      switch error {
      case .gitUnavailable:
        throw ManagedWorktreeError.git(error)
      default:
        return ManagedWorktree(
          id: record.id,
          projectID: record.projectID,
          repositoryRootURL: repositoryRootURL,
          rootURL: rootURL,
          branch: record.branch,
          baseRevision: record.baseRevision,
          createdAt: record.createdAt,
          state: .detached,
          headRevision: registration.headRevision,
          currentBranch: registration.branch,
          gitStatus: nil
        )
      }
    }
  }

  private func makeCleanupPlan(
    for worktree: ManagedWorktree,
    activeSessionIDs: Set<UUID>,
    expectedRootURL: URL?
  ) -> ManagedWorktreeCleanupPlan {
    var blockers: [ManagedWorktreeCleanupBlocker] = []
    if let expectedRootURL,
      Self.canonicalURL(for: expectedRootURL).path != worktree.rootURL.standardizedFileURL.path
    {
      blockers.append(.targetMismatch)
    }
    switch worktree.state {
    case .available:
      break
    case .missing:
      blockers.append(.missingWorktree)
    case .detached:
      blockers.append(.detachedWorktree)
    }
    if worktree.isDirty {
      blockers.append(.dirtyWorkingTree)
    }
    if !activeSessionIDs.isEmpty {
      blockers.append(.activeSession)
    }
    return ManagedWorktreeCleanupPlan(
      confirmationID: UUID(),
      worktreeID: worktree.id,
      rootURL: worktree.rootURL,
      branch: worktree.branch,
      state: worktree.state,
      expectedHeadRevision: worktree.headRevision,
      expectedCurrentBranch: worktree.currentBranch,
      blockers: blockers
    )
  }

  private func cleanupFingerprint(for worktree: ManagedWorktree) -> String {
    cleanupFingerprint(
      state: worktree.state,
      headRevision: worktree.headRevision,
      currentBranch: worktree.currentBranch
    )
  }

  private func cleanupFingerprint(
    state: ManagedWorktreeState,
    headRevision: String?,
    currentBranch: String?
  ) -> String {
    "state=\(state.rawValue), branch=\(currentBranch ?? "<detached>"), head=\(headRevision ?? "<unknown>")"
  }

  private func validateRepository() throws {
    let output: GitCommandOutput
    do {
      output = try runGit(
        ["rev-parse", "--show-toplevel"],
        operation: "locate repository"
      )
    } catch let error as ManagedWorktreeError {
      if case .commandFailed = error {
        throw ManagedWorktreeError.notRepository(path: repositoryRootURL.path)
      }
      throw error
    }
    let detectedRoot = Self.canonicalURL(
      for: URL(fileURLWithPath: output.text.trimmingCharacters(in: .whitespacesAndNewlines))
    )
    guard detectedRoot.path == repositoryRootURL.path else {
      throw ManagedWorktreeError.notRepository(path: repositoryRootURL.path)
    }
  }

  private func prepareManagementRoot() throws -> URL {
    _ = try validatedManagementRoot()

    do {
      try fileManager.createDirectory(
        at: managementRootURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw ManagedWorktreeError.invalidManagementRoot(path: managementRootURL.path)
    }

    return try validatedManagementRoot()
  }

  private func validatedManagementRoot() throws -> URL {
    let candidate = Self.canonicalURL(for: managementRootURL)
    guard managementRootURL.isFileURL, candidate.path.hasPrefix("/") else {
      throw ManagedWorktreeError.invalidManagementRoot(path: managementRootURL.path)
    }
    let repositoryPrefix = pathPrefix(for: repositoryRootURL)
    guard candidate.path != repositoryRootURL.path, !candidate.path.hasPrefix(repositoryPrefix)
    else {
      throw ManagedWorktreeError.invalidManagementRoot(path: candidate.path)
    }
    return candidate
  }

  private func validatedRecordRoot(
    _ record: ManagedWorktreeRecord,
    managedRoot: URL
  ) throws -> URL {
    let storedURL = URL(fileURLWithPath: record.rootPath, isDirectory: true)
    let rootURL = Self.canonicalURL(for: storedURL)
    let managedPrefix = pathPrefix(for: managedRoot)
    guard rootURL.path != managedRoot.path, rootURL.path.hasPrefix(managedPrefix) else {
      throw ManagedWorktreeError.invalidTarget(record.rootPath)
    }
    return rootURL
  }

  private func validateBranch(_ branch: String) throws -> String {
    let normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, !normalized.hasPrefix("-"), !normalized.contains("\0") else {
      throw ManagedWorktreeError.invalidBranchName
    }
    let validation = try runGit(
      ["check-ref-format", "--branch", normalized],
      operation: "validate worktree branch",
      allowedExitStatuses: [0, 1]
    )
    guard validation.status == 0 else {
      throw ManagedWorktreeError.invalidBranchName
    }
    let existing = try runGit(
      ["show-ref", "--verify", "--quiet", "refs/heads/\(normalized)"],
      operation: "check worktree branch",
      allowedExitStatuses: [0, 1]
    )
    guard existing.status != 0 else {
      throw ManagedWorktreeError.branchAlreadyExists(normalized)
    }
    return normalized
  }

  private func resolveBaseRevision(_ revision: String) throws -> String {
    let normalized = revision.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, !normalized.hasPrefix("-"), !normalized.contains("\0") else {
      throw ManagedWorktreeError.invalidBaseRevision(revision)
    }
    do {
      let output = try runGit(
        ["rev-parse", "--verify", "--end-of-options", "\(normalized)^{commit}"],
        operation: "resolve worktree base"
      )
      let resolved = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !resolved.isEmpty else {
        throw ManagedWorktreeError.invalidBaseRevision(revision)
      }
      return resolved
    } catch let error as ManagedWorktreeError {
      if case .commandFailed = error {
        throw ManagedWorktreeError.invalidBaseRevision(revision)
      }
      throw error
    }
  }

  private func validateTarget(_ targetURL: URL, managedRoot: URL) throws -> URL {
    let normalized = targetURL.standardizedFileURL
    let canonical = Self.canonicalURL(for: normalized)
    let managedPrefix = pathPrefix(for: managedRoot)
    guard canonical.path != managedRoot.path, canonical.path.hasPrefix(managedPrefix) else {
      throw ManagedWorktreeError.invalidTarget(canonical.path)
    }
    let repositoryPrefix = pathPrefix(for: repositoryRootURL)
    guard canonical.path != repositoryRootURL.path, !canonical.path.hasPrefix(repositoryPrefix)
    else {
      throw ManagedWorktreeError.invalidTarget(canonical.path)
    }
    guard !normalized.path.contains("\0") else {
      throw ManagedWorktreeError.invalidTarget(normalized.path)
    }
    return canonical
  }

  private func registeredWorktrees() throws -> [GitWorktreeRegistration] {
    let output = try runGit(
      ["worktree", "list", "--porcelain"],
      operation: "list worktrees"
    )
    var registrations: [GitWorktreeRegistration] = []
    var path: URL?
    var headRevision: String?
    var branch: String?
    var isDetached = false

    func appendCurrent() {
      guard let path else {
        return
      }
      registrations.append(
        GitWorktreeRegistration(
          path: Self.canonicalURL(for: path),
          headRevision: headRevision,
          branch: branch,
          isDetached: isDetached
        )
      )
    }

    for line in output.text.split(whereSeparator: \.isNewline).map(String.init) {
      if line.hasPrefix("worktree ") {
        appendCurrent()
        path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)), isDirectory: true)
        headRevision = nil
        branch = nil
        isDetached = false
      } else if line.hasPrefix("HEAD ") {
        headRevision = String(line.dropFirst("HEAD ".count))
      } else if line.hasPrefix("branch refs/heads/") {
        branch = String(line.dropFirst("branch refs/heads/".count))
      } else if line == "detached" {
        isDetached = true
      }
    }
    appendCurrent()
    return registrations
  }

  private func pathPrefix(for rootURL: URL) -> String {
    rootURL.path == "/" ? "/" : rootURL.path + "/"
  }

  private func runGit(
    _ arguments: [String],
    operation: String,
    allowedExitStatuses: Set<Int32> = [0]
  ) throws -> GitCommandOutput {
    guard fileManager.isExecutableFile(atPath: gitURL.path) else {
      throw ManagedWorktreeError.git(.gitUnavailable)
    }

    let process = Process()
    let pipe = Pipe()
    process.executableURL = gitURL
    process.arguments = arguments
    process.currentDirectoryURL = repositoryRootURL
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["LC_ALL": "C", "LANG": "C"],
      uniquingKeysWith: { _, new in new }
    )
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
    } catch {
      throw ManagedWorktreeError.commandFailed(
        operation: operation,
        status: -1,
        message: error.localizedDescription
      )
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard allowedExitStatuses.contains(process.terminationStatus) else {
      throw ManagedWorktreeError.commandFailed(
        operation: operation,
        status: process.terminationStatus,
        message: String(decoding: data, as: UTF8.self)
      )
    }
    return GitCommandOutput(status: process.terminationStatus, data: data)
  }

  private static func canonicalURL(for url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
  }

  private struct GitCommandOutput {
    let status: Int32
    let data: Data

    var text: String {
      String(decoding: data, as: UTF8.self)
    }
  }

  private struct GitWorktreeRegistration {
    let path: URL
    let headRevision: String?
    let branch: String?
    let isDetached: Bool
  }
}

@MainActor
final class ProjectWorktreeCoordinator: ObservableObject {
  @Published private(set) var worktrees: [ManagedWorktree] = []
  @Published private(set) var lastErrorMessage: String?

  let store: ManagedWorktreeStore
  let managementRootURL: URL?

  private let fileManager: FileManager
  private var services: [UUID: ProjectWorktreeService] = [:]

  init(
    store: ManagedWorktreeStore,
    managementRootURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.store = store
    self.managementRootURL =
      managementRootURL
      ?? store.fileURL?.deletingLastPathComponent().appendingPathComponent(
        "worktrees",
        isDirectory: true
      )
    self.fileManager = fileManager
  }

  static func makeDefault(
    for profile: ClairRuntimeProfile,
    fileManager: FileManager = .default
  ) -> ProjectWorktreeCoordinator {
    ProjectWorktreeCoordinator(
      store: ManagedWorktreeStore.makeDefault(for: profile, fileManager: fileManager),
      fileManager: fileManager
    )
  }

  func worktrees(for projectID: UUID) -> [ManagedWorktree] {
    worktrees.filter { $0.projectID == projectID }
  }

  func availableWorktree(project: Project, id: WorktreeID) -> ManagedWorktree? {
    do {
      let worktree = try service(for: project).inspect(id)
      guard worktree.state == .available else {
        lastErrorMessage =
          "Managed worktree (id.uuidString) is not available for agent launch."
        return nil
      }
      return worktree
    } catch {
      lastErrorMessage = error.localizedDescription
      return nil
    }
  }

  func refresh(project: Project) {
    do {
      let next = try service(for: project).list()
      worktrees = worktrees.filter { $0.projectID != project.id } + next
      worktrees.sort { $0.createdAt < $1.createdAt }
      lastErrorMessage = nil
    } catch ManagedWorktreeError.notRepository {
      worktrees.removeAll { $0.projectID == project.id }
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func create(
    project: Project,
    branch: String,
    baseRevision: String = "HEAD",
    targetName: String
  ) -> ManagedWorktree? {
    do {
      let worktree = try service(for: project).create(
        branch: branch,
        baseRevision: baseRevision,
        targetName: targetName
      )
      refresh(project: project)
      return worktree
    } catch {
      lastErrorMessage = error.localizedDescription
      return nil
    }
  }

  func prepareCleanup(
    project: Project,
    worktreeID: WorktreeID,
    activeSessionIDs: Set<UUID>,
    expectedRootURL: URL? = nil
  ) -> ManagedWorktreeCleanupPlan? {
    do {
      let plan = try service(for: project).prepareCleanup(
        worktreeID,
        activeSessionIDs: activeSessionIDs,
        expectedRootURL: expectedRootURL
      )
      lastErrorMessage = nil
      return plan
    } catch {
      lastErrorMessage = error.localizedDescription
      return nil
    }
  }

  @discardableResult
  func confirmCleanup(
    project: Project,
    plan: ManagedWorktreeCleanupPlan,
    activeSessionIDs: Set<UUID>
  ) -> Bool {
    do {
      try service(for: project).confirmCleanup(
        plan,
        activeSessionIDs: activeSessionIDs
      )
      refresh(project: project)
      return true
    } catch {
      lastErrorMessage = error.localizedDescription
      return false
    }
  }

  func clearError() {
    lastErrorMessage = nil
  }

  private func service(for project: Project) throws -> ProjectWorktreeService {
    guard let managementRootURL else {
      throw ManagedWorktreeError.store(.unavailable)
    }
    if let service = services[project.id], service.repositoryRootURL.path == project.rootURL.path {
      return service
    }

    let projectManagementRoot = managementRootURL.appendingPathComponent(
      project.id.uuidString,
      isDirectory: true
    )
    let service = ProjectWorktreeService(
      projectID: project.id,
      repositoryRootURL: project.rootURL,
      managementRootURL: projectManagementRoot,
      store: store,
      fileManager: fileManager
    )
    services[project.id] = service
    return service
  }
}
