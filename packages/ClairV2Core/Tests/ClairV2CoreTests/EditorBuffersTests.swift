#if os(macOS)
  import XCTest

  @testable import ClairV2AppKit
  @testable import ClairV2EditorCore

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
  }
#endif
