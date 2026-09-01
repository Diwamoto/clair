import Combine
import Darwin
import Foundation

enum CommandIPCTransportError: Error, Equatable, LocalizedError, Sendable {
  case requestTooLarge(Int)
  case responseTooLarge(Int)
  case malformedResponse
  case socketOccupied(String)
  case socketNotPrivate
  case socketSetup(String)

  var errorDescription: String? {
    switch self {
    case .requestTooLarge(let size):
      "The command request is too large (\(size) bytes)."
    case .responseTooLarge(let size):
      "The command response is too large (\(size) bytes)."
    case .malformedResponse:
      "Clair returned a malformed command response."
    case .socketOccupied(let path):
      "The Clair command socket path is occupied by a non-socket file: \(path)"
    case .socketNotPrivate:
      "The Clair command socket must be owner-only."
    case .socketSetup(let message):
      "Clair could not start the local command socket: \(message)"
    }
  }
}

struct CommandIPCClient {
  static let maximumRequestBytes = 1 * 1024 * 1024
  static let maximumResponseBytes = 1 * 1024 * 1024

  static func send(
    _ request: CommandIPCRequest,
    to socketURL: URL,
    fileManager: FileManager = .default
  ) throws -> CommandIPCResponse {
    let handle = try SessionBrokerRuntime.connect(to: socketURL, fileManager: fileManager)
    defer {
      try? handle.close()
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(request)
    data.append(10)
    guard data.count <= maximumRequestBytes else {
      throw CommandIPCTransportError.requestTooLarge(data.count)
    }

    try handle.write(contentsOf: data)
    _ = Darwin.shutdown(handle.fileDescriptor, SHUT_WR)

    var responseData = Data()
    while responseData.count <= Self.maximumResponseBytes {
      let chunk = handle.readData(ofLength: 64 * 1024)
      if chunk.isEmpty {
        break
      }
      responseData.append(chunk)
      if responseData.contains(10) {
        break
      }
    }
    guard responseData.count <= Self.maximumResponseBytes else {
      throw CommandIPCTransportError.responseTooLarge(responseData.count)
    }
    guard let line = responseData.split(separator: 10, maxSplits: 1).first, !line.isEmpty else {
      throw CommandIPCTransportError.malformedResponse
    }
    do {
      return try JSONDecoder().decode(CommandIPCResponse.self, from: Data(line))
    } catch {
      throw CommandIPCTransportError.malformedResponse
    }
  }
}

@MainActor
final class CommandIPCServer: ObservableObject {
  static let maximumRequestBytes = CommandIPCClient.maximumRequestBytes
  static let maximumResponseBytes = CommandIPCClient.maximumResponseBytes

  let socketURL: URL

  private let router: CommandAdapterRouter
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private var listener: DispatchSourceRead?
  private var listenerDescriptor: Int32?
  private var ownsSocket = false
  private(set) var isStarted = false
  private(set) var lastErrorMessage: String?

  init(
    profile: ClairRuntimeProfile,
    router: CommandAdapterRouter,
    fileManager: FileManager = .default
  ) {
    self.socketURL = profile.commandSocketURL
    self.router = router
    self.fileManager = fileManager
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    self.encoder = encoder
  }

  func start() {
    guard !isStarted else {
      return
    }
    isStarted = true
    do {
      guard let descriptor = try claimSocket() else {
        return
      }
      ownsSocket = true
      let source = DispatchSource.makeReadSource(
        fileDescriptor: descriptor,
        queue: .main
      )
      source.setEventHandler { [weak self] in
        Task { @MainActor [weak self] in
          self?.acceptOne()
        }
      }
      source.setCancelHandler {
        Darwin.close(descriptor)
      }
      listenerDescriptor = descriptor
      listener = source
      source.resume()
    } catch {
      isStarted = false
      lastErrorMessage = error.localizedDescription
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    listenerDescriptor = nil
    isStarted = false
    if ownsSocket {
      try? fileManager.removeItem(at: socketURL)
    }
    ownsSocket = false
  }

  private func claimSocket() throws -> Int32? {
    let directory = socketURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )

    if fileManager.fileExists(atPath: socketURL.path) {
      let resourceValues = try socketURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard resourceValues.isSymbolicLink != true else {
        throw CommandIPCTransportError.socketOccupied(socketURL.path)
      }
      let attributes = try fileManager.attributesOfItem(atPath: socketURL.path)
      guard attributes[.type] as? FileAttributeType == .typeSocket else {
        throw CommandIPCTransportError.socketOccupied(socketURL.path)
      }
      guard Self.isOwnerOnly(attributes) else {
        throw CommandIPCTransportError.socketNotPrivate
      }
      if let handle = try? SessionBrokerRuntime.connect(to: socketURL, fileManager: fileManager) {
        try? handle.close()
        return nil
      }
      try fileManager.removeItem(at: socketURL)
    }

    let pathBytes = Array(socketURL.path.utf8)
    var address = sockaddr_un()
    let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1
    guard pathBytes.count <= maximumPathLength else {
      throw CommandIPCTransportError.socketSetup("The socket path is too long.")
    }

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw CommandIPCTransportError.socketSetup(String(cString: strerror(errno)))
    }
    var mutablePath = pathBytes
    mutablePath.append(0)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: mutablePath)
    }
    address.sun_family = sa_family_t(AF_UNIX)
    let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + mutablePath.count)
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, addressLength)
      }
    }
    guard bindResult == 0 else {
      let message = String(cString: strerror(errno))
      Darwin.close(descriptor)
      throw CommandIPCTransportError.socketSetup(message)
    }
    guard Darwin.listen(descriptor, 16) == 0 else {
      let message = String(cString: strerror(errno))
      Darwin.close(descriptor)
      try? fileManager.removeItem(at: socketURL)
      throw CommandIPCTransportError.socketSetup(message)
    }
    guard Darwin.chmod(socketURL.path, 0o600) == 0 else {
      let message = String(cString: strerror(errno))
      Darwin.close(descriptor)
      try? fileManager.removeItem(at: socketURL)
      throw CommandIPCTransportError.socketSetup(message)
    }
    _ = Darwin.fcntl(descriptor, F_SETFL, O_NONBLOCK)
    return descriptor
  }

  private static func isOwnerOnly(_ attributes: [FileAttributeKey: Any]) -> Bool {
    guard let permissions = attributes[.posixPermissions] as? NSNumber else {
      return false
    }
    return permissions.intValue & 0o077 == 0
  }

  private func acceptOne() {
    guard listener != nil, let descriptor = listenerDescriptor else {
      return
    }
    let client = Darwin.accept(descriptor, nil, nil)
    guard client >= 0 else {
      return
    }
    guard Darwin.fcntl(client, F_SETFL, 0) == 0 else {
      Darwin.close(client)
      return
    }
    var noSignal: Int32 = 1
    _ = withUnsafePointer(to: &noSignal) { pointer in
      Darwin.setsockopt(
        client,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        pointer,
        socklen_t(MemoryLayout<Int32>.size)
      )
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let requestData = Self.readRequest(from: client)
      Task { @MainActor [weak self] in
        guard let self else {
          Darwin.close(client)
          return
        }
        let response: CommandIPCResponse
        if let requestData {
          do {
            let request = try JSONDecoder().decode(CommandIPCRequest.self, from: requestData)
            response = self.router.handle(request)
          } catch {
            response = .failure(
              requestID: "unknown",
              error: CommandIPCErrorPayload.malformedRequest(error.localizedDescription)
            )
          }
        } else {
          response = .failure(
            requestID: "unknown",
            error: CommandIPCErrorPayload.malformedRequest(
              "The request was empty or exceeded the protocol limit."
            )
          )
        }
        self.write(response, to: client)
        Darwin.close(client)
      }
    }
  }

  nonisolated private static func readRequest(from descriptor: Int32) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while data.count <= CommandIPCClient.maximumRequestBytes {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.recv(descriptor, bytes.baseAddress, bytes.count, 0)
      }
      if count > 0 {
        data.append(contentsOf: buffer.prefix(count))
        if let newline = data.firstIndex(of: 10) {
          return Data(data.prefix(upTo: newline))
        }
        continue
      }
      if count == 0 {
        break
      }
      if errno == EINTR {
        continue
      }
      return nil
    }
    guard data.count <= CommandIPCClient.maximumRequestBytes else {
      return nil
    }
    return data.isEmpty ? nil : data
  }

  private func write(_ response: CommandIPCResponse, to descriptor: Int32) {
    let responseData: Data
    do {
      responseData = try encoder.encode(response)
    } catch {
      return
    }
    var data = responseData
    data.append(10)
    guard data.count <= Self.maximumResponseBytes else {
      return
    }
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { bytes -> Int in
        guard let baseAddress = bytes.baseAddress else {
          return -1
        }
        return Darwin.send(
          descriptor,
          baseAddress.advanced(by: offset),
          data.count - offset,
          0
        )
      }
      if count < 0, errno == EINTR {
        continue
      }
      guard count > 0 else {
        return
      }
      offset += count
    }
  }
}

private enum CommandIPCErrorPayload {
  static func malformedRequest(_ message: String) -> ClairCommandIPCError {
    ClairCommandIPCError(
      code: "malformed_request",
      message: message,
      commandID: nil,
      risk: nil,
      reason: "The request was not valid version 1 command JSON."
    )
  }
}

private typealias ClairCommandIPCError = CommandIPCError
