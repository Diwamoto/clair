import AppKit
import CodeEditSourceEditor
import CodeEditLanguages

final class CommentRail: NSView {
    weak var document: Document?
    override var isFlipped: Bool { true }
    override func draw(_ rect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); rect.fill()
        guard let d = document else { return }
        let layout = d.controller.textView.layoutManager!
        let origin = d.controller.scrollView.contentView.bounds.minY
        for c in d.comments where !c.orphaned {
            guard let line = layout.lineStorage.getLine(atOffset: c.range.location) else { continue }
            ("●" as NSString).draw(at: NSPoint(x: 4, y: line.yPos - origin), withAttributes: [.foregroundColor: NSColor.systemOrange])
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let d = document else { return }
        let y = convert(event.locationInWindow, from: nil).y + d.controller.scrollView.contentView.bounds.minY
        guard let line = d.controller.textView.layoutManager.lineStorage.getLine(atPosition: y) else { return }
        let selected = d.controller.textView.selectedRange()
        d.addComment(range: selected.length > 0 ? selected : line.range)
        needsDisplay = true
    }
}
@MainActor
final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var documents: [Document] = []
    var active = 0
    let host = NSView(), status = NSTextField(labelWithString: ""), tabs = NSPopUpButton()
    let rail = CommentRail()
    let diffView = NativeDiffView(frame: .zero)
    var diffVisible = false
    var observer: NSObjectProtocol?
    var doc: Document { documents[active] }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard window == nil else { return }
        HighlightSchedulingPolicy.configure(arguments: CommandLine.arguments)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Clair Native Editor PoC — isolated"
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 6; root.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        window.contentView = root
        let bar = NSStackView(); bar.orientation = .horizontal
        tabs.target = self; tabs.action = #selector(switchTab)
        bar.addArrangedSubview(tabs)
        for (title, action) in [("Open", #selector(openFile)), ("Multi", #selector(multi)), ("Comment", #selector(comment)), ("Propose / Diff", #selector(propose)), ("Apply all", #selector(applyAll)), ("Apply row", #selector(applyRow)), ("Apply block", #selector(applyBlock)), ("Reject", #selector(reject)), ("Editor", #selector(editor)), ("Release tab cache", #selector(releaseTab)), ("Save as", #selector(save))] {
            bar.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        root.addArrangedSubview(bar)
        let body = NSStackView(); body.orientation = .horizontal; body.spacing = 0
        body.addArrangedSubview(rail); body.addArrangedSubview(host)
        rail.widthAnchor.constraint(equalToConstant: 20).isActive = true
        root.addArrangedSubview(body); root.addArrangedSubview(status)
        for view in [bar, body, status] { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16).isActive = true }
        body.heightAnchor.constraint(equalTo: root.heightAnchor, constant: -90).isActive = true
        host.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        host.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -20).isActive = true
        rail.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
        for path in paths { if let text = try? String(contentsOfFile: path, encoding: .utf8) { add(name: URL(fileURLWithPath: path).lastPathComponent, text: text, language: languageFor(path)) } }
        if documents.isEmpty { add(name: "sample.swift", text: "// 日本語 👨‍👩‍👧‍👦 é\nlet greeting = \"こんにちは\"\nlet count = 42\n", language: .swift) }
        diffView.onSelection = { [weak self] selection in
            self?.status.stringValue = selection
        }
        diffView.onModeChange = { [weak self] mode in
            self?.status.stringValue = "diff mode: \(mode.rawValue)"
        }
        setupMenu()
        show(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--lifecycle-probe") {
            Task { @MainActor in await self.runLifecycleProbe() }
        } else if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--benchmark") {
            Task { @MainActor in await self.runChecks(benchmark: CommandLine.arguments.contains("--benchmark")) }
        }
    }
    func add(name: String, text: String, language: CodeLanguage) {
        let d = Document(name: name, text: text, language: language)
        d.onChange = { [weak self] in self?.refresh() }
        documents.append(d); tabs.addItem(withTitle: "\(documents.count): \(name)"); active = documents.count - 1
    }
    @MainActor func show() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        doc.ensureDisplay()
        host.subviews.forEach { $0.removeFromSuperview() }
        let view = diffVisible ? diffView : doc.controller.view
        view.frame = host.bounds; view.autoresizingMask = [.width, .height]; host.addSubview(view)
        window.contentView?.layoutSubtreeIfNeeded()
        let initialLoad = doc.pendingText != nil
        doc.loadPendingText()
        _ = doc.controller.textView.layoutManager.layoutLines()
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: doc.controller.scrollView.contentView)
        if initialLoad { doc.requestInitialHighlight() }
        rail.document = doc; rail.isHidden = diffVisible; tabs.selectItem(at: active)
        doc.controller.scrollView.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: doc.controller.scrollView.contentView, queue: .main) { [weak self] _ in self?.rail.needsDisplay = true }
        window.makeFirstResponder(diffVisible ? diffView.table : doc.controller.textView); refresh()
    }
    func refresh() {
        guard !documents.isEmpty else { return }
        let comments = doc.comments.map { "\($0.orphaned ? "orphan" : "UTF16 \($0.range.location):\($0.range.length)") \($0.text)" }.joined(separator: " | ")
        status.stringValue = "rev \(doc.revision) · selection \(doc.controller.textView.selectedRange()) · \(comments)"
        rail.needsDisplay = true
    }
    @objc func switchTab() {
        active = tabs.indexOfSelectedItem
        for (index, document) in documents.enumerated() where index != active { _ = document.releaseDisplayCache() }
        diffVisible = false; show()
    }
    @objc func editor() { diffVisible = false; show() }
    @objc func releaseTab() {
        guard doc.releaseDisplayCache() else {
            status.stringValue = "Retained: dirty buffer, undo history, composition, or pending proposal"
            return
        }
        host.subviews.forEach { $0.removeFromSuperview() }
        rail.document = nil
        status.stringValue = "Released display cache; text and selection snapshot retained"
    }
    @objc func openFile() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { if let text = try? String(contentsOf: url, encoding: .utf8) { add(name: url.lastPathComponent, text: text, language: languageFor(url.path)) } }; editor() }
    }
    @objc func multi() {
        let layout = doc.controller.textView.layoutManager!
        let ranges = (0..<min(3, layout.lineCount)).compactMap { layout.lineStorage.getLine(atIndex: $0).map { NSRange(location: $0.range.location, length: 0) } }
        doc.controller.textView.selectionManager.setSelectedRanges(ranges)
        window.makeFirstResponder(doc.controller.textView)
    }
    @objc func comment() { doc.addComment(range: doc.controller.textView.selectedRange()) }
    @objc func propose() {
        doc.propose()
        let old = doc.controller.text
        let proposed = NSMutableString(string: old)
        for (range, text) in doc.proposal!.edits.reversed() { proposed.replaceCharacters(in: range, with: text) }
        let diff = NativeDiffModel.calculate(
            old: .init(documentID: doc.name, path: doc.name, revision: UInt64(max(0, doc.revision)), content: old),
            new: .init(documentID: doc.name, path: doc.name, revision: UInt64(max(0, doc.revision + 1)), content: proposed as String)
        )
        diffView.set(result: diff, language: diffLanguage(for: doc.name), mode: .split)
        diffVisible = true; show()
    }
    @objc func applyAll() { apply(doc.proposal?.pending ?? []) }
    @objc func applyRow() {
        guard let selected = diffView.lastSelection,
              let row = diffView.result?.rows.first(where: { $0.id == selected.rowID }),
              row.kind != .context else { return }
        apply(row.newText?.contains("AI: reviewed") == true ? [0] : [1])
    }
    @objc func applyBlock() { applyRow() } // Fixed sample: each independent block consists of one proposal edit.
    func apply(_ indices: Set<Int>) {
        let ok = doc.apply(indices: indices); editor()
        if !ok { status.stringValue = "Rejected: stale proposal, empty selection, or active composition" }
    }
    @objc func reject() { doc.proposal = nil; editor() }
    @objc func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = doc.name
        if panel.runModal() == .OK, let url = panel.url { do { try doc.save(to: url) } catch { status.stringValue = error.localizedDescription } }
    }
    func setupMenu() {
        let menu = NSMenu(); let appMenu = NSMenuItem(); menu.addItem(appMenu); appMenu.submenu = NSMenu()
        appMenu.submenu?.addItem(withTitle: "Quit PoC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); menu.addItem(edit); edit.submenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.submenu?.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key) }
        NSApp.mainMenu = menu
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
func languageFor(_ path: String) -> CodeLanguage {
    switch URL(fileURLWithPath: path).pathExtension {
    case "swift": return .swift
    case "rs": return .rust
    case "ts": return .typescript
    case "tsx": return .tsx
    case "json": return .json
    case "md": return .markdown
    default: return .default
    }
}

func diffLanguage(for path: String) -> String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "swift": return "swift"
    case "rs": return "rust"
    case "ts", "tsx": return "typescript"
    case "json": return "json"
    case "md": return "markdown"
    default: return "plain"
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate: NSObject & NSApplicationDelegate = CommandLine.arguments.contains("--web-benchmark")
    ? WebBenchmark()
    : MainActor.assumeIsolated { App() }
application.delegate = delegate
application.run()
