#if os(macOS)
  import XCTest

  @testable import ClairAppKit

  /// The HTML preview serves only the previewed file's own folder.
  @MainActor
  final class HTMLPreviewFilesTests: XCTestCase {
    func testServesSiblingsAndRefusesEscapes() throws {
      let top = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let dir = top.appendingPathComponent("site", isDirectory: true)
      try FileManager.default.createDirectory(at: dir.appendingPathComponent("css"), withIntermediateDirectories: true)
      try "x".write(to: dir.appendingPathComponent("css/app.css"), atomically: true, encoding: .utf8)
      try "secret".write(to: top.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
      try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("out.txt"), withDestinationURL: top.appendingPathComponent("secret.txt"))
      defer { try? FileManager.default.removeItem(at: top) }

      let served = { (s: String) in HTMLPreviewFiles.file(for: URL(string: "clair-preview://file/" + s)!, in: dir) }
      XCTAssertEqual(served("css/app.css")?.lastPathComponent, "app.css")
      XCTAssertEqual(served("./css/../css/app.css")?.lastPathComponent, "app.css")
      XCTAssertNil(served("../secret.txt"))
      XCTAssertNil(served("%2E%2E/secret.txt"))
      XCTAssertNil(served("out.txt"), "a symlink out of the folder")
      XCTAssertNil(served(""), "the folder itself")
    }

    func testDirectoryIsTheFilesOwnFolderEvenOutsideTheProject() {
      XCTAssertEqual(HTMLPreviewPane.directory(root: "/p/proj", path: "a/index.html")?.path, "/p/proj/a")
      XCTAssertEqual(HTMLPreviewPane.directory(root: "/p/proj", path: "../other/x.html")?.path, "/p/other")
      XCTAssertEqual(HTMLPreviewPane.directory(root: nil, path: "/p/other/x.html")?.path, "/p/other")
      XCTAssertNil(HTMLPreviewPane.directory(root: nil, path: "x.html"))
    }
  }
#endif
