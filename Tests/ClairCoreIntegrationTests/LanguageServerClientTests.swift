import ClairEditorView
import Foundation
import Testing

@testable import ClairEditorCore
@testable import ClairEditorLanguage

/// E12: the language-server client against a real gopls (skipped when gopls
/// is not installed; `CLAIR_TEST_PATH` prepends extra PATH entries, e.g. a
/// throwaway Go toolchain) and a scripted fake server for the races a real
/// server cannot be made to lose on demand.
#if os(macOS)
  @Suite(.serialized)
  struct LanguageServerClientTests {
    static let source = """
      package main

      import "fmt"

      type Greeter struct{ Name string }

      func (g Greeter) Hello() string { return "hi " + g.Name }

      func main() {
      \tg := Greeter{Name: "x"}
      \tfmt.Println(g.Hello())
      \tvar unused int
      }

      """

    /// Collects every diagnostics publish, in order.
    final class Inbox: @unchecked Sendable {
      private let lock = NSLock()
      private var items: [(String, TextRevision, [EditorDiagnosticSpan])] = []
      func add(_ p: String, _ r: TextRevision, _ d: [EditorDiagnosticSpan]) { lock.withLock { items.append((p, r, d)) } }
      var all: [(String, TextRevision, [EditorDiagnosticSpan])] { lock.withLock { items } }
    }

    static var path: String {
      (ProcessInfo.processInfo.environment["CLAIR_TEST_PATH"].map { $0 + ":" } ?? "") + LanguageServerCommand.loginPath
    }

    private func goProject() throws -> URL {
      let dir = FileManager.default.temporaryDirectory.appending(path: "clair-e12-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try "module example.com/e12\n\ngo 1.21\n".write(to: dir.appending(path: "go.mod"), atomically: true, encoding: .utf8)
      try Self.source.write(to: dir.appending(path: "main.go"), atomically: true, encoding: .utf8)
      return dir.resolvingSymlinksInPath()
    }

    private func gopls(root: URL, inbox: Inbox) -> LanguageServerClient? {
      let command = EditorLanguageID.go.languageServer!
      guard let exe = command.resolve(path: Self.path) else { return nil }
      var env = ProcessInfo.processInfo.environment
      env["PATH"] = Self.path
      return LanguageServerClient(command: command, executable: exe, root: root, environment: env) {
        inbox.add($0, $1, $2)
      }
    }

    private func wait(_ timeout: Duration = .seconds(30), until done: () async -> Bool) async -> Bool {
      let clock = ContinuousClock()
      let end = clock.now + timeout
      while clock.now < end {
        if await done() { return true }
        try? await Task.sleep(for: .milliseconds(50))
      }
      return false
    }

    private func offset(of needle: String, in text: String, plus: Int = 0) -> UTF8Offset {
      let r = text.range(of: needle)!
      return UTF8Offset(text.utf8.distance(from: text.startIndex, to: r.lowerBound) + plus)
    }

    @Test func e12GoplsDiagnosticsFollowRevisionsAndNavigationWorks() async throws {
      let root = try goProject()
      let inbox = Inbox()
      guard let client = gopls(root: root, inbox: inbox) else {
        print("E12: gopls not installed; skipping the real-server test")
        return
      }
      let file = root.appending(path: "main.go").path
      let buffer = try TextBuffer(Self.source)
      let v1 = buffer.snapshot
      await client.open(path: file, languageID: "go", snapshot: v1)

      // Diagnostics: `unused` is declared and not used, underlined in the right place.
      #expect(await wait { inbox.all.contains { $0.1 == v1.revision && !$0.2.isEmpty } })
      let first = try #require(inbox.all.last { $0.1 == v1.revision && !$0.2.isEmpty })
      #expect(first.0 == file)
      let unused = try #require(first.2.first { $0.message.contains("unused") })
      #expect(try v1.text(in: unused.range) == "unused")
      #expect(unused.severity == .error)

      // An incremental edit that removes the problem clears it at the new revision.
      let line = "\tvar unused int\n"
      let start = offset(of: line, in: Self.source)
      let edit = TextEdit(range: TextUTF8Range(start, UTF8Offset(start.value + line.utf8.count)), replacement: "")
      try buffer.replace(edit.range, with: edit.replacement, basedOn: buffer.snapshot.revision)
      let v2 = buffer.snapshot
      await client.change(path: file, edits: [edit], old: v1, new: v2)
      #expect(await wait { inbox.all.contains { $0.1 == v2.revision && $0.2.isEmpty } })
      #expect(!inbox.all.contains { $0.1 == v2.revision && !$0.2.isEmpty })

      // Completion after `g.` on the current revision.
      let dot = offset(of: "g.Hello()", in: v2.string(), plus: 2)
      let completion = try #require(await client.completion(path: file, at: dot))
      #expect(completion.items.contains { $0.label == "Hello" })
      #expect(completion.items.contains { $0.label == "Name" })
      #expect(completion.snapshot.revision == v2.revision)

      // Definition of `Hello` lands on its declaration line (0-based 6).
      let defs = try #require(await client.definition(path: file, at: UTF8Offset(dot.value + 1)))
      #expect(defs.contains { $0.path == file && $0.line == 6 })

      // References of `Greeter`: the declaration, the receiver, the literal.
      let refs = try #require(await client.references(path: file, at: offset(of: "Greeter struct", in: v2.string())))
      #expect(refs.filter { $0.path == file }.count >= 3)

      // Workspace symbol search.
      #expect(await wait { await client.symbols(matching: "Greeter").contains { $0.title.hasPrefix("Greeter") && $0.path == file } })

      // Crash: kill -9 the server; it comes back and republishes for the latest revision.
      let pid = try #require(await client.pid)
      kill(pid, SIGKILL)
      #expect(await wait { await client.pid.map { $0 != pid } ?? false })
      #expect(await wait { await client.status == .running })
      let beforeCount = inbox.all.count
      #expect(await wait { inbox.all.dropFirst(beforeCount).contains { $0.1 == v2.revision } })
      #expect(try #require(await client.completion(path: file, at: dot)).items.contains { $0.label == "Hello" })

      await client.stop()
      #expect(await client.status == .stopped)
      #expect(await client.completion(path: file, at: dot) == nil)
      try? FileManager.default.removeItem(at: root)
    }

    /// A fake server that answers `completion` only after 400 ms and dies on
    /// `didClose`, so a stale answer and repeated crashes are deterministic.
    static let fakeServer = #"""
      import json, sys, time
      def read():
          n = 0
          while True:
              line = sys.stdin.buffer.readline()
              if not line: sys.exit(0)
              if line in (b"\r\n", b"\n"): break
              k, v = line.decode().split(":", 1)
              if k.lower() == "content-length": n = int(v)
          return json.loads(sys.stdin.buffer.read(n))
      def send(o):
          b = json.dumps(o).encode()
          sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(b) + b); sys.stdout.buffer.flush()
      while True:
          m = read(); meth = m.get("method")
          if meth == "initialize": send({"jsonrpc": "2.0", "id": m["id"], "result": {"capabilities": {"completionProvider": {"triggerCharacters": ["."]}}}})
          elif meth == "textDocument/completion":
              time.sleep(0.4); send({"jsonrpc": "2.0", "id": m["id"], "result": [{"label": "late"}]})
          elif meth == "textDocument/didClose": sys.exit(3)
          elif "id" in m: send({"jsonrpc": "2.0", "id": m["id"], "result": None})
      """#

    private func fake(inbox: Inbox, status: @escaping @Sendable (LanguageServerClient.Status) -> Void = { _ in }) throws -> LanguageServerClient? {
      guard let python = LanguageServerCommand(executable: "python3").resolve(path: "/usr/bin:/opt/homebrew/bin") else { return nil }
      let script = FileManager.default.temporaryDirectory.appending(path: "clair-e12-fake-\(UUID().uuidString).py")
      try Self.fakeServer.write(to: script, atomically: true, encoding: .utf8)
      return LanguageServerClient(
        command: LanguageServerCommand(executable: "python3", arguments: [script.path]), executable: python,
        root: FileManager.default.temporaryDirectory, onDiagnostics: { inbox.add($0, $1, $2) }, onStatus: status)
    }

    @Test func e12ACompletionAnsweredAfterAnEditIsRejectedAsStale() async throws {
      guard let client = try fake(inbox: Inbox()) else { return }
      let buffer = try TextBuffer("ab")
      let v1 = buffer.snapshot
      await client.open(path: "/tmp/e12-stale.txt", languageID: "plaintext", snapshot: v1)
      #expect(await client.triggerCharacters == ["."])
      // Same revision throughout: accepted.
      #expect(await client.completion(path: "/tmp/e12-stale.txt", at: UTF8Offset(1))?.items.map(\.label) == ["late"])
      // An edit lands while the answer is in flight: rejected, not re-applied (INV-REV-004).
      async let answer = client.completion(path: "/tmp/e12-stale.txt", at: UTF8Offset(1))
      try await Task.sleep(for: .milliseconds(150))
      let edit = TextEdit(range: TextUTF8Range(UTF8Offset(2), UTF8Offset(2)), replacement: "c")
      try buffer.replace(edit.range, with: edit.replacement, basedOn: buffer.snapshot.revision)
      await client.change(path: "/tmp/e12-stale.txt", edits: [edit], old: v1, new: buffer.snapshot)
      #expect(await answer == nil)
      await client.stop()
    }

    @Test func e12ACrashLoopingServerGivesUpWithAVisibleStatus() async throws {
      guard let client = try fake(inbox: Inbox()) else { return }
      let buffer = try TextBuffer("x")
      // Every close kills the fake; after maxCrashes restarts in the window the client stops trying.
      for i in 0...LanguageServerClient.maxCrashes {
        let path = "/tmp/e12-crash-\(i).txt"
        await client.open(path: path, languageID: "plaintext", snapshot: buffer.snapshot)
        let pid = await client.pid
        await client.close(path: path)
        _ = await wait(.seconds(5)) { await client.pid != pid }
      }
      #expect(await wait(.seconds(10)) { if case .failed = await client.status { true } else { false } })
      #expect(await client.completion(path: "/tmp/e12-crash-0.txt", at: UTF8Offset(0)) == nil)
    }
  }
#endif
