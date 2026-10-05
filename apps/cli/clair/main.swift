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
// `clair help [prefix]` lists the registry this binary was built with; it needs no running GUI.
if let first = CommandLine.arguments.dropFirst().first, ["help", "--help", "-h"].contains(first), CommandLine.arguments.count <= 3 {
  print(WorkbenchCLI.help(CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : ""))
  exit(0)
}
// `clair open --wait <path>` ($VISUAL / git editor): returns once that file has no tab in any open Project.
var args = Array(CommandLine.arguments.dropFirst())
let wait = args.first == "open" && args.count == 3 && args[1] == "--wait"
if wait { args.remove(at: 1) }
guard var request = WorkbenchCLI.parse(args) else {
  FileHandle.standardError.write(Data("usage: clair open [--wait] <path[:line[:col]]> | clair preview <html-path> | clair <command-id> [key=value ...]\n       clair help [prefix] lists the commands\n".utf8))
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
  let reply = try WorkbenchIPC.call(request, timeout: 90)  // may wait on a GUI approval card (60 s)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  print(String(decoding: try encoder.encode(reply), as: UTF8.self))
  guard wait, reply.error == nil else { exit(reply.error == nil ? 0 : 1) }
  let check = WorkbenchIPCRequest(command: "file.isOpen", input: ["path": request.input["path"]!], caller: request.caller)
  // ponytail: 0.5 s polling like agent.wait; a GUI push on tab close if latency or IPC load matters.
  while case .text("open")? = try WorkbenchIPC.call(check).result { Thread.sleep(forTimeInterval: 0.5) }
  exit(0)
} catch {
  FileHandle.standardError.write(Data("clair: \((error as? WorkbenchIPCError) == .notRunning ? "Clair is not running" : "\(error)")\n".utf8))
  exit(3)
}
