#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import ClairShared
  import ClairWorkspace
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  /// ADR-0033 / HTMLTools artboard: 標準 + マイツール. A click opens the tool in a pane of its own; dropping `.html`
  /// files anywhere on the panel copies them into `~/.clair/tools` (same name overwrites).
  struct HTMLToolsSidebar: View {
    static let mode = "chevron.left.forwardslash.chevron.right"
    /// The focused pane's tool path, lit in the list.
    let current: String?
    let open: (String) -> Void
    let add: ([String]) -> Void
    let menus: ClairMenuController
    // ponytail: re-read on appear and after this panel's own actions; a `clair tool add` while it is shown lands on the next appear.
    @State private var tools: [HTMLTools.Tool] = []
    @State private var dropping = false

    var body: some View {
      VStack(spacing: 0) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            SidebarHeading(tr("標準"))
            ForEach(tools.filter(\.builtin), id: \.path) { row($0) }
            SidebarHeading(tr("マイツール"))
            ForEach(tools.filter { !$0.builtin }, id: \.path) { row($0) }
            if !tools.contains(where: { !$0.builtin }) { SidebarNote(tr("生成した HTML をここへドロップすると追加されます")) }
          }.padding(.bottom, 8)
        }.clairScroller()
        Text(tr(".html をドロップして追加")).font(SidebarStyle.detail).foregroundStyle(C.textMuted)
          .frame(maxWidth: .infinity).frame(height: 56)
          .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(L.strong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
          .padding(.horizontal, 12).padding(.bottom, 12)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(dropping ? L.ring : .clear, lineWidth: 1).padding(4))
      .dropDestination(for: URL.self) { urls, _ in
        let paths = urls.filter(\.isFileURL).map(\.path).filter(HTMLTools.isHTML)
        guard !paths.isEmpty else { return false }
        add(paths)
        reload()
        return true
      } isTargeted: { dropping = $0 }
      .onAppear(perform: reload)
    }

    private func reload() { tools = HTMLTools.list() }

    private func row(_ tool: HTMLTools.Tool) -> some View {
      let on = current == tool.path
      return SidebarRow(selected: on, action: { open(tool.path) }) {
        Image(systemName: Self.mode).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary).frame(width: 16)
        Text(tool.name).font(Typography.font(on ? Typography.sidebarStrong : Typography.sidebar))
          .foregroundStyle(on ? C.textPrimary : C.textSecondary).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .help(tool.path)
      .clairContextMenu(menus) {
        ClairMenuSpec(title: tool.name, sub: tool.builtin ? tr("Clair に同梱") : tool.path, entries: tool.builtin
          ? [.item(tr("開く")) { open(tool.path) }]
          : [
            .item(tr("開く")) { open(tool.path) },
            .item(tr("Finder で表示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tool.path)]) },
            .separator,
            .item(tr("ゴミ箱に入れる")) {
              try? FileManager.default.trashItem(at: URL(fileURLWithPath: tool.path), resultingItemURL: nil)
              reload()
            },
          ])
      }
    }
  }
#endif
