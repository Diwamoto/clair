import Testing

@testable import ClairAppKit

#if os(macOS)
  @Suite
  struct HoverMarkdownTests {
    @Test func fencesAreDroppedAndProseMarkupRendered() {
      let s = LanguagePopupView.hoverMarkdown("```go\nvar p *int\n```\n\nSee `x` and **bold**.")
      #expect(String(s.characters) == "var p *int\n\nSee x and bold.")
    }
  }
#endif
