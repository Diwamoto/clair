import CoreGraphics
import Foundation

/// Native Mermaid for the Markdown preview: parses ```mermaid fences and lays them out so the preview can
/// draw them with plain SwiftUI shapes — no WebView, no JavaScript (spec §4).
/// ponytail: flowchart + sequence diagram only, one-pass layered layout with straight edges; other diagram
/// types fall back to the code block. Add types / an edge router when real documents need them.
public enum MermaidDiagram: Equatable, Sendable {
  case flowchart(Flowchart)
  case sequence(Sequence)

  public enum Shape: Sendable { case rect, round, stadium, circle, diamond }

  public struct Node: Equatable, Sendable {
    public let id: String
    public var label: String
    public var shape: Shape
  }

  public struct Edge: Equatable, Sendable {
    public let from: String, to: String
    public var label: String?
    public var dashed = false, thick = false, arrow = true
  }

  public struct Flowchart: Equatable, Sendable {
    /// "TB" (= "TD"), "BT", "LR" or "RL".
    public var direction = "TB"
    public var nodes: [Node] = []
    public var edges: [Edge] = []
  }

  public struct Sequence: Equatable, Sendable {
    public struct Participant: Equatable, Sendable { public let id: String; public var label: String }
    public enum Step: Equatable, Sendable {
      case message(from: String, to: String, text: String, dashed: Bool, arrow: Bool)
      /// `over` holds one or two participant ids; `side` is "left", "right" or "over".
      case note(over: [String], side: String, text: String)
    }
    public var participants: [Participant] = []
    public var steps: [Step] = []
  }

  /// nil for an unsupported diagram type or an empty fence.
  public static func parse(_ source: String) -> MermaidDiagram? {
    let lines = source.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
    guard let head = lines.first?.split(separator: " ").first.map(String.init) else { return nil }
    let body = Array(lines.dropFirst())
    switch head {
    case "graph", "flowchart":
      var f = Flowchart()
      if let d = lines[0].split(separator: " ").dropFirst().first.map({ $0.uppercased() }), ["TB", "TD", "BT", "LR", "RL"].contains(d) {
        f.direction = d == "TD" ? "TB" : d
      }
      for line in body { for stmt in line.split(separator: ";") { flowStatement(stmt.trimmingCharacters(in: .whitespaces), into: &f) } }
      return f.nodes.isEmpty ? nil : .flowchart(f)
    case "sequenceDiagram":
      var s = Sequence()
      for line in body { sequenceStatement(line, into: &s) }
      return s.participants.isEmpty ? nil : .sequence(s)
    default:
      return nil
    }
  }

  // MARK: Flowchart parsing

  private static let ignored = ["classDef", "class ", "style ", "linkStyle", "click ", "subgraph", "end", "direction "]

  private static func flowStatement(_ stmt: String, into f: inout Flowchart) {
    guard !stmt.isEmpty, !ignored.contains(where: { stmt == $0 || stmt.hasPrefix($0) }) else { return }
    var rest = Substring(stmt)
    guard var prev = node(&rest, into: &f) else { return }
    while true {
      guard var edge = edgeOp(&rest), let next = node(&rest, into: &f) else { return }
      edge = Edge(from: prev, to: next, label: edge.label, dashed: edge.dashed, thick: edge.thick, arrow: edge.arrow)
      f.edges.append(edge)
      prev = next
    }
  }

  private static let shapes: [(open: String, close: String, shape: Shape)] = [
    ("((", "))", .circle), ("([", "])", .stadium), ("[[", "]]", .rect), ("[(", ")]", .rect), ("{{", "}}", .diamond),
    ("[", "]", .rect), ("(", ")", .round), ("{", "}", .diamond), (">", "]", .rect),
  ]

  /// Reads `id` plus an optional shape/label, registering the node; returns its id.
  private static func node(_ s: inout Substring, into f: inout Flowchart) -> String? {
    s = s.drop(while: { $0 == " " })
    let id = String(s.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
    guard !id.isEmpty else { return nil }
    s = s.dropFirst(id.count)
    var label: String?, shape = Shape.rect
    if let sh = shapes.first(where: { s.hasPrefix($0.open) }), let end = s.range(of: sh.close, range: s.index(s.startIndex, offsetBy: sh.open.count)..<s.endIndex) {
      label = String(s[s.index(s.startIndex, offsetBy: sh.open.count)..<end.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
      shape = sh.shape
      s = s[end.upperBound...]
    }
    if let i = f.nodes.firstIndex(where: { $0.id == id }) {
      if let label { f.nodes[i].label = label; f.nodes[i].shape = shape }
    } else {
      f.nodes.append(Node(id: id, label: label ?? id, shape: shape))
    }
    return id
  }

  /// Reads an edge operator (`-->`, `---`, `-.->`, `==>`, with `|label|` or `-- label -->`).
  private static func edgeOp(_ s: inout Substring) -> Edge? {
    if let m = s.prefixMatch(of: /\s*(?:--|==|-\.)\s+([^|]+?)\s+(-{2,}>?|={2,}>?|\.+-+>?)\s*/) {
      s = s[m.range.upperBound...]
      let op = String(m.2)
      return Edge(from: "", to: "", label: String(m.1), dashed: op.hasPrefix("."), thick: op.hasPrefix("="), arrow: op.hasSuffix(">"))
    }
    guard let m = s.prefixMatch(of: /\s*<?(-{2,}|={2,}|-\.+-)(>|o|x)?\s*(?:\|([^|]*)\|)?\s*/) else { return nil }
    s = s[m.range.upperBound...]
    let op = String(m.1)
    return Edge(from: "", to: "", label: m.3.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }.flatMap { $0.isEmpty ? nil : $0 },
                dashed: op.contains("."), thick: op.hasPrefix("="), arrow: m.2 != nil)
  }

  // MARK: Sequence parsing

  private static func sequenceStatement(_ line: String, into s: inout Sequence) {
    func participant(_ id: String) {
      if !s.participants.contains(where: { $0.id == id }) { s.participants.append(.init(id: id, label: id)) }
    }
    if let m = line.wholeMatch(of: /(?:participant|actor)\s+(.+?)(?:\s+as\s+(.+))?/) {
      let id = String(m.1)
      participant(id)
      if let alias = m.2, let i = s.participants.firstIndex(where: { $0.id == id }) { s.participants[i].label = String(alias) }
      return
    }
    if let m = line.wholeMatch(of: /(?i:note)\s+(left of|right of|over)\s+([^:]+):\s*(.*)/) {
      let ids = m.2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      ids.forEach(participant)
      s.steps.append(.note(over: ids, side: String(m.1.split(separator: " ")[0]).lowercased(), text: String(m.3)))
      return
    }
    if let m = line.wholeMatch(of: /([^\s:>-][^:>]*?)\s*(--?)(>>|>|x|\))[+-]?\s*([^:]+?)\s*:\s*(.*)/) {
      let from = String(m.1), to = String(m.4)
      participant(from); participant(to)
      s.steps.append(.message(from: from, to: to, text: String(m.5), dashed: m.2 == "--", arrow: m.3 != ")"))
    }
    // loop / alt / opt / end / autonumber / activate: ponytail — drawn flat, their frames are not shown.
  }
}

// MARK: Layout

extension MermaidDiagram {
  public struct PlacedNode: Sendable { public let node: Node; public let frame: CGRect }
  public struct PlacedEdge: Sendable {
    public let edge: Edge
    public let start: CGPoint, end: CGPoint
    /// Quadratic control point; a straight edge's is its midpoint. Back edges bow out so they don't overlap.
    public let control: CGPoint
  }
  public struct FlowLayout: Sendable {
    public let size: CGSize
    public let nodes: [PlacedNode]
    public let edges: [PlacedEdge]
  }

  /// Layered layout: back edges are ignored for ranking, each node sits one rank below its deepest
  /// predecessor, and one barycenter sweep orders each rank. `measure` gives a label's text size.
  public static func layout(_ f: Flowchart, measure: (String) -> CGSize) -> FlowLayout {
    let ids = f.nodes.map(\.id)
    let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    let succ = Dictionary(grouping: f.edges.filter { $0.from != $0.to }, by: \.from).mapValues { $0.compactMap { index[$0.to] } }

    // Drop back edges found by DFS in declaration order, then rank by longest path.
    var state = [Int](repeating: 0, count: ids.count), dag = [[Int]](repeating: [], count: ids.count)
    func dfs(_ u: Int) {
      state[u] = 1
      for v in succ[ids[u]] ?? [] where state[v] != 1 {
        dag[u].append(v)
        if state[v] == 0 { dfs(v) }
      }
      state[u] = 2
    }
    for u in ids.indices where state[u] == 0 { dfs(u) }
    var indeg = [Int](repeating: 0, count: ids.count)
    for vs in dag { for v in vs { indeg[v] += 1 } }
    var rank = [Int](repeating: 0, count: ids.count), queue = ids.indices.filter { indeg[$0] == 0 }
    while let u = queue.first {
      queue.removeFirst()
      for v in dag[u] {
        rank[v] = max(rank[v], rank[u] + 1)
        indeg[v] -= 1
        if indeg[v] == 0 { queue.append(v) }
      }
    }

    var layers = [[Int]](repeating: [], count: (rank.max() ?? 0) + 1)
    for u in ids.indices { layers[rank[u]].append(u) }
    var pos = [Int](repeating: 0, count: ids.count)
    for l in layers { for (i, u) in l.enumerated() { pos[u] = i } }
    let preds = (0..<ids.count).map { v in dag.indices.filter { dag[$0].contains(v) } }
    for r in layers.indices.dropFirst() {
      layers[r].sort { a, b in
        func bary(_ u: Int) -> Double { preds[u].isEmpty ? Double(pos[u]) : Double(preds[u].map { pos[$0] }.reduce(0, +)) / Double(preds[u].count) }
        return bary(a) < bary(b)
      }
      for (i, u) in layers[r].enumerated() { pos[u] = i }
    }

    // Sizes, then place: `along` is the rank axis, `across` the in-rank axis.
    let horizontal = f.direction == "LR" || f.direction == "RL"
    let sizes = f.nodes.map { n -> CGSize in
      let t = measure(n.label)
      switch n.shape {
      case .diamond: return CGSize(width: t.width + 40, height: max(t.height + 30, 44))
      case .circle: let d = max(t.width, t.height) + 24; return CGSize(width: d, height: d)
      default: return CGSize(width: t.width + 24, height: t.height + 16)
      }
    }
    let rankGap: CGFloat = 44, nodeGap: CGFloat = 24, pad: CGFloat = 4
    func along(_ s: CGSize) -> CGFloat { horizontal ? s.width : s.height }
    func across(_ s: CGSize) -> CGFloat { horizontal ? s.height : s.width }
    let thickness = layers.map { l in l.map { along(sizes[$0]) }.max() ?? 0 }
    let spans = layers.map { l in l.map { across(sizes[$0]) }.reduce(0, +) + nodeGap * CGFloat(max(l.count - 1, 0)) }
    let totalAcross = spans.max() ?? 0
    let totalAlong = thickness.reduce(0, +) + rankGap * CGFloat(max(layers.count - 1, 0))
    var centers = [CGPoint](repeating: .zero, count: ids.count)
    var a: CGFloat = pad
    for (r, l) in layers.enumerated() {
      var c = pad + (totalAcross - spans[r]) / 2
      for u in l {
        let mid = a + thickness[r] / 2, m = c + across(sizes[u]) / 2
        let reversed = f.direction == "BT" || f.direction == "RL"
        let alongPos = reversed ? totalAlong + 2 * pad - mid : mid
        centers[u] = horizontal ? CGPoint(x: alongPos, y: m) : CGPoint(x: m, y: alongPos)
        c += across(sizes[u]) + nodeGap
      }
      a += thickness[r] + rankGap
    }

    let placed = f.nodes.indices.map { i in
      PlacedNode(node: f.nodes[i], frame: CGRect(x: centers[i].x - sizes[i].width / 2, y: centers[i].y - sizes[i].height / 2,
                                                 width: sizes[i].width, height: sizes[i].height))
    }
    let edges = f.edges.compactMap { e -> PlacedEdge? in
      guard let u = index[e.from], let v = index[e.to], u != v else { return nil }
      let a = centers[u], b = centers[v], mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
      var control = mid
      if rank[v] <= rank[u] {  // back edge: bow out perpendicular to the chord
        let dx = b.x - a.x, dy = b.y - a.y, len = max((dx * dx + dy * dy).squareRoot(), 1), bow: CGFloat = 60
        control = CGPoint(x: mid.x - dy / len * bow, y: mid.y + dx / len * bow)
      }
      return PlacedEdge(edge: e, start: boundary(placed[u], toward: control), end: boundary(placed[v], toward: control), control: control)
    }
    let size = horizontal ? CGSize(width: totalAlong, height: totalAcross) : CGSize(width: totalAcross, height: totalAlong)
    // ponytail: a bowed back edge may poke past the node box; grow the canvas to hold its control point.
    let reach = edges.reduce(CGPoint(x: size.width + 2 * pad, y: size.height + 2 * pad)) { CGPoint(x: max($0.x, $1.control.x), y: max($0.y, $1.control.y)) }
    return FlowLayout(size: CGSize(width: reach.x, height: reach.y), nodes: placed, edges: edges)
  }

  /// Where the line from a node's center toward `p` leaves the node's outline.
  static func boundary(_ n: PlacedNode, toward p: CGPoint) -> CGPoint {
    let c = CGPoint(x: n.frame.midX, y: n.frame.midY), dx = p.x - c.x, dy = p.y - c.y
    let w = n.frame.width / 2, h = n.frame.height / 2
    guard dx != 0 || dy != 0 else { return c }
    let t: CGFloat
    switch n.node.shape {
    case .diamond: t = 1 / (abs(dx) / w + abs(dy) / h)
    case .circle: t = 1 / ((dx / w) * (dx / w) + (dy / h) * (dy / h)).squareRoot()
    default: t = min(dx == 0 ? .infinity : w / abs(dx), dy == 0 ? .infinity : h / abs(dy))
    }
    return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
  }
}
