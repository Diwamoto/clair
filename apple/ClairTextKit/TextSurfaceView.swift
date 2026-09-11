import AppKit
import CoreGraphics
import Foundation

/// Counters the Dev harness shows. Stable never displays them.
struct TextSurfaceDiagnostics: Equatable, Sendable {
  var visibleRowCount = 0
  var drawnRowCount = 0
  var damageRectCount = 0
  var fastPathRowCount = 0
  var shapedRowCount = 0
  var runCacheCount = 0
  var runCacheHitCount = 0
  var fallbackResolutionCount = 0
}

/// The `NSView` both surfaces draw into.
///
/// It owns no text. Rows come from a `TextSurfaceSource`, and invalidation from
/// that source becomes dirty rectangles for exactly the damaged rows: there is no
/// path here that marks the whole view as needing display.
@MainActor
final class TextSurfaceView: NSView, TextSurfaceSourceObserver {
  let renderer: TextSurfaceRenderer
  private(set) var source: any TextSurfaceSource
  private(set) var pendingDamage: TextSurfaceDamage = .empty
  private(set) var lastPlan: TextSurfaceRenderer.Plan = .empty
  private(set) var diagnostics = TextSurfaceDiagnostics()
  var diagnosticsDidChange: (@MainActor (TextSurfaceDiagnostics) -> Void)?

  init(source: any TextSurfaceSource, renderer: TextSurfaceRenderer) {
    self.source = source
    self.renderer = renderer
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = renderer.theme.background.cgColor
    source.observer = self
    updateFrameSize()
  }

  required init?(coder: NSCoder) {
    fatalError("TextSurfaceView does not support NSCoder initialization.")
  }

  override var isFlipped: Bool {
    true
  }

  override var isOpaque: Bool {
    true
  }

  /// Swaps the model behind the surface. Only the visible rows are repainted.
  func setSource(_ newSource: any TextSurfaceSource) {
    source.observer = nil
    source = newSource
    newSource.observer = self
    updateFrameSize()
    pendingDamage = .empty
    setNeedsDisplay(visibleRect)
  }

  func updateFrameSize() {
    let size = renderer.contentSize(
      rowCount: source.rowCount,
      columnCount: max(source.columnCount, 1)
    )
    if frame.size != size {
      setFrameSize(size)
    }
  }

  // MARK: - TextSurfaceSourceObserver

  func textSurfaceSource(
    _ source: any TextSurfaceSource,
    didInvalidate damage: TextSurfaceDamage
  ) {
    guard !damage.isEmpty else {
      return
    }
    pendingDamage.formUnion(damage)
    for rect in renderer.rects(for: damage, width: bounds.width) {
      setNeedsDisplay(rect)
    }
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else {
      return
    }
    let exposedRows = renderer.rowRange(intersecting: dirtyRect, rowCount: source.rowCount)
    let damage = TextSurfaceDamage(rows: exposedRows)
    let plan = renderer.plan(
      damage: damage,
      in: dirtyRect,
      viewportWidth: bounds.width,
      source: source
    )
    context.setFillColor(renderer.theme.background.cgColor)
    context.fill(dirtyRect)
    renderer.draw(plan, source: source, in: context)
    lastPlan = plan
    updateDiagnostics(plan: plan, exposedRows: exposedRows)
    pendingDamage = .empty
  }

  private func updateDiagnostics(plan: TextSurfaceRenderer.Plan, exposedRows: Range<Int>) {
    diagnostics.visibleRowCount = renderer.rowRange(
      intersecting: visibleRect,
      rowCount: source.rowCount
    ).count
    diagnostics.drawnRowCount = plan.rows.count
    diagnostics.damageRectCount = max(pendingDamage.rowRanges.count, exposedRows.isEmpty ? 0 : 1)
    diagnostics.fastPathRowCount = plan.rows.filter { $0.path == .fastASCII }.count
    diagnostics.shapedRowCount = plan.rows.filter { $0.path == .coreText }.count
    diagnostics.runCacheCount = renderer.metrics.runCache.count
    diagnostics.runCacheHitCount = renderer.metrics.runCache.hitCount
    diagnostics.fallbackResolutionCount = renderer.metrics.fallbackResolutionCount
    diagnosticsDidChange?(diagnostics)
  }
}
