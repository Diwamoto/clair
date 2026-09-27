import ClairEditorFixtures
import XCTest

final class UnicodeCorpusTests: XCTestCase {
  func testConcatenatedCorpusContainsAllNamedCases() {
    for (_, text) in UnicodeCorpus.namedCases {
      XCTAssertTrue(
        UnicodeCorpus.concatenated.contains(text),
        "Concatenated corpus missing case: \(text.prefix(20))"
      )
    }
  }

  func testCRLFIsOneLineBreak() {
    let lines = UnicodeCorpus.crlfLines.components(separatedBy: "\r\n")
    XCTAssertEqual(lines.count, 3)
    for line in lines {
      XCTAssertFalse(line.hasSuffix("\r"), "Line still contains trailing CR: \(line)")
    }
  }

  func testDeleteBoundaryCasesAreNonEmpty() {
    for text in UnicodeCorpus.deleteBoundaryCases {
      XCTAssertFalse(text.isEmpty)
    }
  }
}

final class EditorFixtureGeneratorTests: XCTestCase {
  func testCanonicalFixturesAreDocumented() {
    let names = Set(EditorFixtureGenerator.canonicalFixtures.map(\.name))
    XCTAssertTrue(names.contains("unicode-corpus"))
    XCTAssertTrue(names.contains("10mb"))
    XCTAssertTrue(names.contains("long-line"))
    XCTAssertTrue(names.contains("1mb-japanese"))
  }

  func testGenerateUnicodeFixture() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fixture = EditorFixtureGenerator.canonicalFixtures.first { $0.name == "unicode-corpus" }!
    let url = try EditorFixtureGenerator.generate(fixture, into: directory)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = attributes[.size] as? Int ?? 0
    XCTAssertGreaterThan(size, 0)
  }

  func testGenerateAllFixtures() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let urls = try EditorFixtureGenerator.generateAll(into: directory)
    XCTAssertEqual(urls.count, EditorFixtureGenerator.canonicalFixtures.count)
  }
}

final class EditorBenchmarkTests: XCTestCase {
  func testHarnessRunsAndReports() async throws {
    let operation = EditorBenchmark.Operation(
      name: "spin",
      fixture: "unicode-corpus",
      iterations: 5,
      // A noop can measure 0 ns below clock resolution, which made the > 0 assertion flaky.
      closure: { var x = 0; for i in 0..<100_000 { x &+= i }; precondition(x != 1) }
    )
    let result = try await EditorBenchmark.run(operation)
    XCTAssertEqual(result.iterations, 5)
    XCTAssertGreaterThan(result.medianNanos, 0)
    XCTAssertGreaterThanOrEqual(result.p95Nanos, result.medianNanos)
  }
}

final class EditorInvariantsTests: XCTestCase {
  func testAllInvariantsHaveUniqueIDs() {
    let ids = EditorInvariants.all.map(\.id)
    let unique = Set(ids)
    XCTAssertEqual(
      ids.count,
      unique.count,
      "Duplicate invariant IDs found: \(Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted())"
    )
  }

  func testInvariantIDsFollowNamingConvention() {
    let pattern = /^INV-[A-Z]+-\d{3}$/
    for invariant in EditorInvariants.all {
      XCTAssertNotNil(
        invariant.id.wholeMatch(of: pattern),
        "Invariant ID '\(invariant.id)' does not match INV-CATEGORY-NNN"
      )
    }
  }

  func testEveryInvariantHasStatementAndRationale() {
    for invariant in EditorInvariants.all {
      XCTAssertFalse(invariant.statement.isEmpty, "\(invariant.id) has empty statement")
      XCTAssertFalse(invariant.rationale.isEmpty, "\(invariant.id) has empty rationale")
      XCTAssertFalse(invariant.provenBy.isEmpty, "\(invariant.id) is not proven by any task")
    }
  }

  func testEveryCategoryHasAtLeastOneInvariant() {
    for category in EditorInvariant.Category.allCases {
      XCTAssertFalse(
        EditorInvariants.all(in: category).isEmpty,
        "Category \(category) has no invariants"
      )
    }
  }

  func testInvariantLookupByID() {
    for invariant in EditorInvariants.all {
      XCTAssertEqual(
        EditorInvariants.invariant(withID: invariant.id),
        invariant,
        "Lookup failed for \(invariant.id)"
      )
    }
    XCTAssertNil(EditorInvariants.invariant(withID: "INV-NONEXISTENT"))
  }

  func testAllProvenByTaskIDsAreWellFormed() {
    let taskPattern = /^[BHNETU]\d{2}$/
    for invariant in EditorInvariants.all {
      for taskID in invariant.provenBy {
        XCTAssertNotNil(
          taskID.wholeMatch(of: taskPattern),
          "Invariant \(invariant.id) references malformed task ID '\(taskID)'"
        )
      }
    }
  }
}

final class EditorBaselineEvidenceTests: XCTestCase {
  func testAllMeasurementsHaveUniqueIDs() {
    let ids = EditorBaselineEvidence.all.map(\.id)
    let unique = Set(ids)
    XCTAssertEqual(
      ids.count,
      unique.count,
      "Duplicate baseline IDs found: \(Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted())"
    )
  }

  func testBaselineFailureCeilingExistsForKnownFailures() {
    let ceiling = EditorBaselineEvidence.regressionCeiling(
      fixture: "10mb.swift",
      metric: "cumulative_max_rss"
    )
    XCTAssertNotNil(ceiling)
    XCTAssertGreaterThan(ceiling!, 0)
  }

  func testFailuresAreRecordedFromEachFailedSurface() {
    let failureSurfaces = Set(EditorBaselineEvidence.failures.map(\.surface))
    XCTAssertTrue(failureSurfaces.contains(.codeEditPoC))
    XCTAssertTrue(failureSurfaces.contains(.codeMirrorWebView))
  }

  func testFailuresHavePositiveValues() {
    for failure in EditorBaselineEvidence.failures {
      XCTAssertGreaterThan(
        failure.value,
        0,
        "Failure \(failure.id) must have a positive measured value"
      )
    }
  }

  func testMeasurementLookupByID() {
    for measurement in EditorBaselineEvidence.all {
      XCTAssertEqual(
        EditorBaselineEvidence.measurement(withID: measurement.id),
        measurement
      )
    }
  }
}
