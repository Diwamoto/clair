import Combine
import Foundation

@MainActor
final class TerminalSession: ObservableObject {
  enum Event: Sendable {
    case attached
    case output(Data)
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
  private var transcriptObservers: [UUID: (String) -> Void] = [:]
  private var eventObservers: [UUID: (Event) -> Void] = [:]
  private var pendingCommands: [Data] = []

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
      "Not started"
    case .starting:
      "Starting"
    case .running:
      "Running"
    case .stopping:
      "Stopping"
    case .exited(let status):
      status == 0 ? "Exited" : "Exited (\(status))"
    case .missing(let message):
      "Session unavailable: \(message)"
    case .failed(let message):
      "Failed: \(message)"
    }
  }

  func start() {
    guard case .idle = state else {
      return
    }
    guard let ptyHostURL else {
      fail("clair-ptyhost was not found. Build the Rust workspace first.")
      return
    }
    guard let brokerPaths else {
      fail("Clair's local session broker path is unavailable.")
      return
    }

    state = .starting
    let client = SessionBrokerClient(paths: brokerPaths, ptyHostURL: ptyHostURL)
    client.onFrame = { [weak self] frame in
      self?.receive(frame)
    }
    client.onDisconnect = { [weak self] in
      self?.handleDisconnect()
    }
    brokerClient = client

    do {
      try client.start(
        mode: startMode == .create ? .create : .reattach,
        sessionID: sessionID,
        cursor: outputCursor,
        dimensions: dimensions,
        cwd: projectRootURL.path,
        shell: shellURL.path
      )
    } catch {
      brokerClient = nil
      fail("Could not connect to the local session broker: \(error.localizedDescription)")
    }
  }

  func stop() {
    guard brokerClient != nil, isRunning else {
      return
    }
    state = .stopping
    do {
      try brokerClient?.send(.terminate)
    } catch {
      fail("Could not terminate terminal session: \(error.localizedDescription)")
    }
  }

  func startNewSession() {
    guard case .missing = state else {
      return
    }
    brokerClient?.close()
    brokerClient = nil
    startMode = .create
    outputCursor = 0
    sessionEpoch = nil
    transcriptBuffer.reset()
    transcript = ""
    pendingCommands.removeAll()
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
      pendingCommands.append(data)
    case .running:
      sendInput(data)
    case .stopping, .exited, .missing, .failed:
      return
    }
  }

  func sendInput(_ data: Data) {
    guard case .running = state, !data.isEmpty else {
      return
    }
    do {
      try brokerClient?.send(try SessionBrokerFrame.input(data))
    } catch {
      fail("Could not write to terminal session: \(error.localizedDescription)")
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
    guard case .running = state else {
      return
    }
    do {
      try brokerClient?.send(try SessionBrokerFrame.resize(rows: rows, columns: columns))
    } catch {
      fail("Could not resize terminal session: \(error.localizedDescription)")
    }
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
    return id
  }

  func removeEventObserver(_ id: UUID) {
    eventObservers[id] = nil
  }

  private func receive(_ frame: SessionBrokerFrame) {
    switch frame.kind {
    case .attached:
      do {
        let attachment = try SessionBrokerAttachment(frame: frame)
        guard attachment.sessionID == sessionID, attachment.epoch > 0 else {
          fail("Session broker returned an invalid attachment.")
          return
        }
        sessionEpoch = attachment.epoch
        if attachment.isExited {
          return
        }
        state = .running
        publishEvent(.attached)
        flushPendingCommands()
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
        publishEvent(.output(output.data))
        if effects.bellCount > 0 {
          publishEvent(.bell(count: effects.bellCount))
        }
        outputCursor = output.offset + UInt64(output.data.count)
      } catch {
        fail("Session broker output error: \(error)")
        return
      }
      publishTranscript()
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
        state = .exited(Int(exit.status))
        publishEvent(.exited(Int(exit.status)))
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
          state = .missing(message)
          publishEvent(.failed(message))
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
    transcriptBuffer.append(
      Data("[terminal output gap: offsets \(start)..<\(end) were not retained]\n".utf8)
    )
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

  private func flushPendingCommands() {
    guard case .running = state else {
      return
    }
    let commands = pendingCommands
    pendingCommands.removeAll()
    for command in commands {
      sendInput(command)
    }
  }

  private func handleDisconnect() {
    if case .failed = state {
      return
    }
    if case .missing = state {
      return
    }
    if case .exited = state {
      return
    }
    let message = "The local session broker connection closed."
    state = .failed(message)
    publishEvent(.failed(message))
  }

  private func fail(_ message: String) {
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
