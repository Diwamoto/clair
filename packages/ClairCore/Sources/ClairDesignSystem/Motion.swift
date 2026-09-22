import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The Mac IDE screens the checklist's `KIND`/`ORDER` motion tables are
/// keyed by (checklist §2.5, `Screen` in `motion.tsx`). This is a motion
/// primitive, not a router — it exists so `Motion.kind`/`Motion.order` can
/// be typed instead of stringly keyed. Screen *content* is `U04`+ scope.
public enum Screen: String, CaseIterable, Sendable {
  case workspace
  case review
  case graph
  case activity
  case debug
  case debugAgent
  case sessions
  case settings
}

/// Screen transition primitives ported from `motion.tsx` / checklist §2.5.
/// This only carries durations, the per-screen `Kind` and the direction
/// math `transitionFor` needs — the transition *system* itself (mounting,
/// cross-fade of outgoing/incoming layers, etc.) is `U04`/`U05`/`U06` scope.
public enum Motion {
  /// `SCREEN_MS = 200`: main-area screen changes.
  /// Keep screen-level feedback perceptibly immediate; the interaction budget is < 200 ms.
  public static let screenDuration: TimeInterval = 0.16
  /// `OVERLAY_MS = 90`: overlays, panels and context menus.
  public static let overlayDuration: TimeInterval = 0.09

  /// The five motion kinds the canvas defines (checklist §2.5). `depth` is
  /// the default (recede/emerge along z); `slide` additionally needs a
  /// direction, computed by `transition(from:to:)` below rather than
  /// carried on the case itself, mirroring `motion.tsx`'s `Kind` type.
  public enum Kind: String, Sendable, Equatable {
    case depth
    case slide
    case lift
    case sheet
    case fade
  }

  /// Per-screen motion kind (`KIND` in `motion.tsx` / checklist §2.5).
  public static let kind: [Screen: Kind] = [
    .workspace: .depth,
    .review: .slide,
    .graph: .slide,
    .activity: .depth,
    .debug: .depth,
    .debugAgent: .depth,
    .sessions: .lift,
    .settings: .sheet,
  ]

  /// Left-to-right order in the sidebar strip, so a `slide` transition
  /// knows its direction (`ORDER` in `motion.tsx` / checklist §2.5).
  public static let order: [Screen] = [
    .workspace, .graph, .review, .debug, .debugAgent, .activity, .sessions, .settings,
  ]

  /// The resolved motion for a transition, with `slide` already given a
  /// direction — what a caller actually needs to pick an animation.
  public enum Transition: Sendable, Equatable {
    case depth
    case slideForward
    case slideBackward
    case lift
    case sheet
    case fade
  }

  /// Mirrors `transitionFor` in `motion.tsx`: the screen being *entered*
  /// chooses the motion, except when returning to `workspace`, where the
  /// screen being *left* is the one with character (workspace itself is
  /// always `depth`).
  public static func transition(from: Screen, to: Screen) -> Transition {
    let resolvedKind = (to == .workspace ? kind[from] : kind[to]) ?? .depth
    switch resolvedKind {
    case .depth: return .depth
    case .lift: return .lift
    case .sheet: return .sheet
    case .fade: return .fade
    case .slide:
      let toIndex = order.firstIndex(of: to) ?? 0
      let fromIndex = order.firstIndex(of: from) ?? 0
      return toIndex >= fromIndex ? .slideForward : .slideBackward
    }
  }

  /// Overlays/context menus/the command palette open from the corner
  /// nearest the pointer, scaling from `0.97` to `1` over
  /// `overlayDuration`; closing is not animated (checklist §2.5, §3.6).
  public static let overlayOpenScale: Double = 0.97

  /// Native equivalent of `prefers-reduced-motion: reduce` (checklist
  /// §2.5: "全て停止する" — everything above should stop, not just slow
  /// down, when this is `true`). Consulting this is the caller's
  /// responsibility; this type does not itself gate anything.
  public enum ReducedMotion {
    public static var isEnabled: Bool {
      #if canImport(AppKit)
      return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      #elseif canImport(UIKit)
      return UIAccessibility.isReduceMotionEnabled
      #else
      return false
      #endif
    }
  }
}
