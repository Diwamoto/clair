import ClairV2EditorCore

#if os(iOS)
  import SwiftUI
  import UIKit

  /// Minimal `UIViewRepresentable` harness proving `ClairEditorView` (E08)
  /// is embeddable from SwiftUI, the shape a real host screen would use.
  /// This is deliberately not product chrome — no toolbar, no Workbench
  /// styling, no scroll-view host beyond the one `UIScrollView` needed to
  /// prove viewport virtualization scrolls at all — that is `U05`'s scope
  /// once the Design canvas has an iOS editor screen to conform to; this
  /// file only exists so the surface this task built has one real,
  /// type-checked SwiftUI call site instead of only being reachable from
  /// XCTest.
  public struct ClairEditorSurface: UIViewRepresentable {
    private let snapshot: TextSnapshot
    private let selection: TextSelectionSet
    private let manager: EditorTransactionManager

    public init(manager: EditorTransactionManager) {
      self.manager = manager
      self.snapshot = manager.buffer.snapshot
      self.selection = manager.selection
    }

    public func makeUIView(context: Context) -> UIScrollView {
      let scrollView = UIScrollView()
      let editorView = ClairEditorView(snapshot: snapshot, selection: selection)
      editorView.onCommitEdits = { [weak editorView] edits in
        guard let editorView else { return }
        let old = manager.buffer.snapshot
        guard let new = try? manager.apply(edits) else { return }
        editorView.applyEdits(
          edits, oldSnapshot: old, newSnapshot: new, selection: manager.selection)
      }
      editorView.onSelectionChange = { [weak manager] selection in
        manager?.setSelection(selection)
      }
      scrollView.addSubview(editorView)
      context.coordinator.editorView = editorView
      return scrollView
    }

    public func updateUIView(_ scrollView: UIScrollView, context: Context) {
      context.coordinator.editorView?.configure(
        snapshot: manager.buffer.snapshot, selection: manager.selection)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
      weak var editorView: ClairEditorView?
    }
  }

  #Preview {
    let manager = EditorTransactionManager(
      buffer: try! TextBuffer("func greet() {\n    print(\"hello\")\n}\n"),
      selection: TextSelectionSet(cursor: UTF8Offset(0)))
    return ClairEditorSurface(manager: manager)
  }
#endif
