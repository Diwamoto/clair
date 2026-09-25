#if os(macOS)
  import AppKit
  import ClairDesignSystem
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
