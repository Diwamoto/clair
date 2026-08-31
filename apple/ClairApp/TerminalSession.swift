import Combine
import Foundation

@MainActor
final class TerminalSession: ObservableObject {
  enum State: Equatable {
    case idle
    case starting
    case running
    case stopping
    case exited(Int)
    case failed(String)
  }

  let projectRootURL: URL
  let shellURL: URL
  let ptyHostURL: URL?

  @Published private(set) var transcript = ""
  @Published private(set) var state: State = .idle
  @Published private(set) var dimensions = TerminalDimensions.defaultDimensions

  private var process: Process?
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var frameDecoder = TerminalFrameDecoder()
  private var transcriptBuffer = TerminalTranscriptBuffer()
  private var transcriptObservers: [UUID: (String) -> Void] = [:]

  init(
    projectRootURL: URL,
    shellURL: URL = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ),
    ptyHostURL: URL? = PtyHostLocator.defaultURL()
  ) {
    self.projectRootURL = projectRootURL
    self.shellURL = shellURL
    self.ptyHostURL = ptyHostURL
  }

  deinit {
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    process?.terminationHandler = nil
    if let process, process.isRunning {
      process.terminate()
    }
  }

  var isRunning: Bool {
    switch state {
    case .starting, .running, .stopping:
      true
    case .idle, .exited, .failed:
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
    case .failed(let message):
      "Failed: \(message)"
    }
  }

  func start() {
    guard process == nil else {
      return
    }
    guard let ptyHostURL else {
      fail("clair-ptyhost was not found. Build the Rust workspace first.")
      return
    }

    state = .starting
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    let nextProcess = Process()
    nextProcess.executableURL = ptyHostURL
    nextProcess.arguments = [
      "--spawn",
      "--cwd",
      projectRootURL.path,
      "--shell",
      shellURL.path,
      "--rows",
      String(dimensions.rows),
      "--cols",
      String(dimensions.columns),
    ]
    nextProcess.currentDirectoryURL = projectRootURL
    nextProcess.standardInput = input
    nextProcess.standardOutput = output
    nextProcess.standardError = error
    nextProcess.terminationHandler = { [weak self] process in
      let status = process.terminationStatus
      Task { @MainActor [weak self] in
        self?.handleTermination(status: status)
      }
    }

    inputPipe = input
    outputPipe = output
    errorPipe = error
    process = nextProcess
    installOutputHandler(output.fileHandleForReading)
    installErrorHandler(error.fileHandleForReading)

    do {
      try nextProcess.run()
      state = .running
    } catch {
      clearPipeHandlers()
      process = nil
      inputPipe = nil
      outputPipe = nil
      errorPipe = nil
      fail("Could not start clair-ptyhost: \(error.localizedDescription)")
    }
  }

  func stop() {
    guard let process, process.isRunning else {
      return
    }
    state = .stopping
    do {
      try inputPipe?.fileHandleForWriting.write(contentsOf: TerminalFrame.close.encoded)
    } catch {
      process.terminate()
    }
  }

  func sendText(_ text: String) {
    guard !text.isEmpty else {
      return
    }
    sendInput(Data(text.utf8))
  }

  func sendInput(_ data: Data) {
    guard case .running = state, !data.isEmpty else {
      return
    }
    do {
      try inputPipe?.fileHandleForWriting.write(contentsOf: try TerminalFrame.input(data).encoded)
    } catch {
      fail("Could not write to PTY: \(error.localizedDescription)")
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
      try inputPipe?.fileHandleForWriting.write(
        contentsOf: try TerminalFrame.resize(rows: rows, columns: columns).encoded
      )
    } catch {
      fail("Could not resize PTY: \(error.localizedDescription)")
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

  private func installOutputHandler(_ handle: FileHandle) {
    handle.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        return
      }
      Task { @MainActor [weak self] in
        self?.receive(data)
      }
    }
  }

  private func installErrorHandler(_ handle: FileHandle) {
    handle.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        return
      }
      let message = String(decoding: data, as: UTF8.self)
      Task { @MainActor [weak self] in
        self?.receiveDiagnostic(message)
      }
    }
  }

  private func receive(_ data: Data) {
    do {
      for frame in try frameDecoder.append(data) {
        receive(frame)
      }
    } catch {
      fail("PTY protocol error: \(error)")
    }
  }

  private func receive(_ frame: TerminalFrame) {
    switch frame.kind {
    case .output:
      transcriptBuffer.append(frame.payload)
      transcript = transcriptBuffer.string
      for observer in transcriptObservers.values {
        observer(transcript)
      }
    case .exit:
      if let status = frame.payload.first {
        state = .exited(Int(status))
      }
    case .error:
      fail(String(decoding: frame.payload, as: UTF8.self))
    case .input, .resize, .close:
      fail("PTY host returned a client-only frame.")
    }
  }

  private func receiveDiagnostic(_ message: String) {
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    fail(message.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func handleTermination(status: Int32) {
    clearPipeHandlers()
    if case .failed = state {
      return
    }
    if case .exited = state {
      return
    }
    state = .exited(Int(status))
  }

  private func fail(_ message: String) {
    state = .failed(message)
    clearPipeHandlers()
    if let process, process.isRunning {
      do {
        try inputPipe?.fileHandleForWriting.write(contentsOf: TerminalFrame.close.encoded)
      } catch {
        process.terminate()
      }
    }
  }

  private func clearPipeHandlers() {
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
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
