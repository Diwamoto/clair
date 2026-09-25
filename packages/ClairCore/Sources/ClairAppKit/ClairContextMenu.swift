#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import SwiftUI

  private typealias C = DesignTokens.Color
  private typealias L = DesignTokens.Line

  // Clair's own context menu, ported from the Workbench (`contextMenu.tsx`, ContextMenu
  // artboard): the CONTROLS card says "nativeを混ぜない", so no NSMenu. Overlay material
  // without a scrim, 26pt rows inside 4pt padding, hover = surfaceActive, destructive last
  // in semibold (never red), opens in 90ms from the corner nearest the pointer.
  // ponytail: keyboard nav covers the top panel only, and the right-clicked row wears no ring.

  struct ClairMenuItem {
    var label: String
    var shortcut: String? = nil
    var disabled = false
    var destructive = false
    var submenu: [ClairMenuEntry]? = nil
    var run: () -> Void = {}
  }

  enum ClairMenuEntry {
    case item(ClairMenuItem)
    case separator

    static func item(
      _ label: String, shortcut: String? = nil, disabled: Bool = false, destructive: Bool = false,
      submenu: [ClairMenuEntry]? = nil, run: @escaping () -> Void = {}
    ) -> ClairMenuEntry {
      .item(ClairMenuItem(label: label, shortcut: shortcut, disabled: disabled, destructive: destructive, submenu: submenu, run: run))
    }

    fileprivate var selectable: Bool { if case .item(let i) = self { !i.disabled } else { false } }
  }

  /// A menu that acts on one object shows its name (and path) on top.
  struct ClairMenuSpec {
    var title: String? = nil
    var sub: String? = nil
    var entries: [ClairMenuEntry]
  }

  /// Name prompt (with `initial`) or a plain confirmation (without).
  struct ClairDialog {
    var title: String
    var message: String? = nil
    var initial: String? = nil
    var confirm: String = "OK"
    var destructive = false
    var onConfirm: (String) -> Void
  }

  @MainActor @Observable final class ClairMenuController {
    fileprivate struct Open { let id = UUID(); let spec: ClairMenuSpec; let at: CGPoint }
    fileprivate var menu: Open?
    fileprivate var dialog: ClairDialog?

    func open(_ spec: ClairMenuSpec, at point: CGPoint) { menu = Open(spec: spec, at: point) }
    func ask(_ dialog: ClairDialog) { menu = nil; self.dialog = dialog }
    fileprivate func close() { menu = nil }
  }

  extension View {
    /// Right-click (or control-click) opens a Clair menu built at click time.
    func clairContextMenu(_ controller: ClairMenuController, _ build: @escaping () -> ClairMenuSpec) -> some View {
      overlay(RightClickCatcher { controller.open(build(), at: $0) })
    }

    /// Hosts the open menu and dialog above this view; attach once at the window root.
    func clairMenuHost(_ controller: ClairMenuController) -> some View {
      overlay {
        if let open = controller.menu {
          MenuLayer(open: open, close: controller.close).id(open.id)
        } else if let dialog = controller.dialog {
          DialogLayer(dialog: dialog) { controller.dialog = nil }
        }
      }
    }
  }

  /// Transparent to everything except the right mouse button, so rows keep their left-click and hover.
  private struct RightClickCatcher: NSViewRepresentable {
    let action: (CGPoint) -> Void
    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
      var action: ((CGPoint) -> Void)?
      override func hitTest(_ point: NSPoint) -> NSView? {
        guard let e = NSApp.currentEvent,
          e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
        else { return nil }
        return super.hitTest(point)
      }
      override func rightMouseDown(with event: NSEvent) { report(event) }
      override func mouseDown(with event: NSEvent) { report(event) }
      /// Window content coordinates, top-left origin — SwiftUI's `.global` space.
      private func report(_ event: NSEvent) {
        guard let content = window?.contentView else { return }
        var p = content.convert(event.locationInWindow, from: nil)
        if !content.isFlipped { p.y = content.bounds.height - p.y }
        action?(p)
      }
    }
  }

  private let pad: CGFloat = 4
  private let margin: CGFloat = 8

  private struct MenuLayer: View {
    let open: ClairMenuController.Open
    let close: () -> Void
    @State private var size: CGSize?
    @State private var shown = false
    @FocusState private var focused: Bool
    @State private var active: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      GeometryReader { geo in
        let origin = geo.frame(in: .global).origin
        let x = open.at.x - origin.x, y = open.at.y - origin.y
        let w = size?.width ?? 0, h = size?.height ?? 0
        let flipX = x + w > geo.size.width - margin, flipY = y + h > geo.size.height - margin
        let left = min(max(flipX ? x - w : x, margin), geo.size.width - w - margin)
        let top = min(max(flipY ? y - h : y, margin), geo.size.height - h - margin)
        ZStack(alignment: .topLeading) {
          // Catches the dismissing click so it never lands underneath; a right-click also just closes.
          Color.clear.contentShape(Rectangle()).onTapGesture(perform: close)
            .overlay(RightClickCatcher { _ in close() })
          MenuPanel(spec: open.spec, active: $active, close: close)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
            .scaleEffect(shown || reduceMotion ? 1 : 0.97, anchor: UnitPoint(x: flipX ? 1 : 0, y: flipY ? 1 : 0))
            .opacity(size == nil ? 0 : shown || reduceMotion ? 1 : 0)
            .offset(x: left, y: top)
            .focusable().focusEffectDisabled().focused($focused)
            .onKeyPress(phases: .down) { key in handle(key) }
        }
      }
      .onAppear {
        focused = true
        withAnimation(.timingCurve(0.2, 0, 0, 1, duration: 0.09)) { shown = true }
      }
      .onDisappear { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private func handle(_ key: KeyPress) -> KeyPress.Result {
      let entries = open.spec.entries
      switch key.key {
      case .downArrow, .upArrow:
        let dir = key.key == .downArrow ? 1 : -1, n = entries.count
        var i = active ?? (dir > 0 ? -1 : n)
        for _ in 0..<n {
          i = (i + dir + n) % n
          if entries[i].selectable { active = i; break }
        }
      case .return, .space:
        if let i = active, case .item(let it) = entries[i], !it.disabled, it.submenu == nil { close(); it.run() }
      case .escape: close()
      default: close()
      }
      return .handled
    }
  }

  private struct MenuPanel: View {
    let spec: ClairMenuSpec
    @Binding var active: Int?
    let close: () -> Void
    @State private var sub: Int?

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        if let title = spec.title {
          VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(C.textPrimary)
            if let s = spec.sub {
              Text(s).font(.system(size: 11)).truncationMode(.head).foregroundStyle(C.textQuaternary)
            }
          }
          .lineLimit(1).padding(.horizontal, 8).padding(.vertical, 4)
          rule
        }
        ForEach(Array(spec.entries.enumerated()), id: \.offset) { i, entry in
          switch entry {
          case .separator: rule
          case .item(let it): row(i, it)
          }
        }
      }
      .padding(pad)
      .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
      .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.overlay))
      .overlay(RoundedRectangle(cornerRadius: Radius.overlay).stroke(L.strong))
      .shadow(color: .black.opacity(0.62), radius: 24, y: 18)
      .onHover { if !$0, sub == nil { active = nil } }
    }

    private var rule: some View { Rectangle().fill(L.hairline).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4) }

    private func row(_ i: Int, _ it: ClairMenuItem) -> some View {
      let on = active == i && !it.disabled
      let quiet = it.disabled ? C.textQuaternary : on ? C.textSecondary : C.textQuaternary
      return HStack(spacing: 8) {
        Text(it.label).font(.system(size: 12, weight: it.destructive ? .semibold : .regular))
          .foregroundStyle(it.disabled ? C.textQuaternary : on || it.destructive ? C.textPrimary : C.textSecondary)
          .lineLimit(1)
        Spacer(minLength: 0)
        if let s = it.shortcut { Text(s).font(.system(size: 11).monospacedDigit()).foregroundStyle(quiet).padding(.leading, 12) }
        if it.submenu != nil {
          Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(quiet).padding(.leading, 12)
        }
      }
      .padding(.horizontal, 8).frame(height: 26)
      .background(on ? C.surfaceActive : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
      .contentShape(Rectangle())
      .onTapGesture {
        guard !it.disabled, it.submenu == nil else { return }
        close(); it.run()
      }
      // The submenu shares the row's edge and lines its first row up with this one.
      .overlay(alignment: .topTrailing) {
        if sub == i, let entries = it.submenu, !it.disabled {
          SubPanel(entries: entries, close: close)
            .alignmentGuide(.trailing) { $0[.leading] }
            .offset(x: pad + 1, y: -pad - 1)
        }
      }
      .onHover { inside in
        guard inside else { return }
        active = it.disabled ? nil : i
        sub = it.submenu == nil ? nil : i
      }
    }
  }

  private struct SubPanel: View {
    let entries: [ClairMenuEntry]
    let close: () -> Void
    @State private var active: Int?
    var body: some View { MenuPanel(spec: ClairMenuSpec(entries: entries), active: $active, close: close).fixedSize() }
  }

  /// Same overlay material as the menu, centred, over a light scrim.
  private struct DialogLayer: View {
    let dialog: ClairDialog
    let dismiss: () -> Void
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
      ZStack {
        Color.black.opacity(0.32).contentShape(Rectangle()).onTapGesture(perform: dismiss)
        VStack(alignment: .leading, spacing: 12) {
          Text(dialog.title).font(Typography.font(Typography.title)).foregroundStyle(C.textPrimary)
          if let m = dialog.message { Text(m).font(.system(size: 12)).foregroundStyle(C.textSecondary) }
          if dialog.initial != nil {
            TextField("", text: $text).textFieldStyle(.plain).font(.system(size: 12))
              .foregroundStyle(C.textPrimary)
              .padding(.horizontal, 8).frame(height: 28)
              .background(C.chrome, in: RoundedRectangle(cornerRadius: Radius.control))
              .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(fieldFocused ? L.ring : L.hairline))
              .focused($fieldFocused)
              .onSubmit(confirm)
          }
          HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(action: dismiss) {
              Text("キャンセル").font(.system(size: 12)).foregroundStyle(C.textSecondary).padding(.horizontal, 12).frame(height: 26)
            }.buttonStyle(.hoverWash).keyboardShortcut(.cancelAction)
            Button(action: confirm) {
              Text(dialog.confirm).font(.system(size: 12, weight: .semibold)).foregroundStyle(C.textPrimary)
                .padding(.horizontal, 12).frame(height: 26)
                .background(C.surfaceActive, in: RoundedRectangle(cornerRadius: Radius.card))
            }.buttonStyle(.hoverWash).keyboardShortcut(dialog.initial == nil ? .defaultAction : nil)
          }
        }
        .padding(16).frame(width: 360)
        .background(C.chromeRaised, in: RoundedRectangle(cornerRadius: Radius.overlay))
        .overlay(RoundedRectangle(cornerRadius: Radius.overlay).stroke(L.strong))
        .shadow(color: .black.opacity(0.62), radius: 24, y: 18)
      }
      .onAppear {
        text = dialog.initial ?? ""
        fieldFocused = dialog.initial != nil
      }
    }

    private func confirm() {
      let value = text
      dismiss()
      dialog.onConfirm(value)
    }
  }
#endif
