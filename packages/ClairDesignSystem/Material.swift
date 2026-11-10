import SwiftUI

/// 設定 › 一般 › 素材 (canvas Tokens: MATERIAL — flat / glass). Flat is Clair's original opaque chrome;
/// glass floats the chrome as translucent panels over a neutral black wallpaper. Reading surfaces
/// (editor, terminal) stay opaque `canvas` in both — text is never drawn over a see-through ground.
public enum MaterialChoice: String, CaseIterable, Sendable {
  case flat = "クラシック", glass = "Liquid Glass"

  /// Unknown or missing values fall back to flat.
  public init(setting: String?) { self = setting.flatMap(Self.init(rawValue:)) ?? .flat }
}

extension DesignTokens {
  /// Glass values transcribed from the canvas Tokens board (2026-11-09).
  public enum Glass {
    public static let wallpaperTop = SwiftUI.Color(hex: "#111214")
    public static let wallpaperBottom = SwiftUI.Color(hex: "#18191b")
    public static let wallpaperGlow = SwiftUI.Color(hex: "#2a2b2e")
    public static let panelFill = SwiftUI.Color.white.opacity(0.06)
    public static let cardFill = SwiftUI.Color.white.opacity(0.07)
    public static let cardSelected = SwiftUI.Color.white.opacity(0.14)
    public static let capsuleFill = SwiftUI.Color.white.opacity(0.08)
    public static let capsuleSelected = SwiftUI.Color.white.opacity(0.2)
    public static let edge = SwiftUI.Color.white.opacity(0.14)
    public static let rim = SwiftUI.Color.white.opacity(0.22)
    public static let panelRadius: CGFloat = 18
    public static let cardRadius: CGFloat = 12
    /// Gap between a floating panel and the window edge / its neighbour.
    public static let inset: CGFloat = 10
  }
}

private struct GlassKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  /// True while 素材 is Liquid Glass and the system does not ask for reduced transparency.
  public var clairGlass: Bool {
    get { self[GlassKey.self] }
    set { self[GlassKey.self] = newValue }
  }
}

/// The black wallpaper glass panels float over.
public struct GlassWallpaper: View {
  public init() {}
  public var body: some View {
    ZStack {
      LinearGradient(colors: [DesignTokens.Glass.wallpaperTop, DesignTokens.Glass.wallpaperBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
      RadialGradient(colors: [DesignTokens.Glass.wallpaperGlow, .clear], center: UnitPoint(x: 0.15, y: 0.1), startRadius: 0, endRadius: 700)
    }
    .ignoresSafeArea()
  }
}

extension View {
  /// A chrome ground: the flat `chrome` colour, or nothing under glass (the wallpaper shows through).
  public func chromeBackground(_ color: SwiftUI.Color = DesignTokens.Color.chrome) -> some View {
    modifier(ChromeBackground(color: color))
  }

  /// A chrome panel: flat `chrome`, or a floating glass panel (blur, white fill, rim) under glass.
  public func glassPanel(_ color: SwiftUI.Color = DesignTokens.Color.chrome, radius: CGFloat = DesignTokens.Glass.panelRadius) -> some View {
    modifier(GlassPanel(color: color, radius: radius))
  }
}

extension View {
  /// The reading ground (editor, terminal): always opaque `canvas`; under glass it becomes a rounded
  /// card on the wallpaper, so the text itself is never see-through.
  /// `tiled`: the content is a pane tree whose leaves draw their own `paneCard()`, so under glass
  /// only the inset is applied and the wallpaper shows between the panes.
  public func readingPanel(tiled: Bool = false) -> some View { modifier(ReadingPanel(tiled: tiled)) }

  /// One pane of a split under glass: its own rounded canvas card, rim-lit while focused. Flat: unchanged.
  public func paneCard(focused: Bool) -> some View { modifier(PaneCard(focused: focused)) }
}

private struct PaneCard: ViewModifier {
  let focused: Bool
  @Environment(\.clairGlass) private var glass
  func body(content: Content) -> some View {
    if glass {
      let shape = RoundedRectangle(cornerRadius: DesignTokens.Glass.panelRadius, style: .continuous)
      content.background(DesignTokens.Color.canvas).clipShape(shape)
        .overlay(shape.strokeBorder(focused ? DesignTokens.Glass.rim : DesignTokens.Glass.edge))
    } else {
      content
    }
  }
}

private struct ReadingPanel: ViewModifier {
  let tiled: Bool
  @Environment(\.clairGlass) private var glass
  func body(content: Content) -> some View {
    if glass && tiled {
      content.padding([.vertical, .trailing], DesignTokens.Glass.inset)
    } else if glass {
      let shape = RoundedRectangle(cornerRadius: DesignTokens.Glass.panelRadius, style: .continuous)
      content.background(DesignTokens.Color.canvas).clipShape(shape)
        .overlay(shape.strokeBorder(DesignTokens.Glass.edge))
        .padding([.vertical, .trailing], DesignTokens.Glass.inset)
    } else {
      content.background(DesignTokens.Color.canvas)
    }
  }
}

private struct ChromeBackground: ViewModifier {
  let color: SwiftUI.Color
  @Environment(\.clairGlass) private var glass
  func body(content: Content) -> some View { content.background(glass ? .clear : color) }
}

private struct GlassPanel: ViewModifier {
  let color: SwiftUI.Color
  let radius: CGFloat
  @Environment(\.clairGlass) private var glass
  func body(content: Content) -> some View {
    if glass {
      let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
      // ponytail: SwiftUI material + white wash approximates the canvas' blur(28) saturate(170%);
      // switch to `glassEffect` once the minimum macOS is 26.
      content
        .background(DesignTokens.Glass.panelFill, in: shape)
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.strokeBorder(DesignTokens.Glass.edge))
        .overlay(alignment: .top) { shape.stroke(DesignTokens.Glass.rim, lineWidth: 1).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)) }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.28), radius: 15, y: 10)
        .padding(DesignTokens.Glass.inset)
    } else {
      content.background(color)
    }
  }
}

extension View {
  /// A selected sidebar row's fill: `surfaceActive` on flat, the canvas' glass `cardSelected` on glass.
  /// Every sidebar panel (explorer, changes, file browser, TODO) uses this so selection reads the same.
  public func sidebarSelection(_ on: Bool) -> some View { modifier(SidebarSelection(on: on)) }
}

private struct SidebarSelection: ViewModifier {
  let on: Bool
  @Environment(\.clairGlass) private var glass
  func body(content: Content) -> some View {
    content.background(
      on ? (glass ? DesignTokens.Glass.cardSelected : DesignTokens.Color.surfaceActive) : .clear,
      in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
  }
}
