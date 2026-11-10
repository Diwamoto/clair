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
  /// The sidebar's own two sizes, shared by every panel: 13 for a row's text, 11 for what annotates it.
  public static let sidebarStrong = TypeSpec(size: 13, weight: .semibold, numericWeight: 600)
  public static let sidebar = TypeSpec(size: 13, weight: .regular, numericWeight: 400)
  public static let sidebarMicro = TypeSpec(size: 11, weight: .medium, numericWeight: 500)

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
    .system(size: chromeSize(spec.size), weight: spec.weight, design: family == .sans ? .default : .monospaced)
  }

  /// A chrome type size for the current material: Liquid Glass sets chrome 11 → 12 and micro 9 → 10
  /// (canvas Tokens `GLASS の中身`, 2026-11-10); every other size, and flat, pass through.
  public static func chromeSize(_ size: CGFloat) -> CGFloat {
    DesignTokens.glassActive && (size == 11 || size == 9) ? size + 1 : size
  }
}
