import ClairWorkspace
import Foundation

// V02: `clair open path[:line:col]` / `clair <group> <command> [key=value …]` → running Clair GUI.
// Output contract: `WorkbenchCLI` (ADR-0026). `attach` and `mcp serve` own stdout, so only they stand outside it.
let raw = Array(CommandLine.arguments.dropFirst())
let args = raw.filter { $0 != "--pretty" }

func finish(_ outcome: WorkbenchCLI.Outcome) -> Never {
  if let output = raw.contains("--pretty") ? outcome.pretty.output : outcome.output { print(output) }
  exit(outcome.code)
}

WorkbenchCLI.loadLanguage()
switch args.first {
// T09: the child a Ghostty surface runs. Its arguments are passed as given: `--command` may hold anything.
case "attach": exit(runAttach(Array(raw.dropFirst())))
// T09: `daemon stop` ends the daemon and its shells; `daemon status` exits 0 only when it answers (used by `make dev`).
case "daemon": finish(runDaemon(Array(args.dropFirst())))
// V03: stdio MCP adapter (newline-delimited JSON-RPC). Authorization is enforced in the GUI.
case "mcp" where args.dropFirst().first == "serve":
  while let line = readLine() {
    if let out = MCPServer.respond(to: line, call: { try WorkbenchIPC.call($0, timeout: 90) }) { print(out); fflush(stdout) }
  }
  exit(0)
default: finish(WorkbenchCLI.run(args))
}
