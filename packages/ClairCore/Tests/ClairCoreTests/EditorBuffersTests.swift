#if os(macOS)
  import XCTest

  @testable import ClairAppKit
  @testable import ClairEditorCore
  @testable import ClairWorkspace

  @MainActor final class EditorBuffersTests: XCTestCase {
    private func root(_ files: [String: Data]) throws -> String {
      let d = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
      for (n, data) in files { try data.write(to: d.appending(path: n)) }
      return d.path
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
      XCTAssertTrue(message.contains("10 MiB"))
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
  }
#endif
