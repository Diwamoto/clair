import ClairDaemonKit
import ClairGhostty
import ClairTerminal
import Foundation

#if os(macOS)
  import AppKit
  import SwiftUI

  /// The macOS Ghostty surface (T03): a real `NSView` backed, when
  /// libghostty is vendored (`scripts/ghostty.sh vendor`), by a real
  /// `ghostty_app_t`/`ghostty_surface_t` retained for this view's entire
  /// lifetime (not just one run-loop turn — see `GhosttyAppHandle
  /// .retainSurface`, added by this task specifically because
  /// `withApp`/`withSurface`'s closure scope cannot span a view's
  /// keystrokes-and-resizes-over-time lifetime). That real surface spawns
  /// and owns its own child shell process — it does not use this view's
  /// `ClairLocalShellSession`, which stays only as the pre-vendor/
  /// pre-window fallback local shell (see `ClairGhosttyABI`'s header
  /// comment: libghostty owns the PTY for surfaces it creates, there is no
  /// entry point to feed it externally-produced bytes).
  ///
  /// Keyboard, mouse, selection/copy, paste, scrollback, and font/DPI
  /// resize are all forwarded to the real surface via the `ghostty_surface_
  /// key/text/mouse_*/set_focus/set_content_scale/has_selection/
  /// read_selection` subset this task pinned (`clair_ghostty_abi.h`).
  /// Glyph rendering itself is never implemented here: libghostty attaches
  /// its own Metal-backed layer directly to the `NSView` pointer handed to
  /// `ghostty_surface_new` (confirmed by reading the vendored macOS app's
  /// source — no `CAMetalLayer`/`makeBackingLayer` glue exists on the Swift
  /// side at all), so this view's own `draw(_:)` — the pre-vendor status
  /// placeholder — steps aside entirely once a real surface is live.
  public final class ClairGhosttySurfaceView: NSView {
    /// T09: nil in the product. The GUI never owns a PTY; the daemon does, and the real
    /// surface runs `clair attach`. Only tests and the pre-vendor placeholder inject one.
    public let session: ClairLocalShellSession?
    private var font: NSFont
    private var metrics: ClairGhosttyCellMetrics
    private var selectionRect: CGRect?
    private var scrollbackOffset: UInt64 = 0
    private var lastReportedError: String?
    private var status: ClairGhosttyStatus
    private var ghosttyApp: GhosttyAppHandle?
    private var ghosttySurface: GhosttySurfaceHandle?
    private var pollTimer: Timer?
    private var pollSequence: UInt = 0
    private var markedText = ""
    private var markedSelection = NSRange(location: 0, length: 0)
    private var interpretingKey = false
    private var committedText: String?

    private let launch: (command: String, cwd: String)?

    public init(
      session: ClairLocalShellSession? = nil,
      launch: (command: String, cwd: String)? = nil,
      font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    ) {
      self.session = session
      self.launch = launch
      self.font = font
      self.metrics = ClairGhosttyCellMetrics.measuring(font: font, contentScale: 1)
      self.status = ClairGhosttyStatus(isVendored: false, activationError: nil)
      super.init(frame: .zero)
      wantsLayer = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
      fatalError("ClairGhosttySurfaceView does not support coder-based restoration")
    }

    /// Safety net for `teardownGhosttySurface()`: that method only runs
    /// from `viewDidMoveToWindow()` when `window` becomes `nil`, but
    /// AppKit does not guarantee a subview always gets that call before
    /// deallocating — a window can be closed without its subviews being
    /// explicitly `removeFromSuperview()`-ed first. Without this, a real
    /// spawned shell process and a 30Hz repeating `Timer` would outlive
    /// every reference to this view. `isolated deinit`: this class is
    /// implicitly `@MainActor` (it stores `@MainActor` `GhosttyAppHandle`/
    /// `GhosttySurfaceHandle` properties), and a plain `deinit` runs
    /// `nonisolated` regardless, so it cannot touch main-actor-isolated
    /// state directly — `Timer` also is not `Sendable`, so even handing
    /// the properties off to a detached `Task` from a nonisolated deinit
    /// does not type-check. `isolated deinit` instead runs the body itself
    /// on the main actor (hopping there first if deinitialization is
    /// triggered off-actor), so this can call `teardownGhosttySurface()`
    /// exactly as any other main-actor method on this view would.
    isolated deinit {
      teardownGhosttySurface()
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }

    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else {
        teardownGhosttySurface()
        return
      }
      status = ClairGhosttyStatus.current()
      if ghosttySurface == nil, status.isVendored, status.activationError == nil {
        createGhosttySurface()
      }
      // Only start the local-shell fallback PTY when no real surface took
      // over — a real surface spawns and owns its own child process, so
      // starting this one too would leave two live shells for one view.
      if ghosttySurface == nil, let session, !session.isRunning {
        do { try session.start() } catch {
          lastReportedError = String(describing: error)
        }
      }
      recomputeMetrics()
      startPollTimerIfNeeded()
      // Only the store's focused pane takes the keyboard; every surface grabbing it on mount
      // left the last-mounted pane typing while another one looked active.
      if wantsFocus { window?.makeFirstResponder(self) }
    }

    /// U06: the store's focused pane is the one source of truth. A click lands on this NSView
    /// (SwiftUI's tap gesture never sees it), so report it; a store focus change moves the keyboard here.
    public var onFocus: (() -> Void)?
    public var wantsFocus = false {
      didSet {
        guard wantsFocus, !oldValue, let window, window.firstResponder !== self else { return }
        DispatchQueue.main.async { [weak self] in
          guard let self, self.wantsFocus else { return }
          self.window?.makeFirstResponder(self)
        }
      }
    }

    public override func becomeFirstResponder() -> Bool {
      let ok = super.becomeFirstResponder()
      if ok { onFocus?() }
      return ok
    }

    public override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      recomputeMetrics()
    }

    public override func layout() {
      super.layout()
      recomputeMetrics()
    }

    /// Font/DPI + window resize. With a real surface, this is
    /// `ghostty_surface_set_content_scale` + `ghostty_surface_set_size` in
    /// real backing pixels (matching the vendored macOS app's own
    /// `convertToBacking`-based sizing) — libghostty re-renders and resizes
    /// its own child process's PTY from those two calls. Without one (not
    /// vendored, or before a window exists), this keeps the pre-T03
    /// fallback: derive a terminal size from font metrics and resize
    /// `session`'s real PTY directly.
    private func recomputeMetrics() {
      let scale = Double(window?.backingScaleFactor ?? 1)
      metrics = ClairGhosttyCellMetrics.measuring(font: font, contentScale: scale)
      if let ghosttySurface {
        let pixelSize = convertToBacking(bounds.size)
        do {
          try ghosttySurface.setContentScale(x: scale, y: scale)
          try ghosttySurface.setSize(
            widthPixels: max(1, Int(pixelSize.width)), heightPixels: max(1, Int(pixelSize.height)))
        } catch {
          lastReportedError = String(describing: error)
        }
        needsDisplay = true
        return
      }
      guard
        let size = try? ClairGhosttySurfaceGeometry.terminalSize(
          forViewSize: bounds.size, metrics: metrics)
      else { return }
      guard let session, size != session.terminalSize else { return }
      do { try session.resizeTerminal(size) } catch {
        lastReportedError = String(describing: error)
      }
      needsDisplay = true
    }

    public func setFont(_ newFont: NSFont) {
      font = newFont
      recomputeMetrics()
    }

    // MARK: - Real surface lifecycle

    /// Allocates a retained `ghostty_app_t` + `ghostty_surface_t` for this
    /// view's own lifetime, backed by this `NSView`'s raw pointer. On any
    /// failure, tears back down to the fallback (no-real-surface) state
    /// rather than leaving a half-created app/surface pair.
    private func createGhosttySurface() {
      // Tracked in a local, not read from `self.ghosttyApp`, so the catch
      // block below closes whatever `retainApp()` actually allocated even
      // when the *next* step (`retainSurface`) is what throws — at that
      // point `self.ghosttyApp` is still nil (only assigned after both
      // steps succeed), so closing it there would silently leak the real
      // `ghostty_app_t` this local variable is the only remaining
      // reference to.
      var app: GhosttyAppHandle?
      do {
        let newApp = try GhosttyRuntime.shared.retainApp { config in
          if let theme = Self.themePath { try config.loadFileAndFinalize(theme) }
        }
        app = newApp
        let config = GhosttySurfaceConfig(
          platform: .macOS(Unmanaged.passUnretained(self).toOpaque()),
          scaleFactor: Double(window?.backingScaleFactor ?? 1),
          fontSize: Double(font.pointSize),
          workingDirectory: launch?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
          command: launch?.command,
          waitAfterCommand: launch != nil  // keep the pane so the exit code stays readable
        )
        let surface = try newApp.retainSurface(config)
        ghosttyApp = newApp
        ghosttySurface = surface
      } catch {
        lastReportedError = String(describing: error)
        app?.close()
        ghosttyApp = nil
        ghosttySurface = nil
      }
    }

    /// U06: the mock's terminal is the editor's One Dark on the pane surface (`tokens.ts`: canvas, code,
    /// codeString/Type/Func/Keyword, danger, textPrimary), not Ghostty's xterm defaults whose dark
    /// blue/black vanish on #282c34. `minimum-contrast` keeps any app-chosen colour readable.
    static let theme = """
      background = #282c34
      foreground = #abb2bf
      cursor-color = #abb2bf
      selection-background = #383d47
      minimum-contrast = 3
      window-padding-x = 8
      palette = 0=#3f4451
      palette = 1=#e27b83
      palette = 2=#98c379
      palette = 3=#e5c07b
      palette = 4=#61afef
      palette = 5=#c678dd
      palette = 6=#56b6c2
      palette = 7=#abb2bf
      palette = 8=#5c6370
      palette = 9=#e27b83
      palette = 10=#98c379
      palette = 11=#e5c07b
      palette = 12=#61afef
      palette = 13=#c678dd
      palette = 14=#56b6c2
      palette = 15=#f1f2f6

      """

    /// libghostty reads config from a file only; written once per process. nil (defaults) if the write fails.
    static let themePath: String? = {
      let url = FileManager.default.temporaryDirectory.appending(path: "clair-ghostty-theme-\(getpid())")
      return (try? Data(theme.utf8).write(to: url, options: .atomic)) != nil ? url.path : nil
    }()

    private func teardownGhosttySurface() {
      markedText = ""
      committedText = nil
      pollTimer?.invalidate()
      pollTimer = nil
      ghosttySurface?.close()
      ghosttySurface = nil
      ghosttyFocused = nil
      ghosttyApp?.close()
      ghosttyApp = nil
    }

    /// libghostty's runtime callback table (`clair_ghostty_abi.c`) keeps
    /// `wakeup_cb` a fixed no-op (T08's documented scope boundary — see
    /// that file's header comment), so nothing calls back into Clair when
    /// the spawned child process produces output. `app.tick()` has to be
    /// driven by polling instead; `T08`'s own smoke test already
    /// established this exact pattern (poll `tick()` in a loop until
    /// expected output appears) rather than wiring the callback through.
    // ponytail: adaptive polling, not event-driven wakeup. Wire
    // `wakeup_cb` through to a real Swift callback (extending
    // `clair_ghostty_abi.c`'s runtime table, matching T08's own "future
    // task extends this table" invariant) if idle CPU use from this timer
    // ever matters.
    private func startPollTimerIfNeeded() {
      guard ghosttySurface != nil, pollTimer == nil else { return }
      let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
        [weak self] _ in
        // The timer is installed on the main run loop; avoid allocating an unstructured
        // Task 30 times/second for every terminal pane.
        MainActor.assumeIsolated { self?.pollGhosttySurfaceIfNeeded() }
      }
      RunLoop.main.add(timer, forMode: .common)
      pollTimer = timer
    }

    /// V08: facts only — bells since the last poll and, once, the child's exit code.
    public var onFacts: ((_ bells: Int, _ exitCode: Int?) -> Void)?
    private var exitReported = false
    private var ghosttyFocused: Bool?

    private func pollGhosttySurfaceIfNeeded() {
      pollSequence &+= 1
      let visible = !isHidden && window?.occlusionState.contains(.visible) == true
      let focused = visible && window?.firstResponder === self
      // Only the key window's first responder is focused to Ghostty, so every
      // other pane gets a steady unfocused caret instead of a blinking one.
      // Synced from the poll (≤33 ms after focus moves) rather than from
      // responder/key-window overrides, which would need four hooks.
      let ghosttyFocus = focused && window?.isKeyWindow == true
      if ghosttyFocus != ghosttyFocused, let ghosttySurface {
        ghosttyFocused = ghosttyFocus
        try? ghosttySurface.setFocus(ghosttyFocus)
      }
      // Focused terminal: 30 Hz (33 ms). Background visible panes: 10 Hz (100 ms).
      // Hidden/minimized windows still collect bells/exits, but only at 1 Hz.
      let divisor: UInt = focused ? 1 : visible ? 3 : 30
      guard pollSequence.isMultiple(of: divisor) else { return }
      pollGhosttySurface(redraw: visible)
    }

    private func pollGhosttySurface(redraw: Bool = true) {
      guard let ghosttyApp else { return }
      do { try ghosttyApp.tick() } catch {
        lastReportedError = String(describing: error)
      }
      let e = ghosttyApp.takeEvents()
      let exit = exitReported ? nil : e.exitCode
      if exit != nil { exitReported = true }
      if e.bells > 0 || exit != nil { onFacts?(e.bells, exit) }
      if redraw { needsDisplay = true }
    }

    // MARK: - Keyboard input

    public override func keyDown(with event: NSEvent) {
      if let ghosttySurface {
        let action: GhosttyKeyAction = event.isARepeat ? .repeatKey : .press
        // AppKit's input method owns printable keys while composing. Keep its
        // provisional text on the surface and send only the committed result.
        let wasComposing = hasMarkedText()
        committedText = nil
        interpretingKey = true
        interpretKeyEvents([event])
        interpretingKey = false
        do {
          if let text = committedText, !text.isEmpty {
            var key = Self.ghosttyKeyEvent(event, action: action)
            if wasComposing {
              key = GhosttyKeyEvent(
                action: action, mods: [], consumedMods: [], keyCode: 0,
                text: text, unshiftedCodepoint: 0)
            } else {
              key = GhosttyKeyEvent(
                action: action, mods: key.mods, consumedMods: key.consumedMods,
                keyCode: key.keyCode, text: text, unshiftedCodepoint: key.unshiftedCodepoint)
            }
            try ghosttySurface.sendKey(key)
          } else if !wasComposing && !hasMarkedText() {
            try ghosttySurface.sendKey(Self.ghosttyKeyEvent(event, action: action))
          }
        } catch {
          lastReportedError = String(describing: error)
        }
        committedText = nil
        return
      }
      guard let bytes = Self.encode(event) else {
        super.keyDown(with: event)
        return
      }
      do { try session?.write(bytes) } catch {
        lastReportedError = String(describing: error)
      }
    }

    public override func keyUp(with event: NSEvent) {
      guard let ghosttySurface, !hasMarkedText() else { return }
      do { try ghosttySurface.sendKey(Self.ghosttyKeyEvent(event, action: .release)) } catch {
        lastReportedError = String(describing: error)
      }
    }

    public override func doCommand(by selector: Selector) {
      // keyDown forwards non-text keys after the input method has had a chance to handle them.
    }

    /// Builds a real key event for `ghostty_surface_key`. `keyCode` is the
    /// raw macOS virtual keycode — libghostty translates it internally
    /// (confirmed by reading the vendored `NSEvent+Extension.swift`), so
    /// this never needs `ghostty_input_key_e`'s large enum. `text` mirrors
    /// upstream's `ghosttyCharacters`: control characters are re-derived
    /// without the control modifier (libghostty encodes the control
    /// sequence itself from `mods`) and PUA-range function-key characters
    /// are dropped (letting `keyCode` alone drive them).
    nonisolated static func ghosttyKeyEvent(_ event: NSEvent, action: GhosttyKeyAction)
      -> GhosttyKeyEvent
    {
      let mods = ghosttyMods(event.modifierFlags)
      let consumedMods = ghosttyMods(event.modifierFlags.subtracting([.control, .command]))
      var unshiftedCodepoint: UInt32 = 0
      if event.type == .keyDown || event.type == .keyUp,
        let chars = event.characters(byApplyingModifiers: []),
        let scalar = chars.unicodeScalars.first
      {
        unshiftedCodepoint = scalar.value
      }
      return GhosttyKeyEvent(
        action: action, mods: mods, consumedMods: consumedMods, keyCode: UInt32(event.keyCode),
        text: ghosttyCharacters(event).flatMap(keyEventText), unshiftedCodepoint: unshiftedCodepoint)
    }

    /// Upstream `String.keyEventText`: control-character text (e.g. Shift+Tab's U+0019) must not
    /// reach libghostty, or it is written raw instead of encoded from `keyCode`/`mods` (`ESC [ Z`).
    nonisolated static func keyEventText(_ text: String) -> String? {
      guard let first = text.unicodeScalars.first, first.value >= 0x20, first.value != 0x7F else { return nil }
      return text
    }

    nonisolated private static func ghosttyCharacters(_ event: NSEvent) -> String? {
      guard let characters = event.characters else { return nil }
      if characters.count == 1, let scalar = characters.unicodeScalars.first {
        if scalar.value < 0x20 {
          return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
        }
        if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
      }
      return characters
    }

    nonisolated private static func ghosttyMods(_ flags: NSEvent.ModifierFlags)
      -> GhosttyKeyModifiers
    {
      var mods: GhosttyKeyModifiers = []
      if flags.contains(.shift) { mods.insert(.shift) }
      if flags.contains(.control) { mods.insert(.control) }
      if flags.contains(.option) { mods.insert(.option) }
      if flags.contains(.command) { mods.insert(.command) }
      if flags.contains(.capsLock) { mods.insert(.capsLock) }
      return mods
    }

    /// Translates a key event into the bytes an interactive shell expects
    /// on its input stream. Only used by the fallback (no real surface)
    /// path — this is ordinary terminal keyboard encoding, not the
    /// forbidden "non-Ghostty terminal engine" rendering path.
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

    // MARK: - Mouse / selection

    public override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      guard let ghosttySurface else {
        selectionRect = CGRect(origin: point, size: .zero)
        needsDisplay = true
        return
      }
      let mods = Self.ghosttyMods(event.modifierFlags)
      do {
        try ghosttySurface.sendMousePosition(x: Double(point.x), y: Double(point.y), mods: mods)
        try ghosttySurface.sendMouseButton(.press, button: .left, mods: mods)
      } catch {
        lastReportedError = String(describing: error)
      }
    }

    public override func mouseUp(with event: NSEvent) {
      guard let ghosttySurface else { return }
      do {
        try ghosttySurface.sendMouseButton(.release, button: .left, mods: Self.ghosttyMods(event.modifierFlags))
      } catch {
        lastReportedError = String(describing: error)
      }
    }

    public override func mouseDragged(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      guard let ghosttySurface else {
        guard let start = selectionRect?.origin else { return }
        selectionRect = CGRect(
          x: min(start.x, point.x), y: min(start.y, point.y),
          width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
        return
      }
      do {
        try ghosttySurface.sendMousePosition(
          x: Double(point.x), y: Double(point.y), mods: Self.ghosttyMods(event.modifierFlags))
      } catch {
        lastReportedError = String(describing: error)
      }
    }

    public override func rightMouseDown(with event: NSEvent) {
      guard let ghosttySurface else {
        super.rightMouseDown(with: event)
        return
      }
      do {
        _ = try ghosttySurface.sendMouseButton(
          .press, button: .right, mods: Self.ghosttyMods(event.modifierFlags))
      } catch {
        lastReportedError = String(describing: error)
      }
    }

    public override func rightMouseUp(with event: NSEvent) {
      guard let ghosttySurface else {
        super.rightMouseUp(with: event)
        return
      }
      do {
        _ = try ghosttySurface.sendMouseButton(
          .release, button: .right, mods: Self.ghosttyMods(event.modifierFlags))
      } catch {
        lastReportedError = String(describing: error)
      }
    }

    /// `true` when there is real, grid-aware selected text (`ghostty_surface_
    /// has_selection`) or, without a real surface, the pre-vendor rectangle
    /// placeholder has non-trivial extent.
    public var hasSelection: Bool {
      if let ghosttySurface {
        return (try? ghosttySurface.hasSelection()) ?? false
      }
      guard let selectionRect else { return false }
      return selectionRect.width > 1 || selectionRect.height > 1
    }

    public func clearSelection() {
      selectionRect = nil
      needsDisplay = true
    }

    // MARK: - Copy / paste

    /// Copies the current selection. With a real surface, this reads the
    /// actual grid-aware selected text (`ghostty_surface_has_selection` +
    /// `_read_selection` — respecting line wraps/scrollback, unlike a
    /// screen-point rectangle guess) and writes it to the real system
    /// pasteboard directly; it does not go through libghostty's
    /// `"copy_to_clipboard"` binding action, since that depends on the
    /// clipboard write callback `clair_ghostty_abi.c` deliberately keeps
    /// fixed at "silently dropped" (T08's documented scope boundary).
    /// Without a real surface (not vendored, or no window yet), this keeps
    /// the pre-T03 fail-closed contract: no rendering grid exists to copy
    /// from, so nothing is guessed.
    @objc public func copy(_ sender: Any?) {
      if let ghosttySurface {
        guard (try? ghosttySurface.hasSelection()) == true,
          let text = try? ghosttySurface.readSelection(), !text.isEmpty
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return
      }
      guard hasSelection else { return }
      lastReportedError = String(describing: GhosttyError.runtimeUnavailable)
    }

    @objc public func paste(_ sender: Any?) {
      pasteFromPasteboard(.general)
    }

    /// Testable seam for `paste(_:)`. With a real surface, feeds the
    /// pasteboard's text straight into the terminal via `ghostty_surface_
    /// text` — the same entry point libghostty uses for committed IME
    /// text — which, like `copy`, never touches the stubbed-out clipboard
    /// read callback. Without a real surface, writes directly into the
    /// fallback `session`'s real PTY, exactly as before T03.
    public func pasteFromPasteboard(_ pasteboard: NSPasteboard) {
      guard let text = pasteboard.string(forType: .string) else { return }
      sendText(text)
    }

    /// Terminal surfaces by pane id, so the shell can type into an agent pane (no Return — the user confirms).
    /// ponytail: pane ids are per-Project; only the visible Project's tree is mounted, so a flat map is enough.
    nonisolated(unsafe) private static var byPane: [Int: Weak] = [:]
    private struct Weak { weak var view: ClairGhosttySurfaceView? }
    static func register(_ v: ClairGhosttySurfaceView, pane: Int) { byPane[pane] = Weak(view: v) }
    @discardableResult public static func send(_ text: String, toPane pane: Int) -> Bool {
      guard let v = byPane[pane]?.view else { return false }
      v.sendText(text); return true
    }

    /// What the pane shows right now, for the header drag preview. libghostty draws into its own Metal
    /// layer, which `cacheDisplay` can't read, so this grabs the composited pixels of our own window.
    // ponytail: CGWindowListCreateImage is deprecated (macOS 14); move to ScreenCaptureKit when it is removed.
    public static func snapshot(pane: Int) -> NSImage? {
      guard let v = byPane[pane]?.view, let window = v.window, let screenH = NSScreen.screens.first?.frame.height else { return nil }
      let r = window.convertToScreen(v.convert(v.bounds, to: nil))
      let cg = CGRect(x: r.minX, y: screenH - r.maxY, width: r.width, height: r.height)
      guard let image = CGWindowListCreateImage(cg, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
      else { return nil }
      return NSImage(cgImage: image, size: r.size)
    }

    func sendText(_ text: String) {
      guard !text.isEmpty else { return }
      if let ghosttySurface {
        do { try ghosttySurface.sendText(text) } catch {
          lastReportedError = String(describing: error)
        }
        return
      }
      do { try session?.write(Data(text.utf8)) } catch {
        lastReportedError = String(describing: error)
      }
    }

    // MARK: - Scrollback

    /// With a real surface, forwards the wheel event to `ghostty_surface_
    /// mouse_scroll` and lets libghostty manage its own scrollback/pan
    /// state — the same real scrollback store a real rendered screen reads
    /// from. Without one, keeps the pre-T03 placeholder: moving a read
    /// cursor over the bounded terminal journal (`T02`'s same journal
    /// type), proving the scrollback data path independently of glyph
    /// rendering.
    public override func scrollWheel(with event: NSEvent) {
      guard let ghosttySurface else {
        guard let snapshot = session?.terminalJournal.snapshot() else { return }
        let delta = Int64(event.scrollingDeltaY.rounded())
        let proposed = Int64(scrollbackOffset) - delta
        let clamped = max(Int64(snapshot.retainedStart), min(Int64(snapshot.endOffset), proposed))
        scrollbackOffset = UInt64(max(0, clamped))
        needsDisplay = true
        return
      }
      let mods = GhosttyScrollModifiers(precise: event.hasPreciseScrollingDeltas)
      do {
        try ghosttySurface.sendMouseScroll(
          x: event.scrollingDeltaX, y: event.scrollingDeltaY, mods: mods)
      } catch {
        lastReportedError = String(describing: error)
      }
    }

    public var currentScrollbackOffset: UInt64 { scrollbackOffset }

    // MARK: - Drawing

    /// Steps aside entirely once a real surface is live: libghostty's own
    /// layer, attached directly to this `NSView`, owns the pixels then.
    /// This placeholder only ever draws in the pre-vendor / pre-window
    /// fallback state.
    public override func draw(_ dirtyRect: NSRect) {
      guard ghosttySurface == nil else { return }
      NSColor.black.setFill()
      dirtyRect.fill()
      var lines = ["Clair macOS Ghostty surface (T03)", status.summary]
      if let session {
        let snapshot = session.terminalJournal.snapshot()
        lines.append("shell pid=\(session.processID) running=\(session.isRunning)")
        lines.append("size=\(session.terminalSize.rows)x\(session.terminalSize.columns)")
        lines.append("scrollback offset=\(scrollbackOffset) retained=\(snapshot.retainedStart)")
      }
      lines.append(lastReportedError.map { "last surface error: \($0)" } ?? "")
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

  extension ClairGhosttySurfaceView: @preconcurrency NSTextInputClient {
    public func hasMarkedText() -> Bool { !markedText.isEmpty }

    public func markedRange() -> NSRange {
      guard hasMarkedText() else { return NSRange(location: NSNotFound, length: 0) }
      return NSRange(location: 0, length: (markedText as NSString).length)
    }

    public func selectedRange() -> NSRange {
      hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
      let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
      markedText = text
      let length = (text as NSString).length
      let start = min(max(0, selectedRange.location), length)
      markedSelection = NSRange(
        location: start,
        length: min(max(0, selectedRange.length), length - start))
      do { try ghosttySurface?.setPreedit(text) } catch {
        lastReportedError = String(describing: error)
      }
    }

    public func unmarkText() {
      markedText = ""
      markedSelection = NSRange(location: 0, length: 0)
      do { try ghosttySurface?.setPreedit(nil) } catch {
        lastReportedError = String(describing: error)
      }
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
      let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
      unmarkText()
      guard !text.isEmpty else { return }
      if interpretingKey {
        committedText = (committedText ?? "") + text
      } else {
        do {
          try ghosttySurface?.sendKey(
            GhosttyKeyEvent(action: .press, mods: [], keyCode: 0, text: text))
        } catch {
          lastReportedError = String(describing: error)
        }
      }
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(
      forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
      guard hasMarkedText() else { return nil }
      let length = (markedText as NSString).length
      guard range.location <= length else { return nil }
      let safe = NSRange(
        location: range.location, length: min(range.length, length - range.location))
      actualRange?.pointee = safe
      return NSAttributedString(string: (markedText as NSString).substring(with: safe))
    }

    public func characterIndex(for point: NSPoint) -> Int { selectedRange().location }

    public func firstRect(
      forCharacterRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSRect {
      actualRange?.pointee = range
      let point = try? ghosttySurface?.imePoint()
      let rect = NSRect(
        x: point?.minX ?? 0, y: point?.minY ?? 0,
        width: max(1, point?.width ?? 1),
        height: max(1, point?.height ?? CGFloat(metrics.cellHeight)))
      let windowRect = convert(rect, to: nil)
      return window?.convertToScreen(windowRect) ?? windowRect
    }
  }

  /// SwiftUI host for `ClairGhosttySurfaceView`.
  public struct ClairGhosttySurface: NSViewRepresentable {
    let launch: (command: String, cwd: String)?
    let onFacts: ((Int, Int?) -> Void)?
    let pane: Int?
    /// `sessionKey` names the daemon-owned shell this surface attaches to (same key = same session).
    let sessionKey: String
    let focused: Bool
    let onFocus: (() -> Void)?
    public init(
      launch: (command: String, cwd: String)? = nil, pane: Int? = nil, sessionKey: String, focused: Bool = false,
      onFocus: (() -> Void)? = nil, onFacts: ((Int, Int?) -> Void)? = nil
    ) {
      self.launch = launch; self.pane = pane; self.sessionKey = sessionKey; self.onFacts = onFacts
      self.focused = focused; self.onFocus = onFocus
    }

    public func makeNSView(context: Context) -> ClairGhosttySurfaceView {
      // The real surface's child is `clair attach`; the shell itself lives in the daemon.
      let cwd = launch?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
      let attach = ClairDaemonLauncher.attachCommand(
        key: sessionKey, cwd: cwd, command: launch.map(\.command).flatMap { $0.isEmpty ? nil : $0 })
      let v = ClairGhosttySurfaceView(launch: (attach, cwd))
      v.onFacts = onFacts
      v.onFocus = onFocus
      v.wantsFocus = focused
      if let pane { ClairGhosttySurfaceView.register(v, pane: pane) }
      return v
    }

    public func updateNSView(_ nsView: ClairGhosttySurfaceView, context: Context) {
      nsView.onFacts = onFacts
      nsView.onFocus = onFocus
      nsView.wantsFocus = focused
    }
  }
#endif
