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
    if CommandLine.arguments.contains("--ne04") {
        return benchmark ? "evidence/benchmark-ne04.json" : "evidence/checks-ne04.json"
    }
    if benchmark {
        return CommandLine.arguments.contains("--async-policy") ? "evidence/benchmark-async.json" : "evidence/benchmark.json"
    }
    return "evidence/checks.json"
}
extension App {
    @MainActor func runChecks(benchmark: Bool) async {
        var results: [[String: Any]] = []
        func check(_ name: String, _ pass: Bool, expectedFailure: Bool = false) {
            results.append(["test": name, "pass": pass, "expectedFailure": expectedFailure]); print("\(pass ? "PASS" : "FAIL") \(name)"); fflush(stdout)
        }
        let d = doc, t = doc.controller.textView!
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
        results.append(["alternative_TextKit2": textKitProbe(), "note": "basic captures only; incremental syntax, IME and multicursor not validated for alternative"])
        if benchmark { await runBenchmarks(into: &results) }
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: evidenceOutput(benchmark: benchmark))) }
        let failed = results.contains { ($0["pass"] as? Bool) == false && ($0["expectedFailure"] as? Bool) != true }
        fflush(stdout)
        exit(failed ? 1 : 0)
    }
    @MainActor func runBenchmarks(into results: inout [[String: Any]]) async {
        let fixtureRoot = URL(fileURLWithPath: "fixtures")
        for name in ["normal.swift", "1mb.swift", "10mb.swift", "long-line.ts"] {
            guard let text = try? String(contentsOf: fixtureRoot.appendingPathComponent(name), encoding: .utf8) else { continue }
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
        let diffTime = milliseconds { count = alignedRows(old: a, new: b).count }
        let displayTime = milliseconds { rows = alignedRows(old: a, new: b); table.reloadData(); diffVisible = true; show(); window.displayIfNeeded() }
        var diffScrollTimes: [Double] = []
        for i in 0..<20 { diffScrollTimes.append(milliseconds { table.scrollRowToVisible(i * 100); window.displayIfNeeded() }); await pump(0.02) }
        results.append(["fixture": "10000 lines / 2000 replacements diff", "alignment_ms": diffTime, "alignment_and_display_ms": displayTime, "scroll_sync_ms": diffScrollTimes, "rows": count])
    }
}
