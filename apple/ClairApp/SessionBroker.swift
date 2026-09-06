import Darwin
import Foundation

enum SessionBrokerFrameKind: UInt8, Equatable, Sendable {
  case attach = 1
  case input = 2
  case resize = 3
  case detach = 4
  case terminate = 5
  case attached = 0x81
  case output = 0x82
  case gap = 0x83
  case exit = 0x84
  case error = 0xff
}

enum SessionBrokerAttachMode: UInt8, Equatable, Sendable {
  case create = 1
  case reattach = 2
}

enum SessionBrokerErrorCode: UInt8, Equatable, Sendable {
  case invalidRequest = 1
  case sessionMissing = 2
  case sessionExists = 3
  case protocolError = 4
  case io = 5
  case staleCursor = 6
}

enum SessionBrokerProtocolError: Error, Equatable, Sendable {
  case invalidMagic
  case unsupportedVersion(UInt8)
  case unknownFrameKind(UInt8)
  case payloadTooLarge(Int)
  case bufferedDataTooLarge(Int)
  case invalidPayloadLength(kind: SessionBrokerFrameKind, expected: String, actual: Int)
  case invalidText
  case invalidSessionID
  case invalidDimensions
  case truncatedPayload
  case trailingPayload
  case invalidState
}

struct SessionBrokerFrame: Equatable, Sendable {
  static let protocolVersion: UInt8 = 1
  static let maxPayloadLength = 64 * 1024
  static let headerLength = 8
  private static let magic: [UInt8] = [0x43, 0x42]

  let kind: SessionBrokerFrameKind
  let payload: Data

  init(kind: SessionBrokerFrameKind, payload: Data) throws {
    guard payload.count <= Self.maxPayloadLength else {
      throw SessionBrokerProtocolError.payloadTooLarge(payload.count)
    }

    let valid: Bool
    let expected: String
    switch kind {
    case .resize:
      valid = payload.count == 4
      expected = "4 bytes"
    case .detach, .terminate:
      valid = payload.isEmpty
      expected = "0 bytes"
    case .output:
      valid = payload.count >= 8
      expected = "at least 8 bytes"
    case .gap:
      valid = payload.count == 16
      expected = "16 bytes"
    case .exit:
      valid = payload.count == 9
      expected = "9 bytes"
    case .error:
      valid = !payload.isEmpty
      expected = "at least 1 byte"
    case .attach, .input, .attached:
      valid = true
      expected = "a valid payload"
    }
    guard valid else {
      throw SessionBrokerProtocolError.invalidPayloadLength(
        kind: kind,
        expected: expected,
        actual: payload.count
      )
    }
    self.kind = kind
    self.payload = payload
  }

  static func attach(
    mode: SessionBrokerAttachMode,
    sessionID: UUID,
    cursor: UInt64,
    dimensions: TerminalDimensions,
    cwd: String,
    shell: String
  ) throws -> SessionBrokerFrame {
    var payload = Data([mode.rawValue])
    try appendText(sessionID.uuidString, to: &payload, lengthBytes: 1)
    appendUInt64(cursor, to: &payload)
    appendUInt16(dimensions.rows, to: &payload)
    appendUInt16(dimensions.columns, to: &payload)
    try appendText(cwd, to: &payload, lengthBytes: 2)
    try appendText(shell, to: &payload, lengthBytes: 2)
    return try SessionBrokerFrame(kind: .attach, payload: payload)
  }

  static func input(_ data: Data) throws -> SessionBrokerFrame {
    try SessionBrokerFrame(kind: .input, payload: data)
  }

  static func resize(rows: UInt16, columns: UInt16) throws -> SessionBrokerFrame {
    guard rows > 0, columns > 0, rows <= 1_000, columns <= 1_000 else {
      throw SessionBrokerProtocolError.invalidDimensions
    }
    var payload = Data()
    appendUInt16(rows, to: &payload)
    appendUInt16(columns, to: &payload)
    return try SessionBrokerFrame(kind: .resize, payload: payload)
  }

  static var detach: SessionBrokerFrame {
    // The fixed-size detach payload is part of the protocol contract.
    try! SessionBrokerFrame(kind: .detach, payload: Data())
  }

  static var terminate: SessionBrokerFrame {
    // The fixed-size terminate payload is part of the protocol contract.
    try! SessionBrokerFrame(kind: .terminate, payload: Data())
  }

  var encoded: Data {
    var data = Data(Self.magic)
    data.append(Self.protocolVersion)
    data.append(kind.rawValue)
    Self.appendUInt32(UInt32(payload.count), to: &data)
    data.append(payload)
    return data
  }

  fileprivate static func readUInt16(from payload: Data, cursor: inout Int) throws -> UInt16 {
    let bytes = try readBytes(from: payload, cursor: &cursor, count: 2)
    return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
  }

  fileprivate static func readUInt64(from payload: Data, cursor: inout Int) throws -> UInt64 {
    let bytes = try readBytes(from: payload, cursor: &cursor, count: 8)
    return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
  }

  fileprivate static func readText(
    from payload: Data,
    cursor: inout Int,
    lengthBytes: Int
  ) throws -> String {
    let length: Int
    if lengthBytes == 1 {
      length = Int(try readByte(from: payload, cursor: &cursor))
    } else {
      length = Int(try readUInt16(from: payload, cursor: &cursor))
    }
    guard length > 0, length <= 4 * 1024 else {
      throw SessionBrokerProtocolError.invalidText
    }
    let bytes = try readBytes(from: payload, cursor: &cursor, count: length)
    guard let text = String(bytes: bytes, encoding: .utf8),
      !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    else {
      throw SessionBrokerProtocolError.invalidText
    }
    return text
  }

  fileprivate static func readByte(from payload: Data, cursor: inout Int) throws -> UInt8 {
    guard cursor < payload.count else {
      throw SessionBrokerProtocolError.truncatedPayload
    }
    defer { cursor += 1 }
    return payload[cursor]
  }

  fileprivate static func readBytes(
    from payload: Data,
    cursor: inout Int,
    count: Int
  ) throws -> [UInt8] {
    guard count >= 0, cursor <= payload.count - count else {
      throw SessionBrokerProtocolError.truncatedPayload
    }
    let bytes = Array(payload[cursor..<(cursor + count)])
    cursor += count
    return bytes
  }

  private static func appendText(
    _ text: String,
    to payload: inout Data,
    lengthBytes: Int
  ) throws {
    let bytes = Array(text.utf8)
    let maximum = lengthBytes == 1 ? 255 : Int(UInt16.max)
    guard !bytes.isEmpty, bytes.count <= maximum, bytes.count <= 4 * 1024,
      !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    else {
      throw SessionBrokerProtocolError.invalidText
    }
    if lengthBytes == 1 {
      payload.append(UInt8(bytes.count))
    } else {
      appendUInt16(UInt16(bytes.count), to: &payload)
    }
    payload.append(contentsOf: bytes)
  }

  private static func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value >> 8))
    data.append(UInt8(value & 0xff))
  }

  private static func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  private static func appendUInt64(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
      data.append(UInt8((value >> UInt64(shift)) & 0xff))
    }
  }
}

struct SessionBrokerFrameDecoder {
  private var buffer = Data()

  mutating func append(_ data: Data) throws -> [SessionBrokerFrame] {
    var frames: [SessionBrokerFrame] = []
    var inputOffset = 0
    let maximumBufferedBytes =
      SessionBrokerFrame.headerLength + SessionBrokerFrame.maxPayloadLength

    while inputOffset < data.count {
      if buffer.count == maximumBufferedBytes {
        frames.append(contentsOf: try drainFrames())
        guard buffer.count < maximumBufferedBytes else {
          throw SessionBrokerProtocolError.bufferedDataTooLarge(
            buffer.count + data.count - inputOffset
          )
        }
      }

      let capacity = maximumBufferedBytes - buffer.count
      let count = min(capacity, data.count - inputOffset)
      buffer.append(data[inputOffset..<(inputOffset + count)])
      inputOffset += count
      frames.append(contentsOf: try drainFrames())
    }

    frames.append(contentsOf: try drainFrames())
    return frames
  }

  private mutating func drainFrames() throws -> [SessionBrokerFrame] {
    var frames: [SessionBrokerFrame] = []
    while buffer.count >= SessionBrokerFrame.headerLength {
      let header = Array(buffer.prefix(SessionBrokerFrame.headerLength))
      guard header.prefix(2).elementsEqual([0x43, 0x42]) else {
        throw SessionBrokerProtocolError.invalidMagic
      }
      guard header[2] == SessionBrokerFrame.protocolVersion else {
        throw SessionBrokerProtocolError.unsupportedVersion(header[2])
      }
      guard let kind = SessionBrokerFrameKind(rawValue: header[3]) else {
        throw SessionBrokerProtocolError.unknownFrameKind(header[3])
      }
      let length = Int(
        UInt32(header[4]) << 24
          | UInt32(header[5]) << 16
          | UInt32(header[6]) << 8
          | UInt32(header[7])
      )
      guard length <= SessionBrokerFrame.maxPayloadLength else {
        throw SessionBrokerProtocolError.payloadTooLarge(length)
      }
      let totalLength = SessionBrokerFrame.headerLength + length
      guard buffer.count >= totalLength else {
        break
      }
      let payload = Data(buffer.dropFirst(SessionBrokerFrame.headerLength).prefix(length))
      frames.append(try SessionBrokerFrame(kind: kind, payload: payload))
      buffer.removeFirst(totalLength)
    }
    return frames
  }
}

struct SessionBrokerAttachment: Equatable, Sendable {
  let sessionID: UUID
  let epoch: UInt64
  let currentOffset: UInt64
  let oldestOffset: UInt64
  let isExited: Bool

  init(frame: SessionBrokerFrame) throws {
    guard frame.kind == .attached else {
      throw SessionBrokerProtocolError.invalidState
    }
    var cursor = 0
    let sessionText = try SessionBrokerFrame.readText(
      from: frame.payload,
      cursor: &cursor,
      lengthBytes: 1
    )
    guard let sessionID = UUID(uuidString: sessionText) else {
      throw SessionBrokerProtocolError.invalidSessionID
    }
    let epoch = try SessionBrokerFrame.readUInt64(from: frame.payload, cursor: &cursor)
    let currentOffset = try SessionBrokerFrame.readUInt64(from: frame.payload, cursor: &cursor)
    let oldestOffset = try SessionBrokerFrame.readUInt64(from: frame.payload, cursor: &cursor)
    let state = try SessionBrokerFrame.readByte(from: frame.payload, cursor: &cursor)
    guard state <= 1, cursor == frame.payload.count else {
      throw SessionBrokerProtocolError.invalidState
    }
    self.sessionID = sessionID
    self.epoch = epoch
    self.currentOffset = currentOffset
    self.oldestOffset = oldestOffset
    self.isExited = state == 1
  }
}

struct SessionBrokerOutput: Equatable, Sendable {
  let offset: UInt64
  let data: Data

  init(frame: SessionBrokerFrame) throws {
    guard frame.kind == .output else {
      throw SessionBrokerProtocolError.invalidState
    }
    var cursor = 0
    self.offset = try SessionBrokerFrame.readUInt64(from: frame.payload, cursor: &cursor)
    self.data = Data(
      try SessionBrokerFrame.readBytes(
        from: frame.payload,
        cursor: &cursor,
        count: frame.payload.count - cursor
      ))
    guard !data.isEmpty else {
      throw SessionBrokerProtocolError.invalidState
    }
  }
}

struct SessionBrokerGap: Equatable, Sendable {
  let start: UInt64
  let end: UInt64

  init(frame: SessionBrokerFrame) throws {
    guard frame.kind == .gap else {
      throw SessionBrokerProtocolError.invalidState
    }
    var cursor = 0
    start = try SessionBrokerFrame.readUInt64(from: frame.payload, cursor: &cursor)
    end = try SessionBrokerFrame.readUInt64(from: frame.payload, cursor: &cursor)
    guard start < end, cursor == frame.payload.count else {
      throw SessionBrokerProtocolError.invalidState
    }
  }
}

struct SessionBrokerExit: Equatable, Sendable {
  let status: UInt8
  let offset: UInt64

  init(frame: SessionBrokerFrame) throws {
    guard frame.kind == .exit else {
      throw SessionBrokerProtocolError.invalidState
    }
    var cursor = 0
    status = try SessionBrokerFrame.readByte(from: frame.payload, cursor: &cursor)
    offset = try SessionBrokerFrame.readUInt64(from: frame.payload, cursor: &cursor)
    guard cursor == frame.payload.count else {
      throw SessionBrokerProtocolError.invalidState
    }
  }
}

struct SessionBrokerErrorFrame: Equatable, Sendable {
  let code: SessionBrokerErrorCode
  let message: String

  init(frame: SessionBrokerFrame) throws {
    guard frame.kind == .error else {
      throw SessionBrokerProtocolError.invalidState
    }
    var cursor = 0
    let rawCode = try SessionBrokerFrame.readByte(from: frame.payload, cursor: &cursor)
    code = SessionBrokerErrorCode(rawValue: rawCode) ?? .protocolError
    let messageBytes = try SessionBrokerFrame.readBytes(
      from: frame.payload,
      cursor: &cursor,
      count: frame.payload.count - cursor
    )
    message = String(decoding: messageBytes, as: UTF8.self)
    guard cursor == frame.payload.count else {
      throw SessionBrokerProtocolError.invalidState
    }
  }
}

struct SessionBrokerPaths: Equatable, Sendable {
  let socketURL: URL
  let catalogURL: URL

  static func makeDefault(
    for profile: ClairRuntimeProfile,
    fileManager: FileManager = .default
  ) -> SessionBrokerPaths? {
    guard
      let baseDirectory = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      return nil
    }
    let directory = profile.applicationSupportURL(baseDirectory: baseDirectory)
    return SessionBrokerPaths(
      socketURL: directory.appendingPathComponent("session-broker-v1.sock"),
      catalogURL: directory.appendingPathComponent("sessions-v1.catalog")
    )
  }
}

enum SessionBrokerRuntime {
  static func open(
    ptyHostURL: URL,
    paths: SessionBrokerPaths,
    fileManager: FileManager = .default
  ) throws -> (handle: FileHandle, process: Process?) {
    if let handle = try? connect(to: paths.socketURL, fileManager: fileManager) {
      return (handle, nil)
    }

    let process = Process()
    process.executableURL = ptyHostURL
    process.arguments = [
      "--broker",
      "--socket",
      paths.socketURL.path,
      "--catalog",
      paths.catalogURL.path,
    ]
    process.environment = brokerEnvironment()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()

    for _ in 0..<100 {
      if let handle = try? connect(to: paths.socketURL, fileManager: fileManager) {
        return (handle, process)
      }
      usleep(10_000)
    }
    throw CocoaError(
      .fileNoSuchFile,
      userInfo: [
        NSLocalizedDescriptionKey: "The local Clair session broker did not start."
      ])
  }

  private static func brokerEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment

    // A broker can outlive the app that launched it. Do not let an embedding
    // terminal's shell integration redirect Clair's zsh startup files or leak
    // its integration-only variables into future sessions.
    for key in environment.keys.filter({ $0.hasPrefix("CCEDIT_") }) {
      environment.removeValue(forKey: key)
    }
    environment.removeValue(forKey: "ZDOTDIR")

    return environment
  }

  static func connect(
    to socketURL: URL,
    fileManager: FileManager = .default
  ) throws -> FileHandle {
    try validateSocketPath(socketURL, fileManager: fileManager)
    let pathBytes = Array(socketURL.path.utf8)
    var address = sockaddr_un()
    let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1
    guard pathBytes.count <= maximumPathLength else {
      throw POSIXError(.ENAMETOOLONG)
    }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var mutablePath = pathBytes
    mutablePath.append(0)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: mutablePath)
    }
    address.sun_family = sa_family_t(AF_UNIX)
    let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + mutablePath.count)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, addressLength)
      }
    }
    guard result == 0 else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      Darwin.close(descriptor)
      throw error
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  private static func validateSocketPath(
    _ socketURL: URL,
    fileManager: FileManager
  ) throws {
    guard fileManager.fileExists(atPath: socketURL.path) else {
      return
    }
    let values = try socketURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw CocoaError(
        .fileReadNoPermission,
        userInfo: [
          NSLocalizedDescriptionKey: "The session broker socket is a symbolic link."
        ])
    }
    let attributes = try fileManager.attributesOfItem(atPath: socketURL.path)
    if let permissions = attributes[.posixPermissions] as? NSNumber,
      permissions.intValue & 0o077 != 0
    {
      throw CocoaError(
        .fileReadNoPermission,
        userInfo: [
          NSLocalizedDescriptionKey: "The session broker socket is not owner-only."
        ])
    }
  }
}

@MainActor
final class SessionBrokerClient {
  private let paths: SessionBrokerPaths
  private let ptyHostURL: URL
  private var handle: FileHandle?
  private var launchedBroker: Process?
  private var decoder = SessionBrokerFrameDecoder()
  private var didDisconnect = false

  var onFrame: ((SessionBrokerFrame) -> Void)?
  var onDisconnect: (() -> Void)?

  init(paths: SessionBrokerPaths, ptyHostURL: URL) {
    self.paths = paths
    self.ptyHostURL = ptyHostURL
  }

  func start(
    mode: SessionBrokerAttachMode,
    sessionID: UUID,
    cursor: UInt64,
    dimensions: TerminalDimensions,
    cwd: String,
    shell: String
  ) throws {
    guard handle == nil else {
      return
    }
    let opened = try SessionBrokerRuntime.open(
      ptyHostURL: ptyHostURL,
      paths: paths
    )
    handle = opened.handle
    launchedBroker = opened.process
    didDisconnect = false
    installReader(on: opened.handle)
    do {
      try send(
        SessionBrokerFrame.attach(
          mode: mode,
          sessionID: sessionID,
          cursor: cursor,
          dimensions: dimensions,
          cwd: cwd,
          shell: shell
        )
      )
    } catch {
      close()
      throw error
    }
  }

  func send(_ frame: SessionBrokerFrame) throws {
    guard let handle else {
      throw CocoaError(
        .fileNoSuchFile,
        userInfo: [
          NSLocalizedDescriptionKey: "The local Clair session broker is not connected."
        ])
    }
    try handle.write(contentsOf: frame.encoded)
  }

  func detach() {
    try? send(.detach)
    close()
  }

  func close() {
    didDisconnect = true
    handle?.readabilityHandler = nil
    try? handle?.close()
    handle = nil
    launchedBroker = nil
  }

  private func installReader(on handle: FileHandle) {
    handle.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      Task { @MainActor [weak self] in
        guard let self else {
          return
        }
        guard !data.isEmpty else {
          handleDisconnect()
          return
        }
        receive(data)
      }
    }
  }

  private func receive(_ data: Data) {
    guard !didDisconnect else {
      return
    }
    do {
      for frame in try decoder.append(data) {
        onFrame?(frame)
      }
    } catch {
      handleDisconnect()
    }
  }

  private func handleDisconnect() {
    guard !didDisconnect else {
      return
    }
    didDisconnect = true
    handle?.readabilityHandler = nil
    try? handle?.close()
    handle = nil
    onDisconnect?()
  }
}
