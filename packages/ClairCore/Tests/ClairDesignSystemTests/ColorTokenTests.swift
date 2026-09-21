@testable import ClairDesignSystem
import SwiftUI
import XCTest

/// Verifies every `DesignTokens.Color` semantic name resolves to the hex
/// value the checklist (`docs/plans/clair-ui-implementation-checklist.md`
/// §2.1) specifies. The (name, color, hex) triples below are retyped from
/// the checklist table directly, not copied from `Color+Tokens.swift`, so a
/// transcription slip in the source can't hide behind an identical slip
/// here.
final class ColorTokenTests: XCTestCase {
  private typealias Case = (name: String, color: Color, hex: String)

  private static let cases: [Case] = [
    // Surface
    ("chrome", DesignTokens.Color.chrome, "#31363f"),
    ("canvas", DesignTokens.Color.canvas, "#282c34"),
    ("surface", DesignTokens.Color.surface, "#282c34"),
    ("chromeRaised", DesignTokens.Color.chromeRaised, "#1e2227"),
    ("surfaceHover", DesignTokens.Color.surfaceHover, "#2e333c"),
    ("surfaceActive", DesignTokens.Color.surfaceActive, "#383d47"),
    // Chrome ink
    ("chromeInk", DesignTokens.Color.chromeInk, "#b6bcb6"),
    ("chromeInkMuted", DesignTokens.Color.chromeInkMuted, "#8a908b"),
    // Text
    ("textPrimary", DesignTokens.Color.textPrimary, "#f1f3ef"),
    ("textSecondary", DesignTokens.Color.textSecondary, "#c9cec8"),
    ("textTertiary", DesignTokens.Color.textTertiary, "#9ba19b"),
    ("textQuaternary", DesignTokens.Color.textQuaternary, "#707871"),
    ("textMuted", DesignTokens.Color.textMuted, "#55605a"),
    // Line/rule
    ("lineNumber", DesignTokens.Color.lineNumber, "#4b5561"),
    ("divider", DesignTokens.Color.divider, "#3d454e"),
    // Meaning
    ("success", DesignTokens.Color.success, "#8acb94"),
    ("attention", DesignTokens.Color.attention, "#e5c07b"),
    ("danger", DesignTokens.Color.danger, "#e27b83"),
    // Debug
    ("debugBlue", DesignTokens.Color.debugBlue, "#5b88f7"),
    ("debugBlueText", DesignTokens.Color.debugBlueText, "#8fb0fa"),
    // Panel
    ("panel", DesignTokens.Color.panel, "#181b1f"),
    ("panelDeep", DesignTokens.Color.panelDeep, "#101214"),
    ("overlayGround", DesignTokens.Color.overlayGround, "#0c0e10"),
    // Editor (One Dark)
    ("code", DesignTokens.Color.code, "#abb2bf"),
    ("codeBright", DesignTokens.Color.codeBright, "#d0d4cf"),
    ("codeComment", DesignTokens.Color.codeComment, "#5c6370"),
    ("codeKeyword", DesignTokens.Color.codeKeyword, "#c678dd"),
    ("codeType", DesignTokens.Color.codeType, "#e5c07b"),
    ("codeFunc", DesignTokens.Color.codeFunc, "#61afef"),
    ("codeString", DesignTokens.Color.codeString, "#98c379"),
    ("codeNumber", DesignTokens.Color.codeNumber, "#d19a66"),
    // Traffic lights
    ("close", DesignTokens.Color.close, "#ff5f57"),
    ("minimize", DesignTokens.Color.minimize, "#febc2e"),
    ("zoom", DesignTokens.Color.zoom, "#28c840"),
  ]

  func testColorTokensMatchChecklistHexValues() {
    for c in Self.cases {
      assertColor(c.color, matchesHex: c.hex, c.name)
    }
  }

  func testAllChecklistColorNamesAreCovered() {
    // Guards against silently losing coverage if a case above is deleted
    // without noticing — the checklist table has exactly 34 color entries.
    XCTAssertEqual(Self.cases.count, 34)
    XCTAssertEqual(Set(Self.cases.map(\.name)).count, 34, "duplicate token name in test table")
  }

  // MARK: - Generic hex -> Color conversion

  /// Tests the hex/rgb conversion pipeline itself (not a per-token
  /// duplicate check): black, white and a representative spread of digits
  /// so a channel-order or off-by-one bug in the parser would show up here
  /// even if it happened to cancel out for every real token above.
  func testHexToColorConversionIsCorrect() {
    let edgeCases: [(hex: String, r: Int, g: Int, b: Int)] = [
      ("#000000", 0, 0, 0),
      ("#ffffff", 255, 255, 255),
      ("#ff0000", 255, 0, 0),
      ("#00ff00", 0, 255, 0),
      ("#0000ff", 0, 0, 255),
      ("#31363f", 49, 54, 63),
      ("#8fb0fa", 143, 176, 250),
    ]
    for c in edgeCases {
      let color = Color(hex: c.hex)
      assertColor(color, matchesHex: c.hex, "hex(\(c.hex))")
      // Belt and suspenders: also check against the literal ints, in case
      // `expectedRGB(fromHex:)` and `Color(hex:)` shared a bug.
      guard let resolved = resolvedRGBA(color) else {
        XCTFail("could not resolve \(c.hex)")
        continue
      }
      XCTAssertEqual(resolved.r, c.r, "\(c.hex) red")
      XCTAssertEqual(resolved.g, c.g, "\(c.hex) green")
      XCTAssertEqual(resolved.b, c.b, "\(c.hex) blue")
    }
  }
}
