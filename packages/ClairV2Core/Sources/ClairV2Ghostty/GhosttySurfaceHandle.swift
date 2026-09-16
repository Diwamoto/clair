#if CLAIR_GHOSTTY_VENDORED
  import ClairV2GhosttyABI
#endif
import Foundation

/// Which platform view backs a `ghostty_surface_t`. Mirrors
/// `clair_ghostty_platform_e`'s two real variants; `ClairV2Ghostty` itself
/// stays AppKit/UIKit-agnostic, so callers (for example `ClairV2AppKit`'s
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
            let handle = GhosttySurfaceHandle(raw: surfaceRaw)
            defer {
              handle.invalidate()
              clair_ghostty_surface_free(surfaceRaw)
            }
            return try body(handle)
          }
        }
      }
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
      defer { clair_ghostty_surface_free_text(raw, &text) }
      guard let pointer = text.text, text.text_len > 0 else { return nil }
      return String(
        decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(pointer), count: Int(text.text_len)),
        as: UTF8.self
      )
    #else
      throw GhosttyError.runtimeUnavailable
    #endif
  }
}

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
}
