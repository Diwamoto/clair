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

  // Transcribed from `prototypes/clair-workbench/src/tokens.ts`, which is
  // itself a copy of the Tokens artboard on the Clair UI design canvas. Values
  // are copied, not chosen: do not add a token the canvas does not define.

  // SURFACE — two tiers. The pane (canvas/surface) is the darkest thing in
  // the window because it is what you read for hours; chrome sits one step
  // above it so the frame reads as frame and never as content. Dark only —
  // there is no light theme.
  static let chrome = rgb(49, 54, 63)
  static let canvas = rgb(40, 44, 52)
  static let surface = rgb(40, 44, 52)
  static let chromeRaised = rgb(30, 34, 39)
  static let surfaceHover = rgb(46, 51, 60)
  static let surfaceActive = rgb(56, 61, 71)

  // CHROME INK — chrome's own ladder. Its strongest step stays under the
  // code's own contrast against the pane (6.6:1) so the frame never speaks
  // louder than the thing being read; textPrimary is content ink only.
  static let chromeInk = rgb(182, 188, 182)
  static let chromeInkMuted = rgb(138, 144, 139)

  // TEXT
  static let textPrimary = rgb(241, 243, 239)
  static let textSecondary = rgb(201, 206, 200)
  static let textTertiary = rgb(155, 161, 155)
  static let textQuaternary = rgb(112, 120, 113)
  static let textMuted = rgb(85, 96, 90)
  static let lineNumber = rgb(75, 85, 97)
  static let divider = rgb(61, 69, 78)

  // MEANING — only diff and debug are allowed to carry colour.
  static let success = rgb(138, 203, 148)
  static let attention = rgb(229, 192, 123)
  static let danger = rgb(226, 123, 131)
  static let debugBlue = rgb(91, 136, 247)
  static let debugBlueText = rgb(143, 176, 250)
  static let accent = debugBlue
  static let live = debugBlue

  // Panel grounds used by cards, footers and overlays.
  static let panel = rgb(24, 27, 31)
  static let panelDeep = rgb(16, 18, 20)
  static let overlayGround = rgb(12, 14, 16)

  // Editor content colours (One Dark).
  static let code = rgb(171, 178, 191)
  static let codeBright = rgb(208, 212, 207)
  static let codeComment = rgb(92, 99, 112)

  // HAIRLINES — washes of the primary ink, exactly as the artboards draw them.
  static let hairline = rgb(242, 244, 238, 0.11)
  static let hairlineSoft = rgb(242, 244, 238, 0.08)
  static let hairlineFaint = rgb(242, 244, 238, 0.055)
  static let chromeLine = rgb(242, 244, 238, 0.1)
  static let chromeLineSoft = rgb(242, 244, 238, 0.09)
  static let paneDivider = rgb(242, 244, 238, 0.15)
  static let border = hairline
  static let borderStrong = rgb(242, 244, 238, 0.19)
  static let borderStronger = rgb(242, 244, 238, 0.28)

  // WASH — raised fills on the flat ground.
  static let washFaint = rgb(242, 244, 238, 0.03)
  static let washSoft = rgb(242, 244, 238, 0.04)
  static let washMedium = rgb(242, 244, 238, 0.06)
  static let washRaised = rgb(242, 244, 238, 0.075)
  static let washSelected = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.08)
  static let washStrong = rgb(242, 244, 238, 0.09)
  static let washStrongest = rgb(242, 244, 238, 0.12)

  // RADIUS — 3 steps.
  enum Radius {
    static let control: CGFloat = 4
    static let card: CGFloat = 6
    static let overlay: CGFloat = 10
  }

  /// CHROME BUDGET — the vertical px spent before code. titlebar 48 + status
  /// bar 26 = 74. The editor breadcrumb is a deliberate exception: a split
  /// pane pays 24px per pane on top of this.
  enum Metrics {
    static let titlebar: CGFloat = 48
    /// Left vertical nav strip — was a horizontal row nested at the top of
    /// the sidebar panel (`sidebarStrip`, now unused); it now sits outside
    /// the panel as its own full-height column, so the sidebar itself lost
    /// this width from its own budget below.
    static let activityBarWidth: CGFloat = 44
    static let statusBar: CGFloat = 26
    static let sidebarWidth: CGFloat = 242
    /// Tabs are a fixed width, left to right, and never stretch. Width is what
    /// makes a tab strip calm, so 200 is generous — the titlebar's own controls
    /// were cut back to pay for it — but it is the same 200 however many tabs
    /// are open and however wide the window is.
    static let tabWidth: CGFloat = 200
    static let tabHeight: CGFloat = 38
    static let mainHeader: CGFloat = 44
    static let breadcrumb: CGFloat = 24
  }

  /// TAB GROUP COLOURS — the one place beyond diff and debug where colour is
  /// allowed: identifying a project's tab group in the titlebar. These reuse
  /// the existing accents rather than introducing new hues.
  static func groupColor(_ color: ProjectColor) -> Color {
    switch color {
    case .blue:
      rgb(91, 136, 247)
    case .green:
      rgb(138, 203, 148)
    case .orange:
      rgb(229, 192, 123)
    case .red:
      rgb(226, 123, 131)
    case .purple:
      rgb(198, 120, 221)
    case .gray:
      borderStronger
    }
  }

  /// A group colour at a given opacity. `gray` already carries its own alpha,
  /// so it passes through unchanged.
  static func groupColor(_ color: ProjectColor, opacity: Double) -> Color {
    color == .gray ? borderStronger : groupColor(color).opacity(opacity)
  }

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

  static let nsCanvas = nsRGB(40, 44, 52)
  static let nsTextPrimary = nsRGB(241, 243, 239)
  static let nsCode = nsRGB(171, 178, 191)
  static let nsLineNumber = nsRGB(75, 85, 97)
  static let nsAccent = nsRGB(91, 136, 247)
  static let nsSelectedTextBackground = nsRGB(91, 136, 247, 0.34)
  static let nsSelectedText = nsRGB(241, 243, 239)

  /// The canvas as a CSS hex, for the editor web views.
  static let canvasHex = "#282c34"

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

  /// The mock's `.cl` face — keyboard hints and anything that echoes the code.
  static func monoFont(size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
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
  /// The titlebar tab group's accent, from the Tokens artboard's GROUP COLORS.
  var workspaceAccent: Color {
    WorkspaceChrome.groupColor(self)
  }

  /// True for the uncoloured default, which carries its own alpha and so is
  /// never tinted further.
  var isUncoloured: Bool {
    self == .gray
  }
}

/// The mock's `.act` control: a square-ish icon button that is quiet at rest
/// and lights its ground on hover or when it stands for the current screen.
///
/// Hover and selected read as one white-wash tint (`washSelected`), not two —
/// this used to be a separate `surfaceHover`/`surfaceActive` pair plus a 2px
/// underline on the active nav entry; both distinctions turned out to read as
/// noise rather than signal (mock review feedback), so a button is either lit
/// or it isn't.
struct ChromeActionButton<Label: View>: View {
  var width: CGFloat = 30
  var height: CGFloat = 28
  var isActive: Bool = false
  var help: String?
  let action: () -> Void
  @ViewBuilder var label: () -> Label

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      label()
        .frame(width: width, height: height)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(tint)
    .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .onHover { isHovered = $0 }
    .help(help ?? "")
    .accessibilityLabel(help ?? "")
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
  }

  /// Chrome ink, not content ink: an icon in the frame must not out-shout the
  /// code in the pane, so even the selected state stops at `chromeInk`.
  private var tint: Color {
    if isActive {
      return WorkspaceChrome.chromeInk
    }
    return isHovered ? WorkspaceChrome.textSecondary : WorkspaceChrome.textQuaternary
  }

  private var background: Color {
    (isActive || isHovered) ? WorkspaceChrome.washSelected : Color.clear
  }
}

/// The mock's `.hoverable` row: `surfaceHover` under the pointer, nothing at
/// rest. A row that is already selected paints its own ground and opts out.
struct HoverableRowBackground: ViewModifier {
  var isSelected: Bool
  var selectedColor: Color = WorkspaceChrome.surfaceActive
  var cornerRadius: CGFloat = 0

  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .onHover { isHovered = $0 }
  }

  private var fill: Color {
    if isSelected {
      return selectedColor
    }
    return isHovered ? WorkspaceChrome.surfaceHover : Color.clear
  }
}

extension View {
  func hoverableRow(
    isSelected: Bool,
    selectedColor: Color = WorkspaceChrome.surfaceActive,
    cornerRadius: CGFloat = 0
  ) -> some View {
    modifier(
      HoverableRowBackground(
        isSelected: isSelected,
        selectedColor: selectedColor,
        cornerRadius: cornerRadius
      )
    )
  }

  /// A label wider than its box is faded out at the trailing edge rather than
  /// ellipsised — the fade says "there is more" without spending characters on
  /// punctuation, and it keeps the label's ink even at the cut.
  func fadingTrailingEdge(_ width: CGFloat = 18) -> some View {
    mask(
      HStack(spacing: 0) {
        Rectangle().fill(Color.black)
        LinearGradient(
          colors: [Color.black, Color.black.opacity(0)],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: width)
      }
    )
  }
}

/// A single-line label constrained by its parent and faded at the trailing
/// edge. The mask lives on the available frame rather than on the text's
/// intrinsic width, so long tab titles cannot escape the tab button.
struct FadingLabel: View {
  let text: String
  var size: CGFloat = 11
  var weight: Font.Weight = .regular
  var fadeWidth: CGFloat = 18

  var body: some View {
    label
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .fadingTrailingEdge(fadeWidth)
  }

  private var label: some View {
    Text(text)
      .font(.system(size: size, weight: weight))
      .lineLimit(1)
  }
}

/// The 44px header a screen puts at the top of the main area. It is not
/// chrome: it belongs to the screen, under the shared titlebar.
struct MainHeader<Content: View>: View {
  var height: CGFloat = WorkspaceChrome.Metrics.mainHeader
  @ViewBuilder var content: () -> Content

  var body: some View {
    HStack(spacing: 10) {
      content()
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
    .background(WorkspaceChrome.chrome)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(WorkspaceChrome.chromeLine)
        .frame(height: 1)
    }
  }
}

/// A segmented switch between the modes of one tool, sitting inside that
/// tool's own `MainHeader`. Used by 変更を確認 so its second view is a mode of
/// one tool rather than a separate destination with its own nav entry — a git
/// GUI does not give history its own top-level tab either.
struct ChromeModeTabs<Mode: Hashable>: View {
  let modes: [(mode: Mode, label: String)]
  @Binding var selection: Mode

  var body: some View {
    HStack(spacing: 0) {
      ForEach(modes, id: \.mode) { entry in
        let isOn = entry.mode == selection
        Button {
          selection = entry.mode
        } label: {
          Text(entry.label)
            .font(WorkspaceChrome.chromeFont(size: 11, weight: isOn ? .semibold : .regular))
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? WorkspaceChrome.chromeInk : WorkspaceChrome.textQuaternary)
        .background(isOn ? WorkspaceChrome.surfaceActive : Color.clear)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
      }
    }
    .frame(height: 24)
    .background(WorkspaceChrome.panel)
    .clipShape(RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.control, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.control, style: .continuous)
        .stroke(WorkspaceChrome.hairline, lineWidth: 1)
    }
  }
}

/// The 32px title row a sidebar panel puts above its own content.
struct SidebarPanelHeader<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
        .font(WorkspaceChrome.chromeFont(size: 13, weight: .semibold))
        .foregroundStyle(WorkspaceChrome.chromeInk)
      Spacer(minLength: 0)
      trailing()
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(WorkspaceChrome.hairline)
        .frame(height: 1)
    }
  }
}

/// The Tokens artboard's EMPTY STATE component: an icon in the divider ink, a
/// short title, and one quiet line of explanation on the flat canvas.
struct ChromeEmptyState: View {
  let symbol: String
  let title: String
  var message: String?

  var body: some View {
    VStack(spacing: 7) {
      Image(systemName: symbol)
        .font(.system(size: 24, weight: .light))
        .foregroundStyle(WorkspaceChrome.divider)
      Text(title)
        .font(WorkspaceChrome.chromeFont(size: 12, weight: .semibold))
        .foregroundStyle(WorkspaceChrome.textSecondary)
      if let message {
        Text(message)
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
          .multilineTextAlignment(.center)
          .lineSpacing(3)
          .frame(maxWidth: 220)
      }
    }
    .padding(.vertical, 16)
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity)
    .background(
      WorkspaceChrome.canvas,
      in: RoundedRectangle(cornerRadius: WorkspaceChrome.Radius.control, style: .continuous)
    )
    .padding(12)
  }
}
