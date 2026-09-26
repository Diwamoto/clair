import ClairDesignSystem
import XCTest

final class FileIconTests: XCTestCase {
  private func symbol(_ path: String) -> String { FileIcon.forPath(path).symbol }

  func testExtensionsAreCaseInsensitiveAndUseTheLastPathComponent() {
    XCTAssertEqual(symbol("cmd/main.go"), "g.circle")
    XCTAssertEqual(symbol("App/View.SWIFT"), "swift")
    XCTAssertEqual(symbol("src.v2/readme.md"), "text.alignleft")
  }

  func testCompoundExtensionWinsOverItsTail() {
    XCTAssertEqual(FileIcon.forPath("types/index.d.ts"), FileIcon.forPath("x.d.ts"))
    XCTAssertNotEqual(FileIcon.forPath("index.d.ts"), FileIcon.forPath("index.ts"))
    XCTAssertEqual(symbol("index.ts"), "t.square")
  }

  func testKnownFileNames() {
    XCTAssertEqual(symbol("Makefile"), "hammer")
    XCTAssertEqual(symbol("docker/Dockerfile"), "shippingbox")
    XCTAssertEqual(symbol("Dockerfile.dev"), "shippingbox")
    XCTAssertEqual(symbol("go.mod"), "g.circle")
    XCTAssertEqual(symbol("web/package.json"), "shippingbox")
    XCTAssertEqual(symbol(".gitignore"), "gearshape")
  }

  func testUnknownFallsBackToGeneric() {
    XCTAssertEqual(FileIcon.forPath("LICENSE"), .generic)
    XCTAssertEqual(FileIcon.forPath("a.tar.gz"), .generic)
    XCTAssertEqual(FileIcon.forPath(""), .generic)
  }

  func testFolderIcons() {
    XCTAssertEqual(FileIcon.folder(open: true).symbol, "folder")
    XCTAssertEqual(FileIcon.folder(open: false).symbol, "folder.fill")
  }
}
