import AppKit
import Foundation

/// Dev-only harness for the shared text surface (`ClairTextKit`).
///
/// It draws fixtures on the Clair-owned surface before either model layer
/// exists, which is how the foundation is exercised without touching the
/// production editor or terminal. Stable never opens it.
enum TextSurfaceHarness {
  static var isAvailable: Bool {
    #if CLAIR_DEV
      return true
    #else
      return false
    #endif
  }

  /// Maps the workspace palette onto the engine's own color type. The engine
  /// never reads Clair's theme; the app hands it colors.
  @MainActor
  static var theme: TextSurfaceTheme {
    TextSurfaceTheme(
      background: color(WorkspaceChrome.nsCanvas, fallback: TextSurfaceTheme.oneDark.background),
      foreground: color(WorkspaceChrome.nsCode, fallback: TextSurfaceTheme.oneDark.foreground),
      selectionBackground: color(
        WorkspaceChrome.nsSelectedTextBackground,
        fallback: TextSurfaceTheme.oneDark.selectionBackground
      ),
      selectionForeground: color(
        WorkspaceChrome.nsSelectedText,
        fallback: TextSurfaceTheme.oneDark.selectionForeground
      ),
      caret: color(WorkspaceChrome.nsAccent, fallback: TextSurfaceTheme.oneDark.caret)
    )
  }

  @MainActor
  static func color(_ nsColor: NSColor, fallback: TextSurfaceColor) -> TextSurfaceColor {
    guard let converted = nsColor.usingColorSpace(.sRGB) else {
      return fallback
    }
    return TextSurfaceColor(
      red: Double(converted.redComponent),
      green: Double(converted.greenComponent),
      blue: Double(converted.blueComponent),
      alpha: Double(converted.alphaComponent)
    )
  }
}

/// Window that hosts the harness surface, a fixture picker, and the Dev
/// diagnostics counters described in the engine design.
@MainActor
final class TextSurfaceHarnessWindowController: NSWindowController, NSWindowDelegate {
  private static var current: TextSurfaceHarnessWindowController?

  private let fixturePicker = NSSegmentedControl()
  private let diagnosticsLabel = NSTextField(labelWithString: "")
  private let scrollView = NSScrollView()
  private let surfaceView: TextSurfaceView
  private var fixture: TextSurfaceFixture
  private var fixtureSource: TextFixtureSource
  private var editCounter = 0

  static func present() {
    guard TextSurfaceHarness.isAvailable else {
      return
    }
    let controller = current ?? TextSurfaceHarnessWindowController(fixture: .mixed)
    current = controller
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  init(fixture: TextSurfaceFixture) {
    let metrics = TextFontMetrics(configuration: .editor)
    let renderer = TextSurfaceRenderer(metrics: metrics, theme: TextSurfaceHarness.theme)
    let source = fixture.makeSource()
    self.fixture = fixture
    fixtureSource = source
    surfaceView = TextSurfaceView(source: source, renderer: renderer)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Text Surface Harness"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    configureContent()
    reloadFixture()
  }

  required init?(coder: NSCoder) {
    fatalError("TextSurfaceHarnessWindowController does not support NSCoder initialization.")
  }

  func windowWillClose(_ notification: Notification) {
    TextSurfaceHarnessWindowController.current = nil
  }

  private func configureContent() {
    guard let window else {
      return
    }
    fixturePicker.segmentStyle = .rounded
    fixturePicker.trackingMode = .selectOne
    fixturePicker.segmentCount = TextSurfaceFixture.allCases.count
    for (index, fixture) in TextSurfaceFixture.allCases.enumerated() {
      fixturePicker.setLabel(fixture.title, forSegment: index)
      fixturePicker.setWidth(0, forSegment: index)
    }
    fixturePicker.selectedSegment =
      TextSurfaceFixture.allCases.firstIndex(of: fixture) ?? 0
    fixturePicker.target = self
    fixturePicker.action = #selector(fixtureChanged)

    let damageButton = NSButton(
      title: "Damage one row",
      target: self,
      action: #selector(damageRow)
    )
    damageButton.bezelStyle = .rounded

    diagnosticsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    diagnosticsLabel.textColor = WorkspaceChrome.nsLineNumber
    diagnosticsLabel.lineBreakMode = .byTruncatingTail

    let controls = NSStackView(views: [fixturePicker, damageButton, diagnosticsLabel])
    controls.orientation = .horizontal
    controls.spacing = 12
    controls.alignment = .centerY
    controls.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

    let clipView = NSClipView()
    clipView.drawsBackground = true
    clipView.backgroundColor = WorkspaceChrome.nsCanvas
    scrollView.contentView = clipView
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.backgroundColor = WorkspaceChrome.nsCanvas
    scrollView.documentView = surfaceView
    WorkspaceChrome.configureThinScrollbars(in: scrollView)

    controls.setContentHuggingPriority(.defaultHigh, for: .vertical)
    scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

    let container = NSStackView(views: [controls, scrollView])
    container.orientation = .vertical
    container.spacing = 0
    container.alignment = .leading
    container.distribution = .fill
    window.contentView = container
    NSLayoutConstraint.activate([
      controls.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      controls.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])

    surfaceView.diagnosticsDidChange = { [weak self] diagnostics in
      self?.showDiagnostics(diagnostics)
    }
  }

  @objc
  private func fixtureChanged() {
    let index = fixturePicker.selectedSegment
    guard TextSurfaceFixture.allCases.indices.contains(index) else {
      return
    }
    fixture = TextSurfaceFixture.allCases[index]
    reloadFixture()
  }

  /// Rewrites a single row so the damage path is visible: only that row's
  /// rectangle is invalidated and redrawn.
  @objc
  private func damageRow() {
    guard fixtureSource.rowCount > 0 else {
      return
    }
    editCounter += 1
    let row = editCounter % fixtureSource.rowCount
    let original = fixtureSource.text(at: row) ?? ""
    fixtureSource.replace(row: row, with: "\(original) ▸ \(editCounter)")
  }

  private func reloadFixture() {
    let source = fixture.makeSource()
    fixtureSource = source
    surfaceView.setSource(source)
  }

  private func showDiagnostics(_ diagnostics: TextSurfaceDiagnostics) {
    diagnosticsLabel.stringValue = [
      "visible \(diagnostics.visibleRowCount)",
      "drawn \(diagnostics.drawnRowCount)",
      "damage \(diagnostics.damageRectCount)",
      "fast \(diagnostics.fastPathRowCount)",
      "shaped \(diagnostics.shapedRowCount)",
      "cache \(diagnostics.runCacheCount)",
    ].joined(separator: " / ")
  }
}
