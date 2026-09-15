import ClairV2Ghostty
import Foundation

/// A small, `MainActor`-free summary of `GhosttyRuntime`'s state that the
/// macOS surface (and its SwiftUI host) can read without importing
/// `ClairV2Ghostty` types directly everywhere. This never substitutes a
/// non-Ghostty renderer for a missing runtime; it only reports which typed
/// state applies right now, matching `T01`'s fail-closed contract.
public struct ClairV2GhosttyStatus: Equatable, Sendable {
  public let isVendored: Bool
  public let activationError: String?

  public init(isVendored: Bool, activationError: String?) {
    self.isVendored = isVendored
    self.activationError = activationError
  }

  @MainActor
  public static func current() -> ClairV2GhosttyStatus {
    let isVendored = GhosttyRuntime.isVendored
    do {
      try GhosttyRuntime.shared.activate()
      return ClairV2GhosttyStatus(isVendored: isVendored, activationError: nil)
    } catch {
      return ClairV2GhosttyStatus(isVendored: isVendored, activationError: String(describing: error))
    }
  }

  public var summary: String {
    guard isVendored else {
      return "Ghostty runtime not vendored (run scripts/v2-ghostty.sh vendor)"
    }
    if let activationError {
      return "Ghostty runtime vendored but failed to activate: \(activationError)"
    }
    return "Ghostty runtime vendored and activated; surface embedding is pending ABI coverage"
  }
}
