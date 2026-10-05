import Foundation

/// `debug.status`: the active Project's debug session as the Run and Debug panel shows it. The registry
/// only validates the call; the GUI fills this from its live DAP session (like `editor.diagnostics`).
public struct WorkbenchDebugStatus: Sendable, Codable, Equatable {
  public struct Thread: Sendable, Codable, Equatable {
    public let id: Int
    public let name: String
    public init(id: Int, name: String) { self.id = id; self.name = name }
  }
  /// `line` is 1-based, as debug.breakpoint takes it.
  public struct Frame: Sendable, Codable, Equatable {
    public let id: Int
    public let name: String
    public let path: String?
    public let line: Int
    public init(id: Int, name: String, path: String?, line: Int) { self.id = id; self.name = name; self.path = path; self.line = line }
  }
  /// `id` is what debug.expandVariable takes; `depth` 0 is a frame's own scope.
  public struct Variable: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let value: String
    public let depth: Int
    public let expandable: Bool
    public init(id: String, name: String, value: String, depth: Int, expandable: Bool) {
      self.id = id; self.name = name; self.value = value; self.depth = depth; self.expandable = expandable
    }
  }
  public struct Breakpoint: Sendable, Codable, Equatable {
    public let path: String
    public let line: Int
    /// nil until the adapter has answered for it.
    public let verified: Bool?
    public let message: String?
    public init(path: String, line: Int, verified: Bool?, message: String?) {
      self.path = path; self.line = line; self.verified = verified; self.message = message
    }
  }

  /// `idle` / `starting` / `configuring` / `running` / `stopped` / `ended` / `failed` (the `debugPhase` values).
  public var phase: String
  public var error: String? = nil
  public var stoppedReason: String? = nil
  public var threads: [Thread] = []
  public var selectedThread: Int? = nil
  public var frames: [Frame] = []
  public var selectedFrame: Int? = nil
  public var variables: [Variable] = []
  public var breakpoints: [Breakpoint] = []
  /// Last lines of the debug console.
  public var console: [String] = []

  public init(phase: String) { self.phase = phase }
}
