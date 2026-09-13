#if os(macOS)

  import Darwin
  import Foundation
  import Testing

  @testable import ClairV2DaemonKit
  @testable import ClairV2Shared

  @Test
  func daemonLifecycleServesHealthAndVersionOverTheLocalControlChannel() throws {
    let (directory, configuration) = try makeDaemonConfiguration()
    defer { try? FileManager.default.removeItem(at: directory) }

    let daemon = ClairDaemonRuntime(configuration: configuration)
    try daemon.start()
    defer { try? daemon.stop() }

    let client = ClairDaemonControlClient(
      paths: configuration.paths,
      frameLimits: configuration.frameLimits
    )
    let health = try client.health()
    #expect(health.status == .healthy)
    #expect(health.lifecycle == .running)
    #expect(health.processID == ProcessInfo.processInfo.processIdentifier)
    #expect(health.version == configuration.version)

    let version = try client.version()
    #expect(version == configuration.version)
    #expect(ownerOnlyPermissions(at: configuration.paths.directoryURL))
    #expect(ownerOnlyPermissions(at: configuration.paths.socketURL))
  }

  @Test
  func daemonRejectsASecondOwnerWithoutDisturbingTheFirstInstance() throws {
    let (directory, configuration) = try makeDaemonConfiguration()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = ClairDaemon(configuration: configuration)
    let second = ClairDaemon(configuration: configuration)
    try first.start()
    defer { try? first.stop() }

    do {
      try second.start()
      Issue.record("The second daemon unexpectedly acquired the runtime lock.")
    } catch let error as ClairDaemonError {
      #expect(error == .alreadyRunning)
    }
    #expect(second.state == .stopped)
    #expect(try ClairDaemonControlClient(paths: configuration.paths).health().lifecycle == .running)
  }

  @Test
  func daemonShutdownRemovesTheSocketAndSupportsACleanRestart() throws {
    let (directory, configuration) = try makeDaemonConfiguration()
    defer { try? FileManager.default.removeItem(at: directory) }

    let daemon = ClairDaemon(configuration: configuration)
    try daemon.start()
    defer { try? daemon.stop() }

    let client = ClairDaemonControlClient(paths: configuration.paths)
    try client.shutdown()
    #expect(daemon.state == .stopped)
    #expect(!FileManager.default.fileExists(atPath: configuration.paths.socketURL.path))

    do {
      _ = try client.health()
      Issue.record("The stopped daemon unexpectedly served a health response.")
    } catch let error as ClairDaemonError {
      #expect(error == .controlSocketMissing)
    }

    try daemon.start()
    #expect(try client.health().lifecycle == .running)
    try daemon.restart()
    #expect(try client.health().status == .healthy)
    try daemon.stop()
    try daemon.stop()
    #expect(daemon.state == .stopped)
  }

  @Test
  func daemonReturnsTypedFailuresForMalformedAndUnsafeControlInput() throws {
    let (directory, configuration) = try makeDaemonConfiguration()
    defer { try? FileManager.default.removeItem(at: directory) }

    let daemon = ClairDaemon(configuration: configuration)
    try daemon.start()
    defer { try? daemon.stop() }

    let malformedPayload = Data("not-json".utf8)
    let malformedResponse = try sendRawPayload(malformedPayload, configuration: configuration)
    expectFailure(malformedResponse, code: .malformedRequest)

    let truncatedFrame = Data([0, 0, 0, 8, 0x7b])
    let truncatedResponse = try sendRawBytes(truncatedFrame, configuration: configuration)
    expectFailure(truncatedResponse, code: .truncatedFrame)

    let oversizedFrame = Data([0, 1, 0, 1])
    let oversizedResponse = try sendRawBytes(oversizedFrame, configuration: configuration)
    expectFailure(oversizedResponse, code: .frameTooLarge)

    let first = try ProtocolCodec.encodeFrame(
      ClairDaemonControlRequest.health,
      limits: configuration.frameLimits
    )
    let second = try ProtocolCodec.encodeFrame(
      ClairDaemonControlRequest.version,
      limits: configuration.frameLimits
    )
    let trailingResponse = try sendRawBytes(first + second, configuration: configuration)
    expectFailure(trailingResponse, code: .trailingFrame)
  }

  @Test
  func daemonReleasesTheLockWhenSocketSetupFails() throws {
    let (directory, configuration) = try makeDaemonConfiguration()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: configuration.paths.directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try Data([1, 2, 3]).write(to: configuration.paths.socketURL)

    let failed = ClairDaemon(configuration: configuration)
    do {
      try failed.start()
      Issue.record("The daemon unexpectedly replaced a regular control-socket file.")
    } catch let error as ClairDaemonError {
      #expect(error == .controlSocketOccupied)
    }
    #expect(failed.state == .stopped)

    try FileManager.default.removeItem(at: configuration.paths.socketURL)
    let retry = ClairDaemon(configuration: configuration)
    try retry.start()
    defer { try? retry.stop() }
    #expect(try ClairDaemonControlClient(paths: configuration.paths).health().status == .healthy)
  }

  @Test
  func daemonRejectsASymbolicLinkAtTheLockPath() throws {
    let (directory, configuration) = try makeDaemonConfiguration()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: configuration.paths.directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let target = configuration.paths.directoryURL.appendingPathComponent("lock-target")
    try Data().write(to: target)
    try FileManager.default.createSymbolicLink(
      at: configuration.paths.lockURL,
      withDestinationURL: target
    )

    let daemon = ClairDaemon(configuration: configuration)
    do {
      try daemon.start()
      Issue.record("The daemon unexpectedly followed a lock-path symbolic link.")
    } catch let error as ClairDaemonError {
      #expect(error == .lockPathOccupied)
    }
    #expect(daemon.state == .stopped)
  }

  private func makeDaemonConfiguration() throws -> (URL, ClairDaemonConfiguration) {
    let directory = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("clair-v2-h01-\(UUID().uuidString)", isDirectory: true)
    let paths = ClairDaemonPaths(directoryURL: directory)
    return (directory, try ClairDaemonConfiguration(paths: paths))
  }

  private func ownerOnlyPermissions(at url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let permissions = attributes[.posixPermissions] as? NSNumber
    else {
      return false
    }
    return permissions.intValue & 0o077 == 0
  }

  private func sendRawPayload(
    _ payload: Data,
    configuration: ClairDaemonConfiguration
  ) throws -> ClairDaemonControlResponse {
    let frame = try BoundedFrame(payload: payload, limits: configuration.frameLimits).encoded
    return try sendRawBytes(frame, configuration: configuration)
  }

  private func sendRawBytes(
    _ bytes: Data,
    configuration: ClairDaemonConfiguration
  ) throws -> ClairDaemonControlResponse {
    let descriptor = try ClairDaemonSocketSupport.connect(
      to: configuration.paths,
      timeout: ClairDaemonSocketSupport.controlTimeout
    )
    defer { Darwin.close(descriptor) }
    try ClairDaemonSocketSupport.writeAll(bytes, to: descriptor)
    _ = Darwin.shutdown(descriptor, SHUT_WR)
    let frames = try ClairDaemonSocketSupport.readFrames(
      from: descriptor,
      limits: configuration.frameLimits,
      direction: .response
    )
    #expect(frames.count == 1)
    return try ProtocolCodec.decode(
      ClairDaemonControlResponse.self,
      from: frames[0].payload,
      limits: configuration.frameLimits
    )
  }

  private func expectFailure(
    _ response: ClairDaemonControlResponse,
    code: ClairDaemonControlFailureCode
  ) {
    guard case .failure(let failure) = response else {
      Issue.record("Expected a typed control failure, received \(response).")
      return
    }
    #expect(failure.code == code)
  }

#endif
