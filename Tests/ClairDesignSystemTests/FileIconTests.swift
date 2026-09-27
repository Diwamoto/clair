@testable import ClairDesignSystem
import XCTest

final class FileIconTests: XCTestCase {
  private func symbol(_ path: String) -> String { FileIcon.forPath(path).symbol }

  func testExtensionsAreCaseInsensitiveAndUseTheLastPathComponent() {
    XCTAssertEqual(symbol("cmd/main.go"), "go")
    XCTAssertEqual(symbol("App/View.SWIFT"), "swift")
    XCTAssertEqual(symbol("src.v2/readme.md"), "markdown")
  }

  func testCompoundExtensionWinsOverItsTail() {
    XCTAssertEqual(FileIcon.forPath("types/index.d.ts"), FileIcon.forPath("x.d.ts"))
    XCTAssertEqual(symbol("a.test.tsx"), "typescript")
    XCTAssertEqual(symbol("index.ts"), "typescript")
  }

  func testKnownFileNames() {
    XCTAssertEqual(symbol("Makefile"), "hammer")
    XCTAssertEqual(symbol("docker/Dockerfile"), "docker")
    XCTAssertEqual(symbol("Dockerfile.dev"), "docker")
    XCTAssertEqual(symbol("go.mod"), "go")
    XCTAssertEqual(symbol("web/package.json"), "npm")
    XCTAssertEqual(symbol(".gitignore"), "git")
  }

  func testUnknownFallsBackToGeneric() {
    XCTAssertEqual(FileIcon.forPath("LICENSE"), .generic)
    XCTAssertEqual(FileIcon.forPath("a.tar.gz"), .generic)
    XCTAssertEqual(FileIcon.forPath(""), .generic)
  }

  func testEveryLogoInTheTableHasAPath() {
    for p in ["a.go", "a.swift", "a.ts", "a.js", "a.py", "a.rs", "a.md", "a.json", "a.yml", "a.toml",
              "a.html", "a.css", "a.sh", "Dockerfile", ".gitignore", "package.json"] {
      XCTAssertFalse(SimpleIcons.paths[symbol(p)]?.isEmpty ?? true, p)
    }
  }

  func testFolderIcons() {
    XCTAssertEqual(FileIcon.folder(open: true).symbol, "folder")
    XCTAssertEqual(FileIcon.folder(open: false).symbol, "folder.fill")
  }
}
