#if os(macOS)
  import XCTest

  @testable import ClairAppKit
  @testable import ClairEditorCore
  @testable import ClairWorkspace

  private final class BlockingFileScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func arm() { lock.withLock { armed = true } }
    func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 3) == .success }

    func scan(_ root: String) -> [WorkbenchFile] {
      let shouldBlock = lock.withLock {
        defer { armed = false }
        return armed
      }
      if shouldBlock {
        started.signal()
        release.wait()
      }
      return WorkbenchFiles.scan(root)
    }
  }

  @MainActor final class EditorBuffersTests: XCTestCase {
    private func root(_ files: [String: Data]) throws -> String {
      let d = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
      for (n, data) in files { try data.write(to: d.appending(path: n)) }
      return d.path
    }

    private func waitUntil(
      timeout: Duration = .seconds(3), _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: timeout)
      while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
      }
      return condition()
    }

    private func openWatchedProject(_ root: String, in store: ClairWorkbenchStore) async throws {
      _ = try store.run("project.open", ["path": .string(root)]).get()
      let loaded = await waitUntil { store.state.files.contains { $0.path == "a.txt" } }
      XCTAssertTrue(loaded)
    }

    func testCommandWClosesActiveFileAndSelectsAnother() throws {
      let path = try root(["a.txt": Data("a".utf8), "b.txt": Data("b".utf8)])
      let store = ClairWorkbenchStore(persistAt: nil)
      _ = try store.run("project.open", ["path": .string(path)]).get()
      _ = try store.run("file.open", ["path": .string(path + "/a.txt")]).get()
      _ = try store.run("file.open", ["path": .string(path + "/b.txt")]).get()
      let editorID = store.state.tree.leaves.first!.id
      store.performFromUI("pane.close")
      XCTAssertEqual(store.state.active, "a.txt")
      XCTAssertEqual(store.state.tabs, ["a.txt"])
      XCTAssertEqual(store.state.tree.leaves.first?.id, editorID)
      XCTAssertEqual(store.state.tree.leaves.first?.kind, .editor)
    }

    func testEditSaveAndDiskDrop() throws {
      let r = try root(["a.txt": Data("hi".utf8)])
      let b = EditorBuffers()
      guard case .ready(let m) = b.load("a.txt", root: r) else { return XCTFail("load") }
      _ = try m.apply([TextEdit(range: TextUTF8Range(UTF8Offset(2), UTF8Offset(2)), replacement: "!")])
      try b.save("a.txt", root: r)
      XCTAssertEqual(try String(contentsOfFile: r + "/a.txt", encoding: .utf8), "hi!")
      b.drop(["a.txt"])
      XCTAssertEqual(b.revision("a.txt"), 1)
      XCTAssertFalse(b.isOpen("a.txt"))
    }

    func testBlamePublishesWholeFileAndDropsWithBuffer() async throws {
      let r = try root(["a.txt": Data("first\nsecond\n".utf8)])
      defer { try? FileManager.default.removeItem(atPath: r) }
      func git(_ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = URL(fileURLWithPath: r)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(arguments)")
      }
      try git(["init", "-q"])
      try git(["add", "a.txt"])
      try git(["-c", "user.name=Blame Tester", "-c", "user.email=blame@example.invalid", "commit", "-qm", "initial lines"])

      let buffers = EditorBuffers()
      guard case .ready(let manager) = buffers.load("a.txt", root: r) else { return XCTFail("load") }
      buffers.startBlame("a.txt", root: r, snapshot: manager.buffer.snapshot)
      XCTAssertNil(buffers.blame["a.txt"], "no partial annotation while Git is working")
      let loaded = await waitUntil { buffers.blame["a.txt"] != nil }
      XCTAssertTrue(loaded)
      XCTAssertEqual(buffers.blame["a.txt"]?.count, 2) // Git has no entry for the empty line after the final newline.
      XCTAssertEqual(buffers.blame["a.txt"]?.first?.author, "Blame Tester")
      XCTAssertEqual(buffers.blame["a.txt"]?.first?.summary, "initial lines")
      buffers.drop(["a.txt"])
      XCTAssertNil(buffers.blame["a.txt"])
    }

    func testBinaryAndMissingFilesAreRefused() throws {
      let r = try root(["b.bin": Data([0xff, 0xfe, 0x00])])
      let b = EditorBuffers()
      for p in ["b.bin", "nope"] { if case .ready = b.load(p, root: r) { XCTFail(p) } }
    }

    func testTenMiBPrefetchAndRapidSwitchingDoNotBlockTheMainActor() async throws {
      let exact = Data(repeating: Character("a").asciiValue!, count: EditorBuffers.maxBytes)
      let r = try root(["a.swift": exact, "b.swift": exact])
      defer { try? FileManager.default.removeItem(atPath: r) }
      let buffers = EditorBuffers()
      var tasks: [Task<Void, Never>] = []

      let interactionStart = ProcessInfo.processInfo.systemUptime
      for path in ["a.swift", "b.swift", "a.swift", "b.swift"] {
        tasks.last?.cancel()
        tasks.append(Task { await buffers.prefetch(path, root: r) })
        await Task.yield()
      }
      let interactionElapsed = ProcessInfo.processInfo.systemUptime - interactionStart
      XCTAssertLessThan(interactionElapsed, 0.2, "rapid tab selection must only schedule background work")

      for task in tasks { await task.value }
      XCTAssertTrue(buffers.isOpen("b.swift"), "the final selection must recover even if an earlier load of the same path was cancelled")

      try Data(repeating: Character("b").asciiValue!, count: EditorBuffers.maxBytes + 1)
        .write(to: URL(fileURLWithPath: r + "/too-large.swift"))
      await buffers.prefetch("too-large.swift", root: r)
      guard case .failed(let message)? = buffers.peek("too-large.swift") else { return XCTFail("size limit") }
      XCTAssertTrue(message.contains("\(EditorBuffers.maxBytes >> 20) MiB"))
    }

    func testDropDuringPrefetchRejectsTheOldSnapshot() async throws {
      let old = Data(repeating: Character("x").asciiValue!, count: 5 * 1024 * 1024)
      let r = try root(["a.swift": old])
      defer { try? FileManager.default.removeItem(atPath: r) }
      let buffers = EditorBuffers()
      let task = Task { await buffers.prefetch("a.swift", root: r) }
      await Task.yield()
      try Data("new\n".utf8).write(to: URL(fileURLWithPath: r + "/a.swift"), options: .atomic)
      buffers.drop(["a.swift"])
      await task.value

      guard case .ready(let manager)? = buffers.peek("a.swift") else { return XCTFail("reload") }
      XCTAssertEqual(manager.buffer.snapshot.string(), "new\n")
    }

    func testWorkspacePersistenceRunsOutsideTheMainActor() async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      let file = directory.appending(path: "workspace.json")
      defer { try? FileManager.default.removeItem(at: directory) }

      let store = ClairWorkbenchStore(persistAt: file)
      store.run("palette.commands")
      try await Task.sleep(for: .milliseconds(250))

      XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
      XCTAssertNotNil(WorkbenchState.restore(from: file, scanFiles: false))
    }

    func testBackgroundGitStageKeepsUnsavedEditorBuffer() async throws {
      let r = try root(["a.txt": Data("a".utf8)])
      defer { try? FileManager.default.removeItem(atPath: r) }
      XCTAssertTrue(WorkbenchGit.run(r, ["init", "-b", "main"], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["-c", "user.name=t", "-c", "user.email=t@t", "add", "."], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"], merge: true).ok)
      try "disk".write(toFile: r + "/a.txt", atomically: true, encoding: .utf8)

      let store = ClairWorkbenchStore(persistAt: nil)
      store.state = WorkbenchState()
      store.state.openProject(WorkbenchProject(name: "git-fixture", path: r))
      store.state.openTab("a.txt")
      guard case .ready(let manager) = store.buffers.load("a.txt", root: r) else { return XCTFail("load") }
      _ = try manager.apply([TextEdit(range: TextUTF8Range(UTF8Offset(4), UTF8Offset(4)), replacement: "-unsaved")])
      store.edited("a.txt")

      let error = await store.performGitFromUI([("git.stage", ["path": .string("a.txt")])])
      XCTAssertNil(error)
      XCTAssertTrue(store.buffers.isOpen("a.txt"))
      XCTAssertEqual(manager.buffer.snapshot.string(), "disk-unsaved")
      XCTAssertTrue(store.state.dirty.contains("a.txt"))
    }

    func testEditMadeDuringSlowBranchSwitchIsPreserved() async throws {
      let r = try root(["a.txt": Data("main".utf8)])
      defer { try? FileManager.default.removeItem(atPath: r) }
      XCTAssertTrue(WorkbenchGit.run(r, ["init", "-b", "main"], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["-c", "user.name=t", "-c", "user.email=t@t", "add", "."], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "main"], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["switch", "-c", "topic"], merge: true).ok)
      try "topic".write(toFile: r + "/a.txt", atomically: true, encoding: .utf8)
      XCTAssertTrue(WorkbenchGit.run(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-am", "topic"], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["switch", "main"], merge: true).ok)
      let hook = r + "/.git/hooks/post-checkout"
      try "#!/bin/sh\nsleep 0.25\n".write(toFile: hook, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)

      let store = ClairWorkbenchStore(persistAt: nil)
      try await openWatchedProject(r, in: store)
      store.state.openTab("a.txt")
      guard case .ready(let manager) = store.buffers.load("a.txt", root: r) else { return XCTFail("load") }

      let switching = Task { await store.performGitFromUI([("git.switch", ["name": .string("topic")])]) }
      try await Task.sleep(for: .milliseconds(50))
      _ = try manager.apply([TextEdit(range: TextUTF8Range(UTF8Offset(4), UTF8Offset(4)), replacement: "-unsaved")])
      store.edited("a.txt")

      let switchError = await switching.value
      XCTAssertNil(switchError)
      XCTAssertEqual(WorkbenchGit.currentBranch(r), "topic")
      XCTAssertTrue(store.buffers.isOpen("a.txt"))
      XCTAssertEqual(manager.buffer.snapshot.string(), "main-unsaved")
      XCTAssertTrue(store.state.dirty.contains("a.txt"))
      XCTAssertEqual(try String(contentsOfFile: r + "/a.txt", encoding: .utf8), "topic")
    }

    func testBranchSwitchInvalidatesClosedTabCache() async throws {
      let r = try root(["a.txt": Data("main".utf8)])
      defer { try? FileManager.default.removeItem(atPath: r) }
      XCTAssertTrue(WorkbenchGit.run(r, ["init", "-b", "main"], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["-c", "user.name=t", "-c", "user.email=t@t", "add", "."], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "main"], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["switch", "-c", "topic"], merge: true).ok)
      try "topic".write(toFile: r + "/a.txt", atomically: true, encoding: .utf8)
      XCTAssertTrue(WorkbenchGit.run(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-am", "topic"], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["switch", "main"], merge: true).ok)

      let store = ClairWorkbenchStore(persistAt: nil)
      try await openWatchedProject(r, in: store)
      store.state.openTab("a.txt")
      guard case .ready(let original) = store.buffers.load("a.txt", root: r) else { return XCTFail("load") }
      XCTAssertEqual(original.buffer.snapshot.string(), "main")
      _ = try store.run("tab.close", ["path": .string("a.txt")]).get()
      XCTAssertTrue(store.buffers.isOpen("a.txt"))

      let switchError = await store.performGitFromUI([("git.switch", ["name": .string("topic")])])
      XCTAssertNil(switchError)
      XCTAssertFalse(store.buffers.isOpen("a.txt"))
      guard case .ready(let reloaded) = store.buffers.load("a.txt", root: r) else { return XCTFail("reload") }
      XCTAssertEqual(reloaded.buffer.snapshot.string(), "topic")
    }

    func testWatcherReplaysExternalEditAfterGitCompletion() async throws {
      let r = try root(["a.txt": Data("main".utf8)])
      defer { try? FileManager.default.removeItem(atPath: r) }
      XCTAssertTrue(WorkbenchGit.run(r, ["init", "-b", "main"], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["-c", "user.name=t", "-c", "user.email=t@t", "add", "."], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "main"], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["switch", "-c", "topic"], merge: true).ok)

      let store = ClairWorkbenchStore(persistAt: nil)
      try await openWatchedProject(r, in: store)
      let switchError = await store.performGitFromUI([("git.switch", ["name": .string("main")])])
      XCTAssertNil(switchError)
      try "agent".write(toFile: r + "/agent.txt", atomically: true, encoding: .utf8)
      let observed = await waitUntil { store.state.files.contains { $0.path == "agent.txt" } }
      XCTAssertTrue(observed)
    }

    func testEditStartedDuringReplayedScanRemainsDirty() async throws {
      let r = try root(["a.txt": Data("main".utf8)])
      defer { try? FileManager.default.removeItem(atPath: r) }
      XCTAssertTrue(WorkbenchGit.run(r, ["init", "-b", "main"], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["-c", "user.name=t", "-c", "user.email=t@t", "add", "."], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "main"], merge: true).ok)
      XCTAssertTrue(WorkbenchGit.run(r, ["switch", "-c", "topic"], merge: true).ok)

      let scanner = BlockingFileScanner()
      let store = ClairWorkbenchStore(persistAt: nil, scanFiles: scanner.scan)
      try await openWatchedProject(r, in: store)
      let switchError = await store.performGitFromUI([("git.switch", ["name": .string("main")])])
      XCTAssertNil(switchError)

      scanner.arm()
      try "disk-after".write(toFile: r + "/a.txt", atomically: true, encoding: .utf8)
      try "agent".write(toFile: r + "/agent.txt", atomically: true, encoding: .utf8)
      let replayStarted = await Task.detached { scanner.waitUntilStarted() }.value
      XCTAssertTrue(replayStarted)
      guard case .ready(let manager) = store.buffers.load("a.txt", root: r) else {
        scanner.release.signal()
        return XCTFail("load")
      }
      _ = try manager.apply([
        TextEdit(range: TextUTF8Range(UTF8Offset(10), UTF8Offset(10)), replacement: "-unsaved")
      ])
      store.edited("a.txt")
      scanner.release.signal()

      let applied = await waitUntil { store.state.files.contains { $0.path == "agent.txt" } }
      XCTAssertTrue(applied)
      XCTAssertTrue(store.state.dirty.contains("a.txt"))
      XCTAssertTrue(store.buffers.isOpen("a.txt"))
      XCTAssertEqual(manager.buffer.snapshot.string(), "disk-after-unsaved")
    }
  }
#endif
