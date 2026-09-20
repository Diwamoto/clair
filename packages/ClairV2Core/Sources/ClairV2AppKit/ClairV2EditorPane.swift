#if os(macOS)
  import AppKit
  import ClairV2DesignSystem
  import ClairV2EditorCore
  import ClairV2EditorView
  import Observation
  import SwiftUI

  private typealias C = DesignTokens.Color

  /// U05: open editor buffers of the active Project. Owned by the workbench store; the store drops a
  /// path when the disk changed under it (principle 8: the unsaved buffer is discarded, not merged).
  @MainActor @Observable public final class EditorBuffers {
    public enum Load { case ready(EditorTransactionManager), failed(String) }

    private var loads: [String: Load] = [:]
    private var revisions: [String: Int] = [:]
    /// Above this the file is refused rather than loaded whole (large-file paths are E10's scope).
    static let maxBytes = 10_000_000

    func isOpen(_ path: String) -> Bool { if case .ready = loads[path] { true } else { false } }

    /// Bumped on drop so the surface rebuilds even when the path is unchanged.
    func revision(_ path: String) -> Int { revisions[path, default: 0] }

    func load(_ path: String, root: String) -> Load {
      if let l = loads[path] { return l }
      let l = Self.read(root + "/" + path)
      loads[path] = l
      return l
    }

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

    var body: some View {
      if let path, let root {
        switch buffers.load(path, root: root) {
        case .ready(let m):
          EditorSurface(manager: m, onEdit: { onEdit(path) }).id("\(path)#\(buffers.revision(path))")
        case .failed(let message): note(message)
        }
      } else {
        note("ファイルを選択してください。")
      }
    }

    private func note(_ s: String) -> some View {
      Text(s).font(Typography.font(Typography.chrome)).foregroundStyle(C.textTertiary)
    }
  }

  private struct EditorSurface: NSViewRepresentable {
    let manager: EditorTransactionManager
    let onEdit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
      scroll.drawsBackground = false
      let view = ClairEditorView(snapshot: manager.buffer.snapshot, selection: manager.selection)
      view.onCommitEdits = { [weak view, manager, onEdit] edits in
        guard let view else { return }
        let old = manager.buffer.snapshot
        guard let new = try? manager.apply(edits) else { return }
        view.applyEdits(edits, oldSnapshot: old, newSnapshot: new, selection: manager.selection)
        onEdit()
      }
      view.onSelectionChange = { [weak manager] in manager?.setSelection($0) }
      scroll.documentView = view
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
  }
#endif
