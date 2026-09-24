import ClairWorkspace
import Foundation

// V02: `clair open path[:line:col]` / `clair <command-id> [key=value …]` → running Clair GUI.
// stdout: JSON reply. exit 0 ok, 1 command error, 2 usage, 3 GUI not running / IPC failure.
// V03: `clair mcp serve` — stdio MCP adapter (newline-delimited JSON-RPC). Authorization is enforced in the GUI.
if CommandLine.arguments.dropFirst().starts(with: ["mcp", "serve"]) {
  while let line = readLine() {
    if let out = MCPServer.respond(to: line, call: { try WorkbenchIPC.call($0, timeout: 90) }) { print(out); fflush(stdout) }
  }
  exit(0)
}
// T09: `clair attach` is the child a Ghostty surface runs; `clair daemon stop` ends the daemon and its shells;
// `clair daemon status` exits 0 only when the daemon answers (used by `make dev`).
if CommandLine.arguments.dropFirst().first == "attach" { exit(runAttach(Array(CommandLine.arguments.dropFirst(2)))) }
if CommandLine.arguments.dropFirst().starts(with: ["daemon", "stop"]) { exit(runDaemonStop(Array(CommandLine.arguments.dropFirst(3)))) }
if CommandLine.arguments.dropFirst().starts(with: ["daemon", "status"]) { exit(runDaemonStatus(Array(CommandLine.arguments.dropFirst(3)))) }
guard var request = WorkbenchCLI.parse(Array(CommandLine.arguments.dropFirst())) else {
  FileHandle.standardError.write(Data("usage: clair open <path[:line[:col]]> | clair <command-id> [key=value ...]\n".utf8))
  exit(2)
}
// V16: `clair agent.wait key=<root#pane> [timeout=<s>]` polls agent.status until that delegated agent exits
// (exit 0), or prints the last status and exits 1 at the timeout (default 1800 s). Client-side: one IPC call stays short.
if request.command == "agent.wait" {
  let deadline = Date().addingTimeInterval(TimeInterval(request.input["timeout"].flatMap { if case .int(let t) = $0 { t } else { nil } } ?? 1800))
  request.command = "agent.status"
  request.input["timeout"] = nil
  while true {
    guard let reply = try? WorkbenchIPC.call(request) else { FileHandle.standardError.write(Data("clair: Clair is not running\n".utf8)); exit(3) }
    let done = { if case .text(let t)? = reply.result { t.hasPrefix("exited") } else { false } }()
    if done || reply.error != nil || Date() > deadline {
      print(String(decoding: try! JSONEncoder().encode(reply), as: UTF8.self))
      exit(done ? 0 : 1)
    }
    Thread.sleep(forTimeInterval: 1)
  }
}
do {
  let reply = try WorkbenchIPC.call(request)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  print(String(decoding: try encoder.encode(reply), as: UTF8.self))
  exit(reply.error == nil ? 0 : 1)
} catch {
  FileHandle.standardError.write(Data("clair: \((error as? WorkbenchIPCError) == .notRunning ? "Clair is not running" : "\(error)")\n".utf8))
  exit(3)
}
