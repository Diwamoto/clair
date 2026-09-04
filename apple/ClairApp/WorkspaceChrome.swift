import AppKit
import SwiftUI

/// Shared One Dark workspace chrome tokens for the native app shell.
///
/// The Interaction Lab contract fixes one dark workspace palette across the
/// titlebar, activity bar, navigator, panes, and status bar. Surfaces must not
/// invent per-surface themes; syntax color, process state, and attention are
/// the only meaningful accents.
enum WorkspaceChrome {
  static let scrollbarThickness: CGFloat = 3

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

  /// Replaces AppKit's wide default scrollers while preserving the user's
  /// overlay/always-visible preference and the normal scroll-wheel behavior.
  @MainActor
  static func configureThinScrollbars(in rootView: NSView) {
    configureThinScrollbarsRecursively(
      in: rootView,
      relativeTo: rootView,
      suppressTitlebarScrollbars: !(rootView is NSScrollView)
    )
  }

  @MainActor
  private static func configureThinScrollbarsRecursively(
    in rootView: NSView,
    relativeTo contentView: NSView,
    suppressTitlebarScrollbars: Bool
  ) {
    if let scrollView = rootView as? NSScrollView {
      if suppressTitlebarScrollbars && isTitlebarScrollView(scrollView, relativeTo: contentView) {
        hideScrollbars(in: scrollView)
      } else {
        configureThinScrollbars(in: scrollView)
      }
    }

    for subview in rootView.subviews {
      configureThinScrollbarsRecursively(
        in: subview,
        relativeTo: contentView,
        suppressTitlebarScrollbars: suppressTitlebarScrollbars
      )
    }
  }

  @MainActor
  private static func isTitlebarScrollView(
    _ scrollView: NSScrollView,
    relativeTo contentView: NSView
  ) -> Bool {
    let frame = scrollView.convert(scrollView.bounds, to: contentView)
    let titlebarHeight: CGFloat = 56
    let topTolerance: CGFloat = 12
    let isNearTop: Bool
    if contentView.isFlipped {
      isNearTop = frame.minY <= contentView.bounds.minY + titlebarHeight + topTolerance
    } else {
      isNearTop = frame.maxY >= contentView.bounds.maxY - titlebarHeight - topTolerance
    }
    return frame.height <= titlebarHeight && isNearTop
  }

  @MainActor
  private static func hideScrollbars(in scrollView: NSScrollView) {
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = false
    scrollView.horizontalScroller = nil
    scrollView.verticalScroller = nil
    scrollView.autohidesScrollers = true
    scrollView.needsLayout = true
  }

  @MainActor
  private static func configureThinScrollbars(in scrollView: NSScrollView) {
    var replacedScroller = false

    if let verticalScroller = scrollView.verticalScroller,
      !(verticalScroller is ClairThinScroller)
    {
      scrollView.verticalScroller = thinScroller(replacing: verticalScroller)
      replacedScroller = true
    }
    if let horizontalScroller = scrollView.horizontalScroller,
      !(horizontalScroller is ClairThinScroller)
    {
      scrollView.horizontalScroller = thinScroller(replacing: horizontalScroller)
      replacedScroller = true
    }

    if replacedScroller {
      // SwiftUI can create the default scroller before we replace it. Retile
      // after the replacement so the custom subclass' 3px width is applied
      // instead of the old macOS track thickness.
      scrollView.tile()
    }
  }

  @MainActor
  private static func thinScroller(replacing scroller: NSScroller) -> NSScroller {
    guard !(scroller is ClairThinScroller) else {
      return scroller
    }

    let replacement = ClairThinScroller(frame: scroller.frame)
    replacement.controlSize = scroller.controlSize
    replacement.scrollerStyle = scroller.scrollerStyle
    replacement.knobStyle = scroller.knobStyle
    replacement.doubleValue = scroller.doubleValue
    replacement.knobProportion = scroller.knobProportion
    replacement.isEnabled = scroller.isEnabled
    replacement.target = scroller.target
    replacement.action = scroller.action
    return replacement
  }

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

@MainActor
final class ClairThinScroller: NSScroller {
  override class var isCompatibleWithOverlayScrollers: Bool { true }

  override class func scrollerWidth(
    for controlSize: NSControl.ControlSize,
    scrollerStyle: NSScroller.Style
  ) -> CGFloat {
    WorkspaceChrome.scrollbarThickness
  }

  override func drawKnob() {
    let knobRect = rect(for: .knob)
    guard !knobRect.isEmpty else {
      return
    }

    let isVertical = knobRect.height >= knobRect.width
    let trackThickness = isVertical ? knobRect.width : knobRect.height
    let thickness = min(WorkspaceChrome.scrollbarThickness, trackThickness)
    let rect: NSRect
    if isVertical {
      rect = NSRect(
        x: knobRect.midX - thickness / 2,
        y: knobRect.minY,
        width: thickness,
        height: knobRect.height
      )
    } else {
      rect = NSRect(
        x: knobRect.minX,
        y: knobRect.midY - thickness / 2,
        width: knobRect.width,
        height: thickness
      )
    }
    let color = WorkspaceChrome.nsTextPrimary.withAlphaComponent(isHighlighted ? 0.82 : 0.52)
    color.setFill()
    NSBezierPath(
      roundedRect: rect,
      xRadius: thickness / 2,
      yRadius: thickness / 2
    ).fill()
  }

  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

struct ThinScrollbarsInstaller: NSViewRepresentable {
  func makeNSView(context: Context) -> ThinScrollbarsInstallerView {
    ThinScrollbarsInstallerView()
  }

  func updateNSView(_ nsView: ThinScrollbarsInstallerView, context: Context) {
    nsView.scheduleInstallation()
  }

  static func dismantleNSView(_ nsView: ThinScrollbarsInstallerView, coordinator: ()) {
    nsView.cancelPendingInstallation()
  }
}

/// Removes the AppKit scrollers that SwiftUI creates for the compact titlebar
/// strips. The horizontal scroll view remains available to trackpad and
/// keyboard input when a narrow window needs it; only the indicator is gone.
struct HiddenScrollbarsInstaller: NSViewRepresentable {
  func makeNSView(context: Context) -> HiddenScrollbarsInstallerView {
    HiddenScrollbarsInstallerView()
  }

  func updateNSView(_ nsView: HiddenScrollbarsInstallerView, context: Context) {
    nsView.scheduleInstallation()
  }

  static func dismantleNSView(_ nsView: HiddenScrollbarsInstallerView, coordinator: ()) {
    nsView.cancelPendingInstallation()
  }
}

@MainActor
final class HiddenScrollbarsInstallerView: NSView {
  private var installationPending = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scheduleInstallation()
  }

  override func layout() {
    super.layout()
    scheduleInstallation()
  }

  func scheduleInstallation() {
    guard window != nil, !installationPending else {
      return
    }

    installationPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }
      self.installationPending = false
      self.hideEnclosingScrollView()
    }
  }

  func cancelPendingInstallation() {
    installationPending = false
  }

  private func hideEnclosingScrollView() {
    var candidate: NSView? = self
    while let view = candidate {
      if let scrollView = view as? NSScrollView {
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScroller = nil
        scrollView.verticalScroller = nil
        scrollView.autohidesScrollers = true
        scrollView.needsLayout = true
        return
      }
      candidate = view.superview
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

@MainActor
final class ThinScrollbarsInstallerView: NSView {
  private var installationPending = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scheduleInstallation()
  }

  override func layout() {
    super.layout()
    scheduleInstallation()
  }

  func scheduleInstallation() {
    guard window != nil, !installationPending else {
      return
    }

    installationPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }
      self.installationPending = false
      guard let rootView = self.window?.contentView else {
        return
      }
      WorkspaceChrome.configureThinScrollbars(in: rootView)
    }
  }

  func cancelPendingInstallation() {
    installationPending = false
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

/// A compact pointer response for the editor's custom chrome.
///
/// SwiftUI's built-in bordered styles already provide platform feedback. This
/// style is for the plain/borderless controls that make up Clair's dense
/// workspace: hover gently dims the control, while a press responds
/// immediately with a small, non-bouncy compression.
struct TactileButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    TactileButtonLabel(configuration: configuration)
  }
}

private struct TactileButtonLabel: View {
  let configuration: ButtonStyle.Configuration
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    configuration.label
      .overlay {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color.black.opacity(configuration.isPressed ? 0.12 : isHovered ? 0.06 : 0))
          .allowsHitTesting(false)
      }
      .brightness(configuration.isPressed ? -0.04 : isHovered ? -0.015 : 0)
      .scaleEffect(
        reduceMotion
          ? 1
          : configuration.isPressed
            ? 0.965
            : isHovered ? 0.992 : 1
      )
      .animation(
        reduceMotion
          ? .linear(duration: 0)
          : .easeOut(duration: configuration.isPressed ? 0.072 : 0.14),
        value: configuration.isPressed
      )
      .animation(
        reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.14),
        value: isHovered
      )
      .onHover { isHovered = $0 }
  }
}

extension ButtonStyle where Self == TactileButtonStyle {
  static var tactile: TactileButtonStyle { .init() }
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
