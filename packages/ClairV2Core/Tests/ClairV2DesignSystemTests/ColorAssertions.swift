import SwiftUI
import XCTest

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Resolves a `SwiftUI.Color` back to 0-255 sRGB components + alpha by
/// bridging through the platform's native color type. This is deliberately
/// independent of `Color(hex:)` in `ClairV2DesignSystem` — it exists so
/// tests can verify what a token *actually resolves to at runtime*, not
/// just that two copies of the same hex string are equal.
func resolvedRGBA(_ color: Color) -> (r: Int, g: Int, b: Int, a: Double)? {
  #if canImport(AppKit)
  let native = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
  return (
    Int((native.redComponent * 255).rounded()),
    Int((native.greenComponent * 255).rounded()),
    Int((native.blueComponent * 255).rounded()),
    Double(native.alphaComponent)
  )
  #elseif canImport(UIKit)
  let native = UIColor(color)
  var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
  guard native.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
  return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), Double(a))
  #else
  return nil
  #endif
}

/// Independently parses a `#RRGGBB` hex literal into 0-255 components,
/// deliberately re-implemented here rather than reusing
/// `ClairV2DesignSystem`'s internal hex parser, so this file is testing the
/// production conversion against a second, separate reading of the spec
/// value rather than against itself.
func expectedRGB(fromHex hex: String) -> (r: Int, g: Int, b: Int) {
  var digits = Substring(hex)
  if digits.hasPrefix("#") { digits.removeFirst() }
  precondition(digits.count == 6, "test fixture: bad hex literal \"\(hex)\"")
  let value = UInt32(digits, radix: 16)!
  return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
}

/// Asserts that `color` resolves to the given `#RRGGBB` hex value (and
/// optionally alpha), the one generic check every color-token test in this
/// module is built from.
func assertColor(
  _ color: Color,
  matchesHex hex: String,
  alpha: Double = 1,
  _ name: String,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  guard let resolved = resolvedRGBA(color) else {
    XCTFail("\(name): could not resolve Color to native RGBA on this platform", file: file, line: line)
    return
  }
  let expected = expectedRGB(fromHex: hex)
  XCTAssertEqual(resolved.r, expected.r, "\(name) red channel vs \(hex)", file: file, line: line)
  XCTAssertEqual(resolved.g, expected.g, "\(name) green channel vs \(hex)", file: file, line: line)
  XCTAssertEqual(resolved.b, expected.b, "\(name) blue channel vs \(hex)", file: file, line: line)
  XCTAssertEqual(resolved.a, alpha, accuracy: 0.005, "\(name) alpha vs \(alpha)", file: file, line: line)
}

/// Asserts that `color` resolves to the given 0-255 rgb triple + alpha —
/// for the `line`/`wash` families, whose spec values are `rgba(r, g, b, a)`
/// literals rather than hex.
func assertColor(
  _ color: Color,
  matchesRGB rgb: (r: Int, g: Int, b: Int),
  alpha: Double,
  _ name: String,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  guard let resolved = resolvedRGBA(color) else {
    XCTFail("\(name): could not resolve Color to native RGBA on this platform", file: file, line: line)
    return
  }
  XCTAssertEqual(resolved.r, rgb.r, "\(name) red channel", file: file, line: line)
  XCTAssertEqual(resolved.g, rgb.g, "\(name) green channel", file: file, line: line)
  XCTAssertEqual(resolved.b, rgb.b, "\(name) blue channel", file: file, line: line)
  XCTAssertEqual(resolved.a, alpha, accuracy: 0.005, "\(name) alpha", file: file, line: line)
}
