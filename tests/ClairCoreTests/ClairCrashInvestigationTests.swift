#if os(macOS)
  import XCTest

  @testable import ClairAppKit

  final class ClairCrashInvestigationTests: XCTestCase {
    func testReportGathersSwallowedExceptionsCrashReportsAndAnomalies() throws {
      let dir = URL.temporaryDirectory.appending(path: "clair-investigate-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: dir) }
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let log = dir.appending(path: "exceptions.log")
      ClairCrashInvestigation.recordException(
        name: "NSInternalInconsistencyException", reason: "view already in hierarchy", stack: ["0 AppKit -[NSView addSubview:]"], at: log)
      ClairCrashInvestigation.recordException(name: "NSRangeException", reason: nil, stack: [], at: log)

      let header = #"{"app_version":"0.13.0","timestamp":"2026-10-13 15:19:00"}"#
      let body = #"{"procName":"ClairMacApp","exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"threads":[],"usedImages":[]}"#
      try (header + "\n" + body).write(to: dir.appending(path: "ClairMacApp-2026-10-13-151900.ips"), atomically: true, encoding: .utf8)
      try "{}\n{}".write(to: dir.appending(path: "Other-2026-10-13-151900.ips"), atomically: true, encoding: .utf8)
      let anomalies = dir.appending(path: "issue-reports.json")
      try JSONEncoder().encode(["terminal: lost the daemon (remoteFailure)": Date()]).write(to: anomalies)

      let report = ClairCrashInvestigation.report(exceptions: log, crashes: dir, anomalies: anomalies, systemLog: { "LOG LINE" })
      XCTAssertTrue(report.contains("NSInternalInconsistencyException\nview already in hierarchy"))
      XCTAssertTrue(report.contains("NSRangeException"))
      XCTAssertTrue(report.contains("ClairMacApp-2026-10-13-151900.ips"))
      XCTAssertTrue(report.contains("EXC_CRASH SIGABRT"))
      XCTAssertFalse(report.contains("Other-2026"))
      XCTAssertTrue(report.contains("terminal: lost the daemon (remoteFailure)"))
      XCTAssertTrue(report.contains("LOG LINE"))
    }

    func testEmptyReportSaysNone() {
      let missing = URL.temporaryDirectory.appending(path: "clair-missing-\(UUID().uuidString)")
      let report = ClairCrashInvestigation.report(
        exceptions: missing, crashes: missing, anomalies: missing, systemLog: { "" })
      XCTAssertTrue(report.contains("none recorded"))
    }
  }
#endif
