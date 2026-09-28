import CoreGraphics
import XCTest

@testable import ClairWorkspace

final class MermaidDiagramTests: XCTestCase {
  func testParsesFlowchartNodesShapesAndEdges() throws {
    let d = MermaidDiagram.parse("""
      flowchart LR
        %% comment
        A[Start] -->|go| B{OK?}
        B -- yes --> C((Done)); B -.-> A
        style A fill:#f9f
      """)
    guard case .flowchart(let f) = d else { return XCTFail("\(String(describing: d))") }
    XCTAssertEqual(f.direction, "LR")
    XCTAssertEqual(f.nodes.map(\.id), ["A", "B", "C"])
    XCTAssertEqual(f.nodes.map(\.label), ["Start", "OK?", "Done"])
    XCTAssertEqual(f.nodes.map(\.shape), [.rect, .diamond, .circle])
    XCTAssertEqual(f.edges.map { "\($0.from)>\($0.to):\($0.label ?? "")" }, ["A>B:go", "B>C:yes", "B>A:"])
    XCTAssertTrue(f.edges[2].dashed)
  }

  func testLayoutRanksTopDownAndIgnoresBackEdges() throws {
    guard case .flowchart(let f)? = MermaidDiagram.parse("graph TD\nA-->B\nB-->C\nC-->A\nA-->D") else { return XCTFail() }
    let l = MermaidDiagram.layout(f, measure: { _ in CGSize(width: 10, height: 10) })
    let y = Dictionary(uniqueKeysWithValues: l.nodes.map { ($0.node.id, $0.frame.midY) })
    XCTAssertLessThan(y["A"]!, y["B"]!)
    XCTAssertLessThan(y["B"]!, y["C"]!)
    XCTAssertEqual(y["B"], y["D"])
    XCTAssertEqual(l.edges.count, 4)
    for n in l.nodes { XCTAssertTrue(CGRect(origin: .zero, size: l.size).contains(n.frame)) }
  }

  func testParsesSequenceDiagram() {
    let d = MermaidDiagram.parse("""
      sequenceDiagram
        participant A as Alice
        A->>B: Hello
        B-->>A: Hi
        Note over A,B: done
        loop every minute
        A-)B: ping
        end
      """)
    guard case .sequence(let s) = d else { return XCTFail() }
    XCTAssertEqual(s.participants.map(\.label), ["Alice", "B"])
    XCTAssertEqual(s.steps, [
      .message(from: "A", to: "B", text: "Hello", dashed: false, arrow: true),
      .message(from: "B", to: "A", text: "Hi", dashed: true, arrow: true),
      .note(over: ["A", "B"], side: "over", text: "done"),
      .message(from: "A", to: "B", text: "ping", dashed: false, arrow: false),
    ])
  }

  func testUnsupportedTypeIsNil() {
    XCTAssertNil(MermaidDiagram.parse("pie title Pets\n\"Dogs\" : 3"))
    XCTAssertNil(MermaidDiagram.parse(""))
  }
}
