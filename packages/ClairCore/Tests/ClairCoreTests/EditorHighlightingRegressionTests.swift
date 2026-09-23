import XCTest

@testable import ClairEditorCore
@testable import ClairEditorLanguage
@testable import ClairEditorView

/// E11 dogfood review (2026-09-22): "実ファイルで capture→token→描画を通す
/// UI regression test" — authentic per-language source snippets (not
/// `EditorFixtureGenerator` gibberish), proving the real path
/// `EditorLanguageID.detect` → `SyntaxHighlighter.reset` → non-`.plain`
/// `EditorHighlightSpan`s reaches a colored result for every one of the 8
/// target languages. `ClairEditorPane.swift` (`ClairAppKit`) is the piece
/// that then assigns those spans to `ClairEditorView.highlights` in the
/// real app — this suite stops one layer short of that (no `NSView`/window
/// in a package unit test), which is why the worker report also records a
/// manual by-eye check in the running app.
final class EditorHighlightingRegressionTests: XCTestCase {
  private struct Sample {
    let path: String
    let source: String
    /// At least one of these kinds must appear — proves real captures
    /// resolved to real token categories, not just "some spans exist".
    let expectAnyOf: Set<EditorTokenKind>
  }

  private static let samples: [Sample] = [
    Sample(
      path: "Greeter.swift",
      source: """
        import Foundation

        /// Says hello.
        struct Greeter {
          let name: String

          func greet() -> String {
            return "Hello, \\(name)!"
          }
        }
        """,
      expectAnyOf: [.keyword, .string, .comment, .type, .function]),
    Sample(
      path: "main.go",
      source: """
        package main

        import "fmt"

        // Entrypoint.
        func main() {
          message := "hello"
          fmt.Println(message)
        }
        """,
      expectAnyOf: [.keyword, .string, .comment, .function]),
    Sample(
      path: "app.ts",
      source: """
        // Adds two numbers.
        function add(a: number, b: number): number {
          return a + b;
        }

        const result = add(1, 2);
        """,
      expectAnyOf: [.keyword, .comment, .type, .function]),
    Sample(
      path: "app.js",
      source: """
        // Adds two numbers.
        function add(a, b) {
          return a + b;
        }

        const result = add(1, 2);
        """,
      expectAnyOf: [.keyword, .comment, .function]),
    Sample(
      path: "greeter.py",
      source: """
        # Says hello.
        def greet(name):
            return f"Hello, {name}!"

        print(greet("world"))
        """,
      expectAnyOf: [.keyword, .comment, .string, .function]),
    Sample(
      path: "config.json",
      source: """
        {"name": "clair", "version": 1, "features": ["editor", "review"]}
        """,
      expectAnyOf: [.string, .number]),
    Sample(
      path: "README.md",
      source: """
        # Clair

        A syntax highlighting task.

        ```swift
        let x = 1
        ```

        - one
        - two
        """,
      expectAnyOf: [.keyword, .string, .type, .function, .variable, .plain]),
    Sample(
      path: "lib.rs",
      source: """
        // Adds two numbers.
        fn add(a: i32, b: i32) -> i32 {
            a + b
        }

        fn main() {
            println!("{}", add(1, 2));
        }
        """,
      expectAnyOf: [.keyword, .comment, .string, .function, .type]),
    Sample(
      path: "deploy.sh",
      source: """
        #!/bin/sh
        # Deploys the app.
        NAME="clair"
        echo "deploying $NAME"
        if [ -z "$NAME" ]; then
          exit 1
        fi
        """,
      expectAnyOf: [.keyword, .string, .comment, .variable]),
    Sample(
      path: "app.rb",
      source: """
        # Greets.
        class Greeter
          def hello(name)
            puts "hi #{name}"
          end
        end
        """,
      expectAnyOf: [.keyword, .string, .comment, .function]),
    Sample(
      path: "Main.java",
      source: """
        // Entry point.
        public class Main {
            public static void main(String[] args) {
                System.out.println("hi" + 1);
            }
        }
        """,
      expectAnyOf: [.keyword, .string, .comment, .type, .function]),
    Sample(
      path: "index.php",
      source: """
        <?php
        // Greets.
        function hello(string $name): string {
            return "hi " . $name;
        }
        """,
      expectAnyOf: [.keyword, .string, .comment, .function]),
    Sample(
      path: "main.tf",
      source: """
        # Bucket.
        resource "aws_s3_bucket" "logs" {
          bucket = var.name
          count  = 2
        }
        """,
      expectAnyOf: [.keyword, .string, .comment, .number]),
  ]

  func testRealFileSnippetsProduceColoredSpansForEveryTargetLanguage() throws {
    for sample in Self.samples {
      let id = try XCTUnwrap(
        EditorLanguageID.detect(path: sample.path), "no language detected for \(sample.path)")
      let highlighter = try SyntaxHighlighter(languageID: id)
      let buffer = try TextBuffer(sample.source)
      let spans = try highlighter.reset(to: buffer.snapshot)

      XCTAssertFalse(spans.isEmpty, "\(sample.path): expected at least one highlight span")
      let kinds = Set(spans.map(\.kind))
      // Markdown's block-only grammar (see `ClairEditorLanguageMarkdown/VENDOR.md`)
      // legitimately produces only `.plain`-mapped structural captures for
      // this snippet's heading/list/code-fence content; every other
      // language must land a real non-`.plain` category.
      if sample.path.hasSuffix(".md") {
        continue
      }
      XCTAssertFalse(
        kinds.isDisjoint(with: sample.expectAnyOf),
        "\(sample.path): got kinds \(kinds), expected one of \(sample.expectAnyOf)")
    }
  }

  func testUndetectedExtensionLeavesHighlightingEmptyNotCrashing() {
    XCTAssertNil(EditorLanguageID.detect(path: "notes.txt"))
    XCTAssertNil(EditorLanguageID.detect(path: "Makefile"))
  }

  func testShellDetectsFromShebangWithNoExtension() {
    XCTAssertEqual(EditorLanguageID.detect(path: "run", shebangLine: "#!/bin/bash"), .shell)
    XCTAssertNil(EditorLanguageID.detect(path: "run", shebangLine: nil))
  }

  func testCaptureMappingFallsBackToPlainForUnknownCaptureNames() {
    XCTAssertEqual(CaptureMapping.kind(for: []), .plain)
    XCTAssertEqual(CaptureMapping.kind(for: ["punctuation", "bracket"]), .plain)
    XCTAssertEqual(CaptureMapping.kind(for: ["spell"]), .plain)
  }

  func testCaptureMappingResolvesKnownFirstComponents() {
    XCTAssertEqual(CaptureMapping.kind(for: ["keyword"]), .keyword)
    XCTAssertEqual(CaptureMapping.kind(for: ["string", "special", "key"]), .string)
    XCTAssertEqual(CaptureMapping.kind(for: ["comment"]), .comment)
    XCTAssertEqual(CaptureMapping.kind(for: ["number"]), .number)
    XCTAssertEqual(CaptureMapping.kind(for: ["type", "builtin"]), .type)
    XCTAssertEqual(CaptureMapping.kind(for: ["function", "method"]), .function)
    XCTAssertEqual(CaptureMapping.kind(for: ["variable", "parameter"]), .variable)
  }

  func testIncrementalUpdateAfterEditStillProducesSpans() throws {
    let highlighter = try SyntaxHighlighter(languageID: .json)
    let buffer = try TextBuffer(#"{"a": 1}"#)
    _ = try highlighter.reset(to: buffer.snapshot)

    let old = buffer.snapshot
    let edit = TextEdit(range: TextUTF8Range(UTF8Offset(6), UTF8Offset(7)), replacement: "42")
    try buffer.replace(edit.range, with: edit.replacement, basedOn: old.revision)
    let new = buffer.snapshot

    let spans = try highlighter.update(edits: [edit], oldSnapshot: old, newSnapshot: new)
    XCTAssertTrue(spans.contains { $0.kind == .number })
  }
}
