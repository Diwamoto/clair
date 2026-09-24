#if CLAIR_GHOSTTY_VENDORED
  import ClairGhosttyABI
#endif
import CoreGraphics
import Foundation

/// Which platform view backs a `ghostty_surface_t`. Mirrors
/// `clair_ghostty_platform_e`'s two real variants; `ClairGhostty` itself
/// stays AppKit/UIKit-agnostic, so callers (for example `ClairAppKit`'s
/// macOS surface view) pass the already-created native view's raw pointer
/// rather than this module importing AppKit/UIKit itself.
// `@unchecked Sendable`: a raw view pointer is not inherently thread-safe,
// but `GhosttySurfacePlatform` is only ever constructed and consumed on
// the main actor (`GhosttyAppHandle.withSurface`, like the rest of this
// boundary, is `@MainActor`), matching this file's existing "no C handle
// escapes its owning scope/thread" invariant.
public enum GhosttySurfacePlatform: @unchecked Sendable {
  /// An `NSView*`, retained by the caller for at least the lifetime of the
  /// surface created from it.
  case macOS(UnsafeMutableRawPointer)
  /// A `UIView*`, retained by the caller for at least the lifetime of the
  /// surface created from it.
  case iOS(UnsafeMutableRawPointer)
}

/// Swift-facing configuration for `GhosttyAppHandle.withSurface`. Mirrors
/// the subset of `clair_ghostty_surface_config_s` this task's embedding
/// smoke test needs.
///
/// `command`/`initialInput`/`workingDirectory` configure the *real child
/// process libghostty itself spawns and owns* for this surface — see the
/// header comment on the `ghostty_surface_*` subset in
/// `clair_ghostty_abi.h` for why this, not writing bytes into an
/// externally-owned PTY, is what "feeding PTY output into a surface" means
/// at this API layer.
public struct GhosttySurfaceConfig: Sendable {
  public var platform: GhosttySurfacePlatform
  public var scaleFactor: Double
  public var fontSize: Double
  public var workingDirectory: String
  public var command: String?
  public var initialInput: String?
  public var waitAfterCommand: Bool

  public init(
    platform: GhosttySurfacePlatform,
    scaleFactor: Double = 1,
    fontSize: Double = 13,
    workingDirectory: String,
    command: String? = nil,
    initialInput: String? = nil,
    waitAfterCommand: Bool = false
  ) {
    self.platform = platform
    self.scaleFactor = scaleFactor
    self.fontSize = fontSize
    self.workingDirectory = workingDirectory
    self.command = command
    self.initialInput = initialInput
    self.waitAfterCommand = waitAfterCommand
  }
}

/// Mirrors `clair_ghostty_surface_size_s`: the rendered cell grid's
/// dimensions, in cells and in pixels.
public struct GhosttySurfaceSize: Sendable, Equatable {
  public let columns: Int
  public let rows: Int
  public let widthPixels: Int
  public let heightPixels: Int
  public let cellWidthPixels: Int
  public let cellHeightPixels: Int
}

/// Which region of the surface's screen model to read back with
/// `GhosttySurfaceHandle.readText`. `.cursor` addresses text relative to
/// the cursor (`CLAIR_GHOSTTY_POINT_ACTIVE`) — the closest verifiable
/// equivalent this internal embedder ABI exposes to a direct "read cursor
/// row/column" call; `.screen` reads the entire visible screen.
public enum GhosttySurfaceSelection: Sendable {
  case screen
  case cursor
}

/// Mirrors `clair_ghostty_input_action_e`.
public enum GhosttyKeyAction: Sendable {
  case press
  case release
  case repeatKey
}

/// Mirrors `clair_ghostty_input_mods_e`'s bits this task's keyboard path
/// needs. `GhosttyKeyEvent.mods`/`.consumedMods` matches the real macOS app's
/// `Ghostty.ghosttyMods(_:)`/`eventModifierFlags(mods:)` bit layout — see
/// `NSEvent+Extension.swift` and `Ghostty.Input.swift` in the vendored
/// source. Right-side variants (`.shiftRight` etc.) are omitted: nothing in
/// this task's keyboard path (plain `NSEvent.modifierFlags`, no per-side
/// dead-key handling) can distinguish them, matching `ClairGhosttySurfaceView`'s
/// pre-T03 keyboard encoding, which never distinguished sides either.
public struct GhosttyKeyModifiers: OptionSet, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let shift = GhosttyKeyModifiers(rawValue: 1 << 0)
  public static let control = GhosttyKeyModifiers(rawValue: 1 << 1)
  public static let option = GhosttyKeyModifiers(rawValue: 1 << 2)
  public static let command = GhosttyKeyModifiers(rawValue: 1 << 3)
  public static let capsLock = GhosttyKeyModifiers(rawValue: 1 << 4)
}

/// Mirrors `clair_ghostty_input_key_s`. `keyCode` is the raw macOS virtual
/// keycode (`NSEvent.keyCode`) — libghostty translates it internally, so
/// `ClairAppKit` never needs `ghostty_input_key_e`'s large enum mirrored
/// on this side of the boundary (confirmed by reading the vendored
/// `ghostty.h` and `NSEvent+Extension.swift`, not assumed).
public struct GhosttyKeyEvent: Sendable {
  public var action: GhosttyKeyAction
  public var mods: GhosttyKeyModifiers
  public var consumedMods: GhosttyKeyModifiers
  public var keyCode: UInt32
  public var text: String?
  public var unshiftedCodepoint: UInt32

  public init(
    action: GhosttyKeyAction, mods: GhosttyKeyModifiers, consumedMods: GhosttyKeyModifiers = [],
    keyCode: UInt32, text: String? = nil, unshiftedCodepoint: UInt32 = 0
  ) {
    self.action = action
    self.mods = mods
    self.consumedMods = consumedMods
    self.keyCode = keyCode
    self.text = text
    self.unshiftedCodepoint = unshiftedCodepoint
  }
}

/// Mirrors `clair_ghostty_mouse_state_e`.
public enum GhosttyMouseState: Sendable {
  case press
  case release
}

/// Mirrors the subset of `clair_ghostty_mouse_button_e` a trackpad/mouse
/// surface needs. Extended buttons (back/forward/four..eleven) are not
/// modeled — `ClairGhosttySurfaceView` only wires primary/secondary/middle
/// click today.
// ponytail: no extended-button mapping; add `.four`...`.eleven` cases and
// `NSEvent.buttonNumber` translation (see the vendored
// `Ghostty.Input.MouseButton.init(fromNSEventButtonNumber:)`) if/when a
// caller needs back/forward mouse buttons.
public enum GhosttyMouseButton: Sendable {
  case left
  case right
  case middle
  case unknown
}

/// Mirrors `clair_ghostty_scroll_mods_t`'s bit layout (bit 0 = precision;
/// momentum-phase bits are not modeled).
// ponytail: momentum phase (inertial scroll begin/changed/ended) not
// forwarded; every scroll reports `.none`. Add if a real trackpad's
// momentum-driven scrollback ever needs to distinguish it from a
// user-driven scroll.
public struct GhosttyScrollModifiers: Sendable {
  public var precise: Bool
  public init(precise: Bool = false) { self.precise = precise }
}

/// A scope-bound handle to a `ghostty_app_t`. Same ownership discipline as
/// `GhosttyConfigHandle`: only constructible inside
/// `GhosttyRuntime.withApp` (itself `@MainActor`), invalidated at scope
/// exit, never `Sendable`.
@MainActor
public final class GhosttyAppHandle {
  #if CLAIR_GHOSTTY_VENDORED
    private let raw: clair_ghostty_app_t
    init(raw: clair_ghostty_app_t) {
      self.raw = raw
    }
  #endif
  private var isValid = true

  func invalidate() {
    isValid = false
  }

  /// Frees the underlying `ghostty_app_t` and invalidates the handle.
  /// Idempotent: a second call is a no-op. Only meaningful for handles
  /// created via `GhosttyRuntime.retainApp` — handles from `withApp` are
  /// already freed by that method's own `defer` when its closure returns,
  /// and calling `close()` on one of those is harmless (it is already
  /// invalid, so this just no-ops).
  public func close() {
    guard isValid else { return }
    isValid = false
    #if CLAIR_GHOSTTY_VENDORED
      clair_ghostty_app_free(raw)
    #endif
  }

  /// Processes one iteration of libghostty's internal event loop. A real
  /// surface's spawned child process's output only reaches the screen
  /// model after this has been called at least once following that
  /// output; callers that need to observe freshly-produced output (as
  /// opposed to the state immediately after `withSurface` returns) must
  /// call this in a loop.
  public func tick() throws {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      clair_ghostty_app_tick(raw)
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  /// V08: facts seen since the last call — bell count (drained) and the child's exit code
  /// (nil until it exits, then sticky). Terminal bytes never cross this boundary.
  /// `title` is the new OSC 0/2 window title, nil when unchanged.
  public func takeEvents() -> (bells: Int, exitCode: Int?, title: String?, notification: (title: String, body: String)?) {
    #if CLAIR_GHOSTTY_VENDORED
      guard isValid else { return (0, nil, nil, nil) }
      var e = clair_ghostty_app_events_s()
      clair_ghostty_app_take_events(raw, &e)
      let title = e.title_changed ? withUnsafeBytes(of: e.title) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : nil
      let notification = e.notification_changed ? (
        title: withUnsafeBytes(of: e.notification_title) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) },
        body: withUnsafeBytes(of: e.notification_body) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      ) : nil
      return (Int(e.bells), e.exit_code < 0 ? nil : Int(e.exit_code), title, notification)
    #else
      return (0, nil, nil, nil)
    #endif
  }

  #if CLAIR_GHOSTTY_VENDORED
    /// Shared config-marshalling between `withSurface` and `retainSurface`:
    /// only the free-on-return-vs-caller-owns policy differs between them.
    private func newRawSurface(
      _ config: GhosttySurfaceConfig
    ) throws -> clair_ghostty_surface_t {
      var rawConfig = clair_ghostty_surface_config_new()
      switch config.platform {
      case .macOS(let nsview):
        rawConfig.platform_tag = CLAIR_GHOSTTY_PLATFORM_MACOS
        rawConfig.platform.macos = clair_ghostty_platform_macos_s(nsview: nsview)
      case .iOS(let uiview):
        rawConfig.platform_tag = CLAIR_GHOSTTY_PLATFORM_IOS
        rawConfig.platform.ios = clair_ghostty_platform_ios_s(uiview: uiview)
      }
      rawConfig.scale_factor = config.scaleFactor
      rawConfig.font_size = Float(config.fontSize)
      rawConfig.wait_after_command = config.waitAfterCommand
      rawConfig.context = CLAIR_GHOSTTY_SURFACE_CONTEXT_WINDOW

      return try config.workingDirectory.withCString { workingDirectoryPointer in
        try withOptionalCString(config.command) { commandPointer in
          try withOptionalCString(config.initialInput) { initialInputPointer in
            rawConfig.working_directory = workingDirectoryPointer
            rawConfig.command = commandPointer
            rawConfig.initial_input = initialInputPointer
            guard let surfaceRaw = clair_ghostty_surface_new(raw, &rawConfig) else {
              throw GhosttyError.initializationFailed("ghostty_surface_new returned NULL")
            }
            return surfaceRaw
          }
        }
      }
    }
  #endif

  /// Allocates a `ghostty_surface_t` for the duration of `body` and frees
  /// it exactly once when `body` returns or throws. `config.command` (if
  /// set) is spawned as a real child process by libghostty itself as part
  /// of surface creation; its real output reaches the surface's screen
  /// model as `tick()` is called.
  public func withSurface<T>(
    _ config: GhosttySurfaceConfig,
    _ body: (GhosttySurfaceHandle) throws -> T
  ) throws -> T {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      let surfaceRaw = try newRawSurface(config)
      let handle = GhosttySurfaceHandle(raw: surfaceRaw)
      defer {
        handle.invalidate()
        clair_ghostty_surface_free(surfaceRaw)
      }
      return try body(handle)
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  /// Allocates a `ghostty_surface_t` for the caller's own retained
  /// lifetime instead of a closure's scope. A macOS `NSView` (this task's
  /// `ClairGhosttySurfaceView`) spans many run-loop turns — keystrokes,
  /// mouse events, and resizes for as long as the view is in a window — so
  /// `withSurface`'s "freed the instant the closure returns" contract
  /// cannot hold it. The caller owns the returned handle and must call its
  /// `close()` exactly once (typically when the view leaves its window or
  /// deallocates) — nothing frees it automatically.
  public func retainSurface(_ config: GhosttySurfaceConfig) throws -> GhosttySurfaceHandle {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      let surfaceRaw = try newRawSurface(config)
      return GhosttySurfaceHandle(raw: surfaceRaw)
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }
}

/// A scope-bound handle to a `ghostty_surface_t`.
@MainActor
public final class GhosttySurfaceHandle {
  #if CLAIR_GHOSTTY_VENDORED
    private let raw: clair_ghostty_surface_t
    init(raw: clair_ghostty_surface_t) {
      self.raw = raw
    }
  #endif
  private var isValid = true

  func invalidate() {
    isValid = false
  }

  /// Frees the underlying `ghostty_surface_t` and invalidates the handle.
  /// Idempotent. See `GhosttyAppHandle.close()` — the retained-lifetime
  /// counterpart to `withSurface`'s automatic `defer`-based free.
  public func close() {
    guard isValid else { return }
    isValid = false
    #if CLAIR_GHOSTTY_VENDORED
      clair_ghostty_surface_free(raw)
    #endif
  }

  public func setSize(widthPixels: Int, heightPixels: Int) throws {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      clair_ghostty_surface_set_size(raw, UInt32(widthPixels), UInt32(heightPixels))
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  /// The rendered cell grid's current dimensions.
  public func size() throws -> GhosttySurfaceSize {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      let raw_size = clair_ghostty_surface_size(raw)
      return GhosttySurfaceSize(
        columns: Int(raw_size.columns),
        rows: Int(raw_size.rows),
        widthPixels: Int(raw_size.width_px),
        heightPixels: Int(raw_size.height_px),
        cellWidthPixels: Int(raw_size.cell_width_px),
        cellHeightPixels: Int(raw_size.cell_height_px)
      )
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  /// Reads back rendered screen text for `selection`. Returns `nil` when
  /// libghostty reports nothing to read for that region (for example, an
  /// empty cursor-relative read before any output has arrived) — this is
  /// a normal, expected outcome, not a failure.
  public func readText(_ selection: GhosttySurfaceSelection) throws -> String? {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      var rawSelection = clair_ghostty_selection_s()
      switch selection {
      case .screen:
        rawSelection.top_left = clair_ghostty_point_s(
          tag: CLAIR_GHOSTTY_POINT_SCREEN, coord: CLAIR_GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        rawSelection.bottom_right = clair_ghostty_point_s(
          tag: CLAIR_GHOSTTY_POINT_SCREEN, coord: CLAIR_GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
      case .cursor:
        rawSelection.top_left = clair_ghostty_point_s(
          tag: CLAIR_GHOSTTY_POINT_ACTIVE, coord: CLAIR_GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0)
        rawSelection.bottom_right = clair_ghostty_point_s(
          tag: CLAIR_GHOSTTY_POINT_ACTIVE, coord: CLAIR_GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0)
      }
      rawSelection.rectangle = false

      var text = clair_ghostty_text_s()
      guard clair_ghostty_surface_read_text(raw, rawSelection, &text) else { return nil }
      return decodeAndFreeText(&text)
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  #if CLAIR_GHOSTTY_VENDORED
    /// Shared by `readText` and `readSelection`: decodes a borrowed
    /// `clair_ghostty_text_s`'s bytes and frees it exactly once, regardless
    /// of which `ghostty_surface_*` call produced it.
    private func decodeAndFreeText(_ text: inout clair_ghostty_text_s) -> String? {
      defer { clair_ghostty_surface_free_text(raw, &text) }
      guard let pointer = text.text, text.text_len > 0 else { return nil }
      return String(
        decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(pointer), count: Int(text.text_len)),
        as: UTF8.self
      )
    }
  #endif

  // MARK: - Keyboard / text input

  /// Forwards a real key event to the surface. Returns whether libghostty
  /// consumed it (for example as a keybinding) — callers that also want a
  /// literal input fallback (this task's view does not) would only apply it
  /// when this returns `false`.
  @discardableResult
  public func sendKey(_ event: GhosttyKeyEvent) throws -> Bool {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      return withOptionalCString(event.text) { textPointer in
        var rawEvent = clair_ghostty_input_key_s()
        rawEvent.action = event.action.raw
        rawEvent.mods = event.mods.raw
        rawEvent.consumed_mods = event.consumedMods.raw
        rawEvent.keycode = event.keyCode
        rawEvent.text = textPointer
        rawEvent.unshifted_codepoint = event.unshiftedCodepoint
        rawEvent.composing = false
        return clair_ghostty_surface_key(raw, rawEvent)
      }
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  /// Feeds already-resolved text directly into the terminal — the real
  /// entry point this task's paste path uses (`NSPasteboard`'s string, read
  /// in `ClairAppKit`, handed here) rather than a per-character
  /// `sendKey`. This is the same entry point libghostty uses for committed
  /// IME text; it does not touch the clipboard read/write callbacks
  /// `clair_ghostty_abi.c`'s fixed runtime table stubs out.
  public func sendText(_ text: String) throws {
    guard isValid else { throw GhosttyError.handleExpired }
    guard !text.isEmpty else { return }
    #if CLAIR_GHOSTTY_VENDORED
      text.withCString { pointer in
        clair_ghostty_surface_text(raw, pointer, UInt(text.utf8.count))
      }
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  /// Display IME composition without writing it to the child PTY.
  public func setPreedit(_ text: String?) throws {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      if let text, !text.isEmpty {
        text.withCString { pointer in
          clair_ghostty_surface_preedit(raw, pointer, UInt(text.utf8.count))
        }
      } else {
        clair_ghostty_surface_preedit(raw, nil, 0)
      }
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  /// Cursor rectangle for the macOS input method candidate window, in surface points.
  public func imePoint() throws -> CGRect {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      var x = 0.0
      var y = 0.0
      var width = 0.0
      var height = 0.0
      clair_ghostty_surface_ime_point(raw, &x, &y, &width, &height)
      return CGRect(x: x, y: y, width: width, height: height)
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  // MARK: - Mouse input

  @discardableResult
  public func sendMouseButton(
    _ state: GhosttyMouseState, button: GhosttyMouseButton, mods: GhosttyKeyModifiers
  ) throws -> Bool {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      return clair_ghostty_surface_mouse_button(raw, state.raw, button.raw, mods.raw)
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  /// `x`/`y` are view-space points with `(0, 0)` at the surface's top-left
  /// corner (matching `ClairGhosttySurfaceView.isFlipped == true`, so
  /// callers pass `convert(_:from:)`'s result unmodified — unlike the
  /// upstream, non-flipped `SurfaceView_AppKit.swift`, which inverts Y
  /// itself before this call).
  public func sendMousePosition(x: Double, y: Double, mods: GhosttyKeyModifiers) throws {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      clair_ghostty_surface_mouse_pos(raw, x, y, mods.raw)
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  public func sendMouseScroll(x: Double, y: Double, mods: GhosttyScrollModifiers) throws {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      let rawMods: clair_ghostty_scroll_mods_t = mods.precise ? 1 : 0
      clair_ghostty_surface_mouse_scroll(raw, x, y, rawMods)
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  // MARK: - Focus / DPI

  public func setFocus(_ focused: Bool) throws {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      clair_ghostty_surface_set_focus(raw, focused)
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  public func setContentScale(x: Double, y: Double) throws {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      clair_ghostty_surface_set_content_scale(raw, x, y)
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  // MARK: - Selection / copy

  public func hasSelection() throws -> Bool {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      return clair_ghostty_surface_has_selection(raw)
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }

  /// Reads the surface's real, grid-aware current selection — respecting
  /// line wraps and scrollback the way a plain rectangular on-screen-point
  /// guess (this task's pre-vendored placeholder) cannot. `nil` when
  /// `hasSelection()` would report `false`.
  public func readSelection() throws -> String? {
    guard isValid else { throw GhosttyError.handleExpired }
    #if CLAIR_GHOSTTY_VENDORED
      var text = clair_ghostty_text_s()
      guard clair_ghostty_surface_read_selection(raw, &text) else { return nil }
      return decodeAndFreeText(&text)
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }
}

#if CLAIR_GHOSTTY_VENDORED
  extension GhosttyKeyAction {
    fileprivate var raw: clair_ghostty_input_action_e {
      switch self {
      case .press: CLAIR_GHOSTTY_INPUT_ACTION_PRESS
      case .release: CLAIR_GHOSTTY_INPUT_ACTION_RELEASE
      case .repeatKey: CLAIR_GHOSTTY_INPUT_ACTION_REPEAT
      }
    }
  }

  extension GhosttyKeyModifiers {
    fileprivate var raw: clair_ghostty_input_mods_e {
      var value: UInt32 = 0
      if contains(.shift) { value |= CLAIR_GHOSTTY_MODS_SHIFT.rawValue }
      if contains(.control) { value |= CLAIR_GHOSTTY_MODS_CTRL.rawValue }
      if contains(.option) { value |= CLAIR_GHOSTTY_MODS_ALT.rawValue }
      if contains(.command) { value |= CLAIR_GHOSTTY_MODS_SUPER.rawValue }
      if contains(.capsLock) { value |= CLAIR_GHOSTTY_MODS_CAPS.rawValue }
      return clair_ghostty_input_mods_e(rawValue: value)
    }
  }

  extension GhosttyMouseState {
    fileprivate var raw: clair_ghostty_mouse_state_e {
      switch self {
      case .press: CLAIR_GHOSTTY_MOUSE_PRESS
      case .release: CLAIR_GHOSTTY_MOUSE_RELEASE
      }
    }
  }

  extension GhosttyMouseButton {
    fileprivate var raw: clair_ghostty_mouse_button_e {
      switch self {
      case .left: CLAIR_GHOSTTY_MOUSE_LEFT
      case .right: CLAIR_GHOSTTY_MOUSE_RIGHT
      case .middle: CLAIR_GHOSTTY_MOUSE_MIDDLE
      case .unknown: CLAIR_GHOSTTY_MOUSE_UNKNOWN
      }
    }
  }
#endif

/// Calls `body` with `string`'s C string, or `nil` if `string` is `nil`.
private func withOptionalCString<T>(
  _ string: String?, _ body: (UnsafePointer<CChar>?) throws -> T
) rethrows -> T {
  if let string {
    return try string.withCString(body)
  }
  return try body(nil)
}

extension GhosttyRuntime {
  /// Allocates a `ghostty_app_t` for the duration of `body` and frees it
  /// exactly once when `body` returns or throws — the app-level half of
  /// this task's surface-embedding round trip (`GhosttyConfigHandle` /
  /// `withConfig` is the config-level half). The runtime callback table
  /// (wakeup/clipboard/action) is not exposed here: see
  /// `clair_ghostty_abi.c` for why every callback is a fixed, always-safe
  /// no-op/deny at this subset's current scope.
  public func withApp<T>(
    configuring configureBody: (GhosttyConfigHandle) throws -> Void = { _ in },
    _ body: (GhosttyAppHandle) throws -> T
  ) throws -> T {
    try withConfig { configHandle in
      try configHandle.withValidHandle {
        try configureBody(configHandle)
      }
      #if CLAIR_GHOSTTY_VENDORED
        guard let appRaw = configHandle.withRawConfig({ clair_ghostty_app_new($0) }) else {
          throw GhosttyError.initializationFailed("ghostty_app_new returned NULL")
        }
        let handle = GhosttyAppHandle(raw: appRaw)
        defer {
          handle.invalidate()
          clair_ghostty_app_free(appRaw)
        }
        return try body(handle)
      #else
        throw GhosttyError.runtimeUnavailable
      #endif
    }
  }

  /// Allocates a `ghostty_app_t` for the caller's own retained lifetime —
  /// the app-level counterpart to `GhosttyAppHandle.retainSurface`. See
  /// that method's doc comment for why a macOS surface view needs this
  /// instead of `withApp`'s closure scope. The caller must call the
  /// returned handle's `close()` exactly once.
  public func retainApp(
    configuring configureBody: (GhosttyConfigHandle) throws -> Void = { _ in }
  ) throws -> GhosttyAppHandle {
    try withConfig { configHandle in
      try configHandle.withValidHandle {
        try configureBody(configHandle)
      }
      #if CLAIR_GHOSTTY_VENDORED
        guard let appRaw = configHandle.withRawConfig({ clair_ghostty_app_new($0) }) else {
          throw GhosttyError.initializationFailed("ghostty_app_new returned NULL")
        }
        return GhosttyAppHandle(raw: appRaw)
      #else
        throw GhosttyError.runtimeUnavailable
      #endif
    }
  }
}
