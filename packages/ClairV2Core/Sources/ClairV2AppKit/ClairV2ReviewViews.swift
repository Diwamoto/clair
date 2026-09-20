#if os(macOS)
  import ClairV2DesignSystem
  import ClairV2Workspace
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  /// U05: which side of a change the diff pane is showing.
  struct DiffTarget: Equatable {
    let path: String
    let staged: Bool
    let untracked: Bool
  }

  /// Source-control sidebar: staged / changes / untracked sections with a stage toggle per row.
  struct ChangesList: View {
    let changes: [GitChange]
    let selected: DiffTarget?
    let onSelect: (DiffTarget) -> Void
    let onToggle: (GitChange, _ staged: Bool) -> Void

    var body: some View {
      if changes.isEmpty {
        VStack(spacing: 4) {
          Text("変更はありません").font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textSecondary)
          Text("working tree はきれいです。").font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary)
        }.frame(maxWidth: .infinity).padding(16)
      } else {
        section("ステージ済み", changes.filter(\.staged)) { DiffTarget(path: $0.path, staged: true, untracked: false) }
        section("変更", changes.filter { $0.unstaged && !$0.untracked }) { DiffTarget(path: $0.path, staged: false, untracked: false) }
        section("未追跡", changes.filter(\.untracked)) { DiffTarget(path: $0.path, staged: false, untracked: true) }
      }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [GitChange], _ target: @escaping (GitChange) -> DiffTarget) -> some View {
      if !rows.isEmpty {
        HStack(spacing: 4) {
          Text(title).font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textTertiary)
          Text("\(rows.count)").font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary)
          Spacer()
        }.padding(.leading, 20).padding(.trailing, 12).frame(height: 26)
        ForEach(rows, id: \.path) { c in
          let t = target(c), on = selected == t
          HStack(spacing: 4) {
            Text(c.path.split(separator: "/").last.map(String.init) ?? c.path)
              .font(Typography.font(Typography.chrome)).lineLimit(1)
              .foregroundStyle(c.untracked ? C.success : on ? C.textPrimary : C.textSecondary)
            Spacer()
            if c.untracked { Text("未追跡").font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary) }
            Button { onToggle(c, !t.staged) } label: {
              Text(t.staged ? "−" : "+").font(Typography.font(Typography.title)).foregroundStyle(C.textTertiary).frame(width: 18, height: 18)
            }.buttonStyle(.plain).help(t.staged ? "ステージを取り消す" : "ステージに追加")
          }
          .padding(.horizontal, 8).frame(height: 26)
          .background(on ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
          .padding(.horizontal, 8).contentShape(Rectangle()).onTapGesture { onSelect(t) }
        }
      }
    }
  }

  /// Unified diff of one file. Colour is only for add/remove (state meaning); hunk headers stay quiet.
  struct DiffView: View {
    let target: DiffTarget
    let text: String
    let onClose: () -> Void
    /// A diff this long is cut with a notice instead of laying out every row.
    static let maxLines = 5000

    private var rows: [Substring] {
      // Skip the file header (diff/index/---/+++); everything from the first @@ is content.
      let all = text.split(separator: "\n", omittingEmptySubsequences: false)
      let body = all.drop { !$0.hasPrefix("@@") }
      return Array((body.isEmpty ? all.filter { $0.hasPrefix("Binary") } : Array(body)).prefix(Self.maxLines))
    }

    var body: some View {
      VStack(spacing: 0) {
        HStack {
          Text(target.path).font(Typography.font(Typography.chromeStrong)).foregroundStyle(C.textPrimary)
          Text(target.staged ? "ステージ済み" : target.untracked ? "未追跡" : "変更").font(Typography.font(Typography.chrome)).foregroundStyle(C.textQuaternary)
          Spacer()
          Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(C.chromeInk) }.buttonStyle(.plain)
        }.padding(.horizontal, 12).frame(height: 32).background(C.chromeRaised)
        if text.isEmpty {
          Text("差分はありません。").font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(rows.enumerated()), id: \.offset) { _, l in
                Text(l.isEmpty ? " " : String(l)).font(.system(size: 12, design: .monospaced))
                  .foregroundStyle(l.hasPrefix("@@") ? C.textQuaternary : C.code)
                  .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 18)
                  .background(l.hasPrefix("+") ? C.success.opacity(0.12) : l.hasPrefix("-") ? C.danger.opacity(0.12) : .clear)
              }
              if rows.count == Self.maxLines {
                Text("差分が長いため \(Self.maxLines) 行で打ち切りました。").font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).padding(12)
              }
            }
          }
        }
      }.background(C.surface)
    }
  }
#endif
