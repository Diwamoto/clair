import SwiftUI

// Transcribed verbatim from `tokens.ts`'s `color` map / checklist §2.1.
// Color is allowed for exactly three purposes elsewhere in the app: diff,
// debug and tab-group identity (checklist §5) — this table is the full set
// the canvas defines, including those three groups; it is not itself a
// statement that every value here may be used decoratively.
extension DesignTokens {
  public enum Color {
    // SURFACE
    public static let chrome = SwiftUI.Color(hex: "#31363f")
    public static let canvas = SwiftUI.Color(hex: "#282c34")
    public static let surface = SwiftUI.Color(hex: "#282c34")
    public static let chromeRaised = SwiftUI.Color(hex: "#1e2227")
    public static let surfaceHover = SwiftUI.Color(hex: "#2e333c")
    public static let surfaceActive = SwiftUI.Color(hex: "#383d47")

    // CHROME INK
    public static let chromeInk = SwiftUI.Color(hex: "#b6bcb6")
    public static let chromeInkMuted = SwiftUI.Color(hex: "#8a908b")

    // TEXT
    public static let textPrimary = SwiftUI.Color(hex: "#f1f3ef")
    public static let textSecondary = SwiftUI.Color(hex: "#c9cec8")
    public static let textTertiary = SwiftUI.Color(hex: "#9ba19b")
    public static let textQuaternary = SwiftUI.Color(hex: "#707871")
    public static let textMuted = SwiftUI.Color(hex: "#55605a")

    // LINE / RULE
    public static let lineNumber = SwiftUI.Color(hex: "#4b5561")
    public static let divider = SwiftUI.Color(hex: "#3d454e")

    // MEANING — diff/debug only (checklist §5).
    public static let success = SwiftUI.Color(hex: "#8acb94")
    public static let attention = SwiftUI.Color(hex: "#e5c07b")
    public static let danger = SwiftUI.Color(hex: "#e27b83")

    // DEBUG accents (current line / call stack).
    public static let debugBlue = SwiftUI.Color(hex: "#5b88f7")
    public static let debugBlueText = SwiftUI.Color(hex: "#8fb0fa")

    // PANEL grounds (cards, footers, overlays).
    public static let panel = SwiftUI.Color(hex: "#181b1f")
    public static let panelDeep = SwiftUI.Color(hex: "#101214")
    public static let overlayGround = SwiftUI.Color(hex: "#0c0e10")

    // EDITOR (One Dark).
    public static let code = SwiftUI.Color(hex: "#abb2bf")
    public static let codeBright = SwiftUI.Color(hex: "#d0d4cf")
    public static let codeComment = SwiftUI.Color(hex: "#5c6370")
    public static let codeKeyword = SwiftUI.Color(hex: "#c678dd")
    public static let codeType = SwiftUI.Color(hex: "#e5c07b")
    public static let codeFunc = SwiftUI.Color(hex: "#61afef")
    public static let codeString = SwiftUI.Color(hex: "#98c379")
    public static let codeNumber = SwiftUI.Color(hex: "#d19a66")

    // TRAFFIC LIGHTS.
    public static let close = SwiftUI.Color(hex: "#ff5f57")
    public static let minimize = SwiftUI.Color(hex: "#febc2e")
    public static let zoom = SwiftUI.Color(hex: "#28c840")
  }

  /// Hairline / rule overlays — alpha-only washes applied over whatever sits
  /// underneath. Structural rules are black (One Dark grooves); `strong`,
  /// `stronger` and `ring` stay off-white so emphasis and focus stay visible.
  /// Transcribed from `tokens.ts`'s `line` map / checklist §2.1.
  public enum Line {
    public static let hairline = SwiftUI.Color(rgb255: 0, 0, 0, alpha: 0.4)
    public static let hairlineSoft = SwiftUI.Color(rgb255: 0, 0, 0, alpha: 0.32)
    public static let hairlineFaint = SwiftUI.Color(rgb255: 0, 0, 0, alpha: 0.24)
    public static let chrome = SwiftUI.Color(rgb255: 0, 0, 0, alpha: 0.36)
    public static let chromeSoft = SwiftUI.Color(rgb255: 0, 0, 0, alpha: 0.32)
    public static let strong = SwiftUI.Color(rgb255: 242, 244, 238, alpha: 0.19)
    public static let stronger = SwiftUI.Color(rgb255: 242, 244, 238, alpha: 0.28)
    public static let ring = SwiftUI.Color(rgb255: 242, 244, 238, alpha: 0.32)
    public static let paneDivider = SwiftUI.Color(rgb255: 0, 0, 0, alpha: 0.5)
  }

  /// Surface washes — alpha-only fills used for hover/selected states.
  /// `selected` is the one entry based on pure white (`rgba(255,255,255,…)`)
  /// rather than the `242,244,238` off-white the rest of the family uses;
  /// that is intentional and matches `tokens.ts`'s `wash` map / checklist
  /// §2.1 exactly.
  public enum Wash {
    public static let faint = SwiftUI.Color(rgb255: 242, 244, 238, alpha: 0.03)
    public static let soft = SwiftUI.Color(rgb255: 242, 244, 238, alpha: 0.04)
    public static let medium = SwiftUI.Color(rgb255: 242, 244, 238, alpha: 0.06)
    public static let raised = SwiftUI.Color(rgb255: 242, 244, 238, alpha: 0.075)
    public static let selected = SwiftUI.Color(rgb255: 255, 255, 255, alpha: 0.08)
    public static let strong = SwiftUI.Color(rgb255: 242, 244, 238, alpha: 0.09)
    public static let strongest = SwiftUI.Color(rgb255: 242, 244, 238, alpha: 0.12)
  }

  /// Tab-group identity colors — the third and last place color is allowed,
  /// alongside diff and debug (checklist §5). Reuses the existing accents
  /// rather than introducing new hues; `gray` is the uncolored default and
  /// is `Line.stronger` verbatim, not its own swatch.
  public enum GroupColor: String, CaseIterable, Sendable {
    case blue
    case green
    case amber
    case red
    case purple
    case gray

    /// The `#RRGGBB` swatch backing this key, or `nil` for `gray`, which
    /// has no swatch of its own (it passes an already-alpha'd color
    /// through instead). Mirrors `withAlpha`'s `!swatch.startsWith('#')`
    /// guard in `tokens.ts`.
    public var swatchHex: String? {
      switch self {
      case .blue: return "#5b88f7"
      case .green: return "#8acb94"
      case .amber: return "#e5c07b"
      case .red: return "#e27b83"
      case .purple: return "#c678dd"
      case .gray: return nil
      }
    }

    /// The group's own color at full opacity.
    public var color: SwiftUI.Color {
      guard let swatchHex else { return DesignTokens.Line.stronger }
      return SwiftUI.Color(hex: swatchHex)
    }

    /// Native equivalent of `withAlpha(groupColor, alpha)`: applies `alpha`
    /// to a colored swatch. `gray` already carries its own alpha
    /// (`Line.stronger`) and passes through unchanged, exactly as the
    /// mock's early return does for values that aren't a bare hex string.
    public func withAlpha(_ alpha: Double) -> SwiftUI.Color {
      guard let swatchHex else { return color }
      return SwiftUI.Color(hex: swatchHex, alpha: alpha)
    }
  }
}
