import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView

/// Keeps a result from an older parse/query from being applied after a newer edit.
struct HighlightRevisionGate {
    private(set) var revision = 0

    func token() -> Int { revision }

    mutating func beginEdit() -> Int {
        revision += 1
        return revision
    }

    func accepts(_ token: Int) -> Bool { token == revision }
}

/// A small adapter around the PoC dependency's highlighter.
///
/// The upstream highlighter already cancels work by priority, but its completion
/// callbacks do not carry a document revision. The gate makes cancellation
/// observable at the adapter boundary too, so a late callback is re-queued by
/// `Highlighter` instead of styling a newer document with an older tree.
final class RevisionAwareHighlightProvider: HighlightProviding {
    private let client = TreeSitterClient()
    private var gate = HighlightRevisionGate()
    private(set) var lifecycleState: NativeEditorAnalysisLifecycle = .active

    /// Invalidates completions before the display controller is released.
    /// This remains the deinitialization fallback; the display-cache release
    /// path below uses the explicit lifecycle barrier while retaining the
    /// provider until its executor is idle.
    func requestClose() {
        guard lifecycleState == .active else { return }
        _ = gate.beginEdit()
        lifecycleState = .closeRequestedIdleUnknown
    }

    /// Requests close through the pinned dependency's lifecycle API. The
    /// provider remains retained by `Document` until the dependency reports
    /// that its executor queue is idle.
    @MainActor func requestClose(completion: @escaping @MainActor (Bool) -> Void) {
        guard lifecycleState == .active else {
            completion(lifecycleState == .idleVerified)
            return
        }

        _ = gate.beginEdit()
        lifecycleState = .closeRequestedIdleUnknown

        client.close { [weak self] idleVerified in
            guard let self, self.lifecycleState == .closeRequestedIdleUnknown else {
                completion(false)
                return
            }
            if idleVerified {
                self.lifecycleState = .idleVerified
            }
            completion(idleVerified)
        }
    }

    @MainActor func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        guard lifecycleState == .active else { return }
        client.setUp(textView: textView, codeLanguage: codeLanguage)
    }

    @MainActor func willApplyEdit(textView: TextView, range: NSRange) {
        guard lifecycleState == .active else { return }
        _ = gate.beginEdit()
        client.willApplyEdit(textView: textView, range: range)
    }

    @MainActor func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        guard lifecycleState == .active else {
            completion(closingResult(.success(IndexSet())))
            return
        }
        let token = gate.token()
        client.applyEdit(textView: textView, range: range, delta: delta) { [weak self] result in
            guard let self, self.gate.accepts(token) else {
                completion(
                    self?.closingResult(.success(IndexSet()))
                        ?? .failure(HighlightProvidingError.operationCancelled)
                )
                return
            }
            completion(result)
        }
    }

    @MainActor func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        guard lifecycleState == .active else {
            completion(closingResult(.success([])))
            return
        }
        let token = gate.token()
        client.queryHighlightsFor(textView: textView, range: range) { [weak self] result in
            guard let self, self.gate.accepts(token) else {
                completion(
                    self?.closingResult(.success([]))
                        ?? .failure(HighlightProvidingError.operationCancelled)
                )
                return
            }
            completion(result)
        }
    }

    private func closingResult<T>(_ closed: Result<T, Error>) -> Result<T, Error> {
        switch lifecycleState {
        case .closeRequestedIdleUnknown, .idleVerified:
            return closed
        case .active, .notStarted:
            return .failure(HighlightProvidingError.operationCancelled)
        }
    }

    /// Replays the initial visibility signal after the view has a real frame.
    /// The second pass is on the next main-queue turn so the provider sees the
    /// final scroll bounds after AppKit layout/display.
    @MainActor func requestInitialVisibleRange(for textView: TextView) {
        guard lifecycleState == .active else { return }
        _ = textView.layoutManager.layoutLines()
        postVisibleRangeChange(for: textView)
        DispatchQueue.main.async { [weak self, weak textView] in
            guard self != nil, let textView else { return }
            self?.postVisibleRangeChange(for: textView)
        }
    }

    private func postVisibleRangeChange(for textView: TextView) {
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }
}

enum HighlightSchedulingPolicy {
    static let defaultMaxSyncContentLength = 250_000
    static let legacyMaxSyncContentLength = 1_000_000

    static func configure(arguments: [String]) {
        TreeSitterClient.Constants.maxSyncContentLength = arguments.contains("--legacy-policy")
            ? legacyMaxSyncContentLength
            : defaultMaxSyncContentLength
    }
}
