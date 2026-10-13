#if os(macOS)
  import ClairShared
  import ClairDesignSystem
  import ClairEditorCore
  import ClairEditorLanguage
  import ClairReview
  import SwiftUI

  private typealias C = DesignTokens.Color

  /// The user's own review of one file (spec §6): the file as the editor shows it — one number gutter,
  /// syntax colours — with a comment composer and threads under any line. Deliberately not `DiffView`:
  /// a review has no change to compare, so it carries no old/new gutters, hunks or split.
  struct CodeReviewView: View {
    let lines: [String]
    let highlighted: [AttributedString]
    /// Line → open threads; key 0 holds stale ones (their line's text is gone).
    let threads: [Int: [ReviewThread]]
    let style: EditorStyle
    let onComment: (Int, _ lineText: String, _ body: String) -> Void
    let onResolve: (UUID) -> Void
    @State private var composing: Int?
    @State private var draft = ""
    @State private var hovered: Int?

    nonisolated static let maxLines = 5000

    /// Each line coloured by the editor's tree-sitter highlighter (same token colours as the editor). Off the main actor.
    nonisolated static func highlight(_ lines: [String], path: String) -> [AttributedString] {
      let lines = Array(lines.prefix(maxLines))
      var out = lines.map { AttributedString($0) }
      guard let id = EditorLanguageID.detect(path: path), let h = try? SyntaxHighlighter(languageID: id),
        let snapshot = try? TextBuffer(lines.joined(separator: "\n")).snapshot, let spans = try? h.reset(to: snapshot)
      else { return out }
      var starts: [Int] = [], offset = 0
      for l in lines { starts.append(offset); offset += l.utf8.count + 1 }
      for span in spans + h.bracketSpans {
        let lo = span.range.lowerBound.value, hi = span.range.upperBound.value
        // Last line starting at or before `lo`, then every line the span reaches.
        var a = 0, b = starts.count
        while a < b { let m = (a + b) / 2; if starts[m] <= lo { a = m + 1 } else { b = m } }
        var i = max(a - 1, 0)
        while i < lines.count, starts[i] < hi {
          let s = lines[i], u = s.utf8
          let from = max(lo - starts[i], 0), to = min(hi - starts[i], u.count)
          if from < to, let r = Range(u.index(u.startIndex, offsetBy: from)..<u.index(u.startIndex, offsetBy: to), in: out[i]) {
            out[i][r].foregroundColor = Color(nsColor: span.kind.defaultColor)
          }
          i += 1
        }
      }
      return out
    }

    var body: some View {
      let font = Font(style.font)
      let gutter = (44 * style.size / 12).rounded()
      GeometryReader { viewport in
      ScrollView([.vertical, .horizontal]) {
        LazyVStack(alignment: .leading, spacing: 0) {
          if let stale = threads[0] {
            Text(tr("行が変更されたため位置を特定できないコメント")).font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textTertiary)
              .padding(.horizontal, 12).padding(.vertical, 6)
            ForEach(stale) { thread($0) }
          }
          ForEach(highlighted.indices, id: \.self) { i in
            let n = i + 1
            HStack(spacing: 0) {
              Text("\(n)").font(font).foregroundStyle(composing == n ? C.textSecondary : C.lineNumber)
                .padding(.trailing, 8).frame(width: gutter, alignment: .trailing)
              Text(highlighted[i]).font(font).foregroundStyle(C.code).fixedSize().padding(.leading, 12).padding(.trailing, 24)
            }
            .frame(maxWidth: .infinity, minHeight: style.lineHeight, maxHeight: style.lineHeight, alignment: .leading)
            .background(composing == n ? C.surfaceActive : hovered == n ? C.surfaceHover : .clear)
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? n : (hovered == n ? nil : hovered) }
            .onTapGesture { composing = composing == n ? nil : n; draft = "" }
            .help(tr("クリックしてコメント"))
            ForEach(threads[n] ?? []) { thread($0) }
            if composing == n { composer(n) }
          }
          if lines.count > Self.maxLines {
            Text(tr("ファイルが長いため %@ 行で打ち切りました。", Self.maxLines)).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).padding(12)
          }
        }
        .padding(.vertical, 4).padding(.bottom, 56)  // room under the last line for the floating send button
        .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
        .clairScroller()
      }
      }
      .background(C.canvas)
    }

    private func thread(_ t: ReviewThread) -> some View {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(t.comments) { c in
          Text(c.body).font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary).textSelection(.enabled)
        }
        Button(tr("解決する")) { onResolve(t.id) }.buttonStyle(.hoverWash).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
      }
      .padding(8).frame(maxWidth: 520, alignment: .leading).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card))
      .padding(.leading, 28).padding(.vertical, 4)
    }

    private func composer(_ n: Int) -> some View {
      let submit = {
        if n <= lines.count { onComment(n, lines[n - 1], draft) }
        composing = nil
      }
      return HStack(spacing: 8) {
        TextField(tr("コメント"), text: $draft).textFieldStyle(.plain).font(Typography.font(Typography.chrome)).frame(width: 360)
          .onSubmit(submit)
        Button(tr("追加"), action: submit).buttonStyle(.hoverWash).foregroundStyle(C.textSecondary)
        Button(tr("キャンセル")) { composing = nil }.buttonStyle(.hoverWash).foregroundStyle(C.textTertiary)
      }
      .padding(8).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card)).padding(.leading, 28).padding(.vertical, 4)
    }
  }
#endif
