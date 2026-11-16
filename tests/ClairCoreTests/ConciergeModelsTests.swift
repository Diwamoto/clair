import Foundation
import Testing

@testable import ClairAppKit

#if os(macOS)
  @Suite
  struct ConciergeModelsTests {
    @MainActor @Test func aliasesThenUsedModelsNewestFirst() throws {
      let url = URL.temporaryDirectory.appending(path: "stats-\(UUID().uuidString).json")
      try Data(#"{"modelUsage":{"claude-opus-4-6":{},"claude-opus-4-10":{},"<synthetic>":{}}}"#.utf8).write(to: url)
      let models = ConciergeChatView.models(statsCache: url)
      #expect(models.first == "default")
      #expect(Array(models.suffix(2)) == ["claude-opus-4-10", "claude-opus-4-6"])
      #expect(ConciergeChatView.models(statsCache: url.appending(path: "missing")).last == "haiku")
    }
  }
#endif
