import ClairDesignSystem
import SwiftUI
import XCTest

/// Verifies the type scale against checklist §2.2's `type` table, retyped
/// independently rather than copied from `Typography.swift`.
final class TypographyTests: XCTestCase {
  private struct Expected {
    let size: CGFloat
    let numericWeight: Int
    let weight: Font.Weight
  }

  private static let cases: [(name: String, spec: TypeSpec, expected: Expected)] = [
    ("title", Typography.title, Expected(size: 13, numericWeight: 600, weight: .semibold)),
    ("chromeStrong", Typography.chromeStrong, Expected(size: 11, numericWeight: 600, weight: .semibold)),
    ("chrome", Typography.chrome, Expected(size: 11, numericWeight: 400, weight: .regular)),
    ("micro", Typography.micro, Expected(size: 9, numericWeight: 500, weight: .medium)),
  ]

  func testTypeScaleMatchesChecklistValues() {
    for c in Self.cases {
      XCTAssertEqual(c.spec.size, c.expected.size, "\(c.name).size")
      XCTAssertEqual(c.spec.numericWeight, c.expected.numericWeight, "\(c.name).numericWeight")
      XCTAssertEqual(c.spec.weight, c.expected.weight, "\(c.name).weight")
    }
  }

  func testFontBuildsForBothFamilies() {
    // Both families must produce distinct, non-crashing Font values; the
    // families themselves (system default vs. monospaced design) are the
    // native equivalent of the `sans`/`mono` CSS stacks (checklist §2.2).
    let sans = Typography.font(Typography.title, family: .sans)
    let mono = Typography.font(Typography.title, family: .mono)
    XCTAssertNotEqual(sans, mono)
  }
}
