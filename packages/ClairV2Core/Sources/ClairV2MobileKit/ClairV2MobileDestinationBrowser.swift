import ClairV2Shared
import ClairV2Workspace
import Foundation

/// A read-only session item supplied by the authenticated host catalog.
///
/// N04 intentionally does not start, stop, or subscribe to a session. Its
/// browser only retains the exact typed scope needed by later transport-backed
/// session features.
public struct ClairMobileSessionCatalogEntry: Codable, Equatable, Identifiable, Sendable {
  public let scope: ResourceScope
  public let displayName: String
  public let status: String

  public var id: SessionID { scope.sessionID! }

  public init(scope: ResourceScope, displayName: String, status: String) throws {
    guard scope.isSessionScope else {
      throw ClairMobileDestinationBrowserError.invalidSessionScope(scope)
    }
    self.scope = scope
    self.displayName = displayName
    self.status = status
  }
}

/// A destination which may be restored after the app returns to the foreground.
/// The stored value contains only typed identifiers; it never stores a root URL,
/// session transcript, credential, or transport handle.
public struct ClairMobileRecentDestination: Codable, Equatable, Sendable {
  public let scope: ResourceScope

  public init(scope: ResourceScope) {
    self.scope = scope
  }
}

public enum ClairMobileDestinationBrowserError: Error, Equatable, LocalizedError, Sendable {
  case projectNotFound(ProjectID)
  case worktreeNotFound(projectID: ProjectID, worktreeID: WorktreeID)
  case sessionNotFound(SessionID)
  case invalidSessionScope(ResourceScope)
  case projectRootUnavailable(ProjectID, ClairV2WorkspaceRootState)
  case worktreeRootUnavailable(WorktreeID, ClairV2WorkspaceRootState)
  case staleDestination(ResourceScope)

  public var errorDescription: String? {
    switch self {
    case .projectNotFound(let projectID):
      "The selected Project is no longer available: \(projectID)."
    case .worktreeNotFound(let projectID, let worktreeID):
      "The selected Worktree \(worktreeID) does not belong to Project \(projectID)."
    case .sessionNotFound(let sessionID):
      "The selected session is no longer available: \(sessionID)."
    case .invalidSessionScope:
      "A session browser entry must contain an exact session scope."
    case .projectRootUnavailable(let projectID, let state):
      "The Project root \(projectID) is unavailable (\(state.rawValue))."
    case .worktreeRootUnavailable(let worktreeID, let state):
      "The Worktree root \(worktreeID) is unavailable (\(state.rawValue))."
    case .staleDestination:
      "The recent destination is no longer available on this host."
    }
  }
}

/// Local, transport-neutral state for the native Project / Worktree / session
/// browser. A host snapshot is the only input. This makes selection,
/// persistence, and stale-state handling deterministic and guarantees that UI
/// navigation itself cannot send a transport operation.
public struct ClairMobileDestinationBrowserState: Equatable, Sendable {
  public private(set) var catalog: ClairV2WorkspaceCatalog
  public private(set) var sessions: [ClairMobileSessionCatalogEntry]
  public private(set) var selectedScope: ResourceScope?
  public private(set) var recentDestination: ClairMobileRecentDestination?
  public private(set) var lastError: ClairMobileDestinationBrowserError?

  public init(
    catalog: ClairV2WorkspaceCatalog = .init(projects: []),
    sessions: [ClairMobileSessionCatalogEntry] = [],
    recentDestination: ClairMobileRecentDestination? = nil
  ) {
    self.catalog = catalog
    self.sessions = []
    self.selectedScope = nil
    self.recentDestination = nil
    self.lastError = nil
    replaceSnapshot(catalog: catalog, sessions: sessions)
    if let recentDestination {
      restoreRecentDestination(recentDestination)
    }
  }

  public var projects: [ClairV2ProjectCatalogEntry] {
    catalog.projects.sorted { $0.id.rawValue < $1.id.rawValue }
  }

  public func worktrees(for projectID: ProjectID) -> [ClairV2WorktreeCatalogEntry] {
    project(projectID)?.worktrees.sorted { $0.id.rawValue < $1.id.rawValue } ?? []
  }

  public func sessions(for scope: ResourceScope) -> [ClairMobileSessionCatalogEntry] {
    sessions.filter { entry in
      entry.scope.projectID == scope.projectID
        && (scope.worktreeID == nil || entry.scope.worktreeID == scope.worktreeID)
    }
  }

  public func sessions(forProjectID projectID: ProjectID) -> [ClairMobileSessionCatalogEntry] {
    sessions.filter { $0.scope.projectID == projectID }
  }

  public mutating func replaceSnapshot(
    catalog: ClairV2WorkspaceCatalog,
    sessions: [ClairMobileSessionCatalogEntry]
  ) {
    self.catalog = catalog
    self.sessions = sessions.filter { isValidSessionScope($0.scope) }
      .sorted { $0.id.rawValue < $1.id.rawValue }
    selectedScope = selectedScope.flatMap { isSelectable($0) ? $0 : nil }
    recentDestination = recentDestination.flatMap {
      isSelectable($0.scope) ? $0 : nil
    }
    lastError = nil
  }

  @discardableResult
  public mutating func selectProject(_ projectID: ProjectID) -> Bool {
    guard let scope = try? ResourceScope(projectID: projectID) else {
      lastError = .projectNotFound(projectID)
      return false
    }
    return select(scope)
  }

  @discardableResult
  public mutating func selectWorktree(
    projectID: ProjectID,
    worktreeID: WorktreeID
  ) -> Bool {
    guard let scope = try? ResourceScope(projectID: projectID, worktreeID: worktreeID) else {
      lastError = .worktreeNotFound(projectID: projectID, worktreeID: worktreeID)
      return false
    }
    return select(scope)
  }

  @discardableResult
  public mutating func selectSession(_ sessionID: SessionID) -> Bool {
    guard let entry = sessions.first(where: { $0.id == sessionID }) else {
      lastError = .sessionNotFound(sessionID)
      return false
    }
    return select(entry.scope)
  }

  @discardableResult
  public mutating func restoreRecentDestination(_ recent: ClairMobileRecentDestination) -> Bool {
    guard isSelectable(recent.scope) else {
      recentDestination = nil
      lastError = .staleDestination(recent.scope)
      return false
    }
    selectedScope = recent.scope
    recentDestination = recent
    lastError = nil
    return true
  }

  public mutating func clearRecentDestination() {
    recentDestination = nil
  }

  private mutating func select(_ scope: ResourceScope) -> Bool {
    do {
      try validateSelection(scope)
      selectedScope = scope
      recentDestination = ClairMobileRecentDestination(scope: scope)
      lastError = nil
      return true
    } catch let error as ClairMobileDestinationBrowserError {
      lastError = error
      return false
    } catch {
      lastError = .staleDestination(scope)
      return false
    }
  }

  private func validateSelection(_ scope: ResourceScope) throws {
    guard let project = project(scope.projectID) else {
      throw ClairMobileDestinationBrowserError.projectNotFound(scope.projectID)
    }
    guard project.state == .available else {
      throw ClairMobileDestinationBrowserError.projectRootUnavailable(project.id, project.state)
    }
    if let worktreeID = scope.worktreeID {
      guard let worktree = project.worktrees.first(where: { $0.id == worktreeID }) else {
        throw ClairMobileDestinationBrowserError.worktreeNotFound(
          projectID: project.id,
          worktreeID: worktreeID
        )
      }
      guard worktree.projectID == project.id else {
        throw ClairMobileDestinationBrowserError.worktreeNotFound(
          projectID: project.id,
          worktreeID: worktreeID
        )
      }
      guard worktree.state == .available else {
        throw ClairMobileDestinationBrowserError.worktreeRootUnavailable(
          worktree.id, worktree.state)
      }
    }
    if let sessionID = scope.sessionID,
      !sessions.contains(where: { $0.id == sessionID && $0.scope == scope })
    {
      throw ClairMobileDestinationBrowserError.sessionNotFound(sessionID)
    }
  }

  private func project(_ projectID: ProjectID) -> ClairV2ProjectCatalogEntry? {
    catalog.projects.first(where: { $0.id == projectID })
  }

  private func isValidSessionScope(_ scope: ResourceScope) -> Bool {
    guard scope.isSessionScope else { return false }
    do {
      try validateCatalogRoot(scope)
      return true
    } catch {
      return false
    }
  }

  private func isSelectable(_ scope: ResourceScope) -> Bool {
    do {
      try validateSelection(scope)
      return true
    } catch {
      return false
    }
  }

  private func validateCatalogRoot(_ scope: ResourceScope) throws {
    guard let project = project(scope.projectID), project.state == .available else {
      throw ClairMobileDestinationBrowserError.staleDestination(scope)
    }
    if let worktreeID = scope.worktreeID {
      guard let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
        worktree.projectID == project.id,
        worktree.state == .available
      else {
        throw ClairMobileDestinationBrowserError.staleDestination(scope)
      }
    }
  }
}
