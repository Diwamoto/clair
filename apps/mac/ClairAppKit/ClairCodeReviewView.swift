#if os(macOS)
  import ClairShared
  import ClairDesignSystem
  import ClairEditorCore
  import ClairEditorLanguage
  import ClairEditorView
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
    /// The clicked line: highlighted, with the composer (or, once it closes, a "+" that reopens it) under it.
    @State private var selected: Int?
    @State private var composing: Int?
    @State private var draft = ""
    @FocusState private var field: Bool

    nonisolated static let maxLines = 5000

    /// Each line coloured by the editor's tree-sitter highlighter (same token colours as the editor). Off the main actor.
    nonisolated static func highlight(_ lines: [String], path: String) -> [AttributedString] {
      let lines = Array(lines.prefix(maxLines))
      var out = lines.map(flagged)
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

    /// `text` with the editor's suspicious-character underline (homoglyphs, invisible and control characters).
    nonisolated static func flagged(_ text: String) -> AttributedString {
      var out = AttributedString(text)
      for r in suspiciousCharacterRanges(in: text) {
        guard let range = Range(r, in: out) else { continue }
        out[range].underlineStyle = Text.LineStyle(pattern: .solid, color: .red)
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
              Text("\(n)").font(font).foregroundStyle(selected == n ? C.textSecondary : C.lineNumber)
                .padding(.trailing, 8).frame(width: gutter, alignment: .trailing)
              Text(highlighted[i]).font(font).foregroundStyle(C.code).fixedSize().padding(.leading, 12).padding(.trailing, 24)
            }
            .frame(maxWidth: .infinity, minHeight: style.lineHeight, maxHeight: style.lineHeight, alignment: .leading)
            .background(selected == n ? C.surfaceActive : .clear)
            .contentShape(Rectangle())
            // A click opens the composer; clicking its line again folds it back to the "+".
            .onTapGesture { if composing == n { composing = nil } else { selected = n; composing = n; draft = "" } }
            if composing == n { composer(n) } else if selected == n { addButton(n, indent: gutter + 12) }
            ForEach(threads[n] ?? []) { thread($0) }
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

    private func addButton(_ n: Int, indent: CGFloat) -> some View {
      Button { composing = n; draft = "" } label: {
        HStack(spacing: 4) {
          Image(systemName: "plus").font(.system(size: 10, weight: .bold))
          Text(tr("コメント")).font(Typography.font(Typography.chrome))
        }
        .foregroundStyle(C.textSecondary).padding(.horizontal, 8).frame(height: 22)
        .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.control))
      }
      .buttonStyle(.hoverWash).accessibilityLabel(tr("%@ 行目にコメント", n))
      .padding(.leading, indent).padding(.vertical, 3)
    }

    private func composer(_ n: Int) -> some View {
      let submit = {
        if n <= lines.count { onComment(n, lines[n - 1], draft) }
        composing = nil
      }
      return HStack(spacing: 8) {
        TextField(tr("コメント"), text: $draft).textFieldStyle(.plain).font(Typography.font(Typography.chrome)).frame(width: 360)
          .focused($field).onSubmit(submit)
          .task { await focusField { field = true } }
        Button(tr("追加"), action: submit).buttonStyle(.hoverWash).foregroundStyle(C.textSecondary)
        Button(tr("キャンセル")) { composing = nil }.buttonStyle(.hoverWash).foregroundStyle(C.textTertiary)
      }
      .padding(8).background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.card)).padding(.leading, 28).padding(.vertical, 4)
    }
  }
#endif
