import SwiftUI

/// One entry of the 4-step type scale (`type` in `tokens.ts` / checklist
/// §2.2): a size/weight pair, independent of font family.
public struct TypeSpec: Sendable, Equatable {
  public let size: CGFloat
  public let weight: Font.Weight
  /// The CSS `font-weight` number the checklist gives, kept alongside
  /// `weight` so tests (and any caller that needs the raw spec value) don't
  /// have to reverse-map a `Font.Weight` back to a number.
  public let numericWeight: Int
}

/// Type scale and font families ported from `tokens.ts`'s `type` / `sans` /
/// `mono` and checklist §2.2. Only two font families exist — there is no
/// third "display" family or arbitrary custom font.
public enum Typography {
  public static let title = TypeSpec(size: 13, weight: .semibold, numericWeight: 600)
  public static let chromeStrong = TypeSpec(size: 11, weight: .semibold, numericWeight: 600)
  public static let chrome = TypeSpec(size: 11, weight: .regular, numericWeight: 400)
  public static let micro = TypeSpec(size: 9, weight: .medium, numericWeight: 500)

  /// The two font families the canvas defines. The mock's CSS stacks
  /// (`-apple-system, ..., 'SF Pro Text', system-ui, sans-serif` and
  /// `"SF Mono", ui-monospace, "JetBrains Mono", Menlo, monospace`) both
  /// resolve to the platform system font on Apple platforms — SF Pro for
  /// `sans`, SF Mono for `mono` — so the native equivalent is `Font.system`
  /// with `.default` vs. `.monospaced` design, not a bundled custom font.
  public enum FontFamily: Sendable {
    case sans
    case mono
  }

  /// Builds the `Font` for a type-scale entry in a given family.
  public static func font(_ spec: TypeSpec, family: FontFamily = .sans) -> Font {
    switch family {
    case .sans:
      return .system(size: spec.size, weight: spec.weight, design: .default)
    case .mono:
      return .system(size: spec.size, weight: spec.weight, design: .monospaced)
    }
  }
}
