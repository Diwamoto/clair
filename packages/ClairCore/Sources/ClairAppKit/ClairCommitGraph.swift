#if os(macOS)
  import ClairDesignSystem
  import ClairWorkspace
  import SwiftUI

  private typealias C = DesignTokens.Color

  /// V17: branch/merge history as a lane graph; the selected commit opens full-pane as a per-file diff.
  /// Pages of `pageSize` commits load off the main actor as the list scrolls to its end.
  struct CommitGraphPane: View {
    let root: String
    @State private var graph = CommitGraph()
    @State private var loading = false
    @State private var exhausted = false
    @State private var selected: String?
    @State private var files: [(path: String, model: DiffView.Model)] = []
    @State private var file = 0
    @State private var loadingFiles = false

    nonisolated static let pageSize = 400
    private static let laneWidth: CGFloat = 12
    private static let rowHeight: CGFloat = 22
    private static let lanePalette: [Color] = [C.debugBlue, C.codeString, C.codeKeyword, C.codeType, C.codeFunc, C.codeNumber, C.danger]

    var body: some View {
      if !FileManager.default.fileExists(atPath: root + "/.git") {
        Text("Git リポジトリではありません。").font(.system(size: 12)).foregroundStyle(C.textTertiary)
          .frame(maxWidth: .infinity, maxHeight: .infinity).background(C.canvas)
      } else {
        Group { if let selected { detailView(selected) } else { list } }
        .background(C.canvas)
        .task(id: root) {
          graph = CommitGraph(); exhausted = false; selected = nil; files = []
          await loadMore()
        }
      }
    }

    private var list: some View {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(graph.rows.enumerated()), id: \.offset) { i, row in
            rowView(row)
              .onAppear { if i == graph.rows.count - 1 { Task { await loadMore() } } }
          }
          if loading { ProgressView().controlSize(.small).padding(8) }
          if graph.rows.isEmpty, exhausted { Text("コミットがありません").font(.system(size: 12)).foregroundStyle(C.textTertiary).padding(12) }
        }
      }
    }

    private func rowView(_ row: GraphRow) -> some View {
      let c = row.commit
      let on = c.id == selected
      return HStack(spacing: 8) {
        lanes(row).frame(width: CGFloat(row.width) * Self.laneWidth, height: Self.rowHeight)
        Text(c.id.prefix(8)).font(.system(size: 11, design: .monospaced)).foregroundStyle(C.textQuaternary)
        ForEach(c.refs, id: \.self) { ref in
          Text(ref).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            .foregroundStyle(ref.hasPrefix("tag: ") ? C.codeType : C.textPrimary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(C.surfaceActive, in: RoundedRectangle(cornerRadius: 4))
        }
        Text(c.subject).font(.system(size: 12, weight: c.isHead ? .semibold : .regular)).lineLimit(1)
          .foregroundStyle(on ? C.textPrimary : C.textSecondary)
        Spacer(minLength: 8)
        Text("\(c.author) · \(c.date)").font(.system(size: 11)).lineLimit(1).foregroundStyle(C.textQuaternary)
      }
      .padding(.horizontal, 8).frame(height: Self.rowHeight)
      .background(on ? C.surfaceActive : .clear)
      .contentShape(Rectangle())
      .onTapGesture { open(c.id) }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
    }

    private func lanes(_ row: GraphRow) -> some View {
      Canvas { ctx, size in
        let w = Self.laneWidth, h = size.height, mid = h / 2
        func x(_ lane: Int) -> CGFloat { CGFloat(lane) * w + w / 2 }
        func color(_ lane: Int) -> Color { Self.lanePalette[lane % Self.lanePalette.count] }
        func line(_ from: CGPoint, _ to: CGPoint, _ lane: Int) {
          var p = Path()
          p.move(to: from)
          if from.x == to.x { p.addLine(to: to) } else { p.addCurve(to: to, control1: CGPoint(x: from.x, y: (from.y + to.y) / 2), control2: CGPoint(x: to.x, y: (from.y + to.y) / 2)) }
          ctx.stroke(p, with: .color(color(lane)), lineWidth: 1.5)
        }
        let node = CGPoint(x: x(row.lane), y: mid)
        for l in row.passing { line(CGPoint(x: x(l), y: 0), CGPoint(x: x(l), y: h), l) }
        for l in row.converging { line(CGPoint(x: x(l), y: 0), node, l) }
        for l in row.parents { line(node, CGPoint(x: x(l), y: h), l) }
        let r: CGFloat = row.commit.isHead ? 4.5 : 3.5
        ctx.fill(Path(ellipseIn: CGRect(x: node.x - r, y: mid - r, width: r * 2, height: r * 2)), with: .color(color(row.lane)))
        if row.commit.isHead {
          ctx.stroke(Path(ellipseIn: CGRect(x: node.x - r - 2, y: mid - r - 2, width: r * 2 + 4, height: r * 2 + 4)), with: .color(C.textPrimary), lineWidth: 1)
        }
      }
    }

    private func detailView(_ id: String) -> some View {
      let subject = graph.rows.first { $0.commit.id == id }?.commit.subject ?? ""
      return HStack(spacing: 0) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            Button { selected = nil } label: { Label("グラフに戻る", systemImage: "chevron.left") }
              .buttonStyle(.hoverWash).font(.system(size: 12)).foregroundStyle(C.textSecondary).padding(8)
            Text(subject).font(.system(size: 12, weight: .semibold)).foregroundStyle(C.textPrimary)
              .lineLimit(3).padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(Array(files.enumerated()), id: \.offset) { i, f in
              Text(f.path).font(.system(size: 12)).lineLimit(1).truncationMode(.head)
                .foregroundStyle(i == file ? C.textPrimary : C.textSecondary)
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(i == file ? C.surfaceActive : .clear)
                .contentShape(Rectangle()).onTapGesture { file = i }
                .help(f.path).accessibilityAddTraits(.isButton)
            }
          }
        }
        .frame(width: 220).background(C.panel)
        if files.indices.contains(file) {
          let f = files[file]
          DiffView(
            target: DiffTarget(path: f.path, staged: false, untracked: false), model: f.model,
            threads: [:], suggestions: [], onComment: { _, _, _ in }, onSuggest: { _, _ in },
            onResolve: { _ in }, onApply: { _ in nil }, onReject: { _ in }, onSend: nil,
            onClose: { selected = nil }, editor: nil, onSave: nil, isDirty: false,
            label: String(id.prefix(8)), commentable: false)
          .id(f.path)
        } else if loadingFiles {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Text("差分はありません。").font(.system(size: 12)).foregroundStyle(C.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }

    private func loadMore() async {
      guard !loading, !exhausted else { return }
      loading = true
      let root = root, skip = graph.rows.count
      let page = await Task.detached(priority: .userInitiated) { CommitGraph.page(root, skip: skip, count: Self.pageSize) }.value
      loading = false
      guard root == self.root, skip == graph.rows.count else { return }
      graph.append(page)
      exhausted = page.count < Self.pageSize
    }

    private func open(_ id: String) {
      selected = id
      files = []; file = 0; loadingFiles = true
      let root = root
      Task {
        let loaded = await Task.detached(priority: .userInitiated) {
          CommitGraph.files(root, id).map { (path: $0.path, model: DiffView.model($0.patch)) }
        }.value
        guard selected == id else { return }
        files = loaded; loadingFiles = false
      }
    }
  }
#endif
