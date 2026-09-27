#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import ClairEditorCore
  import ClairWorkspace
  import SwiftUI

  private typealias C = DesignTokens.Color

  /// E15: native Markdown preview of the active file's buffer (unsaved edits included). No WebView or JS
  /// (spec §4, §12): blocks come from `MarkdownPreview.parse`, inline markup from `AttributedString(markdown:)`.
  struct MarkdownPreviewPane: View {
    let buffers: EditorBuffers
    let root: String?
    let path: String?

    var body: some View {
      if let root, let path, MarkdownPreview.isMarkdown(path), case .ready(let m)? = buffers.peek(path) {
        let _ = buffers.edits[path]  // observed: re-render on every edit, not only on save
        // ponytail: reparses the whole buffer per keystroke on the main actor; debounce off-main if big docs lag.
        let blocks = MarkdownPreview.parse(m.buffer.snapshot.string())
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                MarkdownBlockView(block: b.block, root: root, path: path).id(i)
              }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .background(C.canvas)
          .textSelection(.enabled)
          .onChange(of: buffers.topLine[path]) { _, line in
            if let line, let i = MarkdownPreview.block(at: line, in: blocks) { proxy.scrollTo(i, anchor: .top) }
          }
        }
        // Only web/mail links leave the app, in the default browser; relative and custom-scheme links do nothing.
        .environment(\.openURL, OpenURLAction { url in
          if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
          return .handled
        })
      } else {
        Text("Markdown ファイルを開くとプレビューを表示します。")
          .font(.system(size: 12)).foregroundStyle(C.textTertiary)
          .frame(maxWidth: .infinity, maxHeight: .infinity).background(C.canvas)
      }
    }
  }

  private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let root: String
    let path: String

    var body: some View {
      switch block {
      case .heading(let level, let text):
        inline(text).font(.system(size: [26, 21, 17, 15, 13, 12][level - 1], weight: .semibold))
          .foregroundStyle(C.textPrimary).padding(.top, level <= 2 ? 8 : 4)
        if level <= 2 { Rectangle().fill(C.divider).frame(height: 1) }
      case .paragraph(let text):
        inline(text).font(.system(size: 13)).foregroundStyle(C.textSecondary)
      case .listItem(let marker, let depth, let text, let checked):
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if let checked { Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(C.textTertiary) }
          else { Text(marker).foregroundStyle(C.textTertiary) }
          inline(text)
        }
        .font(.system(size: 13)).foregroundStyle(C.textSecondary).padding(.leading, CGFloat(depth) * 18)
      case .code(_, let text):
        ScrollView(.horizontal, showsIndicators: false) {
          Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(C.code).padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.panel, in: RoundedRectangle(cornerRadius: 6))
      case .quote(let text):
        inline(text).font(.system(size: 13)).foregroundStyle(C.textTertiary)
          .padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(C.divider).frame(width: 3) }
      case .table(let header, let rows):
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
          GridRow { ForEach(Array(header.enumerated()), id: \.offset) { inline($1).fontWeight(.semibold) } }
          Divider()
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            GridRow { ForEach(Array(row.enumerated()), id: \.offset) { inline($1) } }
          }
        }
        .font(.system(size: 12)).foregroundStyle(C.textSecondary)
      case .image(let alt, let source):
        if let url = MarkdownPreview.localImage(source, root: root, file: path) {
          AsyncImage(url: url) { image in image.resizable().scaledToFit().frame(maxWidth: 640, alignment: .leading) }
            placeholder: { Text(alt).foregroundStyle(C.textQuaternary) }
            .accessibilityLabel(alt)
        } else {
          // Remote images are never fetched; show what they are instead.
          Label(alt.isEmpty ? source : alt, systemImage: "photo").font(.system(size: 12)).foregroundStyle(C.textQuaternary)
        }
      case .rule:
        Rectangle().fill(C.divider).frame(height: 1)
      }
    }

    private func inline(_ s: String) -> Text {
      let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
      return Text(a)
    }
  }
#endif

#if os(macOS)
  /// CSV / TSV opened in the preview pane as an editable grid. Each committed cell (Return or focus
  /// leaving it) rewrites the buffer as one undo unit, so ⌘Z, dirty and ⌘S work as in the text editor.
  struct TablePane: View {
    let buffers: EditorBuffers
    let path: String
    let onEdit: (String) -> Void
    @State private var rows: [[String]] = []
    @FocusState private var cell: Cell?
    private struct Cell: Hashable { let r: Int, c: Int }

    var body: some View {
      if case .ready(let m)? = buffers.peek(path), let sep = TableFile.separator(path) {
        let edit = buffers.edits[path, default: 0]
        let width = rows.map(\.count).max() ?? 0
        ScrollView([.horizontal, .vertical]) {
         VStack(alignment: .leading, spacing: 0) {
          Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(rows.indices, id: \.self) { r in
              GridRow {
                Text("\(r + 1)").font(.system(size: 10).monospacedDigit()).foregroundStyle(C.textTertiary)
                  .frame(width: 32).contextMenu {
                    Button("上に行を挿入") { mutate(m, sep) { $0.insert(Array(repeating: "", count: width), at: r) } }
                    Button("下に行を挿入") { mutate(m, sep) { $0.insert(Array(repeating: "", count: width), at: r + 1) } }
                    Button("行を削除") { mutate(m, sep) { $0.remove(at: r) } }
                  }
                ForEach(0..<width, id: \.self) { c in
                  TextField("", text: binding(r, c))
                    .textFieldStyle(.plain).font(.system(size: 12, weight: r == 0 ? .semibold : .regular))
                    .focused($cell, equals: Cell(r: r, c: c))
                    .onSubmit { commit(m, sep) }
                    .padding(.horizontal, 6).padding(.vertical, 4).frame(minWidth: 90, maxWidth: 240, alignment: .leading)
                    .border(C.textTertiary.opacity(0.2), width: 0.5)
                }
              }
            }
          }
          .padding(12)
          HStack {
            Button("行を追加") { mutate(m, sep) { $0.append(Array(repeating: "", count: max(width, 1))) } }
            Button("列を追加") { mutate(m, sep) { rs in for i in rs.indices { rs[i].append("") } } }
          }
          .buttonStyle(.borderless).font(.system(size: 11)).padding(.horizontal, 12).padding(.bottom, 12)
         }
        }
        .defaultScrollAnchor(.topLeading)
        .background(C.canvas)
        .onAppear { reload(m, sep) }
        .onChange(of: edit) { _, _ in if cell == nil { reload(m, sep) } }  // outside edits land when no cell is being typed in
        .onChange(of: cell) { old, _ in if old != nil { commit(m, sep) } }
      } else {
        Text("CSV / TSV ファイルを開くと表で編集できます。")
          .font(.system(size: 12)).foregroundStyle(C.textTertiary)
          .frame(maxWidth: .infinity, maxHeight: .infinity).background(C.canvas)
      }
    }

    private func binding(_ r: Int, _ c: Int) -> Binding<String> {
      Binding(get: { r < rows.count && c < rows[r].count ? rows[r][c] : "" }, set: { v in
        guard r < rows.count else { return }
        while rows[r].count <= c { rows[r].append("") }  // ragged rows grow only when typed into
        rows[r][c] = v
      })
    }

    private func reload(_ m: EditorTransactionManager, _ sep: Character) {
      rows = TableFile.parse(m.buffer.snapshot.string(), separator: sep)
    }

    private func mutate(_ m: EditorTransactionManager, _ sep: Character, _ f: (inout [[String]]) -> Void) {
      f(&rows); commit(m, sep)
    }

    private func commit(_ m: EditorTransactionManager, _ sep: Character) {
      let snap = m.buffer.snapshot, old = snap.string()
      let text = TableFile.serialize(rows, separator: sep, lineEnding: old.contains("\r\n") ? "\r\n" : "\n",
                                     trailingNewline: old.isEmpty || old.hasSuffix("\n"))
      // Re-serializing an untouched file may still normalize quoting; only a real cell change writes.
      guard rows != TableFile.parse(old, separator: sep) else { return }
      guard (try? m.apply([TextEdit(range: snap.fullRange, replacement: text)], label: "表の編集")) != nil else { return }
      buffers.refresh(path); buffers.edited(path); onEdit(path)
    }
  }
#endif
