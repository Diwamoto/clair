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
  /// True while the shell draws Liquid Glass. `Radius` and `Typography` read it, so their couple of hundred
  /// call sites follow the material without environment plumbing.
  /// ponytail: a global, not an environment value — a view that is not re-evaluated when 素材 flips keeps the
  /// old step until its next update. Thread it through the environment if a stale view ever shows.
  nonisolated(unsafe) public static var glassActive = false

  /// Glass values transcribed from the canvas Tokens board (2026-11-09; `GLASS の中身` 2026-11-10).
  public enum Glass {
    /// An overlay sheet's ground (palette, context menu, notice, dialog): dark enough to read over anything.
    public static let sheetFill = SwiftUI.Color(hex: "#26272a").opacity(0.78)
    public static let sheetRadius: CGFloat = 18
    /// Somewhere you type: a well cut into the glass, not a button raised out of it.
    public static let wellFill = SwiftUI.Color.black.opacity(0.26)
    public static let wellEdge = SwiftUI.Color.white.opacity(0.09)
    public static let guide = SwiftUI.Color.white.opacity(0.07)
    public static let railWidth: CGFloat = 38
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

/// The one shadow an overlay (palette, menu, popover, notice) casts: black 40%, radius 12, y 6.
public enum Elevation {
  public static let overlayColor = SwiftUI.Color.black.opacity(0.4)
  public static let overlayRadius: CGFloat = 12
  public static let overlayY: CGFloat = 6
}

extension View {
  /// The overlay shadow (`Elevation`). The only shadow chrome casts outside the glass panel's own.
  public func overlayShadow() -> some View {
    shadow(color: Elevation.overlayColor, radius: Elevation.overlayRadius, y: Elevation.overlayY)
  }

  /// A chrome ground: the flat `chrome` colour, or nothing under glass (the wallpaper shows through).
  public func chromeBackground(_ color: SwiftUI.Color = DesignTokens.Color.chrome) -> some View {
    modifier(ChromeBackground(color: color))
  }

  /// A chrome panel: flat `chrome`, or a floating glass panel (blur, white fill, rim) under glass.
  public func glassPanel(_ color: SwiftUI.Color = DesignTokens.Color.chrome, radius: CGFloat = DesignTokens.Glass.panelRadius, inset: CGFloat = DesignTokens.Glass.inset) -> some View {
    modifier(GlassPanel(color: color, radius: radius, inset: inset))
  }

  /// An overlay's ground and edge: opaque `chromeRaised` with a `strong` hairline, or a glass sheet under glass.
  /// `palette`: the centred 560pt overlays, which take the larger sheet radius under glass.
  public func sheetSurface(palette: Bool = false) -> some View { modifier(SheetSurface(palette: palette)) }

  /// A text field's ground: `flat` with a hairline, or a well cut into the glass. `radius` nil is the `card` step.
  public func fieldWell(_ flat: SwiftUI.Color = DesignTokens.Color.chrome, radius: CGFloat? = nil, edged: Bool = true) -> some View {
    modifier(FieldWell(flat: flat, radius: radius, edged: edged))
  }

  /// A pressable control's fill. Flat: `surfaceActive` when `on` (plus a `strong` edge if `edged`), nothing otherwise.
  /// Glass: a capsule, white 20% when `on` and 8% otherwise.
  public func controlFill(on: Bool = true, flatRadius: CGFloat? = nil, edged: Bool = false) -> some View {
    modifier(ControlFill(on: on, flatRadius: flatRadius, edged: edged))
  }
}

private struct SheetSurface: ViewModifier {
  let palette: Bool
  @Environment(\.clairGlass) private var glass
  func body(content: Content) -> some View {
    let r = glass && palette ? DesignTokens.Glass.sheetRadius : Radius.overlay
    if glass {
      let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
      content
        .background(DesignTokens.Glass.sheetFill, in: shape)
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.strokeBorder(DesignTokens.Glass.edge))
        .overlay(alignment: .top) { shape.stroke(DesignTokens.Glass.rim, lineWidth: 1).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)) }
    } else {
      content
        .background(DesignTokens.Color.chromeRaised, in: RoundedRectangle(cornerRadius: r))
        .overlay(RoundedRectangle(cornerRadius: r).stroke(DesignTokens.Line.strong))
    }
  }
}

private struct FieldWell: ViewModifier {
  let flat: SwiftUI.Color
  let radius: CGFloat?
  let edged: Bool
  @Environment(\.clairGlass) private var glass
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius ?? Radius.card, style: glass ? .continuous : .circular)
    content
      .background(glass ? DesignTokens.Glass.wellFill : flat, in: shape)
      .overlay(shape.stroke(glass ? DesignTokens.Glass.wellEdge : edged ? DesignTokens.Line.hairlineFaint : .clear))
  }
}

private struct ControlFill: ViewModifier {
  let on: Bool
  let flatRadius: CGFloat?
  let edged: Bool
  @Environment(\.clairGlass) private var glass
  func body(content: Content) -> some View {
    if glass {
      content.background(on ? DesignTokens.Glass.capsuleSelected : DesignTokens.Glass.capsuleFill, in: Capsule())
    } else {
      let shape = RoundedRectangle(cornerRadius: flatRadius ?? Radius.control)
      content
        .background(on ? DesignTokens.Color.surfaceActive : .clear, in: shape)
        .overlay(shape.stroke(on && edged ? DesignTokens.Line.strong : .clear))
    }
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
  let inset: CGFloat
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
        .padding(inset)
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
