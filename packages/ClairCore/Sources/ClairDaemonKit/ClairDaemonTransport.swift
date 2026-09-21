#if os(macOS)

  import Darwin
  import Foundation

  import ClairShared

  enum ClairDaemonTransportDirection: Equatable {
    case request
    case response
  }

  enum ClairDaemonSocketSupport {
    static let controlTimeout = TimeInterval(5)
    private static let processLockRegistry = ProcessLockRegistry()

    static func ensurePrivateDirectory(at url: URL) throws {
      let fileManager = FileManager.default
      if fileManager.fileExists(atPath: url.path) {
        let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else {
          throw ClairDaemonError.controlSocketSetup("The runtime directory is not private.")
        }
      } else {
        try fileManager.createDirectory(
          at: url,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      }

      try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: url.path
      )
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      guard isOwnerOnly(attributes) else {
        throw ClairDaemonError.controlSocketSetup("The runtime directory is not owner-only.")
      }
    }

    static func acquireLock(at url: URL) throws -> ClairDaemonInstanceLock {
      let lockDirectory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        .standardizedFileURL
      let lockPath = lockDirectory.appendingPathComponent(url.lastPathComponent)
        .path
      if processLockRegistry.contains(lockPath) {
        throw ClairDaemonError.alreadyRunning
      }

      let descriptor = Darwin.open(
        url.path,
        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
        mode_t(0o600)
      )
      guard descriptor >= 0 else {
        switch errno {
        case EACCES, ELOOP, EISDIR, ENOTDIR:
          throw ClairDaemonError.lockPathOccupied
        default:
          throw ClairDaemonError.lockUnavailable
        }
      }

      guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
        Darwin.close(descriptor)
        throw ClairDaemonError.lockUnavailable
      }
      var lock = Darwin.flock()
      lock.l_type = Int16(F_WRLCK)
      lock.l_whence = Int16(SEEK_SET)
      lock.l_start = 0
      lock.l_len = 0
      guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
        let errorNumber = errno
        Darwin.close(descriptor)
        if errorNumber == EWOULDBLOCK || errorNumber == EAGAIN {
          throw ClairDaemonError.alreadyRunning
        }
        throw ClairDaemonError.lockUnavailable
      }

      var information = stat()
      guard Darwin.fstat(descriptor, &information) == 0 else {
        unlock(descriptor)
        Darwin.close(descriptor)
        throw ClairDaemonError.lockUnavailable
      }
      guard information.st_mode & mode_t(0o077) == 0 else {
        unlock(descriptor)
        Darwin.close(descriptor)
        throw ClairDaemonError.lockNotPrivate
      }

      guard processLockRegistry.insertIfAbsent(lockPath) else {
        unlock(descriptor)
        Darwin.close(descriptor)
        throw ClairDaemonError.alreadyRunning
      }
      return ClairDaemonInstanceLock(descriptor: descriptor, path: lockPath)
    }

    static func openListener(at url: URL) throws -> (descriptor: Int32, identity: FileIdentity) {
      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else {
        throw ClairDaemonError.controlSocketSetup(String(cString: strerror(errno)))
      }
      setCloseOnExec(descriptor)

      var boundIdentity: FileIdentity?
      do {
        let bindResult = try withUnixAddress(for: url) { address, length in
          Darwin.bind(descriptor, address, length)
        }
        guard bindResult == 0 else {
          throw socketSetupError()
        }
        boundIdentity = fileIdentity(at: url)
        guard Darwin.listen(descriptor, 16) == 0 else {
          throw socketSetupError()
        }
        guard Darwin.chmod(url.path, mode_t(0o600)) == 0 else {
          throw socketSetupError()
        }
        guard setNonBlocking(descriptor) else {
          throw socketSetupError()
        }
        guard let identity = fileIdentity(at: url) else {
          throw ClairDaemonError.controlSocketSetup("The control socket disappeared.")
        }
        return (descriptor, identity)
      } catch {
        Darwin.close(descriptor)
        if let boundIdentity {
          try? removeSocketIfOwned(at: url, identity: boundIdentity)
        }
        throw error
      }
    }

    static func connect(to paths: ClairDaemonPaths, timeout: TimeInterval) throws -> Int32 {
      try validateRuntimeDirectory(paths.directoryURL)
      try validateSocket(at: paths.socketURL, allowMissing: false)

      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard descriptor >= 0 else {
        throw ClairDaemonError.controlSocketSetup(String(cString: strerror(errno)))
      }
      setCloseOnExec(descriptor)
      setNoSigPipe(descriptor)
      setSocketTimeout(descriptor, timeout: timeout)

      do {
        let result = try withUnixAddress(for: paths.socketURL) { address, length in
          Darwin.connect(descriptor, address, length)
        }
        guard result == 0 else {
          throw connectionError()
        }
        return descriptor
      } catch {
        Darwin.close(descriptor)
        throw error
      }
    }

    static func validateRuntimeDirectory(_ url: URL) throws {
      let fileManager = FileManager.default
      guard fileManager.fileExists(atPath: url.path) else {
        throw ClairDaemonError.controlSocketMissing
      }
      let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else {
        throw ClairDaemonError.controlSocketSetup("The runtime directory is not private.")
      }
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      guard isOwnerOnly(attributes) else {
        throw ClairDaemonError.controlSocketSetup("The runtime directory is not owner-only.")
      }
    }

    static func validateSocket(at url: URL, allowMissing: Bool) throws {
      var information = stat()
      guard Darwin.lstat(url.path, &information) == 0 else {
        if allowMissing && errno == ENOENT {
          return
        }
        if errno == ENOENT {
          throw ClairDaemonError.controlSocketMissing
        }
        throw ClairDaemonError.controlSocketSetup(String(cString: strerror(errno)))
      }
      guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
        throw ClairDaemonError.controlSocketOccupied
      }
      guard information.st_mode & mode_t(0o077) == 0 else {
        throw ClairDaemonError.controlSocketNotPrivate
      }
    }

    static func removeSocketIfPresent(at url: URL) throws {
      var information = stat()
      guard Darwin.lstat(url.path, &information) == 0 else {
        guard errno == ENOENT else {
          throw ClairDaemonError.cleanupFailed
        }
        return
      }
      guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
        throw ClairDaemonError.controlSocketOccupied
      }
      guard information.st_mode & mode_t(0o077) == 0 else {
        throw ClairDaemonError.controlSocketNotPrivate
      }
      guard Darwin.unlink(url.path) == 0 else {
        throw ClairDaemonError.cleanupFailed
      }
    }

    static func removeSocketIfOwned(at url: URL, identity: FileIdentity) throws {
      var information = stat()
      guard Darwin.lstat(url.path, &information) == 0 else {
        guard errno == ENOENT else {
          throw ClairDaemonError.cleanupFailed
        }
        return
      }
      guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
        information.st_dev == identity.device,
        information.st_ino == identity.inode
      else {
        return
      }
      guard Darwin.unlink(url.path) == 0 else {
        throw ClairDaemonError.cleanupFailed
      }
    }

    static func readFrames(
      from descriptor: Int32,
      limits: FrameLimits,
      direction: ClairDaemonTransportDirection
    ) throws -> [BoundedFrame] {
      var decoder = BoundedFrameDecoder(limits: limits)
      var frames: [BoundedFrame] = []
      var bytesRead = 0
      var buffer = [UInt8](repeating: 0, count: 16 * 1024)

      while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
          guard let baseAddress = bytes.baseAddress else { return -1 }
          return Darwin.recv(descriptor, baseAddress, bytes.count, 0)
        }
        if count > 0 {
          bytesRead += count
          guard bytesRead <= limits.maximumFrameBytes else {
            throw direction == .request
              ? ClairDaemonError.requestTooLarge(bytesRead)
              : ClairDaemonError.responseTooLarge(bytesRead)
          }
          do {
            frames.append(contentsOf: try decoder.append(Data(buffer[0..<count])))
          } catch let error as ProtocolError {
            throw ClairDaemonError.invalidFrame(error)
          }
          if frames.count > 1 {
            throw ClairDaemonError.invalidFrame(.trailingFrameBytes(frames.count - 1))
          }
          continue
        }
        if count == 0 {
          break
        }
        if errno == EINTR {
          continue
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          throw ClairDaemonError.transportTimedOut
        }
        throw ClairDaemonError.transportClosed
      }

      do {
        try decoder.finish()
      } catch let error as ProtocolError {
        throw ClairDaemonError.invalidFrame(error)
      }
      return frames
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
      var offset = 0
      while offset < data.count {
        let count = data.withUnsafeBytes { bytes -> Int in
          guard let baseAddress = bytes.baseAddress else { return -1 }
          return Darwin.send(
            descriptor,
            baseAddress.advanced(by: offset),
            data.count - offset,
            0
          )
        }
        if count > 0 {
          offset += count
          continue
        }
        if count < 0, errno == EINTR {
          continue
        }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
          throw ClairDaemonError.transportTimedOut
        }
        throw ClairDaemonError.transportClosed
      }
    }

    static func unlock(_ descriptor: Int32) {
      var lock = Darwin.flock()
      lock.l_type = Int16(F_UNLCK)
      lock.l_whence = Int16(SEEK_SET)
      lock.l_start = 0
      lock.l_len = 0
      _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
    }

    static func releaseLock(_ lock: ClairDaemonInstanceLock) {
      unlock(lock.descriptor)
      Darwin.close(lock.descriptor)
      processLockRegistry.remove(lock.path)
    }

    static func setNoSigPipe(_ descriptor: Int32) {
      var noSignal: Int32 = 1
      _ = withUnsafePointer(to: &noSignal) { pointer in
        Darwin.setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          pointer,
          socklen_t(MemoryLayout<Int32>.size)
        )
      }
    }

    static func setBlocking(_ descriptor: Int32) -> Bool {
      let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
      guard flags >= 0 else { return false }
      return Darwin.fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0
    }

    private static func withUnixAddress<T>(
      for url: URL,
      _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) throws -> T {
      let pathBytes = Array(url.path.utf8)
      var address = sockaddr_un()
      let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1
      guard pathBytes.count <= maximumPathLength else {
        throw ClairDaemonError.controlSocketPathTooLong
      }
      var mutablePath = pathBytes
      mutablePath.append(0)
      withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: mutablePath)
      }
      address.sun_family = sa_family_t(AF_UNIX)
      let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + mutablePath.count)
      return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          body($0, addressLength)
        }
      }
    }

    private static func fileIdentity(at url: URL) -> FileIdentity? {
      var information = stat()
      guard Darwin.lstat(url.path, &information) == 0 else { return nil }
      return FileIdentity(device: information.st_dev, inode: information.st_ino)
    }

    private static func isOwnerOnly(_ attributes: [FileAttributeKey: Any]) -> Bool {
      guard let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
      return permissions.intValue & 0o077 == 0
    }

    private static func setCloseOnExec(_ descriptor: Int32) {
      let flags = Darwin.fcntl(descriptor, F_GETFD, 0)
      if flags >= 0 {
        _ = Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
      }
    }

    private static func setNonBlocking(_ descriptor: Int32) -> Bool {
      let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
      guard flags >= 0 else { return false }
      return Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    static func setSocketTimeout(_ descriptor: Int32, timeout: TimeInterval) {
      var value = timeval(
        tv_sec: Int(timeout),
        tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
      )
      withUnsafePointer(to: &value) { pointer in
        Darwin.setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_RCVTIMEO,
          pointer,
          socklen_t(MemoryLayout<timeval>.size)
        )
        Darwin.setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_SNDTIMEO,
          pointer,
          socklen_t(MemoryLayout<timeval>.size)
        )
      }
    }

    private static func socketSetupError() -> ClairDaemonError {
      ClairDaemonError.controlSocketSetup(String(cString: strerror(errno)))
    }

    private static func connectionError() -> ClairDaemonError {
      switch errno {
      case ENOENT, ECONNREFUSED:
        .controlSocketMissing
      case EACCES:
        .controlSocketNotPrivate
      default:
        .controlSocketSetup(String(cString: strerror(errno)))
      }
    }
  }

  struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
  }

  final class ClairDaemonInstanceLock: @unchecked Sendable {
    let descriptor: Int32
    let path: String

    init(descriptor: Int32, path: String) {
      self.descriptor = descriptor
      self.path = path
    }
  }

  private final class ProcessLockRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()

    func contains(_ path: String) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return paths.contains(path)
    }

    func insertIfAbsent(_ path: String) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard paths.insert(path).inserted else { return false }
      return true
    }

    func remove(_ path: String) {
      lock.lock()
      paths.remove(path)
      lock.unlock()
    }
  }

  extension ClairDaemonError {
    var controlFailure: ClairDaemonControlFailure {
      switch self {
      case .requestTooLarge, .responseTooLarge:
        ClairDaemonControlFailure(code: .frameTooLarge)
      case .transportTimedOut:
        ClairDaemonControlFailure(code: .requestTimedOut, retryable: true)
      case .invalidFrame(let error):
        switch error {
        case .frameTooLarge:
          ClairDaemonControlFailure(code: .frameTooLarge)
        case .truncatedFrame:
          ClairDaemonControlFailure(code: .truncatedFrame)
        case .trailingFrameBytes:
          ClairDaemonControlFailure(code: .trailingFrame)
        default:
          ClairDaemonControlFailure(code: .malformedRequest)
        }
      case .malformedRequest:
        ClairDaemonControlFailure(code: .malformedRequest)
      default:
        ClairDaemonControlFailure(code: .internalFailure)
      }
    }
  }

#endif
