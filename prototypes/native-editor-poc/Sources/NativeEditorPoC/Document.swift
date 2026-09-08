import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import CodeEditLanguages

struct CommentAnchor {
    var range: NSRange
    var orphaned = false
    let text: String
    mutating func transform(edit: NSRange, inserted: Int) {
        guard !orphaned else { return }
        if NSMaxRange(edit) <= range.location {
            range.location += inserted - edit.length
        } else if edit.location < NSMaxRange(range) {
            // Conservative: touching the quoted text invalidates it instead of silently retargeting.
            orphaned = true
        }
    }
}
struct Proposal {
    let revision: Int
    let edits: [(NSRange, String)]
    var pending: Set<Int>
}

final class Document: NSObject, TextViewCoordinator, NSTextStorageDelegate {
    let name: String
    var controller: TextViewController!
    var pendingText: String?
    var revision = 0
    var groupMulticursorEdits = true
    private var ownsUndoGroup = false
    private var observers: [NSObjectProtocol] = []
    var comments: [CommentAnchor] = []
    var proposal: Proposal?
    var onChange: (() -> Void)?
    init(name: String, text: String, language: CodeLanguage) {
        self.name = name
        self.pendingText = text
        super.init()
        controller = TextViewController(string: "", language: language,
            configuration: .init(appearance: .init(theme: Self.theme,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false),
                peripherals: .init(showMinimap: false)), cursorPositions: [], coordinators: [self])
        _ = controller.view
        observers.append(NotificationCenter.default.addObserver(forName: CodeEditTextView.TextView.textWillChangeNotification, object: controller.textView, queue: .main) { [weak self] _ in
            guard let self, self.groupMulticursorEdits, !self.ownsUndoGroup,
                  self.controller.textView.selectionManager.textSelections.count > 1,
                  let undo = self.controller.textView._undoManager,
                  !undo.isGrouping, !undo.isUndoing, !undo.isRedoing else { return }
            self.ownsUndoGroup = true; undo.beginUndoGrouping()
        })
        observers.append(NotificationCenter.default.addObserver(forName: CodeEditTextView.TextView.textDidChangeNotification, object: controller.textView, queue: .main) { [weak self] _ in
            guard let self, self.ownsUndoGroup else { return }
            self.controller.textView.undoManager?.endUndoGrouping(); self.ownsUndoGroup = false
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func prepareCoordinator(controller: TextViewController) { controller.textView.addStorageDelegate(self) }
    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        revision += 1
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        for index in comments.indices { comments[index].transform(edit: oldRange, inserted: editedRange.length) }
        onChange?()
    }
    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        onChange?() // no text getter, no document binding
    }
    func addComment(range: NSRange) {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= controller.textView.textStorage.length,
              range.length <= controller.textView.textStorage.length - range.location else { return }
        comments.append(.init(range: range, text: "確認: この範囲を維持する"))
        onChange?()
    }
    func propose() {
        let length = controller.textView.textStorage.length
        let edits = [(NSRange(location: 0, length: 0), "// AI: reviewed\n"),
                     (NSRange(location: length, length: 0), "\n// AI: end\n")]
        proposal = .init(revision: revision, edits: edits, pending: Set(edits.indices))
    }
    @discardableResult func apply(indices: Set<Int>) -> Bool {
        guard var p = proposal, p.revision == revision, !indices.isEmpty,
              indices.isSubset(of: p.pending), !controller.textView.hasMarkedText() else { return false }
        let undo = controller.textView.undoManager!
        undo.beginUndoGrouping()
        for index in indices.sorted(by: { p.edits[$0].0.location > p.edits[$1].0.location }) {
            let (range, string) = p.edits[index]
            controller.textView.replaceCharacters(in: range, with: string)
        }
        undo.endUndoGrouping()
        p.pending.subtract(indices)
        // Remaining operations intentionally retain the original revision and become stale.
        proposal = p
        return true
    }
    func save(to url: URL) throws {
        guard !controller.textView.hasMarkedText() else { throw NSError(domain: "CompositionActive", code: 1) }
        try controller.text.write(to: url, atomically: true, encoding: .utf8)
    }
    static let theme = EditorTheme(text: .init(color: .white), insertionPoint: .white,
        invisibles: .init(color: .tertiaryLabelColor), background: NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1),
        lineHighlight: .controlBackgroundColor, selection: .selectedTextBackgroundColor,
        keywords: .init(color: .systemPurple), commands: .init(color: .systemBlue),
        types: .init(color: .systemTeal), attributes: .init(color: .systemOrange),
        variables: .init(color: .white), values: .init(color: .systemOrange),
        numbers: .init(color: .systemOrange), strings: .init(color: .systemRed),
        characters: .init(color: .systemRed), comments: .init(color: .systemGreen))
}

// Alignment model shared by both columns: blanks exist only in the presentation, never in a document.
struct DiffRow {
    let old: String?
    let new: String?
    let oldLine: Int?
    let newLine: Int?
    let changed: Bool
    let block: Int?
}
func alignedRows(old: String, new: String) -> [DiffRow] {
    let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
    let changes = b.difference(from: a)
    var removed = Set<Int>(), inserted = Set<Int>()
    for change in changes {
        switch change { case .remove(let n, _, _): removed.insert(n)
        case .insert(let n, _, _): inserted.insert(n) }
    }
    var rows: [DiffRow] = [], i = 0, j = 0, block = 0
    while i < a.count || j < b.count {
        if removed.contains(i) || inserted.contains(j) {
            var left: [Int] = [], right: [Int] = []
            while i < a.count && removed.contains(i) { left.append(i); i += 1 }
            while j < b.count && inserted.contains(j) { right.append(j); j += 1 }
            for k in 0..<max(left.count, right.count) {
                let x = k < left.count ? left[k] : nil, y = k < right.count ? right[k] : nil
                rows.append(.init(old: x.map { a[$0] }, new: y.map { b[$0] },
                    oldLine: x.map { $0 + 1 }, newLine: y.map { $0 + 1 }, changed: true, block: block))
            }
            block += 1
        } else {
            rows.append(.init(old: i < a.count ? a[i] : nil, new: j < b.count ? b[j] : nil,
                oldLine: i < a.count ? i + 1 : nil, newLine: j < b.count ? j + 1 : nil,
                changed: false, block: nil))
            i += 1; j += 1
        }
    }
    return rows
}
