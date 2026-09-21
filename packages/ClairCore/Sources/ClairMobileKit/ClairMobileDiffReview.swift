import ClairShared
import ClairTransport
import ClairWorkspace
import Foundation

/// Errors surfaced by the native diff review surface. This layer never
/// mutates the working tree: every case reflects either a client-local
/// precondition (nothing attached, an unknown file) or an opaque transport
/// failure, mirroring `ClairMobileConversationError`'s shape for N05
/// command dispatch.
public enum ClairMobileDiffReviewError: Error, Equatable, LocalizedError, Sendable {
  case notAttached
  case invalidScope(ResourceScope)
  case fileNotFound(ClairWorkspacePath)
  case transportFailed

  public var errorDescription: String? {
    switch self {
    case .notAttached:
      "No Project or Worktree is attached for review."
    case .invalidScope(let scope):
      "Diff review requires a Project or Worktree scope, not a session scope: \(scope)."
    case .fileNotFound(let path):
      "The file is not in the current changed-file list: \(path)."
    case .transportFailed:
      "The changed-file list or diff could not be retrieved from the host."
    }
  }
}

/// Local, transport-neutral fold of H07's read-only changed-file/diff
/// snapshots for one Project/Worktree scope, plus a pure client-only
/// hunk-navigation cursor. Applying a fresh snapshot or moving between hunks
/// is ordinary state bookkeeping: nothing here issues a Git command or
/// touches a working tree, and nothing here can, since it only ever consumes
/// already-computed `ClairChangedFileSummary`/`ClairGitDiff` values.
public struct ClairMobileDiffReviewState: Equatable, Sendable {
  public private(set) var scope: ResourceScope?
  public private(set) var changedFiles: ClairChangedFileSummary?
  public private(set) var selectedPath: ClairWorkspacePath?
  public private(set) var diff: ClairGitDiff?
  public private(set) var hunkIndex: Int?

  public init() {}

  public var files: [ClairChangedFile] { changedFiles?.files ?? [] }
  public var hunks: [ClairGitDiffHunk] { diff?.hunks ?? [] }

  public var currentHunk: ClairGitDiffHunk? {
    guard let hunkIndex, hunks.indices.contains(hunkIndex) else { return nil }
    return hunks[hunkIndex]
  }

  /// True once a diff has been loaded for a binary file. `diff.text` is `nil`
  /// for a binary diff; the client must label this explicitly rather than
  /// rendering nothing (which would look like an empty text diff) or
  /// attempting to decode the binary content as text.
  public var isBinary: Bool { diff?.kind == .binary }

  /// True when H07 bounded the diff (large or truncated Git output). The
  /// client must surface this explicitly instead of silently presenting a
  /// partial diff as if it were the complete one.
  public var isTruncated: Bool { diff?.isTruncated ?? false }

  /// True when the changed-file list itself was bounded by H07's limits, so
  /// the file picker is known to be an incomplete view of the repository.
  public var isChangedFileListTruncated: Bool { changedFiles?.isTruncated ?? false }

  public mutating func reset(scope: ResourceScope?) {
    self.scope = scope
    changedFiles = nil
    selectedPath = nil
    diff = nil
    hunkIndex = nil
  }

  mutating func applyChangedFiles(_ summary: ClairChangedFileSummary) {
    changedFiles = summary
    if let selectedPath, !summary.files.contains(where: { $0.path == selectedPath }) {
      // The previously selected file dropped out of the changed-file list
      // (e.g. it was reverted). Its stale diff must not linger as if it were
      // still current.
      self.selectedPath = nil
      diff = nil
      hunkIndex = nil
    }
  }

  mutating func applyDiff(_ diff: ClairGitDiff, path: ClairWorkspacePath) {
    selectedPath = path
    self.diff = diff
    hunkIndex = diff.hunks.isEmpty ? nil : 0
  }

  /// Selects a specific hunk by its H07-issued identity. A stale or unknown
  /// id (for example a duplicate tap that arrives after the diff already
  /// changed) is safely ignored instead of corrupting the cursor.
  @discardableResult
  public mutating func selectHunk(id: String) -> Bool {
    guard let index = hunks.firstIndex(where: { $0.id == id }) else { return false }
    hunkIndex = index
    return true
  }

  /// Moves to the next hunk, clamped at the last one. Calling this
  /// repeatedly past the end (duplicate/rapid-repeat input) is a safe no-op
  /// once clamped, matching N05's duplicate-tap-safety precedent.
  @discardableResult
  public mutating func moveToNextHunk() -> Bool {
    guard !hunks.isEmpty else {
      let changed = hunkIndex != nil
      hunkIndex = nil
      return changed
    }
    let current = hunkIndex ?? -1
    let next = min(current + 1, hunks.count - 1)
    let changed = next != hunkIndex
    hunkIndex = next
    return changed
  }

  /// Moves to the previous hunk, clamped at the first one. Safe against
  /// duplicate/rapid-repeat input for the same reason as `moveToNextHunk`.
  @discardableResult
  public mutating func moveToPreviousHunk() -> Bool {
    guard !hunks.isEmpty else {
      let changed = hunkIndex != nil
      hunkIndex = nil
      return changed
    }
    let current = hunkIndex ?? hunks.count
    let previous = max(current - 1, 0)
    let changed = previous != hunkIndex
    hunkIndex = previous
    return changed
  }

  /// A deterministic, display-only seed for a review follow-up message. The
  /// diff review surface never dispatches a command itself: sending the
  /// follow-up reuses N05's existing
  /// `ClairMobileConversationController.submitPrompt`, so this stays a
  /// pure string helper with no transport side effect and no new mutating
  /// pathway.
  public var followUpPromptSeed: String? {
    guard let selectedPath else { return nil }
    guard let currentHunk else {
      return "Regarding \(selectedPath.rawValue): "
    }
    return "Regarding \(selectedPath.rawValue) \(currentHunk.header): "
  }
}

/// Transport-neutral seam for H07's read-only changed-file/diff data,
/// mirroring `ClairMobileAgentTransport`'s role for H06 commands. The
/// production Network.framework/TLS adapter is a later integration boundary;
/// this protocol only depends on `ClairWorkspace`'s Codable result types.
/// No conforming implementation may stage, commit, or otherwise mutate the
/// Git repository or working tree -- it may only return data already
/// computed by H07's read-only `ClairWorkspaceRuntime`.
public protocol ClairMobileWorkspaceReading: Sendable {
  func changedFileSummary(
    for scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairChangedFileSummary

  func diff(
    for scope: ResourceScope,
    path: ClairWorkspacePath,
    basis: ClairGitDiffBasis,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairGitDiff
}

/// Explicit "not yet wired" boundary, mirroring
/// `ClairMobileUnavailableAgentTransport`. The native app can construct a
/// diff review controller before the real transport exists; every read fails
/// closed instead of silently returning stale or fabricated data.
public struct ClairMobileUnavailableWorkspaceReading: ClairMobileWorkspaceReading {
  public init() {}

  public func changedFileSummary(
    for scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairChangedFileSummary {
    throw ClairMobileTransportBoundaryError.unavailable
  }

  public func diff(
    for scope: ResourceScope,
    path: ClairWorkspacePath,
    basis: ClairGitDiffBasis,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairGitDiff {
    throw ClairMobileTransportBoundaryError.unavailable
  }
}

/// Actor-owned client-side diff review surface. It is display-only: it folds
/// H07 read-only Git status/diff snapshots and tracks a pure hunk-navigation
/// cursor. It never issues a write, stage, or commit, and it is the single
/// owner of in-flight load de-duplication so a duplicated or rapid-repeat tap
/// can never fan out into two concurrent reads for the same key.
public actor ClairMobileDiffReviewController {
  /// Everything needed to address one Project/Worktree scope on a live
  /// authenticated connection. Rejecting a session scope keeps this
  /// controller's identity model aligned with H07, which reports Git status
  /// per Project/Worktree, not per agent session.
  public struct Attachment: Equatable, Sendable {
    public let scope: ResourceScope
    public let connection: ClairAuthenticatedConnection

    public init(scope: ResourceScope, connection: ClairAuthenticatedConnection) throws {
      guard !scope.isSessionScope else {
        throw ClairMobileDiffReviewError.invalidScope(scope)
      }
      self.scope = scope
      self.connection = connection
    }
  }

  private let reader: any ClairMobileWorkspaceReading
  private var attachment: Attachment?
  private var stateValue = ClairMobileDiffReviewState()
  private var inFlightChangedFiles: Task<ClairChangedFileSummary, Error>?
  private var inFlightDiffs: [String: Task<ClairGitDiff, Error>] = [:]

  public init(
    reader: any ClairMobileWorkspaceReading = ClairMobileUnavailableWorkspaceReading()
  ) {
    self.reader = reader
  }

  public var state: ClairMobileDiffReviewState { stateValue }
  public var isAttached: Bool { attachment != nil }

  /// Attaches (or re-attaches) to a Project/Worktree scope and resets to a
  /// clean state. Re-attaching after a destination change is the expected
  /// shape: no stale changed-file/diff data from a previous scope leaks into
  /// the new one.
  public func attach(_ attachment: Attachment) {
    self.attachment = attachment
    inFlightChangedFiles = nil
    inFlightDiffs.removeAll()
    stateValue.reset(scope: attachment.scope)
  }

  public func detach() {
    attachment = nil
    inFlightChangedFiles = nil
    inFlightDiffs.removeAll()
  }

  /// Loads (or joins an already in-flight load of) the changed-file list. A
  /// duplicate/rapid-repeat refresh call joins the single in-flight request
  /// instead of racing two reads.
  @discardableResult
  public func refreshChangedFiles() async throws -> ClairChangedFileSummary {
    guard let attachment else { throw ClairMobileDiffReviewError.notAttached }
    if let existing = inFlightChangedFiles {
      return try await existing.value
    }
    let task = Task { [reader] () async throws -> ClairChangedFileSummary in
      do {
        return try await reader.changedFileSummary(
          for: attachment.scope,
          on: attachment.connection
        )
      } catch {
        throw ClairMobileDiffReviewError.transportFailed
      }
    }
    inFlightChangedFiles = task
    defer { inFlightChangedFiles = nil }
    let summary = try await task.value
    stateValue.applyChangedFiles(summary)
    return summary
  }

  /// Loads (or joins an in-flight load of) the diff for one changed file and
  /// moves the hunk cursor to its first hunk (or clears it for a binary or
  /// otherwise hunk-less diff). A duplicate/rapid-repeat selection of the
  /// same file+basis joins the single in-flight request instead of racing
  /// two loads that could otherwise apply out of order.
  @discardableResult
  public func selectFile(
    _ path: ClairWorkspacePath,
    basis: ClairGitDiffBasis = .workingTree
  ) async throws -> ClairGitDiff {
    guard let attachment else { throw ClairMobileDiffReviewError.notAttached }
    if let summary = stateValue.changedFiles,
      !summary.files.contains(where: { $0.path == path })
    {
      throw ClairMobileDiffReviewError.fileNotFound(path)
    }
    let key = "\(basis.rawValue):\(path.rawValue)"
    if let existing = inFlightDiffs[key] {
      return try await existing.value
    }
    let task = Task { [reader] () async throws -> ClairGitDiff in
      do {
        return try await reader.diff(
          for: attachment.scope,
          path: path,
          basis: basis,
          on: attachment.connection
        )
      } catch {
        throw ClairMobileDiffReviewError.transportFailed
      }
    }
    inFlightDiffs[key] = task
    defer { inFlightDiffs[key] = nil }
    let diff = try await task.value
    stateValue.applyDiff(diff, path: path)
    return diff
  }

  /// Pure, synchronous hunk-cursor navigation. Never touches the transport,
  /// so it cannot itself trigger a read, let alone a mutation.
  @discardableResult
  public func selectHunk(id: String) -> Bool { stateValue.selectHunk(id: id) }

  @discardableResult
  public func nextHunk() -> Bool { stateValue.moveToNextHunk() }

  @discardableResult
  public func previousHunk() -> Bool { stateValue.moveToPreviousHunk() }
}
