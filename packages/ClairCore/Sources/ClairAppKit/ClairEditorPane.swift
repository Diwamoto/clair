#if os(macOS)
  import AppKit
  import ClairDesignSystem
  import ClairEditorCore
  import ClairEditorView
  import Observation
  import SwiftUI

  private typealias C = DesignTokens.Color

  /// U05: open editor buffers of the active Project. Owned by the workbench store; the store drops a
  /// path when the disk changed under it (principle 8: the unsaved buffer is discarded, not merged).
  @MainActor @Observable public final class EditorBuffers {
    public enum Load { case ready(EditorTransactionManager), failed(String) }

    private var loads: [String: Load] = [:]
    private var revisions: [String: Int] = [:]
    /// 1-based caret of each open file (status bar Ln/Col); grapheme columns.
    private(set) var caret: [String: (line: Int, col: Int)] = [:]

    func setCaret(_ path: String, _ sel: TextSelectionSet, in snapshot: TextSnapshot) {
      guard let head = sel.selections.first?.head,
        let p = try? snapshot.position(at: head, columnUnit: GraphemeUnit.self, rounding: .down)
      else { return }
      caret[path] = (p.line.value + 1, p.column.value + 1)
    }
    /// Search-hit jump target (1-based line); `nonce` makes a repeat jump to the same line still fire.
    private(set) var reveal: (path: String, line: Int, nonce: Int)?
    /// Above this the file is refused rather than loaded whole (large-file paths are E10's scope).
    static let maxBytes = 10_000_000

    func reveal(_ path: String, line: Int) { reveal = (path, line, (reveal?.nonce ?? 0) + 1) }

    func isOpen(_ path: String) -> Bool { if case .ready = loads[path] { true } else { false } }

    /// Bumped on drop so the surface rebuilds even when the path is unchanged.
    func revision(_ path: String) -> Int { revisions[path, default: 0] }

    func load(_ path: String, root: String) -> Load {
      if let l = loads[path] { return l }
      let l = Self.read(root + "/" + path)
      loads[path] = l
      return l
    }

    /// Rebuilds the surface from the buffer after it was changed outside the view (a review suggestion applied).
    func refresh(_ path: String) { revisions[path, default: 0] += 1 }

    func drop(_ paths: Set<String>) {
      for p in paths where loads.removeValue(forKey: p) != nil { revisions[p, default: 0] += 1 }
    }

    func save(_ path: String, root: String) throws {
      guard case .ready(let m) = loads[path] else { return }
      try m.buffer.snapshot.string().write(toFile: root + "/" + path, atomically: true, encoding: .utf8)
    }

    private static func read(_ full: String) -> Load {
      guard let data = FileManager.default.contents(atPath: full) else { return .failed("ファイルを読み込めません。") }
      guard data.count <= maxBytes else { return .failed("10 MB を超えるファイルは開けません。") }
      guard let text = String(data: data, encoding: .utf8), let buffer = try? TextBuffer(text) else {
        return .failed("UTF-8 のテキストではないため開けません。")
      }
      return .ready(EditorTransactionManager(buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0))))
    }
  }

  /// The editor leaf of the pane tree: the active tab's file, or an explicit empty / error state.
  struct EditorPane: View {
    let buffers: EditorBuffers
    let root: String?
    let path: String?
    let onEdit: (String) -> Void
    let onCaret: (String, TextSelectionSet, TextSnapshot) -> Void

    var body: some View {
      if let path, let root {
        switch buffers.load(path, root: root) {
        case .ready(let m):
          VStack(spacing: 0) {
            breadcrumb(path)
            EditorSurface(manager: m, onCaret: { onCaret(path, $0, m.buffer.snapshot) }, reveal: buffers.reveal?.path == path ? buffers.reveal : nil, onEdit: { onEdit(path) }).id("\(path)#\(buffers.revision(path))")
          }
        case .failed(let message): note(message)
        }
      } else {
        note("ファイルを選択してください。")
      }
    }

    /// Mock `PathBreadcrumb`: 24px, directory parts quiet, the file name semibold.
    private func breadcrumb(_ path: String) -> some View {
      let parts = path.split(separator: "/").map(String.init)
      return HStack(spacing: 4) {
        ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
          if i > 0 { Text("›").font(.system(size: 11)).foregroundStyle(C.textQuaternary) }
          Text(part).font(.system(size: 11, weight: i == parts.count - 1 ? .semibold : .regular))
            .foregroundStyle(i == parts.count - 1 ? C.textSecondary : C.textQuaternary).lineLimit(1)
        }
        Spacer(minLength: 0)
      }.padding(.horizontal, 12).frame(height: 24).background(C.canvas)
    }

    private func note(_ s: String) -> some View {
      Text(s).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
    }
  }

  private struct EditorSurface: NSViewRepresentable {
    let manager: EditorTransactionManager
    let onCaret: (TextSelectionSet) -> Void
    let reveal: (path: String, line: Int, nonce: Int)?
    let onEdit: () -> Void

    final class Coordinator { var nonce = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
      scroll.drawsBackground = true; scroll.backgroundColor = NSColor(C.canvas)
      // Mock editor: 12px mono on 19px rows, One Dark on the canvas colour, 46px gutter.
      let view = ClairEditorView(
        snapshot: manager.buffer.snapshot, selection: manager.selection,
        font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineHeight: 19)
      view.background = NSColor(C.canvas); view.textColor = NSColor(C.code)
      view.caretColor = NSColor(C.textPrimary); view.selectionColor = NSColor(C.debugBlue).withAlphaComponent(0.3)
      view.gutterWidth = 46
      view.lineNumberColor = NSColor(C.lineNumber); view.currentLineNumberColor = NSColor(C.textTertiary)
      view.onCommitEdits = { [weak view, manager, onEdit] edits in
        guard let view else { return }
        let old = manager.buffer.snapshot
        guard let new = try? manager.apply(edits) else { return }
        view.applyEdits(edits, oldSnapshot: old, newSnapshot: new, selection: manager.selection)
        onEdit()
      }
      view.onSelectionChange = { [weak manager, onCaret] in manager?.setSelection($0); onCaret($0) }
      scroll.documentView = view
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
      guard let r = reveal, r.nonce != context.coordinator.nonce, let view = scroll.documentView as? ClairEditorView else { return }
      context.coordinator.nonce = r.nonce
      DispatchQueue.main.async { view.reveal(line: r.line - 1) }  // after the new view is laid out and in a window
    }
  }
#endif
