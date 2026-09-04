import AppKit
import SwiftUI

/// Shared One Dark workspace chrome tokens for the native app shell.
///
/// The Interaction Lab contract fixes one dark workspace palette across the
/// titlebar, activity bar, navigator, panes, and status bar. Surfaces must not
/// invent per-surface themes; syntax color, process state, and attention are
/// the only meaningful accents.
enum WorkspaceChrome {
  static func rgb(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Double = 1) -> Color {
    Color(
      .sRGB,
      red: Double(red) / 255,
      green: Double(green) / 255,
      blue: Double(blue) / 255,
      opacity: alpha
    )
  }

  // These values mirror the Interaction Lab's CSS variables. Keeping the
  // names semantic makes it harder for editor, terminal, or navigation code
  // to drift into separate dark themes.
  static let canvas = rgb(18, 20, 22)
  static let surface = rgb(24, 27, 31)
  static let chrome = rgb(16, 18, 20)
  static let chromeRaised = rgb(30, 34, 39)
  static let surfaceHover = rgb(36, 42, 49)
  static let surfaceActive = rgb(43, 51, 60)
  static let border = rgb(242, 244, 238, 0.11)
  static let borderStrong = rgb(242, 244, 238, 0.19)
  static let textPrimary = rgb(241, 243, 239)
  static let textSecondary = rgb(201, 206, 200)
  static let textTertiary = rgb(155, 161, 155)
  static let textQuaternary = rgb(112, 120, 113)
  static let accent = rgb(91, 136, 247)
  static let live = rgb(91, 136, 247)
  static let attention = rgb(229, 192, 123)
  static let success = rgb(138, 203, 148)
  static let danger = rgb(226, 123, 131)

  static func nsRGB(
    _ red: Int,
    _ green: Int,
    _ blue: Int,
    _ alpha: CGFloat = 1
  ) -> NSColor {
    NSColor(
      srgbRed: CGFloat(red) / 255,
      green: CGFloat(green) / 255,
      blue: CGFloat(blue) / 255,
      alpha: alpha
    )
  }

  static let nsCanvas = nsRGB(18, 20, 22)
  static let nsTextPrimary = nsRGB(241, 243, 239)
  static let nsAccent = nsRGB(91, 136, 247)
  static let nsSelectedTextBackground = nsRGB(91, 136, 247, 0.34)
  static let nsSelectedText = nsRGB(241, 243, 239)

  /// Semantic accent for terminal process state.
  static func terminalState(_ state: TerminalSession.State) -> Color {
    switch state {
    case .running, .starting:
      success
    case .idle, .stopping:
      textTertiary
    case .exited:
      attention
    case .missing, .failed:
      danger
    }
  }
  /// Compact text used across workspace chrome.
  static func chromeFont(size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
  }
}

extension ProjectColor {
  /// One Dark-aligned Project group accent used by the titlebar strip.
  var workspaceAccent: Color {
    switch self {
    case .blue:
      WorkspaceChrome.rgb(91, 136, 247)
    case .purple:
      WorkspaceChrome.rgb(199, 131, 218)
    case .orange:
      WorkspaceChrome.rgb(229, 192, 123)
    case .green:
      WorkspaceChrome.rgb(138, 203, 148)
    case .red:
      WorkspaceChrome.rgb(226, 123, 131)
    case .gray:
      WorkspaceChrome.rgb(155, 161, 155)
    }
  }
}
