import ClairV2EditorFixtures
import XCTest

@testable import ClairV2EditorCore

final class EditorTextPerformanceTests: XCTestCase {
  /// This is storage-only regression evidence, not E10's UI/input latency gate.
  /// The E01 fixture generator, harness and recorded failure ceilings are reused.
  func testCanonicalLargeFixturesHaveBoundedEditWorkAndBeatRecordedFailures() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["10mb", "long-line", "1mb-japanese"] {
      let fixture = try XCTUnwrap(
        EditorFixtureGenerator.canonicalFixtures.first { $0.name == name })
      let url = try EditorFixtureGenerator.generate(fixture, into: directory)
      let input = try String(contentsOf: url, encoding: .utf8)
      let probe = try EditorTextPerformanceProbe(input)
      let initial = await probe.snapshot()
      let operation = EditorBenchmark.Operation(
        name: "E02 storage replace + snapshot", fixture: name, iterations: 20
      ) {
        try await probe.edit()
      }
      let result = try await EditorBenchmark.run(operation)
      EditorBenchmark.print(result)
      let maxWork = await probe.maxResegmentedBytes
      XCTAssertLessThan(
        maxWork, 10 * TextRopeBuilder.leafTarget, "edit scanned too much text in \(name)")
      XCTAssertEqual(Array(initial.string().utf8), Array(input.utf8), "retained snapshot changed")
      let after = await probe.snapshot()
      XCTAssertEqual(after.revision.sequence, 20)
      XCTAssertEqual(after.utf8Count, initial.utf8Count)
      XCTAssertEqual(after.lineCount, initial.lineCount)
      _ = assertEditorTextTree(after.root)
      if name == "long-line" {
        let ceiling = try XCTUnwrap(
          EditorBaselineEvidence.regressionCeiling(fixture: "long-line.ts", metric: "keystroke_p95")
        )
        XCTAssertLessThan(Double(result.p95Nanos) / 1_000_000, ceiling)
      }
      if name == "1mb-japanese" {
        let ceiling = try XCTUnwrap(
          EditorBaselineEvidence.regressionCeiling(fixture: "1mb.swift", metric: "keystroke_median")
        )
        XCTAssertLessThan(Double(result.medianNanos) / 1_000_000, ceiling)
      }
    }
  }
}

private actor EditorTextPerformanceProbe {
  let buffer: TextBuffer
  let range: TextUTF8Range
  var toggle = false
  private(set) var maxResegmentedBytes = 0

  init(_ text: String) throws {
    buffer = try TextBuffer(text)
    // All canonical fixtures begin with an ASCII character. Use a point deep
    // in the document as well, so the test cannot pass with a prefix-only index.
    let midpoint = try buffer.snapshot.convert(
      UTF8Offset(text.utf8.count / 2), to: GraphemeUnit.self, rounding: .down)
    var chosen = midpoint.value
    while true {
      let start = try buffer.snapshot.convert(GraphemeOffset(chosen), to: UTF8Unit.self)
      let end = try buffer.snapshot.convert(GraphemeOffset(chosen + 1), to: UTF8Unit.self)
      let candidate = TextUTF8Range(start, end)
      let original = try buffer.snapshot.text(in: candidate)
      if end.value - start.value == 1 && original != "\n" && original != "\r" {
        range = candidate
        break
      }
      chosen += 1
    }
  }

  func edit() throws {
    toggle.toggle()
    try buffer.replace(range, with: toggle ? "X" : "Y", basedOn: buffer.snapshot.revision)
    maxResegmentedBytes = max(maxResegmentedBytes, buffer.lastEditWork.resegmentedUTF8)
  }

  func snapshot() -> TextSnapshot { buffer.snapshot }
}
