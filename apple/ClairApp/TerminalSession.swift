import Combine
import Foundation

@MainActor
final class TerminalSession: ObservableObject {
  private static let reconnectDelayNanoseconds: [UInt64] = [
    100_000_000,
    250_000_000,
    500_000_000,
    1_000_000_000,
    2_000_000_000,
    5_000_000_000,
  ]
  private static let maximumReconnectAttempts = 8
  private static let transcriptPublishDelayNanoseconds: UInt64 = 16_000_000

  enum Event: Sendable {
    case attached
    case output(Data)
    case screenReset(Data)
    case bell(count: Int)
    case exited(Int)
    case failed(String)
  }

  enum StartMode: Equatable, Sendable {
    case create
    case reattach
  }

  enum State: Equatable {
    case idle
    case starting
    case running
    case stopping
    case exited(Int)
    case missing(String)
    case failed(String)
  }

  let projectRootURL: URL
  let shellURL: URL
  let ptyHostURL: URL?
  let sessionID: UUID

  @Published private(set) var transcript = ""
  @Published private(set) var state: State = .idle
  @Published private(set) var dimensions = TerminalDimensions.defaultDimensions

  private let brokerPaths: SessionBrokerPaths?
  private var startMode: StartMode
  private var brokerClient: SessionBrokerClient?
  private var outputCursor: UInt64 = 0
  private var sessionEpoch: UInt64?
  private var transcriptBuffer = TerminalTranscriptBuffer()
  private var renderReplayBuffer = TerminalRenderReplayBuffer()
  private var transcriptObservers: [UUID: (String) -> Void] = [:]
  private var eventObservers: [UUID: (Event) -> Void] = [:]
  private var pendingInput = Data()
  private var pendingResize: TerminalDimensions?
  private var reconnectTask: Task<Void, Never>?
  private var resizeTask: Task<Void, Never>?
  private var transcriptPublishTask: Task<Void, Never>?
  private var transcriptPublishPending = false
  private var reconnectAttempt = 0
  private var connectionGeneration: UInt64 = 0

  init(
    projectRootURL: URL,
    sessionID: UUID = UUID(),
    startMode: StartMode = .create,
    shellURL: URL = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ),
    ptyHostURL: URL? = PtyHostLocator.defaultURL(),
    brokerPaths: SessionBrokerPaths? = SessionBrokerPaths.makeDefault(for: .current)
  ) {
    self.projectRootURL = projectRootURL
    self.sessionID = sessionID
    self.startMode = startMode
    self.shellURL = shellURL
    self.ptyHostURL = ptyHostURL
    self.brokerPaths = brokerPaths
  }

  var isRunning: Bool {
    switch state {
    case .starting, .running, .stopping:
      true
    case .idle, .exited, .missing, .failed:
      false
    }
  }

  var statusDescription: String {
    switch state {
    case .idle:
      "未開始"
    case .starting:
      "起動中"
    case .running:
      "実行中"
    case .stopping:
      "停止中"
    case .exited(let status):
      status == 0 ? "終了" : "終了 (\(status))"
    case .missing(let message):
      "セッションを利用できません: \(message)"
    case .failed(let message):
      "失敗: \(message)"
    }
  }

  func start() {
    guard case .idle = state else {
      return
    }
    reconnectAttempt = 0
    connect(mode: startMode)
  }

  func stop() {
    guard isRunning else {
      return
    }
    cancelReconnect()
    resizeTask?.cancel()
    resizeTask = nil
    guard let brokerClient else {
      fail("The terminal session could not be stopped because the broker is disconnected.")
      return
    }
    state = .stopping
    do {
      try brokerClient.send(.terminate)
    } catch {
      fail("Could not terminate terminal session: \(error.localizedDescription)")
    }
  }

  func startNewSession() {
    guard case .missing = state else {
      return
    }
    cancelScheduledWork()
    brokerClient?.close()
    brokerClient = nil
    startMode = .create
    outputCursor = 0
    sessionEpoch = nil
    transcriptBuffer.reset()
    renderReplayBuffer.reset()
    transcript = ""
    pendingInput.removeAll(keepingCapacity: true)
    pendingResize = nil
    state = .idle
    start()
  }

  func sendText(_ text: String) {
    guard !text.isEmpty else {
      return
    }
    sendInput(Data(text.utf8))
  }

  func sendCommandWhenReady(_ command: String) {
    guard !command.isEmpty else {
      return
    }
    let data = Data((command + "\n").utf8)
    switch state {
    case .idle, .starting:
      enqueuePendingInput(data)
    case .running:
      sendInput(data)
    case .stopping, .exited, .missing, .failed:
      return
    }
  }

  func sendInput(_ data: Data) {
    guard !data.isEmpty else {
      return
    }
    switch state {
    case .starting:
      enqueuePendingInput(data)
    case .running:
      sendInputImmediately(data)
    case .idle, .stopping, .exited, .missing, .failed:
      return
    }
  }

  func resize(rows: UInt16, columns: UInt16) {
    guard rows > 0, columns > 0 else {
      return
    }
    let nextDimensions = TerminalDimensions(rows: rows, columns: columns)
    guard nextDimensions != dimensions else {
      return
    }
    dimensions = nextDimensions
    pendingResize = nextDimensions
    guard case .running = state else {
      return
    }
    scheduleResizeSend()
  }

  func addTranscriptObserver(_ observer: @escaping (String) -> Void) -> UUID {
    let id = UUID()
    transcriptObservers[id] = observer
    observer(transcript)
    return id
  }

  func removeTranscriptObserver(_ id: UUID) {
    transcriptObservers[id] = nil
  }

  func addEventObserver(_ observer: @escaping (Event) -> Void) -> UUID {
    let id = UUID()
    eventObservers[id] = observer
    let replay = renderReplayBuffer.snapshot
    if !replay.isEmpty {
      observer(.output(replay))
    }
    return id
  }

  func removeEventObserver(_ id: UUID) {
    eventObservers[id] = nil
  }

  private func connect(mode: StartMode) {
    guard let ptyHostURL else {
      fail("clair-ptyhost was not found. Build the Rust workspace first.")
      return
    }
    guard let brokerPaths else {
      fail("Clair's local session broker path is unavailable.")
      return
    }

    state = .starting
    let generation = connectionGeneration &+ 1
    connectionGeneration = generation
    let client = SessionBrokerClient(paths: brokerPaths, ptyHostURL: ptyHostURL)
    client.onFrame = { [weak self] frame in
      self?.receive(frame, generation: generation)
    }
    client.onDisconnect = { [weak self] in
      self?.handleDisconnect(generation: generation)
    }
    brokerClient = client

    do {
      try client.start(
        mode: mode == .create ? .create : .reattach,
        sessionID: sessionID,
        cursor: outputCursor,
        dimensions: dimensions,
        cwd: projectRootURL.path,
        shell: shellURL.path
      )
    } catch {
      if brokerClient === client {
        brokerClient = nil
      }
      client.close()
      let message = "Could not connect to the local session broker: \(error.localizedDescription)"
      if mode == .reattach {
        scheduleReconnect(after: message)
      } else {
        fail(message)
      }
    }
  }

  private func receive(_ frame: SessionBrokerFrame, generation: UInt64) {
    guard generation == connectionGeneration else {
      return
    }
    switch frame.kind {
    case .attached:
      do {
        let attachment = try SessionBrokerAttachment(frame: frame)
        guard attachment.sessionID == sessionID, attachment.epoch > 0 else {
          fail("Session broker returned an invalid attachment.")
          return
        }
        let wasAlreadyAttached = state == .running && sessionEpoch == attachment.epoch
        sessionEpoch = attachment.epoch
        if attachment.isExited {
          return
        }
        guard !wasAlreadyAttached else {
          return
        }
        state = .running
        startMode = .reattach
        reconnectAttempt = 0
        cancelReconnect()
        publishEvent(.attached)
        flushPendingResize()
        flushPendingInput()
      } catch {
        fail("Session broker attachment error: \(error)")
      }
    case .output:
      do {
        let output = try SessionBrokerOutput(frame: frame)
        guard output.offset >= outputCursor else {
          return
        }
        if output.offset > outputCursor {
          receiveGap(start: outputCursor, end: output.offset)
        }
        let effects = transcriptBuffer.append(output.data)
        renderReplayBuffer.append(output.data)
        outputCursor = output.offset + UInt64(output.data.count)
        publishEvent(.output(output.data))
        if effects.bellCount > 0 {
          publishEvent(.bell(count: effects.bellCount))
        }
      } catch {
        fail("Session broker output error: \(error)")
        return
      }
      scheduleTranscriptPublish()
    case .gap:
      do {
        let gap = try SessionBrokerGap(frame: frame)
        receiveGap(start: gap.start, end: gap.end)
      } catch {
        fail("Session broker gap error: \(error)")
      }
    case .exit:
      do {
        let exit = try SessionBrokerExit(frame: frame)
        outputCursor = exit.offset
        cancelReconnect()
        resizeTask?.cancel()
        resizeTask = nil
        pendingInput.removeAll(keepingCapacity: true)
        pendingResize = nil
        state = .exited(Int(exit.status))
        publishEvent(.exited(Int(exit.status)))
        connectionGeneration &+= 1
        brokerClient?.close()
        brokerClient = nil
      } catch {
        fail("Session broker exit error: \(error)")
      }
    case .error:
      do {
        let errorFrame = try SessionBrokerErrorFrame(frame: frame)
        if errorFrame.code == .sessionMissing {
          let message = errorFrame.message.isEmpty ? "session is not available" : errorFrame.message
          cancelReconnect()
          resizeTask?.cancel()
          resizeTask = nil
          state = .missing(message)
          publishEvent(.failed(message))
          connectionGeneration &+= 1
          brokerClient?.close()
          brokerClient = nil
        } else {
          fail(
            errorFrame.message.isEmpty
              ? "Session broker returned an error."
              : errorFrame.message
          )
        }
      } catch {
        fail("Session broker error frame is malformed: \(error)")
      }
    case .attach, .input, .resize, .detach, .terminate:
      fail("Session broker returned a client-only frame.")
    }
  }

  private func receiveGap(start: UInt64, end: UInt64) {
    guard start < end else {
      fail("Session broker returned an invalid output gap.")
      return
    }
    outputCursor = end
    transcriptBuffer.reset()
    let marker = Data("[terminal output gap: offsets \(start)..<\(end) were not retained]\n".utf8)
    transcriptBuffer.append(marker)
    renderReplayBuffer.reset()
    renderReplayBuffer.append(marker)
    publishEvent(.screenReset(marker))
    publishTranscriptImmediately()
  }

  private func scheduleTranscriptPublish() {
    transcriptPublishPending = true
    guard transcriptPublishTask == nil else {
      return
    }
    transcriptPublishTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: Self.transcriptPublishDelayNanoseconds)
      } catch {
        return
      }
      guard let self, !Task.isCancelled else {
        return
      }
      self.transcriptPublishTask = nil
      self.publishPendingTranscript()
    }
  }

  private func publishPendingTranscript() {
    guard transcriptPublishPending else {
      return
    }
    transcriptPublishPending = false
    publishTranscript()
  }

  private func publishTranscriptImmediately() {
    transcriptPublishTask?.cancel()
    transcriptPublishTask = nil
    transcriptPublishPending = false
    publishTranscript()
  }

  private func publishTranscript() {
    transcript = transcriptBuffer.string
    for observer in transcriptObservers.values {
      observer(transcript)
    }
  }

  private func publishEvent(_ event: Event) {
    for observer in eventObservers.values {
      observer(event)
    }
  }

  private func enqueuePendingInput(_ data: Data) {
    guard !data.isEmpty else {
      return
    }
    pendingInput.append(data)
  }

  private func sendInputImmediately(_ data: Data) {
    var offset = 0
    while offset < data.count {
      let count = min(SessionBrokerFrame.maxPayloadLength, data.count - offset)
      let chunk = Data(data[offset..<(offset + count)])
      do {
        guard let brokerClient else {
          enqueuePendingInput(Data(data.dropFirst(offset)))
          handleTransportFailure("The local session broker is not connected.")
          return
        }
        try brokerClient.send(try SessionBrokerFrame.input(chunk))
      } catch {
        enqueuePendingInput(Data(data.dropFirst(offset)))
        handleTransportFailure("Could not write to terminal session: \(error.localizedDescription)")
        return
      }
      offset += count
    }
  }

  private func flushPendingInput() {
    guard case .running = state else {
      return
    }
    while !pendingInput.isEmpty {
      let count = min(SessionBrokerFrame.maxPayloadLength, pendingInput.count)
      let chunk = Data(pendingInput.prefix(count))
      do {
        guard let brokerClient else {
          handleTransportFailure("The local session broker is not connected.")
          return
        }
        try brokerClient.send(try SessionBrokerFrame.input(chunk))
        pendingInput.removeFirst(count)
      } catch {
        handleTransportFailure("Could not write to terminal session: \(error.localizedDescription)")
        return
      }
    }
  }

  private func scheduleResizeSend() {
    guard resizeTask == nil else {
      return
    }
    resizeTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: 16_000_000)
      } catch {
        return
      }
      guard let self, !Task.isCancelled else {
        return
      }
      self.resizeTask = nil
      self.flushPendingResize()
    }
  }

  private func flushPendingResize() {
    guard case .running = state, let pendingResize else {
      return
    }
    guard let brokerClient else {
      handleTransportFailure("The local session broker is not connected.")
      return
    }
    do {
      try brokerClient.send(
        try SessionBrokerFrame.resize(rows: pendingResize.rows, columns: pendingResize.columns)
      )
      self.pendingResize = nil
    } catch {
      handleTransportFailure("Could not resize terminal session: \(error.localizedDescription)")
    }
  }

  private func handleTransportFailure(_ message: String) {
    if sessionEpoch != nil || startMode == .reattach {
      scheduleReconnect(after: message)
    } else {
      fail(message)
    }
  }

  private func handleDisconnect(generation: UInt64) {
    guard generation == connectionGeneration else {
      return
    }
    if case .failed = state {
      return
    }
    if case .missing = state {
      return
    }
    if case .exited = state {
      return
    }
    brokerClient = nil
    let message = "The local session broker connection closed."
    switch state {
    case .starting, .running:
      scheduleReconnect(after: message)
    case .stopping:
      fail(message)
    case .idle, .exited, .missing, .failed:
      return
    }
  }

  private func scheduleReconnect(after message: String) {
    guard sessionEpoch != nil || startMode == .reattach else {
      fail(message)
      return
    }
    guard reconnectTask == nil else {
      return
    }
    guard reconnectAttempt < Self.maximumReconnectAttempts else {
      fail("The terminal session could not reconnect: \(message)")
      return
    }

    brokerClient?.close()
    brokerClient = nil
    state = .starting
    let delayIndex = min(reconnectAttempt, Self.reconnectDelayNanoseconds.count - 1)
    let delay = Self.reconnectDelayNanoseconds[delayIndex]
    reconnectAttempt += 1
    reconnectTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay)
      } catch {
        return
      }
      guard let self, !Task.isCancelled else {
        return
      }
      self.reconnectTask = nil
      guard case .starting = self.state else {
        return
      }
      self.connect(mode: .reattach)
    }
  }

  private func cancelReconnect() {
    reconnectTask?.cancel()
    reconnectTask = nil
  }

  private func cancelScheduledWork() {
    cancelReconnect()
    resizeTask?.cancel()
    resizeTask = nil
    transcriptPublishTask?.cancel()
    transcriptPublishTask = nil
    transcriptPublishPending = false
  }

  private func fail(_ message: String) {
    if transcriptPublishPending {
      publishTranscriptImmediately()
    }
    cancelScheduledWork()
    connectionGeneration &+= 1
    state = .failed(message)
    publishEvent(.failed(message))
    brokerClient?.close()
    brokerClient = nil
  }
}

struct PtyHostLocator {
  static func defaultURL(
    filePath: String = #filePath,
    fileManager: FileManager = .default
  ) -> URL? {
    var candidates: [URL] = []
    if let configuredPath = ProcessInfo.processInfo.environment["CLAIR_PTYHOST_PATH"] {
      candidates.append(URL(fileURLWithPath: configuredPath))
    }
    if let resourceURL = Bundle.main.resourceURL {
      candidates.append(resourceURL.appendingPathComponent("clair-ptyhost"))
    }

    let sourceURL = URL(fileURLWithPath: filePath)
    var sourceDirectory = sourceURL.deletingLastPathComponent()
    for _ in 0..<5 {
      candidates.append(sourceDirectory.appendingPathComponent("target/debug/clair-ptyhost"))
      sourceDirectory.deleteLastPathComponent()
    }

    var currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    for _ in 0..<5 {
      candidates.append(currentDirectory.appendingPathComponent("target/debug/clair-ptyhost"))
      currentDirectory.deleteLastPathComponent()
    }

    var seen = Set<String>()
    for candidate in candidates {
      let standardized = candidate.standardizedFileURL
      guard seen.insert(standardized.path).inserted else {
        continue
      }
      if fileManager.isExecutableFile(atPath: standardized.path) {
        return standardized
      }
    }
    return nil
  }
}
