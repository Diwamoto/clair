import ClairAgent
import ClairPush
import ClairShared
import ClairTerminal
import ClairWorkspace
import CryptoKit
import Foundation
import Network
import Security

// N11 (ADR-0016): the remote client wire. One TLS 1.3 connection is one
// `ClairNativeTransportChannel`; every unit on it is a `BoundedFrame`. A request
// frame is JSON (`ClairRemoteRequest`); `terminalInput` is followed by one raw
// frame holding the input bytes, and a `terminalFrame` reply is followed by one
// `ClairTerminalFrame.encoded()` frame, so terminal bytes never go through JSON.
// Authentication and authorization stay with `ClairPairingAuthority`: the host
// never reads a connection value from the wire, it uses the one bound to the channel.

public enum ClairRemoteWire {
  /// Control JSON and raw terminal frames share one bound per frame.
  public static let limits = try! FrameLimits(maximumPayloadBytes: 256 * 1024)
  public static let maximumReadWaitMilliseconds: UInt32 = 25_000
}

public enum ClairRemoteCall: Codable, Equatable, Sendable {
  // Before authentication.
  case presentation
  case pair(ClairPairingRequest)
  case beginAuthentication(ClairReconnectRequest)
  case authenticate(ClairChallengeProof)
  // After authentication; the host applies them to the channel's own connection.
  case authorizeRead(ResourceScope)
  case terminalAttach(
    scope: ResourceScope, generation: UInt64, subscriberID: UUID, cursor: ClairTerminalCursor?)
  /// Long-poll: waits up to `waitMilliseconds` (capped) for output.
  case terminalRead(attachment: UUID, waitMilliseconds: UInt32)
  case terminalAcknowledge(attachment: UUID, cursor: ClairTerminalCursor)
  case terminalDetach(attachment: UUID)
  /// N10: live terminal sessions this device may attach to.
  case terminalSessions
  /// Followed by one raw frame carrying the input bytes.
  case terminalInput(
    operationID: OperationID, scope: ResourceScope, epoch: SessionEpoch, processGeneration: UInt64)
  case agentDispatch(ClairAgentCommand)
  case workspaceChangedFiles(ResourceScope)
  case workspaceDiff(scope: ResourceScope, path: ClairWorkspacePath, basis: ClairGitDiffBasis)
  case sessionVerify(scope: ResourceScope, cachedCursor: ReplayCursor?)
  case pushRegister(token: Data, environment: ClairPushEnvironment, scope: ResourceScope)
  case pushUnregister(ClairPushEnvironment)

  public var requiresAuthentication: Bool {
    switch self {
    case .presentation, .pair, .beginAuthentication, .authenticate: false
    default: true
    }
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.presentation, .presentation):
      return true
    case (.pair(let left), .pair(let right)):
      return left == right
    case (.beginAuthentication(let left), .beginAuthentication(let right)):
      return left == right
    case (.authenticate(let left), .authenticate(let right)):
      return left == right
    case (.authorizeRead(let left), .authorizeRead(let right)):
      return left == right
    case (
      .terminalAttach(let ls, let lg, let li, let lc),
      .terminalAttach(let rs, let rg, let ri, let rc)
    ):
      return ls == rs && lg == rg && li == ri && lc == rc
    case (
      .terminalRead(let la, let lw),
      .terminalRead(let ra, let rw)
    ):
      return la == ra && lw == rw
    case (
      .terminalAcknowledge(let la, let lc),
      .terminalAcknowledge(let ra, let rc)
    ):
      return la == ra && lc == rc
    case (.terminalDetach(let left), .terminalDetach(let right)):
      return left == right
    case (.terminalSessions, .terminalSessions):
      return true
    case (
      .terminalInput(let lo, let ls, let le, let lg),
      .terminalInput(let ro, let rs, let re, let rg)
    ):
      return lo == ro && ls == rs && le == re && lg == rg
    case (.agentDispatch(let left), .agentDispatch(let right)):
      return left.operationID == right.operationID && left.scope == right.scope
        && left.kind == right.kind && left.baseRevision == right.baseRevision
        && left.capability == right.capability && left.payload == right.payload
    case (.workspaceChangedFiles(let left), .workspaceChangedFiles(let right)):
      return left == right
    case (
      .workspaceDiff(let ls, let lp, let lb),
      .workspaceDiff(let rs, let rp, let rb)
    ):
      return ls == rs && lp == rp && lb == rb
    case (
      .sessionVerify(let ls, let lc),
      .sessionVerify(let rs, let rc)
    ):
      return ls == rs && lc == rc
    case (
      .pushRegister(let lt, let le, let ls),
      .pushRegister(let rt, let re, let rs)
    ):
      return lt == rt && le == re && ls == rs
    case (.pushUnregister(let left), .pushUnregister(let right)):
      return left == right
    default:
      return false
    }
  }
}

public struct ClairRemoteRequest: Codable, Equatable, Sendable {
  public let id: UInt64
  public let call: ClairRemoteCall

  public init(id: UInt64, call: ClairRemoteCall) {
    self.id = id
    self.call = call
  }
}

public enum ClairRemoteReply: Codable, Equatable, Sendable {
  case presentation(ClairHostPresentation)
  case paired(ClairPairingResult)
  case challenge(ClairChallenge)
  case authenticated(ClairConnectionInfo)
  case terminalAttached(
    attachment: UUID, cursor: ClairTerminalCursor, size: ClairTerminalSize, retainedStart: UInt64,
    endOffset: UInt64, isClosed: Bool)
  /// Followed by one `ClairTerminalFrame.encoded()` frame.
  case terminalFrame
  case terminalIdle(isClosed: Bool)
  case terminalSessions([ClairRemoteTerminalSession])
  case terminalInput(ClairTerminalCommitOutcome, OperationReceipt)
  case agentDispatched(outcome: ClairAgentCommandOutcome, receipt: OperationReceipt)
  case changedFileSummary(ClairChangedFileSummary)
  case gitDiff(ClairGitDiff)
  case sessionVerified(ReplayCursor)
  case pushRegistered(
    scope: ResourceScope, environment: ClairPushEnvironment, expiresAt: UInt64,
    requiresRegistration: Bool)
  case ok
  case failure(code: String)
}

/// One attachable terminal session: the exact scope and process generation
/// `terminalAttach` requires.
public struct ClairRemoteTerminalSession: Codable, Equatable, Hashable, Sendable {
  public let scope: ResourceScope
  public let generation: UInt64

  public init(scope: ResourceScope, generation: UInt64) {
    self.scope = scope
    self.generation = generation
  }
}

public struct ClairRemoteResponse: Codable, Equatable, Sendable {
  public let id: UInt64
  public let reply: ClairRemoteReply

  public init(id: UInt64, reply: ClairRemoteReply) {
    self.id = id
    self.reply = reply
  }
}

public enum ClairRemoteError: Error, Equatable, Sendable {
  case remote(code: String)
  case pinMismatch
  case connectionFailed(String)
  case closed
  case protocolViolation
}

extension ClairHostFingerprint {
  /// The pin a TLS peer must match: SHA-256 of the raw P-256 public key in its
  /// certificate, i.e. the same value as the paired host's identity fingerprint.
  public static func ofCertificateKey(_ key: SecKey) -> ClairHostFingerprint? {
    guard let x963 = SecKeyCopyExternalRepresentation(key, nil) as Data?, x963.count == 65,
      x963.first == 0x04
    else { return nil }
    return try? ClairHostFingerprint(
      SHA256.hash(data: x963.dropFirst()).map { String(format: "%02x", $0) }.joined())
  }
}

/// A `ClairNativeTransportChannel` over one Network.framework TLS 1.3 connection.
/// `receive()` has a single reader: the caller's read loop.
public final class ClairTLSChannel: ClairNativeTransportChannel, @unchecked Sendable {
  private let connection: NWConnection
  private let lock = NSLock()
  private var peerCertificateFingerprintValue: Data?
  private var decoder = BoundedFrameDecoder(limits: ClairRemoteWire.limits)
  private var ready: [Data] = []

  public var remoteDescription: String { "\(connection.endpoint)" }
  public var peerCertificateFingerprint: Data? {
    lock.withLock { peerCertificateFingerprintValue }
  }

  private init(_ connection: NWConnection) {
    self.connection = connection
  }

  /// Host side: wraps a connection a TLS listener accepted and waits for its handshake.
  public static func accept(_ connection: NWConnection, queue: DispatchQueue) async throws -> ClairTLSChannel {
    try await start(connection, queue: queue)
  }

  /// Client side: TLS 1.3 to `host:port`, accepting only a certificate whose key
  /// matches `pin`. System trust is never consulted.
  public static func connect(
    host: String, port: UInt16, pinnedTo pin: ClairHostFingerprint, queue: DispatchQueue = .global()
  ) async throws -> ClairTLSChannel {
    let tls = NWProtocolTLS.Options()
    let fingerprint = ClairRemoteCertificateFingerprintBox()
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
    sec_protocol_options_set_verify_block(
      tls.securityProtocolOptions,
      { _, trust, complete in
        let trust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
          let key = SecCertificateCopyKey(leaf)
        else { return complete(false) }
        fingerprint.set(Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)))
        complete(ClairHostFingerprint.ofCertificateKey(key) == pin)
      }, queue)
    guard let port = NWEndpoint.Port(rawValue: port) else {
      throw ClairRemoteError.connectionFailed("port")
    }
    let channel = try await start(
      NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: tls)),
      queue: queue)
    channel.lock.withLock { channel.peerCertificateFingerprintValue = fingerprint.get() }
    return channel
  }

  private static func start(_ connection: NWConnection, queue: DispatchQueue) async throws
    -> ClairTLSChannel
  {
    let channel = ClairTLSChannel(connection)
    let once = ClairOnce()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready: once.run { continuation.resume() }
        case .failed(let error), .waiting(let error):
          connection.cancel()
          once.run {
            if case .tls = error { continuation.resume(throwing: ClairRemoteError.pinMismatch) } else {
              continuation.resume(throwing: ClairRemoteError.connectionFailed("\(error)"))
            }
          }
        case .cancelled: once.run { continuation.resume(throwing: ClairRemoteError.closed) }
        default: break
        }
      }
      connection.start(queue: queue)
    }
    return channel
  }

  public func send(_ frame: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: frame,
        completion: .contentProcessed { error in
          if let error { continuation.resume(throwing: ClairRemoteError.connectionFailed("\(error)")) } else {
            continuation.resume()
          }
        })
    }
  }

  /// Returns the next complete frame, length prefix included, so it decodes with
  /// `ProtocolCodec.decodeFrame` / `ClairTerminalFrame.decode` unchanged.
  public func receive() async throws -> Data {
    while true {
      if let next = lock.withLock({ ready.isEmpty ? nil : ready.removeFirst() }) { return next }
      let chunk: Data = try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
          data, _, isComplete, error in
          if let data, !data.isEmpty { continuation.resume(returning: data) } else if let error {
            continuation.resume(throwing: ClairRemoteError.connectionFailed("\(error)"))
          } else {
            _ = isComplete
            continuation.resume(throwing: ClairRemoteError.closed)
          }
        }
      }
      // An oversize or malformed length prefix throws here and the caller closes the channel.
      let frames = try lock.withLock { try decoder.append(chunk) }
      lock.withLock { ready.append(contentsOf: frames.map(\.encoded)) }
    }
  }

  public func close() async {
    connection.cancel()
  }
}

/// Resumes a continuation at most once across racing Network.framework callbacks.
final class ClairOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  func run(_ body: () -> Void) {
    let first = lock.withLock { () -> Bool in
      defer { done = true }
      return !done
    }
    if first { body() }
  }
}

/// Client end of the wire: one request/response per call, several calls in flight.
/// N12's mobile adapters sit on top of this.
public actor ClairRemoteClient {
  private let channel: any ClairNativeTransportChannel
  private var nextID: UInt64 = 1
  private var waiting: [UInt64: CheckedContinuation<(ClairRemoteReply, Data?), Error>] = [:]
  private var arrived: [UInt64: (ClairRemoteReply, Data?)] = [:]
  private var reader: Task<Void, Never>?
  private var sendTail: Task<Void, Never>?
  private var failure: ClairRemoteError?

  public init(channel: any ClairNativeTransportChannel) {
    self.channel = channel
  }

  public var isOpen: Bool { failure == nil }

  /// `binary` carries terminal input bytes; the returned data is a
  /// `ClairTerminalFrame.encoded()` frame when the reply is `.terminalFrame`.
  public func call(_ call: ClairRemoteCall, binary: Data? = nil) async throws -> (
    ClairRemoteReply, Data?
  ) {
    let (reply, data) = try await reply(to: try enqueue([(call, binary)])[0])
    if case .failure(let code) = reply { throw ClairRemoteError.remote(code: code) }
    return (reply, data)
  }

  /// Writes the calls as one send, chained after earlier sends so calls reach the wire in
  /// call order (terminal input order is the user's keystroke order).
  func enqueue(_ calls: [(ClairRemoteCall, Data?)]) throws -> [UInt64] {
    if let failure { throw failure }
    var frame = Data()
    var ids: [UInt64] = []
    for (call, binary) in calls {
      ids.append(nextID)
      frame.append(try ProtocolCodec.encodeFrame(ClairRemoteRequest(id: nextID, call: call), limits: ClairRemoteWire.limits))
      if let binary { frame.append(try BoundedFrame(payload: binary, limits: ClairRemoteWire.limits).encoded) }
      nextID += 1
    }
    startReader()
    let previous = sendTail
    sendTail = Task { [channel] in
      await previous?.value
      do { try await channel.send(frame) } catch { self.fail(.closed) }
    }
    return ids
  }

  func reply(to id: UInt64) async throws -> (ClairRemoteReply, Data?) {
    if let arrived = arrived.removeValue(forKey: id) { return arrived }
    if let failure { throw failure }
    return try await withCheckedThrowingContinuation { waiting[id] = $0 }
  }

  public func close() async {
    fail(.closed)
    await channel.close()
  }

  private func startReader() {
    guard reader == nil else { return }
    reader = Task { [channel] in
      do {
        while true {
          let response = try ProtocolCodec.decodeFrame(
            ClairRemoteResponse.self, from: try await channel.receive(), limits: ClairRemoteWire.limits)
          let binary = response.reply == .terminalFrame ? try await channel.receive() : nil
          self.deliver(response, binary)
        }
      } catch {
        self.fail((error as? ClairRemoteError) ?? .protocolViolation)
      }
    }
  }

  private func deliver(_ response: ClairRemoteResponse, _ binary: Data?) {
    if let waiter = waiting.removeValue(forKey: response.id) {
      waiter.resume(returning: (response.reply, binary))
    } else {
      arrived[response.id] = (response.reply, binary)  // answered before anyone asked
    }
  }

  private func fail(_ error: ClairRemoteError) {
    if failure == nil { failure = error }
    let pending = waiting
    waiting = [:]
    for continuation in pending.values { continuation.resume(throwing: error) }
  }
}

private final class ClairRemoteCertificateFingerprintBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Data?

  func set(_ value: Data) { lock.withLock { self.value = value } }
  func get() -> Data? { lock.withLock { value } }
}
