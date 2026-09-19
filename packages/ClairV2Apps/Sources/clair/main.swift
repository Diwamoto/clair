import ClairV2Workspace
import Foundation

// V02: `clair open path[:line:col]` / `clair <command-id> [key=value …]` → running Clair GUI.
// stdout: JSON reply. exit 0 ok, 1 command error, 2 usage, 3 GUI not running / IPC failure.
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
