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
    case .conflicted:
      "Conflicted"
    case .untracked:
      "Untracked"
    }
  }
}

enum ProjectGitDiffBasis: String, CaseIterable, Codable, Equatable, Sendable {
  case workingTree
  case staged

  var displayName: String {
    switch self {
    case .workingTree:
      "Working tree"
    case .staged:
      "Staged"
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

enum ProjectGitError: Error, Equatable, LocalizedError, Sendable {
  case gitUnavailable
  case notRepository(path: String)
  case repositoryOutsideProject(projectPath: String, repositoryPath: String)
  case invalidPath(String)
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
    return GitCommandOutput(data: data)
  }

  private struct GitCommandOutput {
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
