@testable import ClairDesignSystem
import SwiftUI
import XCTest

final class ColorSchemeTests: XCTestCase {
  func testChoiceResolvesAndFallsBackToDark() {
    XCTAssertEqual(ColorSchemeChoice(setting: "ライト").resolved(systemIsDark: true), .light)
    XCTAssertEqual(ColorSchemeChoice(setting: "ダーク").resolved(systemIsDark: false), .dark)
    XCTAssertEqual(ColorSchemeChoice(setting: "システム").resolved(systemIsDark: false), .light)
    XCTAssertEqual(ColorSchemeChoice(setting: "システム").resolved(systemIsDark: true), .dark)
    XCTAssertEqual(ColorSchemeChoice(setting: nil), .dark)
    XCTAssertEqual(ColorSchemeChoice(setting: "sepia"), .dark)
  }

  func testTokensResolvePerScheme() {
    XCTAssertEqual(hex(DesignTokens.Color.canvas, light: false), "#282c34")
    XCTAssertEqual(hex(DesignTokens.Color.canvas, light: true), "#fafafa")
    XCTAssertEqual(hex(DesignTokens.Color.code, light: true), "#383a42")
  }

  /// Body ink must hold 4.5:1 on the pane in both schemes (WCAG AA).
  func testBodyTextContrast() {
    let C = DesignTokens.Color.self
    for light in [false, true] {
      for (name, ink) in [("code", C.code), ("textPrimary", C.textPrimary), ("textSecondary", C.textSecondary), ("textTertiary", C.textTertiary)] {
        let ratio = contrast(ink, C.canvas, light: light)
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) light=\(light): \(ratio)")
      }
      XCTAssertGreaterThanOrEqual(contrast(C.chromeInk, C.chrome, light: light), 4.5, "chromeInk light=\(light)")
    }
  }

  private func hex(_ c: Color, light: Bool) -> String {
    let v = resolvedRGBA(c, light: light)!
    return String(format: "#%02x%02x%02x", v.r, v.g, v.b)
  }

  private func contrast(_ a: Color, _ b: Color, light: Bool) -> Double {
    func lum(_ c: Color) -> Double {
      let v = resolvedRGBA(c, light: light)!
      let ch = [v.r, v.g, v.b].map { x -> Double in
        let s = Double(x) / 255
        return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2]
    }
    let (x, y) = (lum(a), lum(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
  }
}
