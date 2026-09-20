import ClairV2Workspace
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
guard let request = WorkbenchCLI.parse(Array(CommandLine.arguments.dropFirst())) else {
  FileHandle.standardError.write(Data("usage: clair open <path[:line[:col]]> | clair <command-id> [key=value ...]\n".utf8))
  exit(2)
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
