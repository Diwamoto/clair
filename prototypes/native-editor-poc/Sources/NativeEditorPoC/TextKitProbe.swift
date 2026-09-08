import AppKit
import SwiftTreeSitter
import CodeEditLanguages

// Bounded alternative probe, not a second production editor implementation.
func textKitProbe() -> [String: Bool] {
    let view = NSTextView(usingTextLayoutManager: true)
    view.frame = NSRect(x: 0, y: 0, width: 1164, height: 710)
    view.allowsUndo = true
    view.string = "// 日本語 🙂\nlet text = \"hello\"\n"
    let initial = view.string
    var results = ["TextKit2 created": view.textLayoutManager != nil]
    let manager = view.undoManager
    view.insertText("日本👨‍👩‍👧‍👦", replacementRange: NSRange(location: 0, length: 0))
    results["TextKit2 Unicode insertion"] = view.string.hasPrefix("日本👨‍👩‍👧‍👦")
    if let manager { manager.undo(); results["TextKit2 undo"] = view.string == initial }
    else { results["TextKit2 undo manager available without window"] = false }
    view.string = initial
    do {
        let parser = Parser(), language = CodeLanguage.swift.language!
        try parser.setLanguage(language)
        guard let tree = parser.parse(initial), let url = CodeLanguage.swift.queryURL else { return results }
        let query = try Query(language: language, data: Data(contentsOf: url))
        let cursor = query.execute(in: tree)
        var count = 0
        while let capture = cursor.nextCapture() {
            guard capture.range.location >= 0, NSMaxRange(capture.range) <= view.textStorage!.length else { continue }
            let color: NSColor
            switch capture.nameComponents.first {
            case "comment": color = .systemGreen
            case "string": color = .systemRed
            case "keyword": color = .systemPurple
            default: continue
            }
            view.textStorage?.addAttribute(.foregroundColor, value: color, range: capture.range)
            count += 1
        }
        results["TextKit2 basic Tree-sitter capture styling"] = count > 2
        results["TextKit2 remains enabled after styling"] = view.textLayoutManager != nil
    } catch { results["TextKit2 basic Tree-sitter capture styling"] = false }
    return results
}
