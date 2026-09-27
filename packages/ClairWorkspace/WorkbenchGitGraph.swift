import Foundation

/// V17: commit graph. `CommitGraph` assigns lanes page by page (so a huge history is read from the top
/// incrementally, `BUDGET-OP-100`); the view only draws each row's lanes.
public struct GraphCommit: Sendable, Equatable {
  public let id: String
  public let parents: [String]
  public let refs: [String]
  public let isHead: Bool
  public let author: String
  public let date: String
  public let subject: String
}

public struct GraphRow: Sendable, Equatable {
  public let commit: GraphCommit
  /// Column of this commit's node.
  public let lane: Int
  /// Lanes that run straight through the row.
  public let passing: [Int]
  /// Lanes that end in this node from above (its children).
  public let converging: [Int]
  /// Lanes that leave this node downward (its parents).
  public let parents: [Int]
  /// Columns the row needs to draw.
  public var width: Int { ([lane] + passing + converging + parents).max()! + 1 }
}

public struct CommitGraph: Sendable {
  public private(set) var rows: [GraphRow] = []
  /// The commit each column expects next; nil is a free column.
  private var lanes: [String?] = []

  public init() {}

  public mutating func append(_ commits: [GraphCommit]) {
    for c in commits {
      let converging = lanes.indices.filter { lanes[$0] == c.id }
      let lane = converging.first ?? lanes.firstIndex(of: nil) ?? lanes.count
      if lane == lanes.count { lanes.append(nil) }
      for i in converging { lanes[i] = nil }
      let passing = lanes.indices.filter { lanes[$0] != nil }
      var parentLanes: [Int] = []
      for (n, p) in c.parents.enumerated() {
        if let existing = lanes.firstIndex(of: p) { parentLanes.append(existing); continue }  // joins a lane already waiting for it
        let slot = n == 0 ? lane : (lanes.firstIndex(of: nil) ?? lanes.count)
        if slot == lanes.count { lanes.append(nil) }
        lanes[slot] = p
        parentLanes.append(slot)
      }
      while lanes.last == .some(nil) { lanes.removeLast() }
      rows.append(GraphRow(commit: c, lane: lane, passing: passing, converging: converging, parents: parentLanes))
    }
  }

  static let separator = "\u{1f}"
  static let format = ["%H", "%P", "%D", "%an", "%ar", "%s"].joined(separator: "%x1f")

  /// One `git log` line in `format`.
  static func parse(_ line: Substring) -> GraphCommit? {
    let f = line.components(separatedBy: separator)
    guard f.count == 6 else { return nil }
    var refs: [String] = []
    var head = false
    for r in f[2].components(separatedBy: ", ") where !r.isEmpty {
      if r == "HEAD" { head = true } else if r.hasPrefix("HEAD -> ") { head = true; refs.append(String(r.dropFirst(8))) } else { refs.append(r) }
    }
    return GraphCommit(
      id: f[0], parents: f[1].split(separator: " ").map(String.init), refs: refs, isHead: head,
      author: f[3], date: f[4], subject: f[5])
  }

  /// A page of commits, newest first across every ref. Blocking: call off the main actor.
  public static func page(_ root: String, skip: Int, count: Int) -> [GraphCommit] {
    WorkbenchGit.lines(root, ["log", "--all", "--topo-order", "--format=\(format)", "--skip=\(skip)", "-n", "\(count)"])
      .compactMap { parse(Substring($0)) }
  }

  /// One commit's patch against its first parent, split per file. Blocking: call off the main actor.
  public static func files(_ root: String, _ id: String) -> [(path: String, patch: String)] {
    guard id.allSatisfy(\.isHexDigit) else { return [] }
    return split(WorkbenchGit.run(root, ["show", "--patch", "--format=", "-m", "--first-parent", id]).out)
  }

  /// Cuts a multi-file patch at each `diff --git a/X b/Y`; the path is the `b/` side.
  static func split(_ patch: String) -> [(path: String, patch: String)] {
    var out: [(path: String, patch: String)] = []
    for l in patch.split(separator: "\n", omittingEmptySubsequences: false) {
      if l.hasPrefix("diff --git "), let r = l.range(of: " b/", options: .backwards) {
        out.append((String(l[r.upperBound...]), ""))
      }
      if !out.isEmpty { out[out.count - 1].patch += l + "\n" }
    }
    return out
  }
}
