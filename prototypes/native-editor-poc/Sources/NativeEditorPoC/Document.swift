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
    private(set) var highlightProvider: RevisionAwareHighlightProvider?
    let language: CodeLanguage
    let policyDecision: NativeEditorDecision
    var controller: TextViewController!
    var pendingText: String?
    private var closingHighlightProvider: RevisionAwareHighlightProvider?
    private(set) var textSnapshot: String
    private(set) var selectionSnapshot = NSRange(location: 0, length: 0)
    private(set) var scrollOriginSnapshot = NSPoint.zero
    var revision = 0
    private(set) var savedRevision = 0
    var groupMulticursorEdits = true
    private var ownsUndoGroup = false
    private var undoGroupCloseScheduled = false
    private var observers: [NSObjectProtocol] = []
    private var restoring = false
    var comments: [CommentAnchor] = []
    var proposal: Proposal?
    var onChange: (() -> Void)?
    private(set) var lifecycleState: NativeEditorLifecycleState
    var text: String { controller?.text ?? textSnapshot }
    var isDirty: Bool { revision != savedRevision }
    var isFallback: Bool { policyDecision.mode == .webFallback }
    var hasUndoHistory: Bool {
        guard let undo = controller?.textView._undoManager else { return false }
        return undo.canUndo || undo.canRedo
    }
    var canReleaseDisplayCache: Bool {
        controller != nil && !isDirty && !hasUndoHistory && controller.textView.hasMarkedText() == false && proposal == nil
    }
    var isDisplayLoaded: Bool { controller != nil }

    init(name: String, text: String, language: CodeLanguage) {
        self.name = name
        self.language = language
        self.policyDecision = NativeEditorPolicy.decide(text: text)
        self.textSnapshot = text
        self.pendingText = text
        self.lifecycleState = .init(
            display: policyDecision.mode == .webFallback ? .fallback : .loaded,
            analysis: policyDecision.mode == .webFallback ? .notStarted : .active
        )
        super.init()
        if !isFallback { makeController() }
    }

    private func makeController() {
        guard !isFallback else { return }
        let highlightProvider = RevisionAwareHighlightProvider()
        self.highlightProvider = highlightProvider
        controller = TextViewController(string: "", language: language,
            configuration: .init(appearance: .init(theme: Self.theme,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false),
            peripherals: .init(showMinimap: false)), cursorPositions: [],
            highlightProviders: [highlightProvider], coordinators: [self])
        lifecycleState = .init(display: .loaded, analysis: .active)
        _ = controller.view
        controller.textView.selectionManager.setSelectedRanges([NSRange(location: 0, length: 0)])
        installObservers()
    }

    private func installObservers() {
        observers.append(NotificationCenter.default.addObserver(forName: CodeEditTextView.TextView.textWillChangeNotification, object: controller.textView, queue: .main) { [weak self] _ in
            guard let self, self.groupMulticursorEdits, !self.ownsUndoGroup,
                  self.controller.textView.selectionManager.textSelections.count > 1,
                  let undo = self.controller.textView._undoManager,
                  !undo.isGrouping, !undo.isUndoing, !undo.isRedoing else { return }
            self.ownsUndoGroup = true; undo.beginUndoGrouping()
        })
        observers.append(NotificationCenter.default.addObserver(forName: CodeEditTextView.TextView.textDidChangeNotification, object: controller.textView, queue: .main) { [weak self] _ in
            self?.scheduleMulticursorUndoGroupClose()
        })
    }
    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    deinit {
        highlightProvider?.requestClose()
        closingHighlightProvider?.requestClose()
        removeObservers()
    }
    /// Marked-range updates are transient notifications. Keep the adapter's multi-cursor
    /// group open across them, then close it after the run-loop turn that commits or cancels
    /// the composition.
    private func scheduleMulticursorUndoGroupClose() {
        guard ownsUndoGroup, !undoGroupCloseScheduled else { return }
        undoGroupCloseScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.undoGroupCloseScheduled = false
            guard self.ownsUndoGroup else { return }
            guard let textView = self.controller?.textView else {
                self.ownsUndoGroup = false
                return
            }
            guard let undo = textView._undoManager else {
                self.ownsUndoGroup = false
                return
            }
            guard !undo.isUndoing, !undo.isRedoing else {
                self.scheduleMulticursorUndoGroupClose()
                return
            }
            guard !textView.hasMarkedText() else { return }
            if undo.isGrouping { undo.endUndoGrouping() }
            self.ownsUndoGroup = false
        }
    }

    @MainActor func requestInitialHighlight() {
        guard let highlightProvider, let controller else { return }
        highlightProvider.requestInitialVisibleRange(for: controller.textView)
    }

    func loadPendingText() {
        guard let initial = pendingText, let controller else { return }
        pendingText = nil
        restoring = true
        controller.setText(initial)
        restoring = false
        selectionSnapshot = NSRange(location: 0, length: 0)
    }

    func ensureDisplay() {
        guard !isFallback, controller == nil else { return }
        let requestedSelection = selectionSnapshot
        makeController()
        restoring = true
        controller.setText(textSnapshot)
        restoring = false
        let range = validSelection(requestedSelection, in: textSnapshot) ? requestedSelection : NSRange(location: 0, length: 0)
        selectionSnapshot = range
        controller.textView.layoutManager.layoutLines()
        controller.textView.selectionManager.setSelectedRanges([range])
        controller.scrollView.contentView.scroll(to: scrollOriginSnapshot)
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
    }

    @MainActor
    @discardableResult
    func releaseDisplayCache() -> Bool {
        guard canReleaseDisplayCache, let controller else { return false }
        let provider = highlightProvider
        textSnapshot = controller.text
        selectionSnapshot = controller.textView.selectedRange()
        scrollOriginSnapshot = controller.scrollView.contentView.bounds.origin
        controller.view.removeFromSuperview()
        removeObservers()
        self.controller = nil
        self.highlightProvider = nil
        lifecycleState = .init(display: .displayCacheReleased, analysis: .closeRequestedIdleUnknown)
        closingHighlightProvider = provider
        provider?.requestClose { [weak self, weak provider] idleVerified in
            guard let self, let provider, self.closingHighlightProvider === provider else { return }
            self.closingHighlightProvider = nil
            guard self.controller == nil else { return }
            if idleVerified {
                self.lifecycleState = .init(display: .displayCacheReleased, analysis: .idleVerified)
            }
        }
        return true
    }

    @MainActor
    func waitForAnalysisIdle(timeout: TimeInterval = 5.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lifecycleState.analysis == .idleVerified {
                return true
            }
            await pump(0.02)
        }
        return lifecycleState.analysis == .idleVerified
    }
    func prepareCoordinator(controller: TextViewController) { controller.textView.addStorageDelegate(self) }
    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters), !restoring else { return }
        revision += 1
        textSnapshot = controller?.text ?? textSnapshot
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        for index in comments.indices { comments[index].transform(edit: oldRange, inserted: editedRange.length) }
        onChange?()
    }
    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        let range = controller.textView.selectedRange()
        if range.location != NSNotFound && range.location >= 0 && range.length >= 0 &&
            range.location <= controller.textView.textStorage.length &&
            range.length <= controller.textView.textStorage.length - range.location {
            selectionSnapshot = range
        }
        onChange?() // no text getter, no document binding
    }

    private func validSelection(_ range: NSRange, in text: String) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0 &&
            range.location <= text.utf16.count && range.length <= text.utf16.count - range.location
    }
    func addComment(range: NSRange) {
        guard let controller else { return }
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= controller.textView.textStorage.length,
              range.length <= controller.textView.textStorage.length - range.location else { return }
        comments.append(.init(range: range, text: "確認: この範囲を維持する"))
        onChange?()
    }
    func propose() {
        let length = text.utf16.count
        let edits = [(NSRange(location: 0, length: 0), "// AI: reviewed\n"),
                     (NSRange(location: length, length: 0), "\n// AI: end\n")]
        proposal = .init(revision: revision, edits: edits, pending: Set(edits.indices))
    }
    @discardableResult func apply(indices: Set<Int>) -> Bool {
        guard let controller, var p = proposal, p.revision == revision, !indices.isEmpty,
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
        guard controller?.textView.hasMarkedText() != true else { throw NSError(domain: "CompositionActive", code: 1) }
        try text.write(to: url, atomically: true, encoding: .utf8)
        textSnapshot = text
        savedRevision = revision
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
