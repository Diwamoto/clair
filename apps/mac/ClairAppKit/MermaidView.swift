#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import ClairWorkspace
  import SwiftUI

  private typealias C = DesignTokens.Color

  /// A ```mermaid fence drawn natively: `MermaidDiagram` parses and lays it out, a SwiftUI `Canvas` strokes it.
  struct MermaidView: View {
    let diagram: MermaidDiagram

    private static let font = NSFont.systemFont(ofSize: 12)

    private static func measure(_ s: String) -> CGSize {
      let r = (s as NSString).boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin],
                                           attributes: [.font: font])
      return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    var body: some View {
      ScrollView(.horizontal, showsIndicators: false) { canvas }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder var canvas: some View {
      switch diagram {
      case .flowchart(let f): flowchart(MermaidDiagram.layout(f, measure: Self.measure))
      case .sequence(let s): sequence(SequenceLayout(s, measure: Self.measure))
      }
    }

    // MARK: Flowchart

    private func flowchart(_ l: MermaidDiagram.FlowLayout) -> some View {
      Canvas { ctx, _ in
        for e in l.edges {
          line(&ctx, e.start, e.end, via: e.control, dashed: e.edge.dashed, width: e.edge.thick ? 2.5 : 1.2, arrow: e.edge.arrow)
          if let t = e.edge.label {
            label(&ctx, t, at: CGPoint(x: (e.start.x + 2 * e.control.x + e.end.x) / 4, y: (e.start.y + 2 * e.control.y + e.end.y) / 4))
          }
        }
        for n in l.nodes {
          let path = shape(n.node.shape, n.frame)
          ctx.fill(path, with: .color(C.panel))
          ctx.stroke(path, with: .color(C.textTertiary), lineWidth: 1)
          ctx.draw(text(n.node.label, C.textPrimary), at: CGPoint(x: n.frame.midX, y: n.frame.midY))
        }
      }
      .frame(width: l.size.width, height: l.size.height)
      .accessibilityLabel(l.nodes.map(\.node.label).joined(separator: ", "))
    }

    private func shape(_ s: MermaidDiagram.Shape, _ r: CGRect) -> Path {
      switch s {
      case .rect: Path(r)
      case .round: Path(roundedRect: r, cornerRadius: 8)
      case .stadium: Path(roundedRect: r, cornerRadius: r.height / 2)
      case .circle: Path(ellipseIn: r)
      case .diamond:
        Path { p in
          p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
          p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.closeSubpath()
        }
      }
    }

    // MARK: Sequence

    private func sequence(_ l: SequenceLayout) -> some View {
      Canvas { ctx, _ in
        for (i, p) in l.participants.enumerated() {
          let x = l.x[i]
          line(&ctx, CGPoint(x: x, y: l.boxHeight), CGPoint(x: x, y: l.height), dashed: true, width: 1, arrow: false)
          let r = CGRect(x: x - l.boxWidth[i] / 2, y: 0, width: l.boxWidth[i], height: l.boxHeight)
          ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(C.panel))
          ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(C.textTertiary), lineWidth: 1)
          ctx.draw(text(p.label, C.textPrimary), at: CGPoint(x: r.midX, y: r.midY))
        }
        for row in l.rows {
          switch row.step {
          case .message(let from, let to, let t, let dashed, let arrow):
            let a = l.x[l.column(from)], b = l.x[l.column(to)]
            if a == b {  // self message: a small loop to the right
              var p = Path()
              p.move(to: CGPoint(x: a, y: row.y)); p.addLine(to: CGPoint(x: a + 30, y: row.y))
              p.addLine(to: CGPoint(x: a + 30, y: row.y + 14))
              ctx.stroke(p, with: .color(C.textSecondary), style: StrokeStyle(lineWidth: 1.2, dash: dashed ? [4, 3] : []))
              line(&ctx, CGPoint(x: a + 30, y: row.y + 14), CGPoint(x: a, y: row.y + 14), dashed: dashed, width: 1.2, arrow: arrow)
              ctx.draw(text(t, C.textSecondary), at: CGPoint(x: a + 36, y: row.y + 7), anchor: .leading)
            } else {
              line(&ctx, CGPoint(x: a, y: row.y), CGPoint(x: b, y: row.y), dashed: dashed, width: 1.2, arrow: arrow)
              ctx.draw(text(t, C.textSecondary), at: CGPoint(x: (a + b) / 2, y: row.y - 3), anchor: .bottom)
            }
          case .note(let over, _, let t):
            let r = l.noteFrame(over: over, row: row, size: Self.measure(t))
            ctx.fill(Path(r), with: .color(C.surfaceActive))
            ctx.stroke(Path(r), with: .color(C.textTertiary), lineWidth: 1)
            ctx.draw(text(t, C.textPrimary), at: CGPoint(x: r.midX, y: r.midY))
          }
        }
      }
      .frame(width: l.width, height: l.height)
      .accessibilityLabel(l.participants.map(\.label).joined(separator: ", "))
    }

    // MARK: Drawing helpers

    private func text(_ s: String, _ color: Color) -> Text {
      Text(s).font(.system(size: 12)).foregroundColor(color)
    }

    private func label(_ ctx: inout GraphicsContext, _ s: String, at p: CGPoint) {
      let size = Self.measure(s)
      ctx.fill(Path(roundedRect: CGRect(x: p.x - size.width / 2 - 4, y: p.y - size.height / 2 - 1, width: size.width + 8, height: size.height + 2),
                    cornerRadius: 3), with: .color(C.canvas))
      ctx.draw(text(s, C.textSecondary), at: p)
    }

    private func line(_ ctx: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, via c: CGPoint? = nil, dashed: Bool, width: CGFloat, arrow: Bool) {
      var p = Path()
      p.move(to: a)
      if let c { p.addQuadCurve(to: b, control: c) } else { p.addLine(to: b) }
      ctx.stroke(p, with: .color(C.textSecondary), style: StrokeStyle(lineWidth: width, dash: dashed ? [4, 3] : []))
      guard arrow else { return }
      let from = c ?? a, angle = atan2(b.y - from.y, b.x - from.x), len: CGFloat = 8
      var head = Path()
      head.move(to: b)
      head.addLine(to: CGPoint(x: b.x - len * cos(angle - .pi / 7), y: b.y - len * sin(angle - .pi / 7)))
      head.addLine(to: CGPoint(x: b.x - len * cos(angle + .pi / 7), y: b.y - len * sin(angle + .pi / 7)))
      head.closeSubpath()
      ctx.fill(head, with: .color(C.textSecondary))
    }
  }

  /// Columns sized so every message label fits between its two lifelines; one row per step.
  private struct SequenceLayout {
    typealias Step = MermaidDiagram.Sequence.Step
    struct Row { let step: Step; let y: CGFloat }
    let participants: [MermaidDiagram.Sequence.Participant]
    var x: [CGFloat] = [], boxWidth: [CGFloat] = [], rows: [Row] = []
    let boxHeight: CGFloat = 30
    var width: CGFloat = 0, height: CGFloat = 0

    init(_ s: MermaidDiagram.Sequence, measure: (String) -> CGSize) {
      participants = s.participants
      boxWidth = participants.map { measure($0.label).width + 24 }
      var gap = zip(boxWidth, boxWidth.dropFirst()).map { ($0 + $1) / 2 + 30 }  // gap[i]: column i → i+1
      for step in s.steps {
        guard case .message(let from, let to, let t, _, _) = step else { continue }
        let (i, j) = (column(from), column(to))
        let need = measure(t).width + (i == j ? 50 : 24)
        if i == j { if i < gap.count { gap[i] = max(gap[i], need) }; continue }
        let (lo, hi) = (min(i, j), max(i, j))
        let have = gap[lo..<hi].reduce(0, +)
        if have < need { gap[hi - 1] += need - have }
      }
      var cx = (boxWidth.first ?? 0) / 2 + 4
      for i in participants.indices { x.append(cx); if i < gap.count { cx += gap[i] } }
      var y = boxHeight + 30
      for step in s.steps {
        rows.append(Row(step: step, y: y))
        switch step {
        case .message(let f, let t, _, _, _): y += f == t ? 46 : 34
        case .note(_, _, let t): y += measure(t).height + 24
        }
      }
      width = max(cx + (boxWidth.last ?? 0) / 2 + 4, x.enumerated().map { $1 + boxWidth[$0] / 2 }.max() ?? 0) + 60
      height = y
    }

    func column(_ id: String) -> Int { participants.firstIndex { $0.id == id } ?? 0 }

    func noteFrame(over: [String], row: Row, size: CGSize) -> CGRect {
      let cols = over.map(column), w = size.width + 16, h = size.height + 10, top = row.y - 16
      let lo = x[cols.min() ?? 0], hi = x[cols.max() ?? 0]
      guard case .note(_, let side, _) = row.step else { return .zero }
      switch side {
      case "left": return CGRect(x: max(0, lo - w - 10), y: top, width: w, height: h)
      case "right": return CGRect(x: hi + 10, y: top, width: w, height: h)
      default:
        let span = max(w, hi - lo + 40)
        return CGRect(x: (lo + hi) / 2 - span / 2, y: top, width: span, height: h)
      }
    }
  }
#endif
