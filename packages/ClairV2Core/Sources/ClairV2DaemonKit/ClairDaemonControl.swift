#if os(macOS)

  import Darwin
  import Foundation

  import ClairV2Shared

  public enum ClairDaemonLifecycleState: String, Codable, Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
  }

  public struct ClairDaemonVersion: Codable, Equatable, Sendable {
    public let product: String
    public let version: String
    public let protocolOffer: ProtocolOffer

    public init(
      product: String = "ClairDaemon",
      version: String = ClairV2DaemonModule.foundationVersion,
      protocolOffer: ProtocolOffer = .current
    ) {
      self.product = product
      self.version = version
      self.protocolOffer = protocolOffer
    }

    public static let current = Self()

    private enum CodingKeys: String, CodingKey {
      case product
      case version
      case protocolOffer = "protocol_offer"
    }
  }

  public enum ClairDaemonHealthStatus: String, Codable, Equatable, Sendable {
    case healthy
    case stopping
    case stopped
  }

  public struct ClairDaemonHealth: Codable, Equatable, Sendable {
    public let status: ClairDaemonHealthStatus
    public let lifecycle: ClairDaemonLifecycleState
    public let processID: Int32
    public let version: ClairDaemonVersion
    public let uptimeSeconds: UInt64

    public init(
      status: ClairDaemonHealthStatus,
      lifecycle: ClairDaemonLifecycleState,
      processID: Int32,
      version: ClairDaemonVersion,
      uptimeSeconds: UInt64
    ) {
      self.status = status
      self.lifecycle = lifecycle
      self.processID = processID
      self.version = version
      self.uptimeSeconds = uptimeSeconds
    }

    private enum CodingKeys: String, CodingKey {
      case status
      case lifecycle
      case processID = "process_id"
      case version
      case uptimeSeconds = "uptime_seconds"
    }
  }

  public struct ClairDaemonPaths: Equatable, Sendable {
    public let directoryURL: URL
    public let socketURL: URL
    public let lockURL: URL

    public init(directoryURL: URL) {
      let directory = directoryURL.standardizedFileURL
      self.directoryURL = directory
      self.socketURL = directory.appendingPathComponent("control.sock", isDirectory: false)
      self.lockURL = directory.appendingPathComponent("daemon.lock", isDirectory: false)
    }

    public static var `default`: Self {
      let applicationSupport =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
      return Self(
        directoryURL:
          applicationSupport
          .appendingPathComponent("Clair", isDirectory: true)
          .appendingPathComponent("v2", isDirectory: true)
      )
    }
  }

  public struct ClairDaemonConfiguration: Equatable, Sendable {
    public let paths: ClairDaemonPaths
    public let frameLimits: FrameLimits
    public let version: ClairDaemonVersion

    public init(
      paths: ClairDaemonPaths = .default,
      frameLimits: FrameLimits = .standard,
      version: ClairDaemonVersion = .current
    ) throws {
      guard frameLimits.maximumPayloadBytes <= version.protocolOffer.maximumFramePayloadBytes else {
        throw ClairDaemonError.invalidConfiguration
      }
      self.paths = paths
      self.frameLimits = frameLimits
      self.version = version
    }
  }

  public enum ClairDaemonControlRequest: Codable, Equatable, Sendable {
    case health
    case version
    case shutdown

    private enum Kind: String, Codable {
      case health
      case version
      case shutdown
    }

    private enum CodingKeys: String, CodingKey {
      case kind
    }

    private var kind: Kind {
      switch self {
      case .health:
        .health
      case .version:
        .version
      case .shutdown:
        .shutdown
      }
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      switch try container.decode(Kind.self, forKey: .kind) {
      case .health:
        self = .health
      case .version:
        self = .version
      case .shutdown:
        self = .shutdown
      }
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(kind, forKey: .kind)
    }
  }

  public enum ClairDaemonControlFailureCode: String, Codable, Equatable, Sendable {
    case malformedRequest = "malformed_request"
    case frameTooLarge = "frame_too_large"
    case truncatedFrame = "truncated_frame"
    case trailingFrame = "trailing_frame"
    case requestTimedOut = "request_timed_out"
    case unsupportedRequest = "unsupported_request"
    case notRunning = "not_running"
    case stopping = "stopping"
    case internalFailure = "internal_failure"
  }

  public struct ClairDaemonControlFailure: Codable, Equatable, Sendable {
    public let code: ClairDaemonControlFailureCode
    public let retryable: Bool

    public init(
      code: ClairDaemonControlFailureCode,
      retryable: Bool = false
    ) {
      self.code = code
      self.retryable = retryable
    }
  }

  public enum ClairDaemonControlResponse: Codable, Equatable, Sendable {
    case health(ClairDaemonHealth)
    case version(ClairDaemonVersion)
    case shutdownAccepted
    case failure(ClairDaemonControlFailure)

    private enum Kind: String, Codable {
      case health
      case version
      case shutdownAccepted = "shutdown_accepted"
      case failure
    }

    private enum CodingKeys: String, CodingKey {
      case kind
      case health
      case version
      case failure
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      switch try container.decode(Kind.self, forKey: .kind) {
      case .health:
        self = .health(try container.decode(ClairDaemonHealth.self, forKey: .health))
      case .version:
        self = .version(try container.decode(ClairDaemonVersion.self, forKey: .version))
      case .shutdownAccepted:
        self = .shutdownAccepted
      case .failure:
        self = .failure(try container.decode(ClairDaemonControlFailure.self, forKey: .failure))
      }
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .health(let health):
        try container.encode(Kind.health, forKey: .kind)
        try container.encode(health, forKey: .health)
      case .version(let version):
        try container.encode(Kind.version, forKey: .kind)
        try container.encode(version, forKey: .version)
      case .shutdownAccepted:
        try container.encode(Kind.shutdownAccepted, forKey: .kind)
      case .failure(let failure):
        try container.encode(Kind.failure, forKey: .kind)
        try container.encode(failure, forKey: .failure)
      }
    }
  }

  public enum ClairDaemonError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case alreadyRunning
    case lockUnavailable
    case lockPathOccupied
    case lockNotPrivate
    case controlSocketMissing
    case controlSocketOccupied
    case controlSocketNotPrivate
    case controlSocketPathTooLong
    case controlSocketSetup(String)
    case requestTooLarge(Int)
    case responseTooLarge(Int)
    case malformedRequest
    case malformedResponse
    case transportClosed
    case transportTimedOut
    case invalidFrame(ProtocolError)
    case remoteFailure(ClairDaemonControlFailureCode)
    case unexpectedResponse
    case cleanupFailed

    public var errorDescription: String? {
      switch self {
      case .invalidConfiguration:
        "The Clair daemon configuration is invalid."
      case .alreadyRunning:
        "Another Clair daemon already owns the runtime."
      case .lockUnavailable:
        "The Clair daemon runtime lock could not be acquired."
      case .lockPathOccupied:
        "The Clair daemon lock path is occupied by an unsafe file."
      case .lockNotPrivate:
        "The Clair daemon lock must be owner-only."
      case .controlSocketMissing:
        "The Clair daemon control socket is not available."
      case .controlSocketOccupied:
        "The Clair daemon control socket path is occupied by a non-socket file."
      case .controlSocketNotPrivate:
        "The Clair daemon control socket must be owner-only."
      case .controlSocketPathTooLong:
        "The Clair daemon control socket path is too long."
      case .controlSocketSetup(let message):
        "The Clair daemon control socket could not be started: \(message)"
      case .requestTooLarge(let size):
        "The Clair daemon control request is too large: \(size) bytes."
      case .responseTooLarge(let size):
        "The Clair daemon control response is too large: \(size) bytes."
      case .malformedRequest:
        "The Clair daemon control request is malformed."
      case .malformedResponse:
        "The Clair daemon returned a malformed control response."
      case .transportClosed:
        "The Clair daemon control channel closed unexpectedly."
      case .transportTimedOut:
        "The Clair daemon control channel timed out."
      case .invalidFrame(let error):
        error.localizedDescription
      case .remoteFailure(let code):
        "The Clair daemon rejected the control request: \(code.rawValue)."
      case .unexpectedResponse:
        "The Clair daemon returned an unexpected control response."
      case .cleanupFailed:
        "The Clair daemon could not safely clean up its control socket."
      }
    }
  }

  public struct ClairDaemonControlClient: Sendable {
    public let paths: ClairDaemonPaths
    public let frameLimits: FrameLimits

    public init(
      paths: ClairDaemonPaths,
      frameLimits: FrameLimits = .standard
    ) {
      self.paths = paths
      self.frameLimits = frameLimits
    }

    public func request(
      _ request: ClairDaemonControlRequest
    ) throws -> ClairDaemonControlResponse {
      let descriptor = try ClairDaemonSocketSupport.connect(
        to: paths,
        timeout: ClairDaemonSocketSupport.controlTimeout
      )
      defer { Darwin.close(descriptor) }

      let payload = try ProtocolCodec.encode(request)
      let frame: Data
      do {
        frame = try BoundedFrame(payload: payload, limits: frameLimits).encoded
      } catch let error as ProtocolError {
        throw ClairDaemonError.invalidFrame(error)
      }
      try ClairDaemonSocketSupport.writeAll(frame, to: descriptor)
      _ = Darwin.shutdown(descriptor, SHUT_WR)

      let responseFrames = try ClairDaemonSocketSupport.readFrames(
        from: descriptor,
        limits: frameLimits,
        direction: .response
      )
      guard responseFrames.count == 1 else {
        throw ClairDaemonError.malformedResponse
      }
      do {
        return try ProtocolCodec.decode(
          ClairDaemonControlResponse.self,
          from: responseFrames[0].payload,
          limits: frameLimits
        )
      } catch let error as ProtocolError {
        throw ClairDaemonError.invalidFrame(error)
      } catch {
        throw ClairDaemonError.malformedResponse
      }
    }

    public func health() throws -> ClairDaemonHealth {
      switch try request(.health) {
      case .health(let health):
        return health
      case .failure(let failure):
        throw ClairDaemonError.remoteFailure(failure.code)
      default:
        throw ClairDaemonError.unexpectedResponse
      }
    }

    public func version() throws -> ClairDaemonVersion {
      switch try request(.version) {
      case .version(let version):
        return version
      case .failure(let failure):
        throw ClairDaemonError.remoteFailure(failure.code)
      default:
        throw ClairDaemonError.unexpectedResponse
      }
    }

    public func shutdown() throws {
      switch try request(.shutdown) {
      case .shutdownAccepted:
        return
      case .failure(let failure):
        throw ClairDaemonError.remoteFailure(failure.code)
      default:
        throw ClairDaemonError.unexpectedResponse
      }
    }
  }

#endif
