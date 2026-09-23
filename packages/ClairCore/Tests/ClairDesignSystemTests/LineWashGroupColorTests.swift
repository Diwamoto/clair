import ClairDesignSystem
import SwiftUI
import XCTest

/// Verifies `DesignTokens.Line`, `.Wash` and `.GroupColor` against checklist
/// §2.1's `line` / `wash` / `groupColor` tables, retyped independently from
/// the checklist text (not from `Color+Tokens.swift`).
final class LineWashGroupColorTests: XCTestCase {
  private typealias RGBACase = (name: String, color: Color, r: Int, g: Int, b: Int, a: Double)

  private static let offWhite = (r: 242, g: 244, b: 238)
  private static let black = (r: 0, g: 0, b: 0)
  private static let pureWhite = (r: 255, g: 255, b: 255)

  private static let lineCases: [RGBACase] = [
    ("hairline", DesignTokens.Line.hairline, black.r, black.g, black.b, 0.4),
    ("hairlineSoft", DesignTokens.Line.hairlineSoft, black.r, black.g, black.b, 0.32),
    ("hairlineFaint", DesignTokens.Line.hairlineFaint, black.r, black.g, black.b, 0.24),
    ("chrome", DesignTokens.Line.chrome, black.r, black.g, black.b, 0.36),
    ("chromeSoft", DesignTokens.Line.chromeSoft, black.r, black.g, black.b, 0.32),
    ("strong", DesignTokens.Line.strong, offWhite.r, offWhite.g, offWhite.b, 0.19),
    ("stronger", DesignTokens.Line.stronger, offWhite.r, offWhite.g, offWhite.b, 0.28),
    ("ring", DesignTokens.Line.ring, offWhite.r, offWhite.g, offWhite.b, 0.32),
    ("paneDivider", DesignTokens.Line.paneDivider, black.r, black.g, black.b, 0.5),
  ]

  private static let washCases: [RGBACase] = [
    ("faint", DesignTokens.Wash.faint, offWhite.r, offWhite.g, offWhite.b, 0.03),
    ("soft", DesignTokens.Wash.soft, offWhite.r, offWhite.g, offWhite.b, 0.04),
    ("medium", DesignTokens.Wash.medium, offWhite.r, offWhite.g, offWhite.b, 0.06),
    ("raised", DesignTokens.Wash.raised, offWhite.r, offWhite.g, offWhite.b, 0.075),
    // `selected` is pure white — the one entry that departs from the
    // off-white base every other line/wash token uses.
    ("selected", DesignTokens.Wash.selected, pureWhite.r, pureWhite.g, pureWhite.b, 0.08),
    ("strong", DesignTokens.Wash.strong, offWhite.r, offWhite.g, offWhite.b, 0.09),
    ("strongest", DesignTokens.Wash.strongest, offWhite.r, offWhite.g, offWhite.b, 0.12),
  ]

  func testLineTokensMatchChecklistRGBA() {
    for c in Self.lineCases {
      assertColor(c.color, matchesRGB: (c.r, c.g, c.b), alpha: c.a, "line.\(c.name)")
    }
    XCTAssertEqual(Self.lineCases.count, 9)
  }

  func testWashTokensMatchChecklistRGBA() {
    for c in Self.washCases {
      assertColor(c.color, matchesRGB: (c.r, c.g, c.b), alpha: c.a, "wash.\(c.name)")
    }
    XCTAssertEqual(Self.washCases.count, 7)
  }

  // MARK: - GroupColor

  func testGroupColorOrderMatchesGroupColorKeys() {
    // `GROUP_COLOR_KEYS` in tokens.ts: blue/green/amber/red/purple/gray.
    XCTAssertEqual(
      DesignTokens.GroupColor.allCases.map(\.rawValue),
      ["blue", "green", "amber", "red", "purple", "gray"]
    )
  }

  func testGroupColorSwatchesMatchChecklistHex() {
    let cases: [(DesignTokens.GroupColor, String)] = [
      (.blue, "#5b88f7"),
      (.green, "#8acb94"),
      (.amber, "#e5c07b"),
      (.red, "#e27b83"),
      (.purple, "#c678dd"),
    ]
    for (key, hex) in cases {
      XCTAssertEqual(key.swatchHex, hex, "\(key.rawValue) swatchHex")
      assertColor(key.color, matchesHex: hex, "groupColor.\(key.rawValue)")
    }
  }

  func testGroupColorGrayIsLineStrongerVerbatim() {
    XCTAssertNil(DesignTokens.GroupColor.gray.swatchHex)
    assertColor(
      DesignTokens.GroupColor.gray.color,
      matchesRGB: Self.offWhite,
      alpha: 0.28,
      "groupColor.gray (== line.stronger)"
    )
  }

  func testWithAlphaAppliesToColoredSwatchesAndPassesThroughGray() {
    assertColor(DesignTokens.GroupColor.blue.withAlpha(0.14), matchesHex: "#5b88f7", alpha: 0.14, "blue.withAlpha(0.14)")
    assertColor(DesignTokens.GroupColor.red.withAlpha(0.55), matchesHex: "#e27b83", alpha: 0.55, "red.withAlpha(0.55)")
    // `gray` has no hex swatch, so `withAlpha` passes it through unchanged
    // regardless of the requested alpha — mirroring `withAlpha`'s
    // `!swatch.startsWith('#')` early return in tokens.ts.
    assertColor(
      DesignTokens.GroupColor.gray.withAlpha(0.9),
      matchesRGB: Self.offWhite,
      alpha: 0.28,
      "gray.withAlpha(0.9) ignores requested alpha"
    )
  }
}
