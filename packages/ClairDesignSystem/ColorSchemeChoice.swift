import SwiftUI

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// Settings → 外観 (spec §5.11 colour scheme). Every token is scheme-aware
/// (`Color(hex:light:)`), so switching only has to set the app appearance:
/// SwiftUI, the editor and the terminal repaint from it without a restart.
public enum ColorSchemeChoice: String, CaseIterable, Sendable {
  case dark = "ダーク", light = "ライト", system = "システム"

  /// The scheme to draw in; `system` follows the OS appearance.
  public func resolved(systemIsDark: Bool) -> ColorScheme {
    switch self {
    case .dark: return .dark
    case .light: return .light
    case .system: return systemIsDark ? .dark : .light
    }
  }

  /// Unknown or missing values fall back to dark, Clair's original scheme.
  public init(setting: String?) { self = setting.flatMap(Self.init(rawValue:)) ?? .dark }

  @MainActor public func apply() {
    #if canImport(AppKit)
      NSApp?.appearance = self == .system ? nil : NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    #elseif canImport(UIKit)
      let style: UIUserInterfaceStyle = self == .system ? .unspecified : self == .dark ? .dark : .light
      for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
        scene.windows.forEach { $0.overrideUserInterfaceStyle = style }
      }
    #endif
  }
}
