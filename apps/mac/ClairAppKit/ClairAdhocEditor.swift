#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import SwiftUI

  /// An ad-hoc file (outside every open Project and Git repository, `WorkbenchState.adhocFile`) opens in its own
  /// window with just the editor: no Project, explorer or terminal. One window per file; reopening focuses it.
  // ponytail: no LSP/blame context beyond the file's folder, no tabs; promote to a Project with `project.open` if needed.
  @MainActor final class AdhocEditorWindow: NSObject, NSWindowDelegate {
    private static var open: [String: AdhocEditorWindow] = [:]

    static func show(_ file: String, line: Int?) {
      let w = open[file] ?? AdhocEditorWindow(file)
      open[file] = w
      if let line { w.buffers.reveal(w.name, line: line) }
      w.window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }

    private let file: String
    private let root: String
    private let name: String
    private let buffers = EditorBuffers()
    private let window: NSWindow

    private init(_ file: String) {
      self.file = file
      let url = URL(fileURLWithPath: file)
      root = url.deletingLastPathComponent().path
      name = url.lastPathComponent
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
      super.init()
      window.isReleasedWhenClosed = false
      window.title = name
      window.representedURL = url  // proxy icon + ⌘-click path menu, like any macOS document window
      window.delegate = self
      window.contentView = NSHostingView(rootView: AdhocEditorView(buffers: buffers, root: root, name: name, owner: self))
      window.center()
    }

    fileprivate func edited() { window.isDocumentEdited = true }

    fileprivate func save() {
      do {
        try buffers.save(name, root: root)
        window.isDocumentEdited = false
      } catch {
        NSAlert(error: error).beginSheetModal(for: window)
      }
    }

    /// Unsaved edits are never dropped silently (principle: no data loss on close).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
      guard window.isDocumentEdited else { return true }
      let alert = NSAlert()
      alert.messageText = "\(name) の変更を保存しますか？"
      alert.informativeText = "保存しないと変更は失われます。"
      alert.addButton(withTitle: "保存")
      alert.addButton(withTitle: "キャンセル")
      alert.addButton(withTitle: "保存しない")
      switch alert.runModal() {
      case .alertFirstButtonReturn: save(); return !window.isDocumentEdited
      case .alertThirdButtonReturn: return true
      default: return false
      }
    }

    func windowWillClose(_ notification: Notification) {
      buffers.drop([name])
      Self.open[file] = nil
    }
  }

  private struct AdhocEditorView: View {
    let buffers: EditorBuffers
    let root: String
    let name: String
    let owner: AdhocEditorWindow

    var body: some View {
      EditorPane(buffers: buffers, root: root, path: name, focused: true, onEdit: { _ in owner.edited() },
        onCaret: { buffers.setCaret($0, $1, in: $2) })
        .background {
          // ⌘S for this window: the key window's shortcut wins over the workbench's File menu item.
          Button("保存") { owner.save() }.keyboardShortcut("s").hidden()
        }
        .frame(minWidth: 320, minHeight: 200)
        .background(DesignTokens.Color.canvas)
    }
  }
#endif
