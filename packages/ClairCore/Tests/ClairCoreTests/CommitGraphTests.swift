import XCTest

@testable import ClairWorkspace

/// V17: lane assignment, paged `git log` parsing, and the Git-only command.
final class CommitGraphTests: XCTestCase {
  private func c(_ id: String, _ parents: String...) -> GraphCommit {
    GraphCommit(id: id, parents: parents, refs: [], isHead: false, author: "a", date: "now", subject: id)
  }

  func testBranchAndMergeLanes() {
    // M merges F (feature) into B; F and B both come from A.
    var g = CommitGraph()
    g.append([c("M", "B", "F"), c("F", "A")])
    g.append([c("B", "A"), c("A")])  // a second page continues the same lanes
    let r = g.rows
    XCTAssertEqual(r.map(\.lane), [0, 1, 0, 1])
    XCTAssertEqual(r[0].parents, [0, 1])
    XCTAssertEqual(r[1].converging, [1])
    XCTAssertEqual(r[1].passing, [0])
    XCTAssertEqual(r[1].parents, [1])
    XCTAssertEqual(r[2].passing, [1])
    XCTAssertEqual(r[2].parents, [1], "B joins the lane already waiting for A")
    XCTAssertEqual(r[3].converging, [1])
    XCTAssertEqual(r[3].parents, [])
    XCTAssertEqual(r.map(\.width), [2, 2, 2, 2])
  }

  func testParsesRefsAndHead() throws {
    let s = CommitGraph.separator
    let line = ["abc", "p1 p2", "HEAD -> main, origin/main, tag: v1", "Ann", "2 days ago", "Merge x"].joined(separator: s)
    let commit = try XCTUnwrap(CommitGraph.parse(Substring(line)))
    XCTAssertEqual(commit.parents, ["p1", "p2"])
    XCTAssertEqual(commit.refs, ["main", "origin/main", "tag: v1"])
    XCTAssertTrue(commit.isHead)
    XCTAssertNil(CommitGraph.parse("garbage"))
  }

  func testPagesARealRepositoryAndGatesTheCommand() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let r = CommandRegistry.workbench
    var s = WorkbenchState()
    s.openProject(WorkbenchProject(name: "g", path: root), scanFiles: false)
    XCTAssertThrowsError(try r.execute("git.graph", state: &s).get(), "no graph outside Git")

    for args in [["init", "-q", "-b", "main"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "one"],
                 ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "two"]] {
      XCTAssertTrue(WorkbenchGit.run(root, args).ok, args.joined(separator: " "))
    }
    let first = CommitGraph.page(root, skip: 0, count: 1), rest = CommitGraph.page(root, skip: 1, count: 10)
    XCTAssertEqual(first.map(\.subject), ["two"])
    XCTAssertTrue(first[0].isHead)
    XCTAssertEqual(rest.map(\.subject), ["one"])
    XCTAssertTrue(CommitGraph.show(root, first[0].id).contains("two"))
    XCTAssertEqual(CommitGraph.show(root, "--output=/tmp/x"), "", "only a hex id reaches git")

    let pane = try r.execute("git.graph", state: &s).get()
    XCTAssertEqual(s.tree.leaves.filter { $0.kind == .graph }.count, 1)
    XCTAssertEqual(pane, .pane(s.tree.focused))
    _ = try r.execute("git.graph", state: &s).get()
    XCTAssertEqual(s.tree.leaves.filter { $0.kind == .graph }.count, 1)
  }
}
