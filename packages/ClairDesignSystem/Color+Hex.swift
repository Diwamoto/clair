import SwiftUI

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// `#RRGGBB` / `rgba(r, g, b, a)` construction shared by every color token
/// file. This is the one place hex/rgb parsing happens; every token below
/// goes through it instead of hand-rolling its own conversion.
extension Color {
  /// A `#RRGGBB` hex literal at full opacity, e.g. `Color(hex: "#31363f")`.
  init(hex: String) {
    self.init(hex: hex, alpha: 1)
  }

  /// A `#RRGGBB` hex literal at a given opacity — the native equivalent of
  /// `tokens.ts`'s `withAlpha(swatch, alpha)` for hex swatches.
  init(hex: String, alpha: Double) {
    let (r, g, b) = Color.rgb255(fromHex: hex)
    self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: alpha)
  }

  /// `rgba(r, g, b, a)` with 0-255 components, matching the literal
  /// `rgba(...)` strings the `line` / `wash` tokens use in `tokens.ts`.
  init(rgb255 r: Int, _ g: Int, _ b: Int, alpha: Double) {
    self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: alpha)
  }

  static func rgb255(fromHex hex: String) -> (Int, Int, Int) {
    var digits = Substring(hex)
    if digits.hasPrefix("#") { digits.removeFirst() }
    precondition(
      digits.count == 6 && UInt32(digits, radix: 16) != nil,
      "DesignTokens: expected a 6-digit #RRGGBB hex literal, got \"\(hex)\""
    )
    let value = UInt32(digits, radix: 16)!
    return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
  }

  /// A scheme-aware token: resolves to `dark` or `light` from the view's (or
  /// drawing context's) appearance, so switching the app appearance repaints
  /// every token without a restart (spec §5.11 colour scheme).
  init(dark: SwiftUI.Color, light: SwiftUI.Color) {
    #if canImport(AppKit)
      let d = NSColor(dark), l = NSColor(light)
      self.init(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? l : d
      })
    #elseif canImport(UIKit)
      let d = UIColor(dark), l = UIColor(light)
      self.init(uiColor: UIColor { $0.userInterfaceStyle == .light ? l : d })
    #else
      self = dark
    #endif
  }

  init(hex dark: String, light: String) {
    self.init(dark: Color(hex: dark), light: Color(hex: light))
  }
}
