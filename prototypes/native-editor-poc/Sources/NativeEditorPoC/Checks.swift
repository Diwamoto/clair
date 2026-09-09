import AppKit
import Darwin
import CodeEditLanguages
import SwiftTreeSitter

func pump(_ seconds: Double = 0.15) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
func milliseconds(_ work: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds; work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
func evidenceOutput(benchmark: Bool) -> String {
    if CommandLine.arguments.contains("--ne09") {
        return benchmark ? "evidence/benchmark-ne09.json" : "evidence/checks-ne09.json"
    }
    if CommandLine.arguments.contains("--ne04") {
        return benchmark ? "evidence/benchmark-ne04.json" : "evidence/checks-ne04.json"
    }
    if benchmark {
        return CommandLine.arguments.contains("--async-policy") ? "evidence/benchmark-async.json" : "evidence/benchmark.json"
    }
    return "evidence/checks.json"
}
extension App {
    @MainActor func runLifecycleProbe() async {
        guard let d = documents.first else { exit(1) }
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let profile = NativeEditorFileProfile(text: d.text)
        await pump(0.3)
        let afterOpen = processFootprintBytes()
        if d.isFallback {
            let result: [String: Any] = [
                "fixture": d.name,
                "measured_at": startedAt,
                "utf8_bytes": profile.utf8Bytes,
                "utf16_length": profile.utf16Length,
                "maximum_line_utf16_length": profile.maximumLineUTF16Length,
                "policy": d.policyDecision.mode.rawValue,
                "open_footprint_bytes": afterOpen,
                "before_release_footprint_bytes": afterOpen,
                "released_display_cache": false,
                "display_lifecycle": d.lifecycleState.display.rawValue,
                "analysis_lifecycle": d.lifecycleState.analysis.rawValue,
                "parser_idle": d.lifecycleState.parserIdle as Any,
                "fully_released": d.lifecycleState.isFullyReleased,
                "after_release_footprint_bytes": afterOpen,
                "note": "native controller and Tree-sitter were not created because the file exceeded a native safety limit"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([10]))
            }
            exit(0)
        }
        guard let controller = d.controller else { exit(1) }
        controller.textView._undoManager?.clearStack()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clair-poc-lifecycle-probe-\(UUID().uuidString).txt")
        try? d.save(to: tempURL)
        let beforeRelease = processFootprintBytes()
        let displayCacheReleased = d.releaseDisplayCache()
        let parserIdleVerified = await d.waitForAnalysisIdle()
        await pump(0.1)
        let afterRelease = processFootprintBytes()
        try? FileManager.default.removeItem(at: tempURL)
        let result: [String: Any] = [
            "fixture": d.name,
            "measured_at": startedAt,
            "utf8_bytes": profile.utf8Bytes,
            "utf16_length": profile.utf16Length,
            "maximum_line_utf16_length": profile.maximumLineUTF16Length,
            "policy": d.policyDecision.mode.rawValue,
            "open_footprint_bytes": afterOpen,
            "before_release_footprint_bytes": beforeRelease,
            "released_display_cache": displayCacheReleased,
            "display_lifecycle": d.lifecycleState.display.rawValue,
            "analysis_lifecycle": d.lifecycleState.analysis.rawValue,
            "parser_idle": d.lifecycleState.parserIdle as Any,
            "parser_idle_verified": parserIdleVerified,
            "fully_released": d.lifecycleState.isFullyReleased,
            "after_release_footprint_bytes": afterRelease,
            "note": "single process, one fixture, one open/close cycle; close uses the PoC lifecycle patch to cancel and drain the Tree-sitter executor before releasing the provider; footprint is task resident_size and not a peak or input-to-photon metric"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
        exit(displayCacheReleased ? 0 : 1)
    }

    @MainActor func runChecks(benchmark: Bool) async {
        var results: [[String: Any]] = []
        func check(_ name: String, _ pass: Bool, expectedFailure: Bool = false) {
            results.append(["test": name, "pass": pass, "expectedFailure": expectedFailure]); print("\(pass ? "PASS" : "FAIL") \(name)"); fflush(stdout)
        }
        guard !doc.isFallback, let controller = doc.controller else {
            print("FAIL self-test requires a native editor document")
            exit(1)
        }
        let d = doc, t = controller.textView!
        func reset() { d.controller.setText(original); t._undoManager?.clearStack(); d.comments = []; d.proposal = nil }

        let original = d.controller.text
        var gate = HighlightRevisionGate()
        let staleToken = gate.token()
        _ = gate.beginEdit()
        check("stale highlight revision rejected", !gate.accepts(staleToken))
        check("current highlight revision accepted", gate.accepts(gate.token()))
        d.groupMulticursorEdits = false
        t.selectionManager.setSelectedRanges([NSRange(location: 0, length: 0), NSRange(location: 3, length: 0)])
        t.insertText("X")
        check("multicursor inserts two copies", t.textStorage.length == original.utf16.count + 2)
        t.undoManager?.undo()
        check("upstream multicursor single undo", d.controller.text == original, expectedFailure: true)
        t.undoManager?.redo()
        check("multicursor redo", t.textStorage.length == original.utf16.count + 2)
        t.undoManager?.undo()
        reset()
        d.groupMulticursorEdits = true
        t.selectionManager.setSelectedRanges([NSRange(location: 0, length: 0), NSRange(location: 3, length: 0)])
        t.insertText("X"); t.undoManager?.undo()
        check("adapter multicursor single undo", d.controller.text == original)
        await pump()
        reset()
        d.addComment(range: NSRange(location: 3, length: 2))
        let beforeLength = t.textStorage.length
        t.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n")
        print("ANCHOR after insert \(d.comments[0].range) orphan=\(d.comments[0].orphaned) delta=\(t.textStorage.length - beforeLength)"); fflush(stdout)
        check("comment shifts after line insertion", d.comments[0].range.location == 3 + t.textStorage.length - beforeLength)
        while t.undoManager?.canUndo == true { t.undoManager?.undo() }
        check("comment shifts back after undo", d.comments[0].range.location == 3)
        t.replaceCharacters(in: NSRange(location: 3, length: 2), with: "")
        check("deleted comment becomes orphan", d.comments[0].orphaned)
        t.undoManager?.undo()
        reset()
        d.propose(); check("partial AI apply", d.apply(indices: [0]))
        check("remaining old proposal rejected", !d.apply(indices: [1]))
        t.undoManager?.undo(); check("AI apply undo", d.controller.text == original)
        d.propose(); t.replaceCharacters(in: NSRange(location: 0, length: 0), with: " ")
        check("stale proposal rejected after edit", !d.apply(indices: [0, 1]))
        t.undoManager?.undo()
        d.propose(); check("AI apply all", d.apply(indices: [0, 1])); t.undoManager?.undo()
        check("AI all one undo", d.controller.text == original)
        t.selectionManager.setSelectedRanges([NSRange(location: 0, length: 0)])
        t.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check("synthetic marked text", t.hasMarkedText())
        t.insertText("日本", replacementRange: t.markedRange())
        check("synthetic composition commit", !t.hasMarkedText() && d.controller.text.hasPrefix("日本"))
        await pump()
        reset()

        let unicode = "A👨‍👩‍👧‍👦e\u{301}日本語\nB"
        d.controller.setText(unicode)
        t.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        let family = (unicode as NSString).range(of: "👨‍👩‍👧‍👦")
        let familyInterior = NSRange(location: family.location + 2, length: 0)
        var actual = NSRange(location: NSNotFound, length: 0)
        let familyResult = t.attributedSubstring(forProposedRange: familyInterior, actualRange: &actual)
        check("family emoji input range stays grapheme aligned", actual == family && familyResult?.string == "👨‍👩‍👧‍👦")
        var rectRange = NSRange(location: NSNotFound, length: 0)
        _ = t.firstRect(forCharacterRange: familyInterior, actualRange: &rectRange)
        check("IME candidate range expands to family grapheme", rectRange == family)
        let combining = (unicode as NSString).range(of: "e\u{301}")
        var combiningActual = NSRange(location: NSNotFound, length: 0)
        let combiningResult = t.attributedSubstring(
            forProposedRange: NSRange(location: combining.location + 1, length: 0),
            actualRange: &combiningActual
        )
        check("combining mark input range stays grapheme aligned", combiningActual == combining && combiningResult?.string == "e\u{301}")

        t.selectionManager.setSelectedRange(NSRange(location: family.max, length: 0))
        t.deleteBackward(nil)
        check("backspace removes family emoji as one grapheme", d.controller.text == "Ae\u{301}日本語\nB")
        t.undoManager?.undo()
        check("family emoji deletion undo restores text", d.controller.text == unicode)
        t.selectionManager.setSelectedRange(NSRange(location: combining.max, length: 0))
        t.deleteBackward(nil)
        check("backspace removes combining sequence as one grapheme", d.controller.text == "A👨‍👩‍👧‍👦日本語\nB")
        t.undoManager?.undo()
        check("combining sequence deletion undo restores text", d.controller.text == unicode)

        reset()
        t.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        t.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        t.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check("composition updates do not enter undo history", t.hasMarkedText() && !(t.undoManager?.canUndo ?? true), expectedFailure: true)
        t.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        await pump()
        check("composition commit clears marked text", !t.hasMarkedText() && d.controller.text.hasPrefix("日本語"))
        t.undoManager?.undo()
        check("composition commit is one undo unit", d.controller.text == original)
        t.undoManager?.redo()
        check("composition commit redo restores text", d.controller.text.hasPrefix("日本語"))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clair-poc-\(UUID().uuidString).txt")
        do { try d.save(to: url); let read = try String(contentsOf: url, encoding: .utf8); check("UTF8 save roundtrip", read == d.controller.text); try FileManager.default.removeItem(at: url) }
        catch { check("UTF8 save roundtrip", false) }
        let rows = alignedRows(old: "a\nb\nc", new: "a\nx\ny\nc")
        check("diff insertion alignment", rows.count == 4 && rows[2].old == nil && rows[3].oldLine == 3 && rows[3].newLine == 4)
        let deletion = alignedRows(old: "a\nx\ny\nc", new: "a\nb\nc")
        check("diff deletion alignment", deletion.count == 4 && deletion[2].new == nil)
        let modelOld = NativeDiffInput(documentID: "fixture", path: "fixture.swift", revision: 7, content: "one\r\nsame\r\nlast")
        let modelNew = NativeDiffInput(documentID: "fixture", path: "fixture.swift", revision: 8, content: "one\r\nchanged\r\nlast\r\n")
        let modelDiff = NativeDiffModel.calculate(old: modelOld, new: modelNew)
        check("diff model preserves CRLF and trailing newline", modelDiff.reconstructOldSource() == modelOld.content && modelDiff.reconstructNewSource() == modelNew.content)
        check("diff model assigns hunk and stable row IDs", modelDiff.rows.contains { $0.hunkID != nil } && modelDiff.rows.map(\.id) == NativeDiffModel.calculate(old: modelOld, new: modelNew).rows.map(\.id))
        let largeDiffOld = (0..<10_000).map { "line \($0)" }.joined(separator: "\n")
        let largeDiffNew = (0..<10_000).map { $0 % 5 == 0 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n")
        let interactiveDiff = NativeDiffModel.calculate(old: .init(documentID: "large", path: "large.swift", revision: 1, content: largeDiffOld), new: .init(documentID: "large", path: "large.swift", revision: 2, content: largeDiffNew))
        diffView.set(result: interactiveDiff, language: "swift", mode: .split)
        diffVisible = true
        show()
        window.contentView?.layoutSubtreeIfNeeded()
        diffView.table.scrollRowToVisible(min(9_999, max(0, diffView.table.numberOfRows - 1)))
        diffView.table.selectRowIndexes(IndexSet(integer: min(1, max(0, diffView.table.numberOfRows - 1))), byExtendingSelection: false)
        check("diff view virtualizes visible cells and returns row/hunk selection", diffView.generatedCellCount > 0 && diffView.lastSelection?.rowID.isEmpty == false)
        diffView.setMode(.unified)
        window.contentView?.layoutSubtreeIfNeeded()
        diffView.setFrameSize(NSSize(width: 760, height: diffView.frame.height))
        diffView.layoutSubtreeIfNeeded()
        check("diff view mode and width changes retain rows", diffView.mode == .unified && diffView.table.numberOfRows == interactiveDiff.rows.count)
        diffView.setMode(.split)
        diffVisible = false
        show()
        let selected = t.selectedRange(), scroll = d.controller.scrollView.contentView.bounds.origin
        add(name: "second.swift", text: "let second = 2", language: .swift); show(); active = 0; show()
        check("tab preserves document selection scroll undo", doc === d && t.selectedRange() == selected && d.controller.scrollView.contentView.bounds.origin == scroll && t.undoManager!.canUndo)
        await pump(0.8)
        var colors = Set<String>()
        t.textStorage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: t.textStorage.length)) { value, _, _ in if let value { colors.insert(String(describing: value)) } }
        check("Swift multiple highlight colors", colors.count > 2)
        for name in ["normal.swift", "sample.rs", "sample.ts", "sample.tsx", "sample.json", "sample.md"] {
            guard let text = try? String(contentsOfFile: "fixtures/" + name, encoding: .utf8) else { continue }
            add(name: name, text: text, language: languageFor(name)); show(); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await pump(0.8)
            let lang = languageFor(name)
            let parser = Parser()
            do { try parser.setLanguage(lang.language!); let tree = parser.parse(text)
                print("PARSER \(name) query=\(lang.queryURL?.path ?? "nil") exists=\(lang.queryURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) root=\(String(describing: tree?.rootNode))")
            } catch { print("PARSER ERROR \(error)") }
            check("query asset " + name, lang.queryURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            fflush(stdout)
            let storage = doc.controller.textView.textStorage!
            var colors = Set<String>()
            storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in if let value { colors.insert(String(describing: value)) } }
            results.append(["fixture": name, "highlight_color_count": colors.count, "view_size": NSStringFromSize(doc.controller.textView.visibleRect.size)])
            check("highlight colors " + name, colors.count > 2)
            let probes: [(String, NSColor)]
            switch name {
            case "normal.swift": probes = [("multi", .systemGreen), ("line", .systemGreen), ("日本語 🙂", .systemRed), ("42", .systemOrange)]
            case "sample.rs": probes = [("nested", .systemGreen), ("comment */ comment", .systemGreen), ("日本語", .systemRed)]
            case "sample.ts": probes = [("continued", .systemGreen), ("日本語", .systemRed)]
            case "sample.tsx": probes = [("日本語", .systemGreen), ("🙂", .systemRed)]
            case "sample.json": probes = [("🙂", .systemRed), ("42", .systemOrange)]
            default: probes = [("let", .systemPurple), ("hi", .systemRed)]
            }
            for (token, expected) in probes {
                let range = (text as NSString).range(of: token)
                let actual = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
                check("highlight probe " + name + " " + token, actual == expected)
                results.append(["fixture": name, "probe": token, "expected_color": expected.description, "actual_color": actual?.description ?? "nil", "matches": actual == expected])
            }
            let currentDocument = doc
            currentDocument.controller.textView.replaceCharacters(in: .zero, with: " ")
            await pump(0.35)
            let editedStorage = currentDocument.controller.textView.textStorage!
            let editedProbe = probes[0].0
            let editedRange = (currentDocument.controller.text as NSString).range(of: editedProbe)
            let editedColor = editedStorage.attribute(.foregroundColor, at: editedRange.location + 1, effectiveRange: nil) as? NSColor
            check("highlight refresh after edit " + name, editedColor == probes[0].1)
            currentDocument.controller.textView.undoManager?.undo()
            await pump(0.15)
        }
        let lifecycle = Document(name: "lifecycle.swift", text: "let value = 1\n", language: .swift)
        lifecycle.loadPendingText()
        lifecycle.controller.textView.selectionManager.setSelectedRange(NSRange(location: 4, length: 5))
        let lifecycleURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clair-poc-lifecycle-\(UUID().uuidString).txt")
        do {
            try lifecycle.save(to: lifecycleURL)
            let released = lifecycle.releaseDisplayCache()
            check("clean tab releases display cache", released && !lifecycle.isDisplayLoaded)
            let parserIdleVerified = await lifecycle.waitForAnalysisIdle()
            check(
                "close drain verifies parser idle",
                parserIdleVerified
                    && lifecycle.lifecycleState == .init(display: .displayCacheReleased, analysis: .idleVerified)
                    && lifecycle.lifecycleState.parserIdle == true
                    && lifecycle.lifecycleState.isFullyReleased
            )
            lifecycle.ensureDisplay()
            check(
                "reopen starts active display lifecycle",
                lifecycle.lifecycleState == .init(display: .loaded, analysis: .active)
            )
            check("reopen preserves text and selection", lifecycle.text == "let value = 1\n" && lifecycle.controller.textView.selectedRange() == NSRange(location: 4, length: 5))
            try? FileManager.default.removeItem(at: lifecycleURL)
        } catch {
            check("clean tab lifecycle fixture", false)
        }
        lifecycle.controller.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// dirty\n")
        check("dirty tab retains undo-capable display", !lifecycle.releaseDisplayCache() && lifecycle.isDisplayLoaded && lifecycle.hasUndoHistory)
        lifecycle.controller.textView.undoManager?.undo()
        check("retained tab undo restores body", lifecycle.text == "let value = 1\n")
        let asyncLifecycleText = String(repeating: "let value = 1\n", count: 20_000)
        let asyncLifecycle = Document(name: "async-lifecycle.swift", text: asyncLifecycleText, language: .swift)
        asyncLifecycle.loadPendingText()
        asyncLifecycle.controller.textView._undoManager?.clearStack()
        asyncLifecycle.requestInitialHighlight()
        let asyncReleased = asyncLifecycle.releaseDisplayCache()
        let asyncParserIdle = await asyncLifecycle.waitForAnalysisIdle()
        check(
            "async native close drains parser",
            asyncLifecycle.policyDecision.mode == .asynchronousNative
                && asyncReleased
                && asyncParserIdle
                && asyncLifecycle.lifecycleState == .init(display: .displayCacheReleased, analysis: .idleVerified)
                && asyncLifecycle.lifecycleState.isFullyReleased
        )
        let policyBoundary = String(repeating: "a", count: NativeEditorPolicy.maximumSynchronousUTF16Length)
        check("policy sync boundary", NativeEditorPolicy.decide(text: policyBoundary).mode == .synchronousNative)
        check("policy async boundary", NativeEditorPolicy.decide(text: policyBoundary + "a").mode == .asynchronousNative)
        let nativeLimit = String(repeating: "a", count: NativeEditorPolicy.maximumNativeUTF8Bytes)
        check("policy byte fallback boundary", NativeEditorPolicy.decide(text: nativeLimit + "a").fallbackReason == .utf8Bytes)
        let longLineLimit = String(repeating: "a", count: NativeEditorPolicy.maximumNativeLineUTF16Length)
        check("policy line boundary", NativeEditorPolicy.decide(text: longLineLimit).mode == .asynchronousNative)
        check("policy long-line fallback boundary", NativeEditorPolicy.decide(text: longLineLimit + "a").fallbackReason == .maximumLineLength)
        let unicodeText = String(repeating: "🙂", count: 5_000_000)
        let unicodeProfile = NativeEditorFileProfile(text: unicodeText)
        check("policy reports UTF8 and UTF16 independently", unicodeProfile.utf8Bytes == 20_000_000 && unicodeProfile.utf16Length == 10_000_000)
        check("policy unicode byte fallback wins at equal UTF16 limit", NativeEditorPolicy.decide(text: unicodeText).fallbackReason == .utf8Bytes)
        let fallbackDocument = Document(name: "fallback.swift", text: unicodeText, language: .swift)
        check(
            "fallback does not create native controller",
            fallbackDocument.isFallback && fallbackDocument.controller == nil
                && fallbackDocument.lifecycleState.display == .fallback
                && fallbackDocument.lifecycleState.analysis == .notStarted
                && fallbackDocument.lifecycleState.isFullyReleased
        )
        results.append(["alternative_TextKit2": textKitProbe(), "note": "basic captures only; incremental syntax, IME and multicursor not validated for alternative"])
        if benchmark { await runBenchmarks(into: &results) }
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: evidenceOutput(benchmark: benchmark))) }
        let failed = results.contains { ($0["pass"] as? Bool) == false && ($0["expectedFailure"] as? Bool) != true }
        fflush(stdout)
        exit(failed ? 1 : 0)
    }

    private func processFootprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : -1
    }

    @MainActor func runBenchmarks(into results: inout [[String: Any]]) async {
        let fixtureRoot = URL(fileURLWithPath: "fixtures")
        for name in ["normal.swift", "1mb.swift", "10mb.swift", "long-line.ts"] {
            guard let text = try? String(contentsOf: fixtureRoot.appendingPathComponent(name), encoding: .utf8) else { continue }
            let decision = NativeEditorPolicy.decide(text: text)
            if decision.mode == .webFallback {
                results.append([
                    "fixture": name,
                    "bytes": text.utf8.count,
                    "skipped": true,
                    "policy": decision.mode.rawValue,
                    "fallback_reason": decision.fallbackReason?.rawValue as Any,
                    "note": "native benchmark skipped because the file exceeded a native safety limit"
                ])
                continue
            }
            print("BENCH START \(name)"); fflush(stdout)
            let cpuStart = clock()
            let openedAt = DispatchTime.now().uptimeNanoseconds
            let initial = milliseconds { add(name: name, text: text, language: languageFor(name)); show(); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            var visibleColors = Set<String>()
            for _ in 0..<500 {
                let storage = doc.controller.textView.textStorage!
                let range = doc.controller.textView.visibleTextRange ?? NSRange(location: 0, length: 0)
                visibleColors = []
                storage.enumerateAttribute(.foregroundColor, in: range) { value, _, _ in if let value { visibleColors.insert(String(describing: value)) } }
                if visibleColors.count > 1 { break }
                await pump(0.02)
            }
            let highlightReady = Double(DispatchTime.now().uptimeNanoseconds - openedAt) / 1e6
            var input: [Double] = [], scroll: [Double] = [], tabs: [Double] = []
            for _ in 0..<20 {
                input.append(milliseconds { doc.controller.textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "a"); window.displayIfNeeded() })
                await pump(0.02)
            }
            for i in 0..<20 {
                scroll.append(milliseconds { doc.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(i * 200))); doc.controller.scrollView.reflectScrolledClipView(doc.controller.scrollView.contentView); window.displayIfNeeded() }); await pump(0.02)
            }
            let previous = active
            for _ in 0..<20 { tabs.append(milliseconds { active = 0; show(); active = previous; show(); window.displayIfNeeded() }) }
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            results.append(["fixture": name, "bytes": text.utf8.count, "construct_layout_ms": initial, "first_visible_highlight_ms": highlightReady, "visible_highlight_colors": visibleColors.count,
                "input_sync_ms": input, "scroll_sync_ms": scroll, "two_tab_switch_sync_ms": tabs,
                "process_cpu_seconds": Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC), "process_maxrss_bytes": usage.ru_maxrss,
                "note": "one run; synchronous API + display submission, not input-to-photon; awaited visible highlight up to 10s; retained earlier documents; maxrss cumulative"])
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: evidenceOutput(benchmark: true))) }
            print("BENCH DONE \(name)"); fflush(stdout)
        }
        let duration = milliseconds { for i in 0..<50 { add(name: "tab\(i).swift", text: "// tab\nlet x = \(i)\n", language: .swift); show() } }
        results.append(["fixture": "50 additional retained tabs", "construct_ms": duration])
        let a = (0..<10000).map { "line \($0)" }.joined(separator: "\n")
        let b = (0..<10000).map { $0 % 5 == 0 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n")
        var count = 0
        let benchmarkOld = NativeDiffInput(documentID: "bench", path: "large.swift", revision: 1, content: a)
        let benchmarkNew = NativeDiffInput(documentID: "bench", path: "large.swift", revision: 2, content: b)
        let diffTime = milliseconds { count = NativeDiffModel.calculate(old: benchmarkOld, new: benchmarkNew).rows.count }
        var benchmarkResult: NativeDiffResult?
        let displayTime = milliseconds { benchmarkResult = NativeDiffModel.calculate(old: benchmarkOld, new: benchmarkNew); if let benchmarkResult { diffView.set(result: benchmarkResult, language: "swift", mode: .split) }; diffVisible = true; show(); window.displayIfNeeded() }
        var diffScrollTimes: [Double] = []
        for i in 0..<20 { diffScrollTimes.append(milliseconds { diffView.table.scrollRowToVisible(i * 100); window.displayIfNeeded() }); await pump(0.02) }
        diffView.setMode(.unified); window.contentView?.layoutSubtreeIfNeeded(); diffView.setFrameSize(NSSize(width: 760, height: diffView.frame.height)); diffView.layoutSubtreeIfNeeded(); diffView.setMode(.split)
        results.append(["fixture": "10000 lines / 2000 replacements diff", "alignment_ms": diffTime, "alignment_and_display_ms": displayTime, "scroll_sync_ms": diffScrollTimes, "rows": count, "visible_cells_created": diffView.generatedCellCount, "modes_tested": ["split", "unified"], "width_change_tested": true])
    }
}
