import ClairDaemonKit
import ClairTerminal
import ClairWorkspace
import Darwin
import Dispatch
import Foundation

/// `--flag value` pairs; unknown flags fail so a typo never silently falls back to a default.
private func flags(_ args: [String]) -> [String: String]? {
  var result: [String: String] = [:]
  var i = 0
  while i < args.count {
    guard args[i].hasPrefix("--"), i + 1 < args.count else { return nil }
    result[String(args[i].dropFirst(2))] = args[i + 1]
    i += 2
  }
  return result
}

private func daemonClient(_ directory: String?) -> ClairDaemonControlClient {
  let dir = directory.map { URL(fileURLWithPath: $0) } ?? ClairChannel.current.dataURL
  return ClairDaemonControlClient(paths: ClairDaemonPaths(directoryURL: dir))
}

private func fail(_ message: String) -> Int32 {
  FileHandle.standardError.write(Data("clair: \(message)\n".utf8))
  return 1
}

private func windowSize() -> ClairTerminalSize {
  var w = winsize()
  guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_row > 0, w.ws_col > 0,
    let size = try? ClairTerminalSize(rows: w.ws_row, columns: w.ws_col)
  else { return try! ClairTerminalSize() }
  return size
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
  var rest = data[...]
  while !rest.isEmpty {
    let n = rest.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    if n < 0 && errno == EINTR { continue }
    guard n > 0 else { throw ClairTerminalAttachError.rejected }
    rest = rest.dropFirst(n)
  }
}

/// Bridges this process's terminal (the Ghostty surface's PTY) to a daemon-owned shell.
/// stdin EOF only detaches: the shell keeps running in the daemon.
func runAttach(_ args: [String]) -> Int32 {
  guard let f = flags(args), let key = f["key"], let cwd = f["cwd"],
    Set(f.keys).isSubset(of: ["key", "cwd", "command", "directory"])
  else { return fail("usage: clair attach --key <key> --cwd <path> [--command <cmd>] [--directory <dir>]") }
  let client = daemonClient(f["directory"])
  let environment = ProcessInfo.processInfo.environment.filter {
    ClairLocalTerminalHost.forwardedEnvironment.contains($0.key)
  }
  // The GUI starts the daemon just before it starts us, so give it a few seconds to come up.
  var attached: ClairTerminalAttach?
  var lastError: Error?
  for _ in 0..<50 where attached == nil {
    do {
      attached = try ClairTerminalAttach(
        client: client, key: key, cwd: cwd, command: f["command"], size: windowSize(), environment: environment)
    } catch {
      lastError = error
      Thread.sleep(forTimeInterval: 0.1)
    }
  }
  guard let attach = attached else { return fail("cannot attach: \(lastError.map { "\($0)" } ?? "unknown")") }

  var original = termios()
  let isTTY = tcgetattr(STDIN_FILENO, &original) == 0
  if isTTY {
    var raw = original
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
  }
  defer { if isTTY { tcsetattr(STDIN_FILENO, TCSANOW, &original) } }

  signal(SIGWINCH, SIG_IGN)
  let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
  winch.setEventHandler { let s = windowSize(); try? attach.resize(rows: s.rows, columns: s.columns) }
  winch.resume()

  // Replayed history still holds the queries apps sent the old surface (OSC 4/10/11 colors, DA,
  // XTVERSION…). The new surface answers them into our stdin, and forwarding those answers would
  // type them into the shell. So flush the backlog first and discard whatever the surface replied.
  // ponytail: a 2 s cap on replay and a 100 ms settle; a surface slower than that still leaks replies.
  let replayDeadline = Date().addingTimeInterval(2)
  var open = true
  do {
    var replayed = true
    while open, replayed, Date() < replayDeadline {
      replayed = false
      open = try attach.pump(waitMilliseconds: 0) { replayed = true; try writeAll(STDOUT_FILENO, $0) }
    }
  } catch { return fail("lost the daemon: \(error)") }
  if isTTY {
    Thread.sleep(forTimeInterval: 0.1)
    tcflush(STDIN_FILENO, TCIFLUSH)
  }

  let savedTermios = original
  let stdinReader = Thread {
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { break }
      do { try attach.send(Data(buffer.prefix(n))) } catch ClairTerminalAttachError.rejected {
        // The daemon refused these bytes (e.g. its input queue is full): drop them and ring the
        // bell, but keep the surface alive. Only EOF or a lost daemon ends the attachment.
        try? writeAll(STDOUT_FILENO, Data([0x07]))
      } catch { break }
    }
    // Surface closed (or the daemon went away): leave the shell where it is and stop.
    if isTTY {
      var restored = savedTermios
      tcsetattr(STDIN_FILENO, TCSANOW, &restored)
    }
    exit(0)
  }
  stdinReader.start()

  do {
    while open, try attach.pump({ try writeAll(STDOUT_FILENO, $0) }) {}
  } catch { return fail("lost the daemon: \(error)") }
  return 0
}

func runDaemonStop(_ args: [String]) -> Int32 {
  guard let f = flags(args), Set(f.keys).isSubset(of: ["directory"]) else {
    return fail("usage: clair daemon stop [--directory <dir>]")
  }
  do { try daemonClient(f["directory"]).shutdown() } catch { return fail("\(error)") }
  return 0
}

func runDaemonStatus(_ args: [String]) -> Int32 {
  guard let f = flags(args), Set(f.keys).isSubset(of: ["directory"]) else {
    return fail("usage: clair daemon status [--directory <dir>]")
  }
  return (try? daemonClient(f["directory"]).health()) == nil ? 1 : 0
}
