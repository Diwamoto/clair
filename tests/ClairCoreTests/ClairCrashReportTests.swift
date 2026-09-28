#if os(macOS)
  import XCTest

  @testable import ClairAppKit

  final class ClairCrashReportTests: XCTestCase {
    func testSummaryPicksCrashedThreadAndCapsFrames() throws {
      let header = #"{"app_version":"0.3.0","os_version":"macOS 26.6","timestamp":"2026-09-28 10:00:00"}"#
      let frames = (0..<30).map { #"{"imageIndex":0,"symbol":"f\#($0)","sourceFile":"A.swift","sourceLine":\#($0)}"# }
      let body = """
        {"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"asi":{"libswiftCore":["Fatal error: boom"]},
         "usedImages":[{"name":"ClairMacApp"}],
         "threads":[{"frames":[{"imageIndex":0,"symbol":"idle"}]},{"triggered":true,"frames":[\(frames.joined(separator: ","))]}]}
        """
      let s = try XCTUnwrap(ClairCrashReport.summary(ips: header + "\n" + body))
      XCTAssertTrue(s.contains("EXC_BAD_ACCESS SIGSEGV"))
      XCTAssertTrue(s.contains("Fatal error: boom"))
      XCTAssertTrue(s.contains("0 ClairMacApp f0 (A.swift:0)"))
      XCTAssertTrue(s.contains("19 ClairMacApp f19"))
      XCTAssertFalse(s.contains("f20"))
      XCTAssertFalse(s.contains("idle"))
      XCTAssertNil(ClairCrashReport.summary(ips: "garbage"))
      XCTAssertNotNil(ClairCrashReport.issueURL(body: s))
    }
  }
#endif
