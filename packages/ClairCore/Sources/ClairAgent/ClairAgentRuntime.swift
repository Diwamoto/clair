import ClairShared
import ClairTerminal
import ClairWorkspace
import Dispatch
import Foundation

#if os(macOS)
  import Darwin
#endif

public enum ClairAgentError: Error, Equatable, LocalizedError, Sendable {
  case invalidProviderID
  case invalidProviderVersion
  case invalidSessionIdentity
  case invalidLaunchLimits
  case invalidExecutableURL
  case missingExecutable(URL)
  case executableNotExecutable(URL)
  case invalidLaunchSpec
  case invalidEnvironment
  case credentialUnavailable
  case unsupportedPlatform
  case duplicateProvider(ClairProviderID)
  case providerNotFound(ClairProviderID)
  case providerIdentityMismatch(
    expected: ClairProviderIdentity,
    actual: ClairProviderIdentity
  )
  case providerUpgradeRequired(
    sessionID: SessionID,
    recorded: ClairProviderIdentity,
    requested: ClairProviderIdentity
  )
  case sessionNotFound(SessionID)
  case staleSession(SessionID)
  case duplicateLaunch(SessionID)
  case lifecycleConflict(SessionID, state: ClairAgentLifecycleState)
  case workingDirectoryMismatch(expected: URL, actual: URL)
  case workingDirectoryChanged(URL)
  case workingDirectoryDescriptorUnavailable(URL)
  case shutdownInProgress
  case workspace(ClairWorkspaceError)
  case processCreationFailed
  case processLaunchFailed
  case processAlreadyStarted
  case processNotRunning
  case signalFailed
  case processGroupUnavailable
  case processTerminationFailed
  case cleanupPending(SessionID)
  case invalidProcessExit

  public var errorDescription: String? {
    switch self {
    case .invalidProviderID:
      "The provider identity is invalid."
    case .invalidProviderVersion:
      "The provider version identity is invalid."
    case .invalidSessionIdentity:
      "The agent session identity is invalid."
    case .invalidLaunchLimits:
      "The agent launch limits are outside the supported bounds."
    case .invalidExecutableURL:
      "The provider executable URL is invalid."
    case .missingExecutable(let url):
      "The provider executable is missing: \(url.path)."
    case .executableNotExecutable(let url):
      "The provider executable is not executable: \(url.path)."
    case .invalidLaunchSpec:
      "The provider launch specification is invalid."
    case .invalidEnvironment:
      "The provider environment is invalid or exceeds its bounds."
    case .credentialUnavailable:
      "The provider credential source is unavailable."
    case .unsupportedPlatform:
      "The provider process runtime is available on macOS only."
    case .duplicateProvider(let providerID):
      "The provider is registered more than once: \(providerID)."
    case .providerNotFound(let providerID):
      "The provider is not registered: \(providerID)."
    case .providerIdentityMismatch(let expected, let actual):
      "The requested provider identity does not match the recorded provider (expected \(expected), got \(actual))."
    case .providerUpgradeRequired(let sessionID, let recorded, let requested):
      "Session \(sessionID) requires an explicit provider upgrade (recorded \(recorded), requested \(requested))."
    case .sessionNotFound(let sessionID):
      "The agent session is not registered: \(sessionID)."
    case .staleSession(let sessionID):
      "The agent session identity is stale: \(sessionID)."
    case .duplicateLaunch(let sessionID):
      "The agent session is already launching or running: \(sessionID)."
    case .lifecycleConflict(let sessionID, let state):
      "The agent session cannot accept this lifecycle operation in state \(state.rawValue): \(sessionID)."
    case .workingDirectoryMismatch(let expected, let actual):
      "The provider working directory does not match the validated workspace root (expected \(expected.path), got \(actual.path))."
    case .workingDirectoryChanged(let url):
      "The validated workspace directory changed before provider launch: \(url.path)."
    case .workingDirectoryDescriptorUnavailable(let url):
      "The validated workspace directory could not be held safely for provider launch: \(url.path)."
    case .shutdownInProgress:
      "The agent runtime is shutting down and is not accepting new lifecycle operations."
    case .workspace(let error):
      error.localizedDescription
    case .processCreationFailed:
      "The provider process could not be created."
    case .processLaunchFailed:
      "The provider process could not be launched."
    case .processAlreadyStarted:
      "The provider process was already started."
    case .processNotRunning:
      "The provider process is not running."
    case .signalFailed:
      "The provider process did not accept the requested signal."
    case .processGroupUnavailable:
      "The provider process group could not be claimed safely."
    case .processTerminationFailed:
      "The provider process could not be terminated safely."
    case .cleanupPending(let sessionID):
      "Cleanup is still pending for provider session \(sessionID)."
    case .invalidProcessExit:
      "The provider process returned an invalid exit result."
    }
  }
}

public struct ClairProviderID: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard Self.isValid(rawValue) else {
      throw ClairAgentError.invalidProviderID
    }
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  public var description: String { rawValue }

  public static let openCode = Self(unchecked: "opencode")

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }

  private static func isValid(_ rawValue: String) -> Bool {
    guard !rawValue.isEmpty, rawValue.utf8.count <= 128 else { return false }
    return rawValue.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E:
        true
      default:
        false
      }
    }
  }
}

public struct ClairProviderVersion: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty,
      rawValue.utf8.count <= 128,
      !rawValue.unicodeScalars.contains(where: { scalar in
        scalar.value < 0x20 || scalar.value == 0x7F
      }),
      rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      throw ClairAgentError.invalidProviderVersion
    }
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  public var description: String { rawValue }

  public static let unknown = Self(unchecked: "unknown")

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct ClairProviderIdentity: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let providerID: ClairProviderID
  public let version: ClairProviderVersion

  public init(providerID: ClairProviderID, version: ClairProviderVersion) {
    self.providerID = providerID
    self.version = version
  }

  public var providerVersion: ClairProviderVersion { version }

  public var description: String {
    "\(providerID.rawValue)@\(version.rawValue)"
  }
}

public struct ClairAgentTarget: Codable, Equatable, Hashable, Sendable {
  public let projectID: ProjectID
  public let worktreeID: WorktreeID?

  public init(projectID: ProjectID, worktreeID: WorktreeID? = nil) {
    self.projectID = projectID
    self.worktreeID = worktreeID
  }

  public var resourceScope: ResourceScope {
    // ResourceScope currently has no throwing validation for this shape.
    try! ResourceScope(projectID: projectID, worktreeID: worktreeID)
  }
}

public struct ClairAgentSessionIdentity: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let provider: ClairProviderIdentity
  public let scope: ResourceScope
  public let sessionID: SessionID

  public init(
    provider: ClairProviderIdentity,
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    sessionID: SessionID
  ) throws {
    self.provider = provider
    self.scope = try ResourceScope(projectID: projectID, worktreeID: worktreeID)
    self.sessionID = sessionID
  }

  public init(
    provider: ClairProviderIdentity,
    scope: ResourceScope,
    sessionID: SessionID
  ) throws {
    guard scope.sessionID == nil else {
      throw ClairAgentError.invalidSessionIdentity
    }
    self.provider = provider
    self.scope = scope
    self.sessionID = sessionID
  }

  public var projectID: ProjectID { scope.projectID }
  public var worktreeID: WorktreeID? { scope.worktreeID }
  public var target: ClairAgentTarget {
    ClairAgentTarget(projectID: projectID, worktreeID: worktreeID)
  }
  public var sessionScope: ResourceScope {
    try! ResourceScope(
      projectID: projectID,
      worktreeID: worktreeID,
      sessionID: sessionID
    )
  }

  public var description: String {
    let worktree = worktreeID.map { ", worktree=\($0)" } ?? ""
    return "provider=\(provider), project=\(projectID)\(worktree), session=\(sessionID)"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      provider: container.decode(ClairProviderIdentity.self, forKey: .provider),
      scope: container.decode(ResourceScope.self, forKey: .scope),
      sessionID: container.decode(SessionID.self, forKey: .sessionID)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(provider, forKey: .provider)
    try container.encode(scope, forKey: .scope)
    try container.encode(sessionID, forKey: .sessionID)
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case scope
    case sessionID
  }
}

public struct ClairAgentLaunchLimits: Codable, Equatable, Sendable {
  public static let hardMaximumArguments = 256
  public static let hardMaximumArgumentBytes = 16 * 1024
  public static let hardMaximumArgumentTotalBytes = 128 * 1024
  public static let hardMaximumEnvironmentEntries = 256
  public static let hardMaximumEnvironmentKeyBytes = 512
  public static let hardMaximumEnvironmentValueBytes = 64 * 1024
  public static let hardMaximumEnvironmentTotalBytes = 512 * 1024
  public static let hardMaximumOutputBytes = 16 * 1024 * 1024
  public static let hardMaximumExecutablePathBytes = 4 * 1024
  public static let hardMaximumWorkingDirectoryPathBytes = 4 * 1024
  public static let hardMaximumTerminationGracePeriod: TimeInterval = 30

  public let maximumArguments: Int
  public let maximumArgumentBytes: Int
  public let maximumArgumentTotalBytes: Int
  public let maximumEnvironmentEntries: Int
  public let maximumEnvironmentKeyBytes: Int
  public let maximumEnvironmentValueBytes: Int
  public let maximumEnvironmentTotalBytes: Int
  public let maximumOutputBytes: Int
  public let terminationGracePeriod: TimeInterval

  public static let standard = try! Self(
    maximumArguments: 64,
    maximumArgumentBytes: 8 * 1024,
    maximumArgumentTotalBytes: 32 * 1024,
    maximumEnvironmentEntries: 64,
    maximumEnvironmentKeyBytes: 256,
    maximumEnvironmentValueBytes: 8 * 1024,
    maximumEnvironmentTotalBytes: 64 * 1024,
    maximumOutputBytes: 1024 * 1024,
    terminationGracePeriod: 2
  )

  public init(
    maximumArguments: Int = Self.standard.maximumArguments,
    maximumArgumentBytes: Int = Self.standard.maximumArgumentBytes,
    maximumArgumentTotalBytes: Int = Self.standard.maximumArgumentTotalBytes,
    maximumEnvironmentEntries: Int = Self.standard.maximumEnvironmentEntries,
    maximumEnvironmentKeyBytes: Int = Self.standard.maximumEnvironmentKeyBytes,
    maximumEnvironmentValueBytes: Int = Self.standard.maximumEnvironmentValueBytes,
    maximumEnvironmentTotalBytes: Int = Self.standard.maximumEnvironmentTotalBytes,
    maximumOutputBytes: Int = Self.standard.maximumOutputBytes,
    terminationGracePeriod: TimeInterval = Self.standard.terminationGracePeriod
  ) throws {
    guard maximumArguments > 0,
      maximumArguments <= Self.hardMaximumArguments,
      maximumArgumentBytes > 0,
      maximumArgumentBytes <= Self.hardMaximumArgumentBytes,
      maximumArgumentTotalBytes >= maximumArgumentBytes,
      maximumArgumentTotalBytes <= Self.hardMaximumArgumentTotalBytes,
      maximumEnvironmentEntries > 0,
      maximumEnvironmentEntries <= Self.hardMaximumEnvironmentEntries,
      maximumEnvironmentKeyBytes > 0,
      maximumEnvironmentKeyBytes <= Self.hardMaximumEnvironmentKeyBytes,
      maximumEnvironmentValueBytes > 0,
      maximumEnvironmentValueBytes <= Self.hardMaximumEnvironmentValueBytes,
      maximumEnvironmentTotalBytes >= maximumEnvironmentValueBytes,
      maximumEnvironmentTotalBytes <= Self.hardMaximumEnvironmentTotalBytes,
      maximumOutputBytes >= 0,
      maximumOutputBytes <= Self.hardMaximumOutputBytes,
      terminationGracePeriod >= 0,
      terminationGracePeriod.isFinite,
      terminationGracePeriod <= Self.hardMaximumTerminationGracePeriod
    else {
      throw ClairAgentError.invalidLaunchLimits
    }

    self.maximumArguments = maximumArguments
    self.maximumArgumentBytes = maximumArgumentBytes
    self.maximumArgumentTotalBytes = maximumArgumentTotalBytes
    self.maximumEnvironmentEntries = maximumEnvironmentEntries
    self.maximumEnvironmentKeyBytes = maximumEnvironmentKeyBytes
    self.maximumEnvironmentValueBytes = maximumEnvironmentValueBytes
    self.maximumEnvironmentTotalBytes = maximumEnvironmentTotalBytes
    self.maximumOutputBytes = maximumOutputBytes
    self.terminationGracePeriod = terminationGracePeriod
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumArguments: container.decode(Int.self, forKey: .maximumArguments),
      maximumArgumentBytes: container.decode(Int.self, forKey: .maximumArgumentBytes),
      maximumArgumentTotalBytes: container.decode(Int.self, forKey: .maximumArgumentTotalBytes),
      maximumEnvironmentEntries: container.decode(Int.self, forKey: .maximumEnvironmentEntries),
      maximumEnvironmentKeyBytes: container.decode(Int.self, forKey: .maximumEnvironmentKeyBytes),
      maximumEnvironmentValueBytes: container.decode(
        Int.self,
        forKey: .maximumEnvironmentValueBytes
      ),
      maximumEnvironmentTotalBytes: container.decode(
        Int.self,
        forKey: .maximumEnvironmentTotalBytes
      ),
      maximumOutputBytes: container.decode(Int.self, forKey: .maximumOutputBytes),
      terminationGracePeriod: container.decode(TimeInterval.self, forKey: .terminationGracePeriod)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case maximumArguments
    case maximumArgumentBytes
    case maximumArgumentTotalBytes
    case maximumEnvironmentEntries
    case maximumEnvironmentKeyBytes
    case maximumEnvironmentValueBytes
    case maximumEnvironmentTotalBytes
    case maximumOutputBytes
    case terminationGracePeriod
  }
}

public enum ClairAgentOutputPolicy: Equatable, Sendable {
  case discard
  case bounded(maximumBytes: Int)
}

public struct ClairAgentLaunchSpec: Equatable, Sendable, CustomStringConvertible {
  public let executableURL: URL
  public let arguments: [String]
  public let environment: [String: String]
  public let workingDirectoryURL: URL
  public let outputPolicy: ClairAgentOutputPolicy
  let workingDirectoryDescriptor: Int32?
  let workingDirectoryDevice: UInt64?
  let workingDirectoryInode: UInt64?

  public init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectoryURL: URL,
    outputPolicy: ClairAgentOutputPolicy = .discard,
    limits: ClairAgentLaunchLimits = .standard
  ) throws {
    guard executableURL.isFileURL,
      executableURL.path.hasPrefix("/"),
      !executableURL.path.contains("\0"),
      executableURL.path.utf8.count <= ClairAgentLaunchLimits.hardMaximumExecutablePathBytes,
      workingDirectoryURL.isFileURL,
      workingDirectoryURL.path.hasPrefix("/"),
      !workingDirectoryURL.path.contains("\0"),
      workingDirectoryURL.path.utf8.count
        <= ClairAgentLaunchLimits.hardMaximumWorkingDirectoryPathBytes,
      arguments.count <= limits.maximumArguments
    else {
      throw ClairAgentError.invalidLaunchSpec
    }

    let argumentBytes = arguments.reduce(into: 0) { total, argument in
      let bytes = argument.utf8.count
      total = total > Int.max - bytes ? Int.max : total + bytes
    }
    guard argumentBytes <= limits.maximumArgumentTotalBytes,
      arguments.allSatisfy({ argument in
        argument.utf8.count <= limits.maximumArgumentBytes && !argument.contains("\0")
      })
    else {
      throw ClairAgentError.invalidLaunchSpec
    }

    guard environment.count <= limits.maximumEnvironmentEntries else {
      throw ClairAgentError.invalidEnvironment
    }
    let environmentBytes = environment.reduce(into: 0) { total, entry in
      // Include the key/value separator and terminating byte that the child
      // process receives, so the bound applies to the actual environment
      // representation rather than only to the visible text.
      let bytes = entry.key.utf8.count + entry.value.utf8.count + 2
      total = total > Int.max - bytes ? Int.max : total + bytes
    }
    guard environmentBytes <= limits.maximumEnvironmentTotalBytes,
      environment.allSatisfy({ key, value in
        !key.isEmpty
          && !key.contains("=")
          && !key.contains("\0")
          && !value.contains("\0")
          && !Self.containsControlCharacter(key)
          && !Self.containsControlCharacter(value)
          && key.utf8.count <= limits.maximumEnvironmentKeyBytes
          && value.utf8.count <= limits.maximumEnvironmentValueBytes
      })
    else {
      throw ClairAgentError.invalidEnvironment
    }

    switch outputPolicy {
    case .discard:
      break
    case .bounded(let maximumBytes):
      guard maximumBytes > 0, maximumBytes <= limits.maximumOutputBytes else {
        throw ClairAgentError.invalidLaunchSpec
      }
    }

    self.executableURL = executableURL.standardizedFileURL
    self.arguments = arguments
    self.environment = environment
    self.workingDirectoryURL = workingDirectoryURL.standardizedFileURL
    self.outputPolicy = outputPolicy
    self.workingDirectoryDescriptor = nil
    self.workingDirectoryDevice = nil
    self.workingDirectoryInode = nil
  }

  public var description: String {
    "executable=\(executableURL.lastPathComponent), arguments=\(arguments.count), environment_entries=\(environment.count), cwd=\(workingDirectoryURL.path), output=\(outputDescription)"
  }

  func attachingWorkingDirectoryDescriptor(
    _ descriptor: Int32,
    device: UInt64,
    inode: UInt64
  ) -> Self {
    Self(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      workingDirectoryURL: workingDirectoryURL,
      outputPolicy: outputPolicy,
      workingDirectoryDescriptor: descriptor,
      workingDirectoryDevice: device,
      workingDirectoryInode: inode
    )
  }

  private init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectoryURL: URL,
    outputPolicy: ClairAgentOutputPolicy,
    workingDirectoryDescriptor: Int32?,
    workingDirectoryDevice: UInt64?,
    workingDirectoryInode: UInt64?
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.workingDirectoryURL = workingDirectoryURL
    self.outputPolicy = outputPolicy
    self.workingDirectoryDescriptor = workingDirectoryDescriptor
    self.workingDirectoryDevice = workingDirectoryDevice
    self.workingDirectoryInode = workingDirectoryInode
  }

  /// Revalidates a launch spec against the runtime's limits. Providers receive
  /// the same limits while constructing a spec, but the runtime must not
  /// trust an adapter that built a spec with a wider limit set.
  func validate(limits: ClairAgentLaunchLimits) throws {
    guard executableURL.isFileURL,
      executableURL.path.hasPrefix("/"),
      !executableURL.path.contains("\0"),
      executableURL.path.utf8.count <= ClairAgentLaunchLimits.hardMaximumExecutablePathBytes,
      workingDirectoryURL.isFileURL,
      workingDirectoryURL.path.hasPrefix("/"),
      !workingDirectoryURL.path.contains("\0"),
      workingDirectoryURL.path.utf8.count
        <= ClairAgentLaunchLimits.hardMaximumWorkingDirectoryPathBytes,
      arguments.count <= limits.maximumArguments
    else {
      throw ClairAgentError.invalidLaunchSpec
    }

    let argumentBytes = arguments.reduce(into: 0) { total, argument in
      let bytes = argument.utf8.count
      total = Self.saturatingAdd(total, bytes)
    }
    guard argumentBytes <= limits.maximumArgumentTotalBytes,
      arguments.allSatisfy({ argument in
        argument.utf8.count <= limits.maximumArgumentBytes && !argument.contains("\0")
      })
    else {
      throw ClairAgentError.invalidLaunchSpec
    }

    guard environment.count <= limits.maximumEnvironmentEntries else {
      throw ClairAgentError.invalidEnvironment
    }
    let environmentBytes = environment.reduce(into: 0) { total, entry in
      let bytes = Self.saturatingAdd(
        Self.saturatingAdd(entry.key.utf8.count, entry.value.utf8.count),
        2
      )
      total = Self.saturatingAdd(total, bytes)
    }
    guard environmentBytes <= limits.maximumEnvironmentTotalBytes,
      environment.allSatisfy({ key, value in
        !key.isEmpty
          && !key.contains("=")
          && !key.contains("\0")
          && !value.contains("\0")
          && !Self.containsControlCharacter(key)
          && !Self.containsControlCharacter(value)
          && key.utf8.count <= limits.maximumEnvironmentKeyBytes
          && value.utf8.count <= limits.maximumEnvironmentValueBytes
      })
    else {
      throw ClairAgentError.invalidEnvironment
    }

    switch outputPolicy {
    case .discard:
      break
    case .bounded(let maximumBytes):
      guard maximumBytes > 0, maximumBytes <= limits.maximumOutputBytes else {
        throw ClairAgentError.invalidLaunchSpec
      }
    }
  }

  private var outputDescription: String {
    switch outputPolicy {
    case .discard:
      "discard"
    case .bounded(let maximumBytes):
      "bounded(\(maximumBytes))"
    }
  }

  private static func containsControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      scalar.value < 0x20 || scalar.value == 0x7F
    }
  }

  private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    lhs > Int.max - rhs ? Int.max : lhs + rhs
  }
}

public struct ClairAgentProcessExit: Equatable, Sendable {
  public let status: Int32?
  public let signal: Int32?
  public let wasRequestedByClair: Bool
  public let wasForceTerminated: Bool
  public let didLaunch: Bool

  public init(
    status: Int32? = nil,
    signal: Int32? = nil,
    wasRequestedByClair: Bool = false,
    wasForceTerminated: Bool = false,
    didLaunch: Bool = true
  ) {
    self.status = status
    self.signal = signal
    self.wasRequestedByClair = wasRequestedByClair
    self.wasForceTerminated = wasForceTerminated
    self.didLaunch = didLaunch
  }
}

public enum ClairAgentProcessStartOutcome: Equatable, Sendable {
  case running
  case terminated(ClairAgentProcessExit)
}

/// Raw provider bytes are deliberately kept outside the provider-independent
/// event model. H05 owns decoding and normalization; H04 only applies the
/// configured byte bound.
public struct ClairAgentRawOutput: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  public let isTruncated: Bool

  public init(stdout: Data = Data(), stderr: Data = Data(), isTruncated: Bool = false) {
    self.stdout = stdout
    self.stderr = stderr
    self.isTruncated = isTruncated
  }
}

public enum ClairAgentSignal: Int32, Codable, Equatable, Sendable {
  case hangup = 1
  case interrupt = 2
  case terminate = 15
}

public protocol ClairAgentProcess: AnyObject, Sendable {
  var processID: Int32 { get }
  var isRunning: Bool { get }
  var hasPendingCleanup: Bool { get }

  func start() throws -> ClairAgentProcessStartOutcome
  func send(signal: ClairAgentSignal) async throws
  func terminate(gracePeriod: TimeInterval) async throws -> ClairAgentProcessExit
  func forceTerminate() async throws -> ClairAgentProcessExit
  func rawOutput() async -> ClairAgentRawOutput
}

public typealias ClairAgentTerminationHandler = @Sendable (ClairAgentProcessExit) -> Void

public protocol ClairAgentProcessFactory: Sendable {
  func makeProcess(
    spec: ClairAgentLaunchSpec,
    onTermination: @escaping ClairAgentTerminationHandler
  ) throws -> any ClairAgentProcess
}

public protocol ClairAgentCredentialSource: Sendable {
  func environment(for providerID: ClairProviderID) throws -> [String: String]
}

public struct ClairNoCredentials: ClairAgentCredentialSource {
  public init() {}

  public func environment(for providerID: ClairProviderID) throws -> [String: String] {
    [:]
  }
}

public protocol ClairAgentProviderAdapter: Sendable {
  var identity: ClairProviderIdentity { get }

  func makeLaunchSpec(
    for session: ClairAgentSessionIdentity,
    workingDirectoryURL: URL,
    limits: ClairAgentLaunchLimits
  ) throws -> ClairAgentLaunchSpec

  func makeProcess(
    spec: ClairAgentLaunchSpec,
    onTermination: @escaping ClairAgentTerminationHandler
  ) throws -> any ClairAgentProcess
}

public struct ClairOpenCodeProvider: ClairAgentProviderAdapter, CustomStringConvertible {
  public let identity: ClairProviderIdentity

  private let executableURL: URL
  private let arguments: [String]
  private let environment: [String: String]
  private let outputPolicy: ClairAgentOutputPolicy
  private let credentials: any ClairAgentCredentialSource
  private let processFactory: any ClairAgentProcessFactory

  public init(
    executableURL: URL,
    version: ClairProviderVersion = .unknown,
    arguments: [String] = [],
    environment: [String: String] = [:],
    outputPolicy: ClairAgentOutputPolicy = .discard,
    credentials: any ClairAgentCredentialSource = ClairNoCredentials(),
    processFactory: any ClairAgentProcessFactory = ClairSystemAgentProcessFactory()
  ) throws {
    guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
      !executableURL.path.contains("\0")
    else {
      throw ClairAgentError.invalidExecutableURL
    }
    self.identity = ClairProviderIdentity(
      providerID: .openCode,
      version: version
    )
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.outputPolicy = outputPolicy
    self.credentials = credentials
    self.processFactory = processFactory
  }

  public func makeLaunchSpec(
    for session: ClairAgentSessionIdentity,
    workingDirectoryURL: URL,
    limits: ClairAgentLaunchLimits
  ) throws -> ClairAgentLaunchSpec {
    guard identity == session.provider else {
      throw ClairAgentError.providerIdentityMismatch(
        expected: identity,
        actual: session.provider
      )
    }

    var launchEnvironment = environment
    let credentialEnvironment: [String: String]
    do {
      credentialEnvironment = try credentials.environment(for: identity.providerID)
    } catch let error as ClairAgentError {
      throw error
    } catch {
      throw ClairAgentError.credentialUnavailable
    }
    launchEnvironment.merge(credentialEnvironment) { _, newValue in newValue }
    launchEnvironment["CLAIR_PROJECT_ID"] = session.projectID.rawValue
    launchEnvironment["CLAIR_SESSION_ID"] = session.sessionID.rawValue
    if let worktreeID = session.worktreeID {
      launchEnvironment["CLAIR_WORKTREE_ID"] = worktreeID.rawValue
    } else {
      launchEnvironment.removeValue(forKey: "CLAIR_WORKTREE_ID")
    }

    let spec = try ClairAgentLaunchSpec(
      executableURL: executableURL,
      arguments: arguments,
      environment: launchEnvironment,
      workingDirectoryURL: workingDirectoryURL,
      outputPolicy: outputPolicy,
      limits: limits
    )
    try validateExecutable(at: spec.executableURL)
    return spec
  }

  public func makeProcess(
    spec: ClairAgentLaunchSpec,
    onTermination: @escaping ClairAgentTerminationHandler
  ) throws -> any ClairAgentProcess {
    try processFactory.makeProcess(spec: spec, onTermination: onTermination)
  }

  public var description: String {
    let output: String
    switch outputPolicy {
    case .discard:
      output = "discard"
    case .bounded(let maximumBytes):
      output = "bounded(\(maximumBytes))"
    }
    return "OpenCodeProvider(identity=\(identity), "
      + "executable=\(executableURL.lastPathComponent), arguments=\(arguments.count), "
      + "environment_entries=\(environment.count), output=\(output))"
  }

  private func validateExecutable(at url: URL) throws {
    let fileManager = FileManager.default
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw ClairAgentError.missingExecutable(url)
    }
    guard !isDirectory.boolValue, fileManager.isExecutableFile(atPath: url.path) else {
      throw ClairAgentError.executableNotExecutable(url)
    }
  }
}

public enum ClairAgentExitReason: String, Codable, Equatable, Sendable {
  case normal
  case abnormal
  case signal
  case stopped
  case forced
}

public struct ClairAgentExit: Codable, Equatable, Sendable {
  public let reason: ClairAgentExitReason
  public let status: Int32?
  public let signal: Int32?

  public init(processExit: ClairAgentProcessExit) throws {
    guard processExit.didLaunch,
      (processExit.status != nil) != (processExit.signal != nil)
    else {
      throw ClairAgentError.invalidProcessExit
    }
    if processExit.wasForceTerminated {
      reason = .forced
    } else if processExit.wasRequestedByClair {
      reason = .stopped
    } else if processExit.signal != nil {
      reason = .signal
    } else if processExit.status == 0 {
      reason = .normal
    } else {
      reason = .abnormal
    }
    status = processExit.status
    signal = processExit.signal
  }
}

public enum ClairAgentLifecycleState: String, Codable, Equatable, Sendable {
  case starting
  case running
  case stopping
  case upgrading
  case cleanupPending = "cleanup_pending"
  case stopped
  case exited
  case failed
}

public enum ClairAgentFailure: String, Codable, Equatable, Sendable {
  case launchFailed = "launch_failed"
  case abnormalExit = "abnormal_exit"
  case signaledExit = "signaled_exit"
  case forcedTermination = "forced_termination"
  case terminationFailed = "termination_failed"
  case cleanupPending = "cleanup_pending"
}

public struct ClairAgentSessionSnapshot: Codable, Equatable, Sendable {
  public let identity: ClairAgentSessionIdentity
  public let workingDirectoryURL: URL
  public let lifecycle: ClairAgentLifecycleState
  public let processID: Int32?
  public let processGeneration: UInt64
  public let exit: ClairAgentExit?
  public let failure: ClairAgentFailure?
  public let outputWasTruncated: Bool

}

public struct ClairSystemAgentProcessFactory: ClairAgentProcessFactory {
  private let processGroupClaimFailures: Int
  private let processGroupClaimFailureDelay: TimeInterval
  private let cleanupFailures: Int
  private let cleanupFailureDelay: TimeInterval
  private let waitIDFailures: Int
  private let onWaitIDFailure: (@Sendable () -> Void)?
  private let onCleanupFailure: (@Sendable () -> Void)?
  private let onBeforeLeaderReap: (@Sendable (Int32) -> Void)?
  private let onProcessGroupKill: (@Sendable (Int32, Int32) -> Void)?
  private let onLeaderReap: (@Sendable (Int32) -> Void)?
  private let onGroupKeeperReap: (@Sendable (Int32) -> Void)?

  public init() {
    self.processGroupClaimFailures = 0
    self.processGroupClaimFailureDelay = 0
    self.cleanupFailures = 0
    self.cleanupFailureDelay = 0
    self.waitIDFailures = 0
    self.onWaitIDFailure = nil
    self.onCleanupFailure = nil
    self.onBeforeLeaderReap = nil
    self.onProcessGroupKill = nil
    self.onLeaderReap = nil
    self.onGroupKeeperReap = nil
  }

  init(
    processGroupClaimFailures: Int,
    processGroupClaimFailureDelay: TimeInterval = 0,
    cleanupFailures: Int = 0,
    cleanupFailureDelay: TimeInterval = 0,
    waitIDFailures: Int = 0,
    onWaitIDFailure: (@Sendable () -> Void)? = nil,
    onCleanupFailure: (@Sendable () -> Void)? = nil,
    onBeforeLeaderReap: (@Sendable (Int32) -> Void)? = nil,
    onProcessGroupKill: (@Sendable (Int32, Int32) -> Void)? = nil,
    onLeaderReap: (@Sendable (Int32) -> Void)? = nil,
    onGroupKeeperReap: (@Sendable (Int32) -> Void)? = nil
  ) {
    self.processGroupClaimFailures = max(0, processGroupClaimFailures)
    self.processGroupClaimFailureDelay = max(0, processGroupClaimFailureDelay)
    self.cleanupFailures = max(0, cleanupFailures)
    self.cleanupFailureDelay = max(0, cleanupFailureDelay)
    self.waitIDFailures = max(0, waitIDFailures)
    self.onWaitIDFailure = onWaitIDFailure
    self.onCleanupFailure = onCleanupFailure
    self.onBeforeLeaderReap = onBeforeLeaderReap
    self.onProcessGroupKill = onProcessGroupKill
    self.onLeaderReap = onLeaderReap
    self.onGroupKeeperReap = onGroupKeeperReap
  }

  public func makeProcess(
    spec: ClairAgentLaunchSpec,
    onTermination: @escaping ClairAgentTerminationHandler
  ) throws -> any ClairAgentProcess {
    #if os(macOS)
      return try ClairFoundationAgentProcess(
        spec: spec,
        processGroupClaimFailures: processGroupClaimFailures,
        processGroupClaimFailureDelay: processGroupClaimFailureDelay,
        cleanupFailures: cleanupFailures,
        cleanupFailureDelay: cleanupFailureDelay,
        waitIDFailures: waitIDFailures,
        onWaitIDFailure: onWaitIDFailure,
        onCleanupFailure: onCleanupFailure,
        onBeforeLeaderReap: onBeforeLeaderReap,
        onProcessGroupKill: onProcessGroupKill,
        onLeaderReap: onLeaderReap,
        onGroupKeeperReap: onGroupKeeperReap,
        onTermination: onTermination
      )
    #else
      throw ClairAgentError.unsupportedPlatform
    #endif
  }
}

#if os(macOS)

  private final class ClairAgentOutputBuffer: @unchecked Sendable {
    enum Stream {
      case stdout
      case stderr
    }

    private let maximumBytes: Int
    private let condition = NSCondition()
    private var stdout = Data()
    private var stderr = Data()
    private var truncated = false

    init(maximumBytes: Int) {
      self.maximumBytes = maximumBytes
    }

    func append(_ data: Data, to stream: Stream) {
      guard !data.isEmpty else { return }
      condition.lock()
      defer { condition.unlock() }

      let retainedBytes = stdout.count + stderr.count
      let remaining = max(0, maximumBytes - retainedBytes)
      if remaining == 0 {
        truncated = true
        return
      }
      let retained = Data(data.prefix(remaining))
      switch stream {
      case .stdout:
        stdout.append(retained)
      case .stderr:
        stderr.append(retained)
      }
      if retained.count != data.count {
        truncated = true
      }
    }

    func snapshot() -> ClairAgentRawOutput {
      condition.lock()
      defer { condition.unlock() }
      return ClairAgentRawOutput(
        stdout: stdout,
        stderr: stderr,
        isTruncated: truncated
      )
    }
  }

  private final class ClairFoundationAgentProcess: ClairAgentProcess,
    @unchecked Sendable
  {
    private static let forceTerminationWait: TimeInterval = 2
    private static let initialExitResolutionWindow = DispatchTimeInterval.milliseconds(10)
    private static let initialReapRecoveryWait: TimeInterval = 0.1
    private static let processGroupPollInterval: TimeInterval = 0.01

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectoryURL: URL
    private let workingDirectoryDescriptor: Int32
    private let workingDirectoryDevice: UInt64
    private let workingDirectoryInode: UInt64
    private let condition = NSCondition()
    private var hasStarted = false
    private var processIDValue: Int32 = 0
    private var processIsRunning = false
    private var expectedTermination = false
    private var forceTermination = false
    private var pendingCleanup = false
    private var processGroupClaimed = false
    private var processGroupClaimFailuresRemaining: Int
    private let processGroupClaimFailureDelay: TimeInterval
    private var cleanupFailuresRemaining: Int
    private let cleanupFailureDelay: TimeInterval
    private var waitIDFailuresRemaining: Int
    private let onWaitIDFailure: (@Sendable () -> Void)?
    private let onCleanupFailure: (@Sendable () -> Void)?
    private let onBeforeLeaderReap: (@Sendable (Int32) -> Void)?
    private let onProcessGroupKill: (@Sendable (Int32, Int32) -> Void)?
    private let onLeaderReap: (@Sendable (Int32) -> Void)?
    private let onGroupKeeperReap: (@Sendable (Int32) -> Void)?
    private var terminationExit: ClairAgentProcessExit?
    private var waitFailure = false
    private var reapPending = false
    private var reapRecoveryInFlight = false
    private var completedExit: ClairAgentProcessExit?
    private var terminationCallbackSent = false
    private let onTermination: ClairAgentTerminationHandler
    private let outputBuffer: ClairAgentOutputBuffer?
    private let stdoutPipe: Pipe?
    private let stderrPipe: Pipe?
    private var processGroupID: Int32?
    private var groupKeeperProcessID: Int32?
    private var groupKeeperControlWriteDescriptor: Int32?
    private var processGroupGeneration: UInt64 = 0
    private var processGroupKillIssued = false
    private var leaderExitObserved = false
    private var leaderReaped = false
    private var groupKeeperReaped = false
    private var initialReapReady = false
    private var initialReapShouldWait = false
    private var initialReapComplete = false

    private struct TerminationRequestState {
      let completedExit: ClairAgentProcessExit?
      let terminationExit: ClairAgentProcessExit?
      let waitFailure: Bool
      let reapPending: Bool
      let hasStarted: Bool
    }

    private struct SpawnedProcess {
      let processID: Int32
      let processGroupID: Int32
      let groupKeeperProcessID: Int32
      let groupKeeperControlWriteDescriptor: Int32
    }

    private static func duplicateDescriptorWithCloseOnExec(_ descriptor: Int32) -> Int32 {
      Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
    }

    init(
      spec: ClairAgentLaunchSpec,
      processGroupClaimFailures: Int,
      processGroupClaimFailureDelay: TimeInterval,
      cleanupFailures: Int,
      cleanupFailureDelay: TimeInterval,
      waitIDFailures: Int,
      onWaitIDFailure: (@Sendable () -> Void)?,
      onCleanupFailure: (@Sendable () -> Void)?,
      onBeforeLeaderReap: (@Sendable (Int32) -> Void)?,
      onProcessGroupKill: (@Sendable (Int32, Int32) -> Void)?,
      onLeaderReap: (@Sendable (Int32) -> Void)?,
      onGroupKeeperReap: (@Sendable (Int32) -> Void)?,
      onTermination: @escaping ClairAgentTerminationHandler
    ) throws {
      self.processGroupClaimFailuresRemaining = max(0, processGroupClaimFailures)
      self.processGroupClaimFailureDelay = max(0, processGroupClaimFailureDelay)
      self.cleanupFailuresRemaining = max(0, cleanupFailures)
      self.cleanupFailureDelay = max(0, cleanupFailureDelay)
      self.waitIDFailuresRemaining = max(0, waitIDFailures)
      self.onWaitIDFailure = onWaitIDFailure
      self.onCleanupFailure = onCleanupFailure
      self.onBeforeLeaderReap = onBeforeLeaderReap
      self.onProcessGroupKill = onProcessGroupKill
      self.onLeaderReap = onLeaderReap
      self.onGroupKeeperReap = onGroupKeeperReap
      self.executableURL = spec.executableURL
      self.arguments = spec.arguments
      self.environment = spec.environment
      self.workingDirectoryURL = spec.workingDirectoryURL
      let ownedDescriptor: Int32
      let workingDirectoryDevice: UInt64
      let workingDirectoryInode: UInt64
      if let descriptor = spec.workingDirectoryDescriptor,
        let device = spec.workingDirectoryDevice,
        let inode = spec.workingDirectoryInode
      {
        let duplicatedDescriptor = Self.duplicateDescriptorWithCloseOnExec(descriptor)
        guard duplicatedDescriptor >= 0 else {
          throw ClairAgentError.workingDirectoryDescriptorUnavailable(
            spec.workingDirectoryURL
          )
        }
        ownedDescriptor = duplicatedDescriptor
        workingDirectoryDevice = device
        workingDirectoryInode = inode
      } else {
        let openedDescriptor = Darwin.open(
          spec.workingDirectoryURL.path,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard openedDescriptor >= 0 else {
          throw ClairAgentError.workingDirectoryDescriptorUnavailable(
            spec.workingDirectoryURL
          )
        }
        var information = stat()
        guard Darwin.fstat(openedDescriptor, &information) == 0,
          information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
          Darwin.close(openedDescriptor)
          throw ClairAgentError.workingDirectoryDescriptorUnavailable(
            spec.workingDirectoryURL
          )
        }
        if openedDescriptor < 3 {
          let duplicatedDescriptor = Self.duplicateDescriptorWithCloseOnExec(openedDescriptor)
          guard duplicatedDescriptor >= 0 else {
            Darwin.close(openedDescriptor)
            throw ClairAgentError.workingDirectoryDescriptorUnavailable(
              spec.workingDirectoryURL
            )
          }
          Darwin.close(openedDescriptor)
          ownedDescriptor = duplicatedDescriptor
        } else {
          ownedDescriptor = openedDescriptor
        }
        workingDirectoryDevice = UInt64(information.st_dev)
        workingDirectoryInode = UInt64(information.st_ino)
      }
      self.workingDirectoryDescriptor = ownedDescriptor
      self.workingDirectoryDevice = workingDirectoryDevice
      self.workingDirectoryInode = workingDirectoryInode
      self.onTermination = onTermination
      switch spec.outputPolicy {
      case .discard:
        self.outputBuffer = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
      case .bounded(let maximumBytes):
        let outputBuffer = ClairAgentOutputBuffer(maximumBytes: maximumBytes)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        self.outputBuffer = outputBuffer
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak outputBuffer] handle in
          let data = handle.availableData
          if data.isEmpty {
            handle.readabilityHandler = nil
          } else {
            outputBuffer?.append(data, to: .stdout)
          }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak outputBuffer] handle in
          let data = handle.availableData
          if data.isEmpty {
            handle.readabilityHandler = nil
          } else {
            outputBuffer?.append(data, to: .stderr)
          }
        }
      }
    }

    var processID: Int32 {
      condition.lock()
      defer { condition.unlock() }
      return processIDValue
    }

    var isRunning: Bool {
      condition.lock()
      defer { condition.unlock() }
      return processIsRunning
    }

    var hasPendingCleanup: Bool {
      condition.lock()
      defer { condition.unlock() }
      return pendingCleanup
    }

    func start() throws -> ClairAgentProcessStartOutcome {
      condition.lock()
      guard !hasStarted else {
        condition.unlock()
        throw ClairAgentError.processAlreadyStarted
      }
      hasStarted = true
      condition.unlock()
      do {
        let spawnedProcess = try spawnProcess()
        let processID = spawnedProcess.processID
        closeParentWriteEnds()
        condition.lock()
        processIDValue = processID
        processIsRunning = true
        processGroupGeneration =
          processGroupGeneration == UInt64.max ? 1 : processGroupGeneration + 1
        processGroupID = spawnedProcess.processGroupID
        groupKeeperProcessID = spawnedProcess.groupKeeperProcessID
        groupKeeperControlWriteDescriptor = spawnedProcess.groupKeeperControlWriteDescriptor
        leaderExitObserved = false
        leaderReaped = false
        groupKeeperReaped = false
        processGroupKillIssued = false
        condition.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
          waitForProcess(processID)
        }
        guard claimProcessGroup() else {
          markInitialReapReady(shouldWait: true)
          throw ClairAgentError.processGroupUnavailable
        }
        // The start thread owns the first nonblocking wait. Observation uses
        // waitid(WNOWAIT), so an exited leader remains waitable while its
        // claimed process group is cleaned up before the only waitpid reap.
        let initialObservation = observeInitialProcess(processID)
        switch initialObservation {
        case .running:
          break
        case .exited(let info):
          handleObservedProcessExit(processID: processID, info: info)
        case .failed:
          didFailToReap(terminationFlags: terminationFlags())
        }
        markInitialReapComplete()
        markInitialReapReady(shouldWait: initialObservation.shouldWait)
        return try startOutcomeAfterInitialReap()
      } catch let error as ClairAgentError {
        closeParentWriteEnds()
        condition.lock()
        let hasSpawnedProcess = processIDValue > 0
        condition.unlock()
        if hasSpawnedProcess {
          markInitialReapReady(shouldWait: true)
        }
        condition.lock()
        if processIDValue == 0 {
          hasStarted = false
        }
        condition.unlock()
        throw error
      } catch {
        closeParentWriteEnds()
        condition.lock()
        let hasSpawnedProcess = processIDValue > 0
        condition.unlock()
        if hasSpawnedProcess {
          markInitialReapReady(shouldWait: true)
        }
        condition.lock()
        if processIDValue == 0 {
          hasStarted = false
        }
        condition.unlock()
        throw ClairAgentError.processLaunchFailed
      }
    }

    func send(signal: ClairAgentSignal) async throws {
      try sendSignal(signal)
    }

    func terminate(gracePeriod: TimeInterval) async throws -> ClairAgentProcessExit {
      let request = try prepareTermination(force: false)
      if let completedExit = request.completedExit {
        return completedExit
      }

      if request.waitFailure || request.reapPending {
        return try await forceTerminate()
      }

      if request.terminationExit == nil, isRunning {
        try sendSignal(.terminate)
      }

      let deadline = Date().addingTimeInterval(gracePeriod)
      while isRunning, Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
      if isRunning {
        _ = try await forceTerminate()
      } else {
        try cleanupProcessGroup()
        if let processExit = publishCompletedTermination() {
          return processExit
        }
      }
      return try await waitForTermination()
    }

    func forceTerminate() async throws -> ClairAgentProcessExit {
      let request = try prepareTermination(force: true)
      guard request.hasStarted else {
        return ClairAgentProcessExit(
          wasRequestedByClair: true,
          wasForceTerminated: true,
          didLaunch: false
        )
      }
      var cleanupError: ClairAgentError?
      do {
        try cleanupProcessGroup()
      } catch let error as ClairAgentError {
        cleanupError = error
      } catch {
        cleanupError = .processTerminationFailed
      }
      if let completedExit = request.completedExit {
        if let cleanupError {
          throw cleanupError
        }
        return completedExit
      }

      if let cleanupError {
        throw cleanupError
      }

      // The process group kill is the only destructive operation. The leader
      // is always reaped by the observation/recovery path after that kill;
      // never fall back to a saved numeric PID, which could have been reused.
      if request.waitFailure || request.reapPending {
        return try await waitForTermination()
      }
      if let processExit = publishCompletedTermination() {
        return processExit
      }
      return try await waitForTermination()
    }

    func rawOutput() async -> ClairAgentRawOutput {
      outputBuffer?.snapshot() ?? ClairAgentRawOutput()
    }

    private func prepareTermination(force: Bool) throws -> TerminationRequestState {
      condition.lock()
      defer { condition.unlock() }
      guard hasStarted else {
        return TerminationRequestState(
          completedExit: nil,
          terminationExit: nil,
          waitFailure: false,
          reapPending: false,
          hasStarted: false
        )
      }
      if let completedExit {
        return TerminationRequestState(
          completedExit: completedExit,
          terminationExit: terminationExit,
          waitFailure: waitFailure,
          reapPending: reapPending,
          hasStarted: true
        )
      }
      if force {
        expectedTermination = true
        forceTermination = true
      }
      return TerminationRequestState(
        completedExit: nil,
        terminationExit: terminationExit,
        waitFailure: waitFailure,
        reapPending: reapPending,
        hasStarted: true
      )
    }

    private func sendSignal(_ signal: ClairAgentSignal) throws {
      condition.lock()
      defer { condition.unlock() }
      guard hasStarted else { throw ClairAgentError.processNotRunning }
      guard completedExit == nil, processIDValue > 0, !waitFailure, !reapPending,
        !pendingCleanup
      else {
        if waitFailure || reapPending || pendingCleanup {
          throw ClairAgentError.processTerminationFailed
        }
        throw ClairAgentError.processNotRunning
      }
      let wasExpected = expectedTermination
      if signal == .terminate {
        expectedTermination = true
      }
      guard Darwin.kill(processIDValue, signal.rawValue) == 0 else {
        expectedTermination = wasExpected
        throw ClairAgentError.signalFailed
      }
    }

    private func waitForTermination() async throws -> ClairAgentProcessExit {
      let deadline = Date().addingTimeInterval(Self.forceTerminationWait)
      while true {
        if let completedExit = completedTermination() {
          return completedExit
        }
        guard Date() < deadline else {
          throw ClairAgentError.processTerminationFailed
        }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
    }

    private func completedTermination() -> ClairAgentProcessExit? {
      condition.lock()
      defer { condition.unlock() }
      return completedExit
    }

    private func startOutcomeAfterInitialReap() throws -> ClairAgentProcessStartOutcome {
      condition.lock()
      while !initialReapComplete {
        condition.wait()
      }
      // A failed waitid observation is opaque state, not an invitation for
      // the actor-facing start call to wait behind a blocking recovery wait.
      // Give a fast recovery a short opportunity to publish a terminal exit,
      // then return .running only while the claimed keeper still proves that
      // the process group belongs to this launch.
      let recoveryDeadline = Date().addingTimeInterval(Self.initialReapRecoveryWait)
      while completedExit == nil,
        waitFailure || reapPending || reapRecoveryInFlight,
        condition.wait(until: recoveryDeadline)
      {}
      if let completedExit {
        condition.unlock()
        return .terminated(completedExit)
      }

      if waitFailure || reapPending || reapRecoveryInFlight {
        let ownershipProofRetained =
          processGroupClaimed
          && processIsRunning
          && !leaderExitObserved
          && terminationExit == nil
          && processGroupID.map { $0 > 0 } == true
          && groupKeeperProcessID.map {
            processGroupIsOwned(by: $0, expectedGroupID: processGroupID)
          } == true
        if ownershipProofRetained {
          condition.unlock()
          return .running
        }
        condition.unlock()
        throw ClairAgentError.processTerminationFailed
      }
      if terminationExit != nil || pendingCleanup {
        condition.unlock()
        throw ClairAgentError.processTerminationFailed
      }
      condition.unlock()
      return .running
    }

    private enum ProcessObservation {
      case running
      case exited(siginfo_t)
      case failed

      var shouldWait: Bool {
        if case .running = self {
          return true
        }
        return false
      }
    }

    private func waitForProcess(_ processID: Int32) {
      guard waitForInitialReapReady() else { return }
      switch observeProcessExit(processID, waitForExit: true) {
      case .exited(let info):
        handleObservedProcessExit(processID: processID, info: info)
      case .running, .failed:
        // A blocking waitid observation should only return a waitable exit.
        // Keep the handle in the typed failure state if the kernel does not
        // provide that proof.
        didFailToReap(terminationFlags: terminationFlags())
      }
    }

    private func observeInitialProcess(_ processID: Int32) -> ProcessObservation {
      let firstObservation = observeProcessExit(processID, waitForExit: false)
      guard case .running = firstObservation else {
        return firstObservation
      }

      // A very short-lived child can still be between spawn and exec when the
      // first nonblocking observation runs. Subscribe to the kernel exit event
      // for the launch-resolution window, then observe with WNOWAIT. This is
      // an event-driven handoff; waitpid remains exclusively after group
      // cleanup has established the safe reap ordering.
      let didExit = DispatchSemaphore(value: 0)
      let processSource = DispatchSource.makeProcessSource(
        identifier: pid_t(processID),
        eventMask: .exit,
        queue: DispatchQueue.global(qos: .utility)
      )
      processSource.setEventHandler {
        didExit.signal()
      }
      processSource.resume()
      defer { processSource.cancel() }

      guard didExit.wait(timeout: .now() + Self.initialExitResolutionWindow) == .success else {
        return observeProcessExit(processID, waitForExit: false)
      }
      return observeProcessExit(processID, waitForExit: true)
    }

    private func observeProcessExit(
      _ processID: Int32,
      waitForExit: Bool
    ) -> ProcessObservation {
      guard !consumeInjectedWaitIDFailure() else { return .failed }
      var info = siginfo_t()
      let options = waitForExit ? (WEXITED | WNOWAIT) : (WEXITED | WNOHANG | WNOWAIT)
      var result: Int32
      repeat {
        result = Darwin.waitid(P_PID, id_t(processID), &info, options)
      } while result == -1 && errno == EINTR

      guard result == 0 else { return .failed }
      guard info.si_pid != 0 else { return .running }
      guard info.si_pid == processID else { return .failed }
      return .exited(info)
    }

    private func consumeInjectedWaitIDFailure() -> Bool {
      condition.lock()
      defer { condition.unlock() }
      guard waitIDFailuresRemaining > 0 else { return false }
      waitIDFailuresRemaining -= 1
      return true
    }

    private func recoverFailedObservation(processID: Int32) {
      defer {
        condition.lock()
        reapRecoveryInFlight = false
        condition.broadcast()
        condition.unlock()
      }

      while true {
        condition.lock()
        let shouldContinue = completedExit == nil && processIDValue == processID && reapPending
        condition.unlock()
        guard shouldContinue else { return }

        // Retry observation before taking any destructive action. If a caller
        // requests force termination concurrently, its ownership-proven group
        // kill wakes this wait and the same path then reaps both processes.
        switch observeProcessExit(processID, waitForExit: true) {
        case .exited(let info):
          handleObservedProcessExit(processID: processID, info: info)
          return
        case .running, .failed:
          // A transient waitid failure leaves the opaque handle retained. Retry
          // until the kernel provides the exit record needed for safe reap.
          Thread.sleep(forTimeInterval: Self.processGroupPollInterval)
        }
      }
    }

    private func handleObservedProcessExit(processID: Int32, info: siginfo_t) {
      let terminationFlags = self.terminationFlags()
      guard info.si_pid == processID,
        let exit = processExit(
          from: info,
          terminationFlags: terminationFlags
        )
      else {
        // A spawned child should only be observed through an exit status that
        // waitid can classify. Retain the handle if the kernel proof is
        // incomplete instead of treating a reused or unrelated PID as ours.
        didFailToReap(terminationFlags: terminationFlags)
        return
      }
      didTerminate(exit)
    }

    private func processExit(
      from info: siginfo_t,
      terminationFlags: (requested: Bool, force: Bool)
    ) -> ClairAgentProcessExit? {
      switch info.si_code {
      case CLD_EXITED:
        return ClairAgentProcessExit(
          status: Int32(info.si_status),
          wasRequestedByClair: terminationFlags.requested
        )
      case CLD_KILLED, CLD_DUMPED:
        return ClairAgentProcessExit(
          signal: Int32(info.si_status),
          wasRequestedByClair: terminationFlags.requested,
          wasForceTerminated: terminationFlags.force
        )
      default:
        return nil
      }
    }

    private func markInitialReapReady(shouldWait: Bool) {
      condition.lock()
      guard !initialReapReady else {
        condition.unlock()
        return
      }
      initialReapReady = true
      initialReapShouldWait = shouldWait
      condition.broadcast()
      condition.unlock()
    }

    private func waitForInitialReapReady() -> Bool {
      condition.lock()
      while !initialReapReady {
        condition.wait()
      }
      let shouldWait = initialReapShouldWait
      condition.unlock()
      return shouldWait
    }

    private func markInitialReapComplete() {
      condition.lock()
      initialReapComplete = true
      condition.broadcast()
      condition.unlock()
    }

    private func terminationFlags() -> (requested: Bool, force: Bool) {
      condition.lock()
      defer { condition.unlock() }
      return (expectedTermination, forceTermination)
    }

    private func didTerminate(_ exit: ClairAgentProcessExit) {
      condition.lock()
      guard completedExit == nil, terminationExit == nil else {
        condition.unlock()
        return
      }
      let expectedProcessGroupID = processGroupID
      let expectedProcessGroupGeneration = processGroupGeneration
      terminationExit = exit
      processIsRunning = false
      leaderExitObserved = true
      condition.unlock()

      do {
        try cleanupProcessGroup()
        _ = publishCompletedTermination()
      } catch {
        // Keep completedExit private until the pre-reap group cleanup, leader
        // reap, and post-reap group absence proof all succeed.
        markCleanupPendingIfCurrent(
          processGroupID: expectedProcessGroupID,
          processGroupGeneration: expectedProcessGroupGeneration,
          terminationExit: exit
        )
      }

      condition.lock()
      guard !terminationCallbackSent else {
        condition.unlock()
        return
      }
      terminationCallbackSent = true
      condition.unlock()

      stdoutPipe?.fileHandleForReading.readabilityHandler = nil
      stderrPipe?.fileHandleForReading.readabilityHandler = nil

      onTermination(exit)
    }

    private func didFailToReap(
      terminationFlags: (requested: Bool, force: Bool)
    ) {
      _ = terminationFlags
      let processID: Int32
      let shouldStartRecovery: Bool
      condition.lock()
      guard completedExit == nil, terminationExit == nil else {
        condition.unlock()
        return
      }
      waitFailure = true
      reapPending = true
      pendingCleanup = true
      processID = processIDValue
      shouldStartRecovery = !reapRecoveryInFlight
      if shouldStartRecovery {
        reapRecoveryInFlight = true
      }
      condition.broadcast()
      condition.unlock()

      if shouldStartRecovery {
        onWaitIDFailure?()
      }

      guard shouldStartRecovery, processID > 0 else { return }
      DispatchQueue.global(qos: .utility).async { [self] in
        recoverFailedObservation(processID: processID)
      }
    }

    private func publishCompletedTermination() -> ClairAgentProcessExit? {
      condition.lock()
      defer { condition.unlock() }
      guard completedExit == nil, !waitFailure, !reapPending, !pendingCleanup,
        processGroupID == nil,
        let terminationExit
      else {
        return completedExit
      }
      completedExit = terminationExit
      condition.broadcast()
      return terminationExit
    }

    private func validateWorkingDirectoryDescriptor() throws {
      var descriptorInformation = stat()
      guard Darwin.fstat(workingDirectoryDescriptor, &descriptorInformation) == 0 else {
        throw ClairAgentError.workingDirectoryDescriptorUnavailable(
          workingDirectoryURL
        )
      }
      guard descriptorInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        UInt64(descriptorInformation.st_dev) == workingDirectoryDevice,
        UInt64(descriptorInformation.st_ino) == workingDirectoryInode
      else {
        throw ClairAgentError.workingDirectoryChanged(workingDirectoryURL)
      }

      var pathInformation = stat()
      guard Darwin.lstat(workingDirectoryURL.path, &pathInformation) == 0 else {
        throw ClairAgentError.workingDirectoryChanged(workingDirectoryURL)
      }
      guard pathInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        UInt64(pathInformation.st_dev) == workingDirectoryDevice,
        UInt64(pathInformation.st_ino) == workingDirectoryInode
      else {
        throw ClairAgentError.workingDirectoryChanged(workingDirectoryURL)
      }
    }

    private func spawnProcess() throws -> SpawnedProcess {
      // Keep a small, known child alive as the process-group leader. macOS can
      // drop an exited provider from getpgid() before its waitable record is
      // reaped, which would otherwise leave the numeric PGID reusable in the
      // cleanup window.
      let groupKeeper = try spawnGroupKeeper()
      var keeperNeedsCleanup = true
      defer {
        if keeperNeedsCleanup {
          _ = Darwin.kill(groupKeeper.processID, SIGKILL)
          var waitStatus: Int32 = 0
          var waitResult: Int32
          repeat {
            waitResult = Darwin.waitpid(groupKeeper.processID, &waitStatus, 0)
          } while waitResult == -1 && errno == EINTR
          Darwin.close(groupKeeper.controlWriteDescriptor)
        }
      }

      var fileActions: posix_spawn_file_actions_t?
      guard posix_spawn_file_actions_init(&fileActions) == 0 else {
        throw ClairAgentError.processLaunchFailed
      }
      defer { _ = posix_spawn_file_actions_destroy(&fileActions) }

      // Hold the validated descriptor through spawn. The descriptor-based cwd
      // remains stable even if the catalog path is replaced concurrently.
      try validateWorkingDirectoryDescriptor()
      let cwdResult = posix_spawn_file_actions_addfchdir_np(
        &fileActions,
        workingDirectoryDescriptor
      )
      guard cwdResult == 0 else {
        throw ClairAgentError.workingDirectoryDescriptorUnavailable(
          workingDirectoryURL
        )
      }
      guard
        posix_spawn_file_actions_addclose(
          &fileActions,
          workingDirectoryDescriptor
        ) == 0
      else {
        throw ClairAgentError.workingDirectoryDescriptorUnavailable(
          workingDirectoryURL
        )
      }
      try addOutputActions(to: &fileActions)

      var attributes: posix_spawnattr_t?
      guard posix_spawnattr_init(&attributes) == 0 else {
        throw ClairAgentError.processGroupUnavailable
      }
      defer { _ = posix_spawnattr_destroy(&attributes) }
      guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
        posix_spawnattr_setpgroup(&attributes, pid_t(groupKeeper.processID)) == 0
      else {
        throw ClairAgentError.processGroupUnavailable
      }
      // The provider joins the keeper's group during spawn; no post-spawn
      // setpgid window can expose descendants to another group.

      let argumentStrings = [executableURL.path] + arguments
      let environmentStrings = environment.keys.sorted().map {
        "\($0)=\(environment[$0] ?? "")"
      }
      let argumentPointers = try makeCStringStorage(argumentStrings)
      let environmentPointers = try makeCStringStorage(environmentStrings)
      defer {
        for pointer in argumentPointers {
          Darwin.free(pointer)
        }
        for pointer in environmentPointers {
          Darwin.free(pointer)
        }
      }
      var argv: [UnsafeMutablePointer<CChar>?] = argumentPointers.map { $0 }
      argv.append(nil)
      var envp: [UnsafeMutablePointer<CChar>?] = environmentPointers.map { $0 }
      envp.append(nil)
      var processID: pid_t = 0
      let result = executableURL.path.withCString { path in
        argv.withUnsafeMutableBufferPointer { argvBuffer in
          envp.withUnsafeMutableBufferPointer { envpBuffer in
            posix_spawn(
              &processID,
              path,
              &fileActions,
              &attributes,
              argvBuffer.baseAddress,
              envpBuffer.baseAddress
            )
          }
        }
      }
      guard result == 0, processID > 0 else {
        if result == EPERM {
          throw ClairAgentError.processGroupUnavailable
        }
        throw ClairAgentError.processLaunchFailed
      }
      keeperNeedsCleanup = false
      return SpawnedProcess(
        processID: processID,
        processGroupID: groupKeeper.processID,
        groupKeeperProcessID: groupKeeper.processID,
        groupKeeperControlWriteDescriptor: groupKeeper.controlWriteDescriptor
      )
    }

    private func spawnGroupKeeper() throws -> (
      processID: Int32,
      controlWriteDescriptor: Int32
    ) {
      var pipeDescriptors = [Int32](repeating: 0, count: 2)
      guard Darwin.pipe(&pipeDescriptors) == 0 else {
        throw ClairAgentError.processGroupUnavailable
      }
      let rawReadDescriptor = pipeDescriptors[0]
      let rawWriteDescriptor = pipeDescriptors[1]
      let readDescriptor = Self.duplicateDescriptorWithCloseOnExec(rawReadDescriptor)
      guard readDescriptor >= 0 else {
        Darwin.close(rawReadDescriptor)
        Darwin.close(rawWriteDescriptor)
        throw ClairAgentError.processGroupUnavailable
      }
      let writeDescriptor = Self.duplicateDescriptorWithCloseOnExec(rawWriteDescriptor)
      guard writeDescriptor >= 0 else {
        Darwin.close(rawReadDescriptor)
        Darwin.close(rawWriteDescriptor)
        Darwin.close(readDescriptor)
        throw ClairAgentError.processGroupUnavailable
      }
      Darwin.close(rawReadDescriptor)
      Darwin.close(rawWriteDescriptor)
      var parentOwnsWriteDescriptor = false
      defer {
        if !parentOwnsWriteDescriptor {
          Darwin.close(readDescriptor)
          Darwin.close(writeDescriptor)
        }
      }
      var fileActions: posix_spawn_file_actions_t?
      guard posix_spawn_file_actions_init(&fileActions) == 0 else {
        throw ClairAgentError.processGroupUnavailable
      }
      defer { _ = posix_spawn_file_actions_destroy(&fileActions) }
      guard
        posix_spawn_file_actions_adddup2(
          &fileActions,
          readDescriptor,
          STDIN_FILENO
        ) == 0
      else {
        throw ClairAgentError.processGroupUnavailable
      }
      guard posix_spawn_file_actions_addclose(&fileActions, readDescriptor) == 0 else {
        throw ClairAgentError.processGroupUnavailable
      }
      guard posix_spawn_file_actions_addclose(&fileActions, writeDescriptor) == 0 else {
        throw ClairAgentError.processGroupUnavailable
      }
      let stdoutResult = "/dev/null".withCString { path in
        posix_spawn_file_actions_addopen(
          &fileActions,
          STDOUT_FILENO,
          path,
          O_WRONLY,
          0
        )
      }
      let stderrResult = "/dev/null".withCString { path in
        posix_spawn_file_actions_addopen(
          &fileActions,
          STDERR_FILENO,
          path,
          O_WRONLY,
          0
        )
      }
      guard stdoutResult == 0, stderrResult == 0 else {
        throw ClairAgentError.processGroupUnavailable
      }

      var attributes: posix_spawnattr_t?
      guard posix_spawnattr_init(&attributes) == 0 else {
        throw ClairAgentError.processGroupUnavailable
      }
      defer { _ = posix_spawnattr_destroy(&attributes) }
      guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0
      else {
        throw ClairAgentError.processGroupUnavailable
      }

      // The keeper's stdin is the daemon-owned control pipe. If the daemon is
      // killed before it can run the normal H04 cleanup path, EOF reaches the
      // keeper and its EXIT trap kills the whole keeper-owned process group.
      // This makes provider cleanup survive an uncatchable daemon SIGKILL
      // without relying on a numeric PGID discovered by a fresh runtime.
      let argumentStrings = [
        "/bin/sh", "-c", "trap 'kill -KILL -$$ 2>/dev/null' EXIT; read -r _",
      ]
      let argumentPointers = try makeCStringStorage(argumentStrings)
      defer {
        for pointer in argumentPointers {
          Darwin.free(pointer)
        }
      }
      var argv: [UnsafeMutablePointer<CChar>?] = argumentPointers.map { $0 }
      argv.append(nil)
      var processID: pid_t = 0
      let result = "/bin/sh".withCString { path in
        argv.withUnsafeMutableBufferPointer { argvBuffer in
          posix_spawn(
            &processID,
            path,
            &fileActions,
            &attributes,
            argvBuffer.baseAddress,
            nil
          )
        }
      }
      guard result == 0, processID > 0 else {
        if result == EPERM {
          throw ClairAgentError.processGroupUnavailable
        }
        throw ClairAgentError.processLaunchFailed
      }
      Darwin.close(readDescriptor)
      parentOwnsWriteDescriptor = true
      return (
        processID: processID,
        controlWriteDescriptor: writeDescriptor
      )
    }

    private func processGroupIsOwned(by processID: Int32, expectedGroupID: Int32? = nil) -> Bool {
      let groupID = Darwin.getpgid(processID)
      // A numeric PGID is not an ownership token. The live group keeper must
      // still be observable in the exact group before any group-directed
      // signal is permitted; ESRCH is therefore a failed proof.
      return groupID == (expectedGroupID ?? processID)
    }

    private func claimProcessGroup() -> Bool {
      condition.lock()
      defer { condition.unlock() }

      if completedExit != nil {
        return true
      }
      guard let processGroupID, processGroupID > 0 else {
        // A completion that already cleared the group is a successful no-op.
        // Do not let an older claim reintroduce pending cleanup.
        return processIDValue > 0 && !pendingCleanup
      }
      let claimGeneration = processGroupGeneration
      if processGroupClaimed {
        return true
      }
      let shouldInjectFailure = processGroupClaimFailuresRemaining > 0
      if shouldInjectFailure {
        processGroupClaimFailuresRemaining -= 1
        if processGroupClaimFailureDelay > 0 {
          Thread.sleep(forTimeInterval: processGroupClaimFailureDelay)
        }
        pendingCleanup = true
        return false
      }

      let claimed =
        groupKeeperProcessID.map {
          processGroupIsOwned(by: $0, expectedGroupID: processGroupID)
        } ?? false
      guard self.processGroupID == processGroupID,
        self.processGroupGeneration == claimGeneration
      else {
        // Cleanup won while this claim was in flight. The lock makes this
        // branch a no-op instead of reasserting pending cleanup.
        return self.processGroupID == nil && !pendingCleanup
      }
      if claimed {
        processGroupClaimed = true
        pendingCleanup = false
      } else {
        pendingCleanup = true
      }
      return claimed
    }

    private func addOutputActions(
      to fileActions: inout posix_spawn_file_actions_t?
    ) throws {
      switch (stdoutPipe, stderrPipe) {
      case (let stdoutPipe?, let stderrPipe?):
        try addPipeActions(
          pipe: stdoutPipe,
          outputFileDescriptor: STDOUT_FILENO,
          to: &fileActions
        )
        try addPipeActions(
          pipe: stderrPipe,
          outputFileDescriptor: STDERR_FILENO,
          to: &fileActions
        )
      case (nil, nil):
        let stdoutResult = "/dev/null".withCString { path in
          posix_spawn_file_actions_addopen(
            &fileActions,
            STDOUT_FILENO,
            path,
            O_WRONLY,
            0
          )
        }
        let stderrResult = "/dev/null".withCString { path in
          posix_spawn_file_actions_addopen(
            &fileActions,
            STDERR_FILENO,
            path,
            O_WRONLY,
            0
          )
        }
        guard stdoutResult == 0, stderrResult == 0 else {
          throw ClairAgentError.processLaunchFailed
        }
      default:
        throw ClairAgentError.processLaunchFailed
      }
    }

    private func addPipeActions(
      pipe: Pipe,
      outputFileDescriptor: Int32,
      to fileActions: inout posix_spawn_file_actions_t?
    ) throws {
      let readFileDescriptor = pipe.fileHandleForReading.fileDescriptor
      let writeFileDescriptor = pipe.fileHandleForWriting.fileDescriptor
      guard
        posix_spawn_file_actions_adddup2(
          &fileActions,
          writeFileDescriptor,
          outputFileDescriptor
        ) == 0
      else {
        throw ClairAgentError.processLaunchFailed
      }
      if readFileDescriptor != outputFileDescriptor {
        guard posix_spawn_file_actions_addclose(&fileActions, readFileDescriptor) == 0 else {
          throw ClairAgentError.processLaunchFailed
        }
      }
      if writeFileDescriptor != outputFileDescriptor {
        guard posix_spawn_file_actions_addclose(&fileActions, writeFileDescriptor) == 0 else {
          throw ClairAgentError.processLaunchFailed
        }
      }
    }

    private func makeCStringStorage(
      _ strings: [String]
    ) throws -> [UnsafeMutablePointer<CChar>] {
      var pointers: [UnsafeMutablePointer<CChar>] = []
      pointers.reserveCapacity(strings.count)
      for string in strings {
        guard let pointer = Darwin.strdup(string) else {
          for pointer in pointers {
            Darwin.free(pointer)
          }
          throw ClairAgentError.processLaunchFailed
        }
        pointers.append(pointer)
      }
      return pointers
    }

    private func closeParentWriteEnds() {
      try? stdoutPipe?.fileHandleForWriting.close()
      try? stderrPipe?.fileHandleForWriting.close()
    }

    private func cleanupProcessGroup() throws {
      condition.lock()
      let processGroupID = self.processGroupID
      let processGroupGeneration = self.processGroupGeneration
      let processGroupClaimed = self.processGroupClaimed
      condition.unlock()
      guard let processGroupID, processGroupID > 0 else {
        condition.lock()
        defer { condition.unlock() }
        guard self.processGroupID == nil,
          self.processGroupGeneration == processGroupGeneration
        else {
          return
        }
        if self.pendingCleanup || self.waitFailure || self.reapPending {
          throw ClairAgentError.processGroupUnavailable
        }
        if self.leaderExitObserved, !self.leaderReaped {
          return try reapLeaderAfterGroupCleanup(
            processGroupID: nil,
            processGroupGeneration: processGroupGeneration
          )
        }
        return
      }
      if !processGroupClaimed {
        guard claimProcessGroup() else {
          throw ClairAgentError.processGroupUnavailable
        }
      }
      condition.lock()
      let shouldInjectFailure = cleanupFailuresRemaining > 0
      if shouldInjectFailure {
        cleanupFailuresRemaining -= 1
      }
      condition.unlock()
      if shouldInjectFailure {
        onCleanupFailure?()
        if cleanupFailureDelay > 0 {
          Thread.sleep(forTimeInterval: cleanupFailureDelay)
        }
        throw ClairAgentError.processTerminationFailed
      }
      condition.lock()
      defer { condition.unlock() }
      guard self.processGroupID == processGroupID,
        self.processGroupGeneration == processGroupGeneration
      else {
        if self.pendingCleanup {
          throw ClairAgentError.processGroupUnavailable
        }
        return
      }

      if self.leaderReaped {
        return try reapLeaderAfterGroupCleanup(
          processGroupID: processGroupID,
          processGroupGeneration: processGroupGeneration
        )
      }

      if !self.processGroupKillIssued {
        guard let groupKeeperProcessID = self.groupKeeperProcessID,
          processGroupIsOwned(by: groupKeeperProcessID, expectedGroupID: processGroupID)
        else {
          // The group keeper may already have exited, or the process may have
          // moved out of the claimed group. Neither state proves ownership of
          // the numeric PGID, so fail closed without a group-directed signal.
          self.pendingCleanup = true
          condition.broadcast()
          throw ClairAgentError.processTerminationFailed
        }

        // Keep the transition lock through the ownership proof and group
        // kill. A stale cleanup or claim cannot clear or reassert this
        // generation while the kill is in flight.
        let killResult = Darwin.kill(-processGroupID, SIGKILL)
        guard killResult == 0 else {
          // A live keeper proved that the group was ours immediately before
          // this call. Any failure still leaves cleanup unproven, including
          // ESRCH, so do not re-use the saved numeric PGID.
          self.pendingCleanup = true
          condition.broadcast()
          throw ClairAgentError.processTerminationFailed
        }
        self.onProcessGroupKill?(processGroupID, groupKeeperProcessID)
        self.processGroupKillIssued = true
      }

      // The group-directed signal is safe because the live keeper proved that
      // this PGID belongs to this launch. Never send that signal after the
      // first group kill; after reap only a non-destructive absence probe is
      // allowed.
      self.pendingCleanup = self.waitFailure || self.reapPending
      if !self.leaderExitObserved {
        condition.broadcast()
        return
      }

      return try reapLeaderAfterGroupCleanup(
        processGroupID: processGroupID,
        processGroupGeneration: processGroupGeneration
      )
    }

    private func reapLeaderAfterGroupCleanup(
      processGroupID: Int32?,
      processGroupGeneration: UInt64
    ) throws {
      guard self.processGroupGeneration == processGroupGeneration,
        self.processGroupID == processGroupID,
        leaderExitObserved
      else { return }
      if !leaderReaped {
        onBeforeLeaderReap?(processIDValue)

        var waitStatus: Int32 = 0
        var waitResult: Int32
        repeat {
          waitResult = Darwin.waitpid(processIDValue, &waitStatus, 0)
        } while waitResult == -1 && errno == EINTR
        guard waitResult == processIDValue else {
          pendingCleanup = true
          condition.broadcast()
          throw ClairAgentError.processTerminationFailed
        }
        leaderReaped = true
        onLeaderReap?(processIDValue)
      }

      if let groupKeeperProcessID, !groupKeeperReaped {
        var keeperWaitStatus: Int32 = 0
        var keeperWaitResult: Int32
        repeat {
          keeperWaitResult = Darwin.waitpid(
            groupKeeperProcessID,
            &keeperWaitStatus,
            0
          )
        } while keeperWaitResult == -1 && errno == EINTR
        guard keeperWaitResult == groupKeeperProcessID else {
          pendingCleanup = true
          condition.broadcast()
          throw ClairAgentError.processTerminationFailed
        }
        groupKeeperReaped = true
        onGroupKeeperReap?(groupKeeperProcessID)
        if let controlWriteDescriptor = groupKeeperControlWriteDescriptor {
          Darwin.close(controlWriteDescriptor)
          groupKeeperControlWriteDescriptor = nil
        }
      }

      do {
        try verifyProcessGroupGoneAfterReap(processGroupID)
      } catch {
        pendingCleanup = true
        condition.broadcast()
        throw error
      }

      self.processGroupID = nil
      self.processGroupClaimed = false
      self.groupKeeperProcessID = nil
      self.processGroupKillIssued = false
      self.waitFailure = false
      self.reapPending = false
      self.pendingCleanup = false
      condition.broadcast()
    }

    private func verifyProcessGroupGoneAfterReap(_ processGroupID: Int32?) throws {
      guard let processGroupID, processGroupID > 0 else { return }
      let deadline = Date().addingTimeInterval(Self.forceTerminationWait)
      while true {
        let probeResult = Darwin.kill(-processGroupID, 0)
        let probeError = probeResult == -1 ? errno : 0
        if probeResult == -1, probeError == ESRCH {
          return
        }
        if probeResult == -1 {
          throw ClairAgentError.processTerminationFailed
        }
        // This is deliberately a read-only wait after reap. If the numeric
        // PGID was reused, fail closed instead of trying to kill the new group.
        guard Date() < deadline else {
          throw ClairAgentError.processTerminationFailed
        }
        Thread.sleep(forTimeInterval: Self.processGroupPollInterval)
      }
    }

    private func markCleanupPendingIfCurrent(
      processGroupID: Int32?,
      processGroupGeneration: UInt64,
      terminationExit: ClairAgentProcessExit?
    ) {
      condition.lock()
      guard completedExit == nil,
        self.terminationExit == terminationExit,
        self.processGroupID == processGroupID,
        self.processGroupGeneration == processGroupGeneration
      else {
        condition.unlock()
        return
      }
      pendingCleanup = true
      condition.broadcast()
      condition.unlock()
    }

    deinit {
      _ = try? cleanupProcessGroup()
      condition.lock()
      let controlWriteDescriptor = groupKeeperControlWriteDescriptor
      groupKeeperControlWriteDescriptor = nil
      condition.unlock()
      if let controlWriteDescriptor {
        Darwin.close(controlWriteDescriptor)
      }
      Darwin.close(workingDirectoryDescriptor)
    }
  }

#endif

public actor ClairAgentRuntime {
  public let limits: ClairAgentLaunchLimits

  private let workspace: ClairWorkspaceRuntime
  private var providers: [ClairProviderID: any ClairAgentProviderAdapter]
  private var sessions: [SessionID: ManagedSession] = [:]
  private var lifecycleObserver: (@Sendable (ClairAgentSessionSnapshot) -> Void)?
  private var nextProcessGeneration: UInt64 = 0
  private var nextShutdownGeneration: UInt64 = 0
  private var shutdownFence: UInt64?

  private struct ManagedSession {
    let identity: ClairAgentSessionIdentity
    let workingDirectoryURL: URL
    var lifecycle: ClairAgentLifecycleState
    var process: (any ClairAgentProcess)?
    var processGeneration: UInt64
    var exit: ClairAgentExit?
    var failure: ClairAgentFailure?
    var rawOutput: ClairAgentRawOutput

    func snapshot() -> ClairAgentSessionSnapshot {
      ClairAgentSessionSnapshot(
        identity: identity,
        workingDirectoryURL: workingDirectoryURL,
        lifecycle: lifecycle,
        processID: process?.processID,
        processGeneration: processGeneration,
        exit: exit,
        failure: failure,
        outputWasTruncated: rawOutput.isTruncated
      )
    }
  }

  public init(
    workspace: ClairWorkspaceRuntime,
    providers: [any ClairAgentProviderAdapter],
    limits: ClairAgentLaunchLimits = .standard
  ) throws {
    var providerMap: [ClairProviderID: any ClairAgentProviderAdapter] = [:]
    for provider in providers {
      guard providerMap.updateValue(provider, forKey: provider.identity.providerID) == nil else {
        throw ClairAgentError.duplicateProvider(provider.identity.providerID)
      }
    }
    self.workspace = workspace
    self.providers = providerMap
    self.limits = limits
  }

  public init(
    workspace: ClairWorkspaceRuntime,
    provider: any ClairAgentProviderAdapter,
    limits: ClairAgentLaunchLimits = .standard
  ) throws {
    try self.init(workspace: workspace, providers: [provider], limits: limits)
  }

  public func installProvider(_ provider: any ClairAgentProviderAdapter) throws {
    if providers[provider.identity.providerID] != nil {
      // Replacing an adapter is deliberately explicit. Existing sessions keep
      // their recorded provider identity and will reject an upgrade at resume.
      providers[provider.identity.providerID] = provider
    } else {
      providers[provider.identity.providerID] = provider
    }
  }

  public func registeredProviders() -> [ClairProviderIdentity] {
    providers.values.map(\.identity).sorted { lhs, rhs in
      lhs.description < rhs.description
    }
  }

  public func start(
    providerID: ClairProviderID,
    target: ClairAgentTarget,
    sessionID: SessionID? = nil
  ) async throws -> ClairAgentSessionSnapshot {
    try ensureLifecycleAdmission()
    guard let provider = providers[providerID] else {
      throw ClairAgentError.providerNotFound(providerID)
    }
    let resolvedSessionID = sessionID ?? makeSessionID()
    guard sessions[resolvedSessionID] == nil else {
      throw ClairAgentError.duplicateLaunch(resolvedSessionID)
    }
    let identity = try ClairAgentSessionIdentity(
      provider: provider.identity,
      projectID: target.projectID,
      worktreeID: target.worktreeID,
      sessionID: resolvedSessionID
    )
    return try await launch(
      identity: identity,
      provider: provider,
      lifecycle: .starting
    )
  }

  public func start(
    target: ClairAgentTarget,
    sessionID: SessionID? = nil
  ) async throws -> ClairAgentSessionSnapshot {
    try ensureLifecycleAdmission()
    guard let providerID = providers.keys.sorted(by: { $0.rawValue < $1.rawValue }).first else {
      throw ClairAgentError.providerNotFound(.openCode)
    }
    return try await start(
      providerID: providerID,
      target: target,
      sessionID: sessionID
    )
  }

  public func resume(
    sessionID: SessionID
  ) async throws -> ClairAgentSessionSnapshot {
    try ensureLifecycleAdmission()
    guard let session = sessions[sessionID] else {
      throw ClairAgentError.staleSession(sessionID)
    }
    try validateResumeProvider(for: session)
    guard let provider = providers[session.identity.provider.providerID] else {
      throw ClairAgentError.providerNotFound(session.identity.provider.providerID)
    }
    return try await relaunchExisting(sessionID: sessionID, provider: provider)
  }

  public func resume(
    identity: ClairAgentSessionIdentity
  ) async throws -> ClairAgentSessionSnapshot {
    try ensureLifecycleAdmission()
    guard let session = sessions[identity.sessionID], session.identity == identity else {
      throw ClairAgentError.staleSession(identity.sessionID)
    }
    return try await resume(sessionID: session.identity.sessionID)
  }

  public func stop(
    sessionID: SessionID
  ) async throws -> ClairAgentSessionSnapshot {
    guard let session = sessions[sessionID] else {
      throw ClairAgentError.staleSession(sessionID)
    }
    guard session.lifecycle == .running else {
      switch session.lifecycle {
      case .stopped, .exited, .failed:
        return session.snapshot()
      case .cleanupPending:
        return try await retryCleanup(sessionID: sessionID)
      case .starting, .stopping, .running, .upgrading:
        throw ClairAgentError.lifecycleConflict(sessionID, state: session.lifecycle)
      }
    }
    return try await stopRunning(sessionID: sessionID, forRestart: false)
  }

  public func stop(
    identity: ClairAgentSessionIdentity
  ) async throws -> ClairAgentSessionSnapshot {
    guard let session = sessions[identity.sessionID], session.identity == identity else {
      throw ClairAgentError.staleSession(identity.sessionID)
    }
    return try await stop(sessionID: identity.sessionID)
  }

  public func restart(
    sessionID: SessionID
  ) async throws -> ClairAgentSessionSnapshot {
    try ensureLifecycleAdmission()
    guard let session = sessions[sessionID] else {
      throw ClairAgentError.staleSession(sessionID)
    }
    try validateResumeProvider(for: session)
    guard let provider = providers[session.identity.provider.providerID] else {
      throw ClairAgentError.providerNotFound(session.identity.provider.providerID)
    }
    if session.lifecycle == .running {
      _ = try await stopRunning(
        sessionID: sessionID,
        forRestart: true,
        reservedLifecycle: .starting
      )
      guard let reserved = sessions[sessionID], reserved.lifecycle == .starting else {
        throw ClairAgentError.lifecycleConflict(
          sessionID,
          state: sessions[sessionID]?.lifecycle ?? .failed
        )
      }
      return try await launch(
        identity: reserved.identity,
        provider: provider,
        lifecycle: .starting
      )
    } else if session.lifecycle == .starting
      || session.lifecycle == .stopping
      || session.lifecycle == .upgrading
      || session.lifecycle == .cleanupPending
    {
      throw ClairAgentError.lifecycleConflict(sessionID, state: session.lifecycle)
    }
    return try await relaunchExisting(sessionID: sessionID, provider: provider)
  }

  public func restart(
    identity: ClairAgentSessionIdentity
  ) async throws -> ClairAgentSessionSnapshot {
    try ensureLifecycleAdmission()
    guard let session = sessions[identity.sessionID], session.identity == identity else {
      throw ClairAgentError.staleSession(identity.sessionID)
    }
    return try await restart(sessionID: identity.sessionID)
  }

  public func session(
    sessionID: SessionID
  ) throws -> ClairAgentSessionSnapshot {
    guard let session = sessions[sessionID] else {
      throw ClairAgentError.sessionNotFound(sessionID)
    }
    return session.snapshot()
  }

  public func allSessions() -> [ClairAgentSessionSnapshot] {
    sessions.values
      .map { $0.snapshot() }
      .sorted { lhs, rhs in lhs.identity.sessionID.rawValue < rhs.identity.sessionID.rawValue }
  }

  /// Daemon composition obtains the exact live generation's raw endpoint.
  /// Surfaces do not own or launch a process through this seam.
  public func terminalProcess(for snapshot: ClairAgentSessionSnapshot) throws
    -> any ClairTerminalProcess
  {
    guard let session = sessions[snapshot.identity.sessionID],
      session.identity == snapshot.identity,
      session.processGeneration == snapshot.processGeneration,
      session.lifecycle == .running, let process = session.process as? any ClairTerminalProcess
    else { throw ClairTerminalError.staleSession }
    return process
  }

  /// Installs the composition-layer hook used by H10 to propagate provider
  /// exits into H06/H08. The callback is non-async and must only schedule work;
  /// it is never invoked while an H04 process transition is awaiting another
  /// actor.
  public func setLifecycleObserver(
    _ observer: (@Sendable (ClairAgentSessionSnapshot) -> Void)?
  ) {
    lifecycleObserver = observer
  }

  public func status(for sessionID: SessionID) throws -> ClairAgentSessionSnapshot {
    try session(sessionID: sessionID)
  }

  /// Sends a provider signal without parsing provider output. An interrupt is
  /// an external lifecycle event unless the provider actually terminates; a
  /// terminate signal is recorded as an intentional Clair stop by the process
  /// boundary.
  public func signal(
    sessionID: SessionID,
    signal: ClairAgentSignal
  ) async throws -> ClairAgentSessionSnapshot {
    guard let session = sessions[sessionID] else {
      throw ClairAgentError.staleSession(sessionID)
    }
    guard session.lifecycle == .running, let process = session.process else {
      throw ClairAgentError.processNotRunning
    }
    do {
      try await process.send(signal: signal)
    } catch let error as ClairAgentError {
      throw error
    } catch {
      throw ClairAgentError.signalFailed
    }
    return sessions[sessionID]?.snapshot() ?? session.snapshot()
  }

  public func rawOutput(
    for sessionID: SessionID
  ) async throws -> ClairAgentRawOutput {
    guard let session = sessions[sessionID] else {
      throw ClairAgentError.staleSession(sessionID)
    }
    if let process = session.process {
      return boundedRawOutput(await process.rawOutput())
    }
    return session.rawOutput
  }

  /// Retries force cleanup for a session whose previous termination attempt
  /// could not prove that its process handle and descendants were gone.
  public func retryCleanup(
    sessionID: SessionID
  ) async throws -> ClairAgentSessionSnapshot {
    guard let session = sessions[sessionID] else {
      throw ClairAgentError.staleSession(sessionID)
    }
    guard session.lifecycle == .cleanupPending, let process = session.process else {
      return session.snapshot()
    }
    return try await retryCleanup(
      sessionID: sessionID,
      process: process,
      processGeneration: session.processGeneration
    )
  }

  /// Stops every live provider in deterministic session-ID order. The daemon
  /// owns the call at shutdown; keeping it explicit avoids relying on an
  /// asynchronous actor deinitializer for child-process cleanup.
  public func shutdown() async {
    while true {
      if let activeFence = shutdownFence {
        while shutdownFence == activeFence {
          try? await Task.sleep(nanoseconds: 1_000_000)
        }
        continue
      }

      nextShutdownGeneration =
        nextShutdownGeneration == UInt64.max ? 1 : nextShutdownGeneration + 1
      let fence = nextShutdownGeneration
      shutdownFence = fence
      defer {
        if shutdownFence == fence {
          shutdownFence = nil
        }
      }

      while true {
        let liveSessionIDs = sessions.values
          .filter {
            switch $0.lifecycle {
            case .starting, .running, .stopping, .upgrading, .cleanupPending:
              true
            case .stopped, .exited, .failed:
              false
            }
          }
          .map { $0.identity.sessionID }
          .sorted { $0.rawValue < $1.rawValue }
        guard !liveSessionIDs.isEmpty else { return }

        for sessionID in liveSessionIDs {
          guard let session = sessions[sessionID] else { continue }
          switch session.lifecycle {
          case .running:
            _ = try? await stopRunning(sessionID: sessionID, forRestart: false)
          case .cleanupPending:
            _ = try? await retryCleanup(sessionID: sessionID)
          case .starting, .stopping, .upgrading, .stopped, .exited, .failed:
            break
          }
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
      }
    }
  }

  /// Replaces a provider adapter only through an explicit lifecycle operation.
  /// The session ID and Project/Worktree target remain stable, while the
  /// recorded provider identity changes to the requested version.
  public func upgrade(
    sessionID: SessionID,
    to provider: any ClairAgentProviderAdapter
  ) async throws -> ClairAgentSessionSnapshot {
    try ensureLifecycleAdmission()
    guard let session = sessions[sessionID] else {
      throw ClairAgentError.staleSession(sessionID)
    }
    guard provider.identity.providerID == session.identity.provider.providerID else {
      throw ClairAgentError.providerIdentityMismatch(
        expected: session.identity.provider,
        actual: provider.identity
      )
    }
    guard session.lifecycle != .starting,
      session.lifecycle != .stopping,
      session.lifecycle != .upgrading,
      session.lifecycle != .cleanupPending
    else {
      throw ClairAgentError.lifecycleConflict(sessionID, state: session.lifecycle)
    }

    let upgradedIdentity = try ClairAgentSessionIdentity(
      provider: provider.identity,
      projectID: session.identity.projectID,
      worktreeID: session.identity.worktreeID,
      sessionID: sessionID
    )

    var upgrading = session
    upgrading.lifecycle = .upgrading
    sessions[sessionID] = upgrading
    if session.lifecycle == .running {
      _ = try await stopRunning(
        sessionID: sessionID,
        forRestart: false,
        reservedLifecycle: .upgrading
      )
    }

    providers[provider.identity.providerID] = provider
    return try await launch(
      identity: upgradedIdentity,
      provider: provider,
      lifecycle: .starting
    )
  }

  public func upgradeProvider(
    sessionID: SessionID,
    to provider: any ClairAgentProviderAdapter
  ) async throws -> ClairAgentSessionSnapshot {
    try await upgrade(sessionID: sessionID, to: provider)
  }

  private func validateResumeProvider(for session: ManagedSession) throws {
    let recorded = session.identity.provider
    guard let provider = providers[recorded.providerID] else {
      throw ClairAgentError.providerNotFound(recorded.providerID)
    }
    let requested = provider.identity
    guard requested.providerID == recorded.providerID else {
      throw ClairAgentError.providerIdentityMismatch(
        expected: recorded,
        actual: requested
      )
    }
    guard requested.version == recorded.version else {
      throw ClairAgentError.providerUpgradeRequired(
        sessionID: session.identity.sessionID,
        recorded: recorded,
        requested: requested
      )
    }
  }

  private func relaunchExisting(
    sessionID: SessionID,
    provider: any ClairAgentProviderAdapter
  ) async throws -> ClairAgentSessionSnapshot {
    guard let session = sessions[sessionID] else {
      throw ClairAgentError.staleSession(sessionID)
    }
    guard session.lifecycle != .starting,
      session.lifecycle != .running,
      session.lifecycle != .stopping,
      session.lifecycle != .upgrading,
      session.lifecycle != .cleanupPending
    else {
      throw ClairAgentError.duplicateLaunch(sessionID)
    }
    return try await launch(
      identity: session.identity,
      provider: provider,
      lifecycle: .starting
    )
  }

  private func launch(
    identity: ClairAgentSessionIdentity,
    provider: any ClairAgentProviderAdapter,
    lifecycle: ClairAgentLifecycleState
  ) async throws -> ClairAgentSessionSnapshot {
    let workingDirectoryCapability: ClairWorkspaceRootCapability
    do {
      workingDirectoryCapability = try validatedWorkingDirectory(for: identity.target)
    } catch {
      if var existing = sessions[identity.sessionID] {
        existing.lifecycle = .failed
        existing.failure = .launchFailed
        sessions[identity.sessionID] = existing
      }
      throw error
    }
    let workingDirectoryURL = workingDirectoryCapability.rootURL.standardizedFileURL
    #if os(macOS)
      let directoryDescriptor: Int32
      do {
        directoryDescriptor = try workingDirectoryCapability.duplicateDescriptor()
      } catch let error as ClairWorkspaceError {
        let typedError = workingDirectoryError(from: error)
        recordLaunchFailure(
          identity: identity,
          workingDirectoryURL: workingDirectoryURL,
          error: typedError
        )
        throw typedError
      } catch {
        let typedError = ClairAgentError.workingDirectoryDescriptorUnavailable(
          workingDirectoryURL
        )
        recordLaunchFailure(
          identity: identity,
          workingDirectoryURL: workingDirectoryURL,
          error: typedError
        )
        throw typedError
      }
      defer { Darwin.close(directoryDescriptor) }
    #endif

    let spec: ClairAgentLaunchSpec
    do {
      spec = try provider.makeLaunchSpec(
        for: identity,
        workingDirectoryURL: workingDirectoryURL,
        limits: limits
      )
    } catch let error as ClairAgentError {
      recordLaunchFailure(
        identity: identity,
        workingDirectoryURL: workingDirectoryURL,
        error: error
      )
      throw error
    } catch {
      recordLaunchFailure(
        identity: identity,
        workingDirectoryURL: workingDirectoryURL,
        error: .invalidLaunchSpec
      )
      throw ClairAgentError.invalidLaunchSpec
    }
    do {
      try spec.validate(limits: limits)
      try validateExecutable(at: spec.executableURL)
    } catch let error as ClairAgentError {
      recordLaunchFailure(
        identity: identity,
        workingDirectoryURL: workingDirectoryURL,
        error: error
      )
      throw error
    } catch {
      recordLaunchFailure(
        identity: identity,
        workingDirectoryURL: workingDirectoryURL,
        error: .invalidLaunchSpec
      )
      throw ClairAgentError.invalidLaunchSpec
    }
    guard normalizedURL(spec.workingDirectoryURL) == normalizedURL(workingDirectoryURL) else {
      let error = ClairAgentError.workingDirectoryMismatch(
        expected: workingDirectoryURL,
        actual: spec.workingDirectoryURL
      )
      recordLaunchFailure(
        identity: identity,
        workingDirectoryURL: workingDirectoryURL,
        error: error
      )
      throw error
    }

    #if os(macOS)
      let runtimeSpec = spec.attachingWorkingDirectoryDescriptor(
        directoryDescriptor,
        device: workingDirectoryCapability.device,
        inode: workingDirectoryCapability.inode
      )
    #else
      let runtimeSpec = spec
    #endif

    nextProcessGeneration =
      nextProcessGeneration == UInt64.max ? 1 : nextProcessGeneration + 1
    let processGeneration = nextProcessGeneration
    sessions[identity.sessionID] = ManagedSession(
      identity: identity,
      workingDirectoryURL: workingDirectoryURL,
      lifecycle: lifecycle,
      process: nil,
      processGeneration: processGeneration,
      exit: nil,
      failure: nil,
      rawOutput: ClairAgentRawOutput()
    )

    do {
      let process: any ClairAgentProcess
      do {
        process = try withExtendedLifetime(workingDirectoryCapability) {
          try provider.makeProcess(
            spec: runtimeSpec,
            onTermination: { [weak self] processExit in
              Task { [weak self] in
                await self?.processDidExit(
                  sessionID: identity.sessionID,
                  processGeneration: processGeneration,
                  processExit: processExit
                )
              }
            }
          )
        }
      } catch let error as ClairAgentError {
        throw error
      } catch {
        throw ClairAgentError.processCreationFailed
      }
      guard let current = sessions[identity.sessionID],
        current.processGeneration == processGeneration
      else {
        throw ClairAgentError.staleSession(identity.sessionID)
      }
      var starting = current
      starting.process = process
      sessions[identity.sessionID] = starting
      let startOutcome = try process.start()
      guard var running = sessions[identity.sessionID],
        running.processGeneration == processGeneration
      else {
        do {
          _ = try await process.forceTerminate()
          guard !process.hasPendingCleanup else {
            throw ClairAgentError.processTerminationFailed
          }
        } catch let error as ClairAgentError {
          throw error
        } catch {
          throw ClairAgentError.processTerminationFailed
        }
        throw ClairAgentError.staleSession(identity.sessionID)
      }
      switch startOutcome {
      case .terminated(let processExit):
        // Classify a synchronous/immediate exit before publishing .running;
        // the callback is allowed to arrive later without changing the result.
        await processDidExit(
          sessionID: identity.sessionID,
          processGeneration: processGeneration,
          processExit: processExit
        )
        guard let terminated = sessions[identity.sessionID],
          terminated.processGeneration == processGeneration
        else {
          throw ClairAgentError.staleSession(identity.sessionID)
        }
        return terminated.snapshot()
      case .running:
        guard running.process != nil else {
          return running.snapshot()
        }
        running.lifecycle = .running
        sessions[identity.sessionID] = running
        return running.snapshot()
      }
    } catch let originalError as ClairAgentError {
      if let process = sessions[identity.sessionID]?.process {
        do {
          _ = try await process.forceTerminate()
          guard !process.hasPendingCleanup else {
            throw ClairAgentError.processTerminationFailed
          }
        } catch {
          recordCleanupPending(
            sessionID: identity.sessionID,
            processGeneration: processGeneration,
            process: process
          )
          throw originalError
        }
      }
      recordLaunchFailure(
        identity: identity,
        workingDirectoryURL: workingDirectoryURL,
        error: originalError
      )
      throw originalError
    } catch {
      if let process = sessions[identity.sessionID]?.process {
        do {
          _ = try await process.forceTerminate()
          guard !process.hasPendingCleanup else {
            throw ClairAgentError.processTerminationFailed
          }
        } catch {
          recordCleanupPending(
            sessionID: identity.sessionID,
            processGeneration: processGeneration,
            process: process
          )
          throw ClairAgentError.processLaunchFailed
        }
      }
      recordLaunchFailure(
        identity: identity,
        workingDirectoryURL: workingDirectoryURL,
        error: .processLaunchFailed
      )
      throw ClairAgentError.processLaunchFailed
    }
  }

  private func stopRunning(
    sessionID: SessionID,
    forRestart: Bool,
    reservedLifecycle: ClairAgentLifecycleState? = nil
  ) async throws -> ClairAgentSessionSnapshot {
    guard let session = sessions[sessionID],
      session.lifecycle == .running || session.lifecycle == .upgrading,
      let process = session.process
    else {
      guard let session = sessions[sessionID] else {
        throw ClairAgentError.staleSession(sessionID)
      }
      return session.snapshot()
    }

    var stopping = session
    stopping.lifecycle = .stopping
    sessions[sessionID] = stopping
    let generation = session.processGeneration
    do {
      let processExit = try await process.terminate(
        gracePeriod: limits.terminationGracePeriod
      )
      return try await finalizeTermination(
        sessionID: sessionID,
        processGeneration: generation,
        process: process,
        processExit: processExit,
        forRestart: forRestart,
        reservedLifecycle: reservedLifecycle
      )
    } catch let originalError as ClairAgentError {
      do {
        let forcedExit = try await process.forceTerminate()
        guard !process.hasPendingCleanup else {
          throw ClairAgentError.processTerminationFailed
        }
        return try await finalizeTermination(
          sessionID: sessionID,
          processGeneration: generation,
          process: process,
          processExit: forcedExit,
          forRestart: forRestart,
          reservedLifecycle: reservedLifecycle
        )
      } catch {
        recordCleanupPending(
          sessionID: sessionID,
          processGeneration: generation,
          process: process
        )
        throw originalError
      }
    } catch {
      do {
        let forcedExit = try await process.forceTerminate()
        guard !process.hasPendingCleanup else {
          throw ClairAgentError.processTerminationFailed
        }
        return try await finalizeTermination(
          sessionID: sessionID,
          processGeneration: generation,
          process: process,
          processExit: forcedExit,
          forRestart: forRestart,
          reservedLifecycle: reservedLifecycle
        )
      } catch {
        recordCleanupPending(
          sessionID: sessionID,
          processGeneration: generation,
          process: process
        )
        throw ClairAgentError.processTerminationFailed
      }
    }
  }

  private func finalizeTermination(
    sessionID: SessionID,
    processGeneration: UInt64,
    process: any ClairAgentProcess,
    processExit: ClairAgentProcessExit,
    forRestart: Bool,
    reservedLifecycle: ClairAgentLifecycleState?
  ) async throws -> ClairAgentSessionSnapshot {
    guard var current = sessions[sessionID],
      current.processGeneration == processGeneration
    else {
      throw ClairAgentError.staleSession(sessionID)
    }
    guard !process.hasPendingCleanup else {
      throw ClairAgentError.processTerminationFailed
    }
    current.process = nil
    current.rawOutput = boundedRawOutput(await process.rawOutput())
    current.exit = try ClairAgentExit(processExit: processExit)
    if let reservedLifecycle {
      current.lifecycle = reservedLifecycle
      current.failure = nil
    } else if processExit.wasForceTerminated {
      current.lifecycle = .stopped
      current.failure = .forcedTermination
    } else if processExit.wasRequestedByClair {
      current.lifecycle = forRestart ? .starting : .stopped
      current.failure = nil
    } else if current.exit?.reason == .normal {
      current.lifecycle = .exited
      current.failure = nil
    } else if current.exit?.reason == .signal {
      current.lifecycle = .failed
      current.failure = .signaledExit
    } else {
      current.lifecycle = .failed
      current.failure = .abnormalExit
    }
    sessions[sessionID] = current
    return current.snapshot()
  }

  private func retryCleanup(
    sessionID: SessionID,
    process: any ClairAgentProcess,
    processGeneration: UInt64
  ) async throws -> ClairAgentSessionSnapshot {
    do {
      let processExit = try await process.forceTerminate()
      guard !process.hasPendingCleanup else {
        throw ClairAgentError.processTerminationFailed
      }
      guard let current = sessions[sessionID],
        current.processGeneration == processGeneration,
        current.process != nil
      else {
        guard let current = sessions[sessionID] else {
          throw ClairAgentError.staleSession(sessionID)
        }
        return current.snapshot()
      }
      return try await finalizeTermination(
        sessionID: sessionID,
        processGeneration: processGeneration,
        process: process,
        processExit: processExit,
        forRestart: false,
        reservedLifecycle: nil
      )
    } catch let error as ClairAgentError {
      recordCleanupPending(
        sessionID: sessionID,
        processGeneration: processGeneration,
        process: process
      )
      throw error
    } catch {
      recordCleanupPending(
        sessionID: sessionID,
        processGeneration: processGeneration,
        process: process
      )
      throw ClairAgentError.processTerminationFailed
    }
  }

  private func processDidExit(
    sessionID: SessionID,
    processGeneration: UInt64,
    processExit: ClairAgentProcessExit
  ) async {
    guard let session = sessions[sessionID],
      session.processGeneration == processGeneration,
      let process = session.process
    else {
      return
    }
    let rawOutput = await process.rawOutput()
    if process.hasPendingCleanup {
      do {
        _ = try await process.forceTerminate()
        guard !process.hasPendingCleanup else {
          throw ClairAgentError.processTerminationFailed
        }
      } catch {
        guard var pending = sessions[sessionID],
          pending.processGeneration == processGeneration,
          pending.process != nil
        else {
          return
        }
        pending.rawOutput = boundedRawOutput(rawOutput)
        pending.lifecycle = .cleanupPending
        pending.failure = .cleanupPending
        sessions[sessionID] = pending
        lifecycleObserver?(pending.snapshot())
        return
      }
    }
    guard var current = sessions[sessionID],
      current.processGeneration == processGeneration,
      current.process != nil
    else {
      return
    }
    guard let exit = try? ClairAgentExit(processExit: processExit) else {
      // An invalid callback is not proof that the provider or its descendants
      // are gone. Retain the opaque process handle, force the ownership-proof
      // cleanup path, and release the handle only after group kill and reap
      // have completed. A failed cleanup remains retryable and visible.
      current.rawOutput = boundedRawOutput(rawOutput)
      current.lifecycle = .cleanupPending
      current.failure = .cleanupPending
      sessions[sessionID] = current
      do {
        _ = try await process.forceTerminate()
        guard !process.hasPendingCleanup else {
          throw ClairAgentError.processTerminationFailed
        }
        guard var failed = sessions[sessionID],
          failed.processGeneration == processGeneration,
          failed.process != nil
        else {
          return
        }
        failed.process = nil
        failed.rawOutput = boundedRawOutput(rawOutput)
        failed.lifecycle = .failed
        failed.failure = .abnormalExit
        sessions[sessionID] = failed
        lifecycleObserver?(failed.snapshot())
      } catch {
        recordCleanupPending(
          sessionID: sessionID,
          processGeneration: processGeneration,
          process: process
        )
        if let pending = sessions[sessionID] {
          lifecycleObserver?(pending.snapshot())
        }
      }
      return
    }
    current.process = nil
    current.rawOutput = boundedRawOutput(rawOutput)
    current.exit = exit
    if processExit.wasForceTerminated {
      current.lifecycle = .stopped
      current.failure = .forcedTermination
    } else if processExit.wasRequestedByClair {
      current.lifecycle = current.lifecycle == .upgrading ? .upgrading : .stopped
      current.failure = nil
    } else if exit.reason == .normal {
      current.lifecycle = .exited
      current.failure = nil
    } else if exit.reason == .signal {
      current.lifecycle = .failed
      current.failure = .signaledExit
    } else {
      current.lifecycle = .failed
      current.failure = .abnormalExit
    }
    sessions[sessionID] = current
    lifecycleObserver?(current.snapshot())
  }

  private func recordLaunchFailure(
    identity: ClairAgentSessionIdentity,
    workingDirectoryURL: URL,
    error: ClairAgentError
  ) {
    let failure: ClairAgentFailure =
      switch error {
      case .processTerminationFailed:
        .terminationFailed
      default:
        .launchFailed
      }
    sessions[identity.sessionID] = ManagedSession(
      identity: identity,
      workingDirectoryURL: workingDirectoryURL,
      lifecycle: .failed,
      process: nil,
      processGeneration: nextProcessGeneration,
      exit: nil,
      failure: failure,
      rawOutput: ClairAgentRawOutput()
    )
  }

  private func recordCleanupPending(
    sessionID: SessionID,
    processGeneration: UInt64,
    process: any ClairAgentProcess
  ) {
    guard var current = sessions[sessionID],
      current.processGeneration == processGeneration,
      current.process != nil
    else {
      return
    }
    current.process = process
    current.lifecycle = .cleanupPending
    current.failure = .cleanupPending
    sessions[sessionID] = current
  }

  private func validatedWorkingDirectory(
    for target: ClairAgentTarget
  ) throws -> ClairWorkspaceRootCapability {
    do {
      return try workspace.launchRootCapability(
        projectID: target.projectID,
        worktreeID: target.worktreeID
      )
    } catch let error as ClairWorkspaceError {
      throw workingDirectoryError(from: error)
    } catch {
      throw ClairAgentError.unsupportedPlatform
    }
  }

  private func workingDirectoryError(from error: ClairWorkspaceError) -> ClairAgentError {
    switch error {
    case .rootIdentityChanged(let changedURL):
      return .workingDirectoryChanged(changedURL.standardizedFileURL)
    case .rootCapabilityUnavailable(let unavailableURL):
      return .workingDirectoryDescriptorUnavailable(unavailableURL.standardizedFileURL)
    default:
      return .workspace(error)
    }
  }

  private func normalizedURL(_ url: URL) -> URL {
    url.standardizedFileURL
  }

  private func ensureLifecycleAdmission() throws {
    guard shutdownFence == nil else {
      throw ClairAgentError.shutdownInProgress
    }
  }

  private func validateExecutable(at url: URL) throws {
    guard url.isFileURL,
      url.path.hasPrefix("/"),
      !url.path.contains("\0")
    else {
      throw ClairAgentError.invalidLaunchSpec
    }
    let fileManager = FileManager.default
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw ClairAgentError.missingExecutable(url.standardizedFileURL)
    }
    guard !isDirectory.boolValue, fileManager.isExecutableFile(atPath: url.path) else {
      throw ClairAgentError.executableNotExecutable(url.standardizedFileURL)
    }
  }

  private func boundedRawOutput(_ output: ClairAgentRawOutput) -> ClairAgentRawOutput {
    let maximumBytes = limits.maximumOutputBytes
    let stdout = Data(output.stdout.prefix(maximumBytes))
    let remaining = maximumBytes - stdout.count
    let stderr = Data(output.stderr.prefix(max(0, remaining)))
    return ClairAgentRawOutput(
      stdout: stdout,
      stderr: stderr,
      isTruncated: output.isTruncated
        || stdout.count != output.stdout.count
        || stderr.count != output.stderr.count
    )
  }

  private func makeSessionID() -> SessionID {
    while true {
      if let sessionID = try? SessionID(UUID().uuidString.lowercased()),
        sessions[sessionID] == nil
      {
        return sessionID
      }
    }
  }
}
