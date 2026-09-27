import XCTest

@testable import ClairEditorCore
@testable import ClairEditorView

final class EditorSpanIndexTests: XCTestCase {
  func testOverlapsKeepOriginalOrderAndExcludeAdjacentRanges() {
    let spans = [
      EditorHighlightSpan(range: TextUTF8Range(UTF8Offset(10), UTF8Offset(30)), kind: .string),
      EditorHighlightSpan(range: TextUTF8Range(UTF8Offset(0), UTF8Offset(12)), kind: .keyword),
      EditorHighlightSpan(range: TextUTF8Range(UTF8Offset(12), UTF8Offset(15)), kind: .comment),
      EditorHighlightSpan(range: TextUTF8Range(UTF8Offset(40), UTF8Offset(50)), kind: .number),
    ]
    let index = EditorSpanIndex(spans, range: \.range)
    XCTAssertEqual(index.overlapping(TextUTF8Range(UTF8Offset(12), UTF8Offset(14))).map(\.kind),
                   [.string, .comment])
    XCTAssertEqual(index.overlapping(TextUTF8Range(UTF8Offset(30), UTF8Offset(40))).count, 0)
    XCTAssertEqual(index.overlapping(TextUTF8Range(UTF8Offset(0), UTF8Offset(10))).map(\.kind),
                   [.keyword])
  }
}
