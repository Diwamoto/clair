import Foundation
import Testing

@testable import ClairDaemonKit

#if os(macOS)
  struct ClairIssueReporterTests {
    @Test func aTitleIsClaimedOncePerQuietPeriod() throws {
      let url = URL.temporaryDirectory.appending(path: "clair-issue-\(UUID().uuidString)/state.json")
      defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
      let now = Date()
      #expect(ClairIssueReporter.claim("a", now: now, at: url))
      #expect(!ClairIssueReporter.claim("a", now: now.addingTimeInterval(3600), at: url))
      #expect(ClairIssueReporter.claim("b", now: now, at: url))
      #expect(ClairIssueReporter.claim("a", now: now.addingTimeInterval(ClairIssueReporter.quietPeriod), at: url))
    }

    @Test func kindDropsRunSpecificValues() {
      #expect(ClairIssueReporter.kind(of: ClairDaemonError.controlSocketSetup("x")) == "controlSocketSetup")
      #expect(ClairIssueReporter.kind(of: ClairDaemonError.transportTimedOut) == "transportTimedOut")
      #expect(ClairIssueReporter.kind(of: URLError(.timedOut)) == "NSURLErrorDomain -1001")
    }

    @Test func aCrashReportNamesTheFirstClairFrameAndTheSwiftMessage() throws {
      let header = #"{"app_name":"ClairMacApp","app_version":"0.7.2","timestamp":"2026-10-01 10:00:00.00 +0900","name":"ClairMacApp"}"#
      let body: [String: Any] = [
        "procName": "ClairMacApp",
        "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP"],
        "asi": ["libswiftCore.dylib": ["Fatal error: Unexpectedly found nil while unwrapping an Optional value"]],
        "faultingThread": 1,
        "usedImages": [["name": "libswiftCore.dylib"], ["name": "ClairMacApp"]],
        "threads": [
          ["frames": []],
          ["frames": [
            ["imageIndex": 0, "imageOffset": 10, "symbol": "_assertionFailure"],
            ["imageIndex": 1, "imageOffset": 99, "symbol": "ClairAppShell.run()"],
          ]],
        ],
      ]
      let ips = header + "\n" + String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
      let crash = try #require(ClairIssueReporter.crashSummary(ips: ips))
      #expect(crash.title == "crash: ClairMacApp EXC_BREAKPOINT SIGTRAP at ClairMacApp  ClairAppShell.run()")
      #expect(crash.details.contains("Fatal error: Unexpectedly found nil"))
      #expect(crash.details.contains("libswiftCore.dylib  _assertionFailure"))
      #expect(ClairIssueReporter.crashSummary(ips: "not a report") == nil)
    }

    @Test func homePathsAreRedacted() {
      #expect(ClairIssueReporter.redact("\(NSHomeDirectory())/Projects/x") == "~/Projects/x")
    }

    @Test func testBinariesNeverReport() {
      #expect(!ClairIssueReporter.isEnabled)
    }
  }
#endif
