import Foundation

/// Pane layout model for the Mac AppShell (checklist §3.1). Pure value type so
/// split/close/maximize/equalize/focus rules are testable without any UI.
public enum PaneKind: String, Sendable, Equatable, Codable {
  case editor, terminal

  /// U06: the Agent panel is gone — an agent is a raw terminal session (ADR-0002), so a saved
  /// `agent` leaf restores as a terminal instead of failing the whole workspace restore.
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let kind = raw == "agent" ? .terminal : Self(rawValue: raw) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown pane kind \(raw)"))
    }
    self = kind
  }
}

public struct PaneTree: Sendable, Equatable, Codable {
  public enum Axis: String, Sendable, Equatable, Codable { case horizontal, vertical }

  public indirect enum Node: Sendable, Equatable, Codable {
    case leaf(id: Int, kind: PaneKind)
    case split(axis: Axis, ratio: Double, first: Node, second: Node)
  }

  public static let ratioRange: ClosedRange<Double> = 0.08...0.92

  public private(set) var root: Node
  public private(set) var focused: Int
  public private(set) var maximized: Int?
  private var nextID: Int

  /// editor (left, 0.62) | terminal for an agent (top right) / terminal (bottom right, 0.55)
  public init() {
    root = .split(
      axis: .horizontal, ratio: 0.62,
      first: .leaf(id: 1, kind: .editor),
      second: .split(
        axis: .vertical, ratio: 0.55,
        first: .leaf(id: 2, kind: .terminal),
        second: .leaf(id: 3, kind: .terminal)))
    focused = 1
    nextID = 4
  }

  /// One pane of `kind`: what the empty workspace reopens into.
  public init(single kind: PaneKind) {
    root = .leaf(id: 1, kind: kind)
    focused = 1
    nextID = 2
  }

  /// Leaves in first-to-last (appearance) order.
  public var leaves: [(id: Int, kind: PaneKind)] { Self.leaves(root) }

  private static func leaves(_ n: Node) -> [(id: Int, kind: PaneKind)] {
    switch n {
    case .leaf(let id, let kind): return [(id, kind)]
    case .split(_, _, let a, let b): return leaves(a) + leaves(b)
    }
  }

  /// `id` names the divider by the pane just before it: the split whose first child ends with that pane.
  /// That split is unique; "first child contains id" also matched every enclosing split, so nested dividers moved together.
  public mutating func setRatio(splitContaining id: Int, _ ratio: Double) {
    root = Self.map(root) { n in
      guard case .split(let ax, _, let a, let b) = n, Self.leaves(a).last?.id == id
      else { return nil }
      return .split(axis: ax, ratio: Self.clamp(ratio), first: a, second: b)
    }
  }

  /// Splits the focused pane; the new pane is a terminal and takes focus.
  /// The editor is a singleton ("ファイルを選択してください。" must never be duplicated).
  public mutating func splitFocused(_ axis: Axis) {
    focused = split(focused, axis)
  }

  /// V16: splits `target` without moving focus (an agent fanning out must not steal the user's pane). Returns the new id.
  @discardableResult
  public mutating func split(_ target: Int, _ axis: Axis) -> Int {
    let new = nextID
    nextID += 1
    root = Self.map(root) { n in
      guard case .leaf(let id, _) = n, id == target else { return nil }
      return .split(axis: axis, ratio: 0.5, first: n, second: .leaf(id: new, kind: .terminal))
    }
    maximized = nil
    return new
  }

  /// V16: closes `id` wherever it is; focus moves only if it was on `id`. The last pane cannot be closed.
  public mutating func close(_ id: Int) {
    let saved = focused
    focused = id
    closeFocused()
    if saved != id, leaves.contains(where: { $0.id == saved }) { focused = saved }
  }

  /// Closes the focused pane; the last pane cannot be closed.
  public mutating func closeFocused() {
    let all = leaves
    guard all.count > 1, let i = all.firstIndex(where: { $0.id == focused }) else { return }
    let target = focused
    root = Self.remove(root, target) ?? root
    focused = all[i == 0 ? 1 : i - 1].id
    if maximized == target { maximized = nil }
  }

  /// Closing the anchored editor replaces its pane, keeping the left edge available for files.
  public mutating func replaceFocusedEditor() {
    guard leaves.first?.id == focused, leaves.first?.kind == .editor else { return }
    let old = focused
    let replacement = nextID
    nextID += 1
    root = Self.map(root) { n in
      guard case .leaf(let id, .editor) = n, id == old else { return nil }
      return .leaf(id: replacement, kind: .editor)
    }
    focused = replacement
    if maximized == old { maximized = replacement }
  }

  public mutating func ensureEditorAtLeft() {
    guard leaves.first?.kind != .editor else { return }
    let editor = nextID
    nextID += 1
    root = .split(axis: .horizontal, ratio: 0.62, first: .leaf(id: editor, kind: .editor), second: root)
    focused = editor
    maximized = nil
  }

  /// False for a decoded tree that could crash or mislead the UI (restore degrades to the default layout).
  public var isValid: Bool {
    let ids = leaves.map(\.id)
    return leaves.first?.kind == .editor && leaves.filter { $0.kind == .editor }.count == 1 && Set(ids).count == ids.count && ids.contains(focused) && (maximized.map(ids.contains) ?? true)
      && nextID > (ids.max() ?? 0)
  }

  public mutating func toggleMaximize() { maximized = maximized == nil ? focused : nil }

  public mutating func equalize() {
    root = Self.map(root) { n in
      guard case .split(let ax, _, let a, let b) = n else { return nil }
      return .split(axis: ax, ratio: 0.5, first: a, second: b)
    }
  }

  /// Cycles focus through leaves in appearance order (`⌃⌘→`).
  public mutating func focusNext() {
    let all = leaves
    guard let i = all.firstIndex(where: { $0.id == focused }) else { return }
    focused = all[(i + 1) % all.count].id
    if maximized != nil { maximized = focused }
  }

  public mutating func focus(_ id: Int) {
    if leaves.contains(where: { $0.id == id }) { focused = id }
  }

  /// Swaps what two leaves show (their `kind`); tree shape, ratios and focus are untouched
  /// (checklist §3.1, 2026-09-20 amendment; mirrors the mock's `swapPanes`).
  public mutating func swapLeaves(_ idA: Int, _ idB: Int) {
    guard idA != idB else { return }
    let all = leaves
    guard let kindA = all.first(where: { $0.id == idA })?.kind, let kindB = all.first(where: { $0.id == idB })?.kind
    else { return }
    guard !(all.first?.id == idA && kindB != .editor), !(all.first?.id == idB && kindA != .editor) else { return }
    root = Self.map(root) { n in
      guard case .leaf(let id, _) = n else { return nil }
      if id == idA { return .leaf(id: idA, kind: kindB) }
      if id == idB { return .leaf(id: idB, kind: kindA) }
      return nil
    }
  }

  public enum Edge: String, Sendable, CaseIterable { case left, right, top, bottom }

  /// Moves leaf `id` beside `target`, splitting `target` in half on `edge`; the moved pane keeps its id
  /// (so its terminal session) and takes focus.
  public mutating func moveLeaf(_ id: Int, to target: Int, _ edge: Edge) {
    guard id != target, let kind = leaves.first(where: { $0.id == id })?.kind,
      leaves.contains(where: { $0.id == target }), let pruned = Self.remove(root, id)
    else { return }
    let moved = Node.leaf(id: id, kind: kind)
    let axis: Axis = edge == .left || edge == .right ? .horizontal : .vertical
    let before = edge == .left || edge == .top
    let candidate = Self.map(pruned) { n in
      guard case .leaf(let i, _) = n, i == target else { return nil }
      return .split(axis: axis, ratio: 0.5, first: before ? moved : n, second: before ? n : moved)
    }
    guard Self.leaves(candidate).first?.kind == .editor else { return }
    root = candidate
    focused = id
    maximized = nil
  }

  private static func clamp(_ r: Double) -> Double { min(max(r, ratioRange.lowerBound), ratioRange.upperBound) }

  /// Bottom-up rewrite; `f` returns a replacement or nil to keep the node.
  private static func map(_ n: Node, _ f: (Node) -> Node?) -> Node {
    var n = n
    if case .split(let ax, let r, let a, let b) = n {
      n = .split(axis: ax, ratio: r, first: map(a, f), second: map(b, f))
    }
    return f(n) ?? n
  }

  private static func remove(_ n: Node, _ id: Int) -> Node? {
    switch n {
    case .leaf(let i, _): return i == id ? nil : n
    case .split(let ax, let r, let a, let b):
      switch (remove(a, id), remove(b, id)) {
      case (nil, let s?), (let s?, nil): return s
      case (let x?, let y?): return .split(axis: ax, ratio: r, first: x, second: y)
      default: return nil
      }
    }
  }
}
