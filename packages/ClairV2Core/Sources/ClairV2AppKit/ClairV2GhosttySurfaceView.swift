import ClairV2Ghostty
import ClairV2Terminal
import Foundation

#if os(macOS)
  import AppKit
  import SwiftUI

  /// The macOS Ghostty surface (T03): a real `NSView` that owns a real local
  /// shell `ClairV2LocalShellSession`, and wires the surface-level behaviors
  /// this task promises — keyboard input, text selection, copy/paste,
  /// scrollback lookup, font/DPI-aware sizing, and window resize — against
  /// that real PTY.
  ///
  /// Glyph rendering is the one piece this view deliberately does not
  /// implement itself: interpreting terminal escape sequences into a grid of
  /// cells is exactly the job `libghostty` does, and the native rewrite plan
  /// (`docs/plans/clair-v2-native-rewrite.md`, "6. Terminal and session")
  /// forbids a hidden non-Ghostty terminal engine as a fallback. Today,
  /// `ClairV2GhosttyABI`'s pinned subset (`T01`) only covers
  /// init/info/config — it does not yet declare the `ghostty_surface_*`
  /// embedding entry points a real pixel surface needs, and this environment
  /// cannot vendor the real library to safely author/verify those
  /// signatures (see `scripts/v2-ghostty.sh status`). Until that ABI subset
  /// and a vendored artifact both exist, this view reports that gap
  /// explicitly via `ClairV2GhosttyStatus` instead of drawing anything that
  /// looks like rendered terminal content.
  public final class ClairV2GhosttySurfaceView: NSView {
    public let session: ClairV2LocalShellSession
    private var font: NSFont
    private var metrics: ClairV2GhosttyCellMetrics
    private var selectionRect: CGRect?
    private var scrollbackOffset: UInt64 = 0
    private var lastReportedError: String?
    private var status: ClairV2GhosttyStatus

    public init(
      session: ClairV2LocalShellSession? = nil,
      font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    ) {
      if let session {
        self.session = session
      } else if let started = try? ClairV2LocalShellSession() {
        self.session = started
      } else {
        // The home directory always exists for a running process, so this
        // fallback practically never throws; if it somehow does, failing to
        // build a Ghostty surface at all is the correct outcome.
        self.session = try! ClairV2LocalShellSession(
          spec: .loginShell(workingDirectoryURL: URL(fileURLWithPath: "/private/tmp")))
      }
      self.font = font
      self.metrics = ClairV2GhosttyCellMetrics.measuring(font: font, contentScale: 1)
      self.status = ClairV2GhosttyStatus(isVendored: false, activationError: nil)
      super.init(frame: .zero)
      wantsLayer = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
      fatalError("ClairV2GhosttySurfaceView does not support coder-based restoration")
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }

    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else { return }
      status = ClairV2GhosttyStatus.current()
      if !session.isRunning {
        do { try session.start() } catch {
          lastReportedError = String(describing: error)
        }
      }
      recomputeMetrics()
      window?.makeFirstResponder(self)
    }

    public override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      recomputeMetrics()
    }

    public override func layout() {
      super.layout()
      recomputeMetrics()
    }

    /// Font/DPI: derives cell geometry from the current font and the
    /// window's `backingScaleFactor`, then converts the view's point-space
    /// bounds into a terminal size. Window resize: applies that size to the
    /// real PTY via `resizeTerminal`, so a live shell (for example `stty
    /// size`) observes the new geometry, not just the drawn view.
    private func recomputeMetrics() {
      let scale = Double(window?.backingScaleFactor ?? 1)
      metrics = ClairV2GhosttyCellMetrics.measuring(font: font, contentScale: scale)
      guard let size = try? ClairV2GhosttySurfaceGeometry.terminalSize(
        forViewSize: bounds.size, metrics: metrics)
      else { return }
      guard size != session.terminalSize else { return }
      do { try session.resizeTerminal(size) } catch {
        lastReportedError = String(describing: error)
      }
      needsDisplay = true
    }

    public func setFont(_ newFont: NSFont) {
      font = newFont
      recomputeMetrics()
    }

    // MARK: - Keyboard input

    public override func keyDown(with event: NSEvent) {
      guard let bytes = Self.encode(event) else {
        super.keyDown(with: event)
        return
      }
      do { try session.write(bytes) } catch {
        lastReportedError = String(describing: error)
      }
    }

    /// Translates a key event into the bytes an interactive shell expects on
    /// its input stream. This is ordinary terminal keyboard encoding (every
    /// terminal client, Ghostty included, turns keystrokes into bytes before
    /// they ever reach the PTY) — it does not interpret or render any
    /// output, so it is not the forbidden "non-Ghostty terminal engine"
    /// rendering path.
    nonisolated static func encode(_ event: NSEvent) -> Data? {
      switch event.specialKey {
      case .some(.enter), .some(.newline), .some(.carriageReturn): return Data([0x0d])
      case .some(.delete): return Data([0x7f])
      case .some(.tab): return Data([0x09])
      case .some(.upArrow): return Data("\u{1b}[A".utf8)
      case .some(.downArrow): return Data("\u{1b}[B".utf8)
      case .some(.rightArrow): return Data("\u{1b}[C".utf8)
      case .some(.leftArrow): return Data("\u{1b}[D".utf8)
      default:
        if event.modifierFlags.contains(.control), let characters = event.charactersIgnoringModifiers,
          let scalar = characters.unicodeScalars.first, scalar.isASCII
        {
          let value = scalar.value & 0x1f
          return Data([UInt8(value)])
        }
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        return Data(characters.utf8)
      }
    }

    // MARK: - Selection

    public override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      selectionRect = CGRect(origin: point, size: .zero)
      needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
      guard let start = selectionRect?.origin else { return }
      let point = convert(event.locationInWindow, from: nil)
      selectionRect = CGRect(
        x: min(start.x, point.x), y: min(start.y, point.y),
        width: abs(point.x - start.x), height: abs(point.y - start.y))
      needsDisplay = true
    }

    public var hasSelection: Bool {
      guard let selectionRect else { return false }
      return selectionRect.width > 1 || selectionRect.height > 1
    }

    public func clearSelection() {
      selectionRect = nil
      needsDisplay = true
    }

    // MARK: - Copy / paste

    /// Copies the current on-screen selection. Selecting *rendered* text
    /// requires the grid a real Ghostty surface maintains (line wraps,
    /// cursor position, scrollback reflow) — exactly the state this view
    /// does not have without the vendored library's surface API. Rather
    /// than guess at the underlying bytes (which would be wrong for
    /// wrapped/scrolled content) this fails closed with the same typed
    /// `GhosttyError.runtimeUnavailable` contract `GhosttyRuntime` already
    /// uses, so callers get one consistent "not available yet" signal.
    @objc public func copy(_ sender: Any?) {
      guard hasSelection else { return }
      lastReportedError = String(describing: GhosttyError.runtimeUnavailable)
    }

    /// Pasting into the shell needs none of the rendering state copy needs:
    /// it is a real write of the system pasteboard's text into the real PTY,
    /// so it works today regardless of Ghostty vendoring.
    @objc public func paste(_ sender: Any?) {
      pasteFromPasteboard(.general)
    }

    /// Testable seam for `paste(_:)`: writes `pasteboard`'s string content
    /// into the real shell, independent of the system-wide general
    /// pasteboard.
    public func pasteFromPasteboard(_ pasteboard: NSPasteboard) {
      guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
      do { try session.write(Data(text.utf8)) } catch {
        lastReportedError = String(describing: error)
      }
    }

    // MARK: - Scrollback

    /// Moves the read cursor over the bounded terminal journal — the same
    /// byte-accurate scrollback store `T02`'s daemon-owned sessions use — by
    /// a wheel delta. This proves the scrollback data path (bounded history,
    /// retrievable by cursor) independently of glyph rendering; a vendored
    /// Ghostty surface reads from the same journal to paint history once it
    /// exists.
    public override func scrollWheel(with event: NSEvent) {
      let snapshot = session.terminalJournal.snapshot()
      let delta = Int64(event.scrollingDeltaY.rounded())
      let proposed = Int64(scrollbackOffset) - delta
      let clamped = max(Int64(snapshot.retainedStart), min(Int64(snapshot.endOffset), proposed))
      scrollbackOffset = UInt64(max(0, clamped))
      needsDisplay = true
    }

    public var currentScrollbackOffset: UInt64 { scrollbackOffset }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
      NSColor.black.setFill()
      dirtyRect.fill()
      let snapshot = session.terminalJournal.snapshot()
      let lines = [
        "Clair v2 macOS Ghostty surface (T03)",
        status.summary,
        "shell pid=\(session.processID) running=\(session.isRunning)",
        "size=\(session.terminalSize.rows)x\(session.terminalSize.columns) "
          + "cell=\(Int(metrics.cellWidth))x\(Int(metrics.cellHeight)) "
          + "scale=\(metrics.contentScale)",
        "scrollback offset=\(scrollbackOffset) retainedStart=\(snapshot.retainedStart) "
          + "end=\(snapshot.endOffset)",
        lastReportedError.map { "last surface error: \($0)" } ?? "",
      ]
      var origin = CGPoint(x: 8, y: 8)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.green,
      ]
      for line in lines where !line.isEmpty {
        NSString(string: line).draw(at: origin, withAttributes: attributes)
        origin.y += metrics.cellHeight
      }
      if let selectionRect {
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.3).setFill()
        selectionRect.fill()
      }
    }
  }

  /// SwiftUI host for `ClairV2GhosttySurfaceView`.
  public struct ClairV2GhosttySurface: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> ClairV2GhosttySurfaceView {
      ClairV2GhosttySurfaceView()
    }

    public func updateNSView(_ nsView: ClairV2GhosttySurfaceView, context: Context) {}
  }
#endif
