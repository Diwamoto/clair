#if os(macOS)
  import ClairV2DesignSystem
  import ClairV2Workspace
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  /// U04: AppShell chrome (checklist §3) — titlebar 48 + sidebar 286 + main +
  /// status 26. Built once; only sidebar panel and main are swapped. Pane
  /// contents other than the terminal are placeholders owned by U05/U06.
  public struct ClairV2AppShell: View {
    @State private var tree = PaneTree()
    @State private var project = "clair"
    private let projects: [(name: String, color: SwiftUI.Color)] = [
      ("clair", C.debugBlue), ("ccedit", C.success), ("clair-releases", C.attention),
    ]

    public init() {}

    public var body: some View {
      VStack(spacing: 0) {
        titlebar
        HStack(spacing: 0) {
          sidebar
          Rectangle().fill(L.hairline).frame(width: 1)
          main
        }
        statusBar
      }
      .background(C.canvas)
      .frame(minWidth: 900, minHeight: 560)
      .background(shortcuts)
    }

    private var titlebar: some View {
      HStack(spacing: 8) {
        HStack(spacing: 8) {
          ForEach([C.close, C.minimize, C.zoom], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
        }
        .padding(.trailing, 12)
        ForEach(projects, id: \.name) { p in
          Button { project = p.name } label: {
            Text(p.name).font(Typography.font(Typography.chromeStrong))
              .foregroundStyle(C.textPrimary)
              .padding(.horizontal, 10).frame(height: 26)
              .background(p.color.opacity(project == p.name ? 0.22 : 0.14), in: RoundedRectangle(cornerRadius: Radius.card))
              .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(p.color.opacity(project == p.name ? 0.55 : 0.28)))
          }.buttonStyle(.plain)
        }
        Spacer()
      }
      .padding(.horizontal, 16)
      .frame(height: ChromeBudget.titlebar)
      .background(C.chrome)
      .overlay(alignment: .bottom) { Rectangle().fill(L.chrome).frame(height: 1) }
    }

    private var sidebar: some View {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          ForEach(["folder", "shield", "bell", "ladybug"], id: \.self) {
            Image(systemName: $0).font(.system(size: 13)).foregroundStyle(C.chromeInkMuted)
          }
          Spacer()
        }
        .padding(.horizontal, 12).frame(height: ChromeBudget.sidebarStrip)
        Rectangle().fill(L.hairline).frame(height: 1)
        Text("Explorer").font(Typography.font(Typography.micro)).foregroundStyle(C.textQuaternary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        Spacer()
      }
      .frame(width: 286)
      .background(C.chromeRaised)
    }

    private var main: some View {
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          ForEach(tree.leaves, id: \.id) { leaf in
            Text("\(leaf.kind.rawValue) \(leaf.id)")
              .font(Typography.font(Typography.chrome)).foregroundStyle(C.textSecondary)
              .padding(.horizontal, 12).frame(width: 168, height: 32, alignment: .leading)
              .background(leaf.id == tree.focused ? C.surfaceActive : .clear)
              .onTapGesture { tree.focus(leaf.id) }
          }
          Spacer(minLength: 0)
        }
        .background(C.chromeRaised)
        PaneView(node: tree.maximized.flatMap { id in tree.leaves.first { $0.id == id }.map { .leaf(id: $0.id, kind: $0.kind) } } ?? tree.root, focused: tree.focused) { tree.focus($0) }
      }
    }

    private var statusBar: some View {
      HStack {
        Text("Ln 1, Col 1").font(Typography.font(Typography.chrome, family: .mono)).foregroundStyle(C.chromeInkMuted)
        Spacer()
      }
      .padding(.horizontal, 12).frame(height: ChromeBudget.statusBar)
      .background(C.chrome)
      .overlay(alignment: .top) { Rectangle().fill(L.chrome).frame(height: 1) }
    }

    /// ⌃⌘D / ⌃⌘⇧D split, ⌃⌘W close, ⌃⌘M maximize, ⌃⌘= equalize, ⌃⌘→ focus next.
    private var shortcuts: some View {
      Group {
        Button("") { tree.splitFocused(.horizontal) }.keyboardShortcut("d", modifiers: [.control, .command])
        Button("") { tree.splitFocused(.vertical) }.keyboardShortcut("d", modifiers: [.control, .command, .shift])
        Button("") { tree.closeFocused() }.keyboardShortcut("w", modifiers: [.control, .command])
        Button("") { tree.toggleMaximize() }.keyboardShortcut("m", modifiers: [.control, .command])
        Button("") { tree.equalize() }.keyboardShortcut("=", modifiers: [.control, .command])
        Button("") { tree.focusNext() }.keyboardShortcut(.rightArrow, modifiers: [.control, .command])
      }.opacity(0).frame(width: 0, height: 0)
    }
  }

  private struct PaneView: View {
    let node: PaneTree.Node
    let focused: Int
    let onFocus: (Int) -> Void

    @ViewBuilder
    private func parts(_ axis: PaneTree.Axis, _ total: CGFloat, _ a: PaneTree.Node, _ b: PaneTree.Node, ratio: Double) -> some View {
      let h = axis == .horizontal
      PaneView(node: a, focused: focused, onFocus: onFocus)
        .frame(width: h ? total * ratio : nil, height: h ? nil : total * ratio)
      Rectangle().fill(L.paneDivider).frame(width: h ? 1 : nil, height: h ? nil : 1)
      PaneView(node: b, focused: focused, onFocus: onFocus)
    }

    var body: some View {
      switch node {
      case .leaf(let id, let kind):
        ZStack {
          C.surface
          if kind == .terminal { ClairV2GhosttySurface() }  // ponytail: one surface per terminal leaf; session binding is U06
          else { Text(kind.rawValue).foregroundStyle(C.textMuted) }  // editor/agent content: U05/U06
        }
        .overlay(Rectangle().stroke(id == focused ? L.ring : .clear))
        .onTapGesture { onFocus(id) }
      case .split(let axis, let ratio, let a, let b):
        GeometryReader { g in
          let total = axis == .horizontal ? g.size.width : g.size.height
          if axis == .horizontal {
            HStack(spacing: 0) { parts(axis, total, a, b, ratio: ratio) }
          } else {
            VStack(spacing: 0) { parts(axis, total, a, b, ratio: ratio) }
          }
        }
      }
    }
  }
#endif
