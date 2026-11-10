#if os(macOS)
import SwiftUI
import ClairDesignSystem

/// The sidebar's one design system: every panel (explorer, changes, file browser, sessions, concierge,
/// TODO, debug) builds its rows, headings and empty states from these, so geometry and type match.
/// Geometry: an 8pt inset, a rounded 28pt row with 8pt inner padding (text starts at 16pt), 12pt per level.
enum SidebarStyle {
  static let rowHeight: CGFloat = 28
  static let inset: CGFloat = 8
  static let indent: CGFloat = 12
  /// Where a row's text (and every heading) starts: inset + inner padding.
  static let lead: CGFloat = 16
  static let title = Font.system(size: 13)
  static let titleStrong = Font.system(size: 13, weight: .semibold)
  static let detail = Font.system(size: 11)
  static let heading = Font.system(size: 11, weight: .semibold)
}

/// A row: inset, rounded, hover wash, glass-aware selection. `trailing` sits over the row (not inside the
/// Button label, where the row's click would swallow it) and gets the hover state; hover lives here, so
/// pointer motion re-renders one row, not the list.
struct SidebarRow<Content: View, Trailing: View>: View {
  let depth: Int
  let selected: Bool
  let height: CGFloat?
  let action: () -> Void
  let content: () -> Content
  let trailing: (_ hovered: Bool) -> Trailing
  @State private var hovered = false
  @Environment(\.clairGlass) private var glass

  init(depth: Int = 0, selected: Bool = false, height: CGFloat? = SidebarStyle.rowHeight, action: @escaping () -> Void,
              @ViewBuilder content: @escaping () -> Content, @ViewBuilder trailing: @escaping (_ hovered: Bool) -> Trailing = { _ in EmptyView() }) {
    self.depth = depth; self.selected = selected; self.height = height; self.action = action; self.content = content; self.trailing = trailing
  }

  var body: some View {
    ZStack(alignment: .trailing) {
      Button(action: action) {
        HStack(spacing: 8, content: content)
          .font(SidebarStyle.title)
          .padding(.leading, SidebarStyle.lead - SidebarStyle.inset + CGFloat(depth) * SidebarStyle.indent)
          .padding(.trailing, SidebarStyle.lead - SidebarStyle.inset)
          .padding(.vertical, height == nil ? 6 : 0)
          .frame(height: height)
          .frame(maxWidth: .infinity, alignment: .leading)
          .sidebarSelection(selected)
          .contentShape(Rectangle())
      }.buttonStyle(.hoverWash)
      HStack(spacing: 8) { trailing(hovered) }.padding(.trailing, SidebarStyle.lead - SidebarStyle.inset)
    }
    .padding(.horizontal, SidebarStyle.inset)
    // Glass: one hairline guide per level, under each ancestor's chevron (canvas Tokens `GLASS の中身`).
    .background(alignment: .leading) {
      if glass, depth > 0 {
        HStack(spacing: SidebarStyle.indent - 1) {
          ForEach(0..<depth, id: \.self) { _ in Rectangle().fill(DesignTokens.Glass.guide).frame(width: 1) }
        }.padding(.leading, SidebarStyle.lead + 5)
      }
    }
    .onHover { hovered = $0 }
  }
}

/// The disclosure chevron every collapsible row and heading uses.
struct SidebarChevron: View {
  let open: Bool
  init(open: Bool) { self.open = open }
  var body: some View {
    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(DesignTokens.Color.textTertiary)
      .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
  }
}

/// A section heading: 11pt semibold tertiary at the row text's x. With `open`, it folds its section.
struct SidebarHeading<Accessory: View>: View {
  let title: String
  let open: Binding<Bool>?
  let accessory: Accessory
  init(_ title: String, open: Binding<Bool>? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
    self.title = title; self.open = open; self.accessory = accessory()
  }
  var body: some View {
    HStack(spacing: 6) {
      Button { open?.wrappedValue.toggle() } label: {
        HStack(spacing: 4) {
          if let open { SidebarChevron(open: open.wrappedValue) }
          Text(title).font(SidebarStyle.heading).foregroundStyle(DesignTokens.Color.textTertiary).lineLimit(1)
          Spacer(minLength: 0)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(open == nil)
      accessory.font(SidebarStyle.detail).foregroundStyle(DesignTokens.Color.textQuaternary)
    }
    .padding(.leading, open == nil ? SidebarStyle.lead : SidebarStyle.lead - 14).padding(.trailing, SidebarStyle.lead)
    .padding(.top, 12).padding(.bottom, 4)
    .accessibilityAddTraits(.isHeader)
  }
}

/// Empty / loading / hint text inside a section.
struct SidebarNote: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(SidebarStyle.detail).foregroundStyle(DesignTokens.Color.textQuaternary).lineSpacing(2)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, SidebarStyle.lead).padding(.vertical, 6)
  }
}

/// An icon + label command row (設定を開く, ボード, …).
struct SidebarAction: View {
  let title: String
  let systemImage: String
  let action: () -> Void
  init(_ title: String, systemImage: String, action: @escaping () -> Void) {
    self.title = title; self.systemImage = systemImage; self.action = action
  }
  var body: some View {
    SidebarRow(action: action) {
      Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(DesignTokens.Color.textTertiary).frame(width: 16)
      Text(title).foregroundStyle(DesignTokens.Color.textSecondary).lineLimit(1)
      Spacer(minLength: 0)
    }
  }
}
#endif
