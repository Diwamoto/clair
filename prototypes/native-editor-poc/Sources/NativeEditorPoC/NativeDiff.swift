import AppKit
import CodeEditLanguages

enum NativeDiffLineKind: Equatable {
    case context
    case added
    case removed
    case replaced
}

struct NativeDiffInput {
    let documentID: String
    let path: String
    let revision: UInt64
    let content: String
}

struct NativeDiffLine {
    let id: String
    let kind: NativeDiffLineKind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let oldText: String?
    let newText: String?
    let oldLineEnding: String?
    let newLineEnding: String?
    let hunkID: String?
}

struct NativeDiffHunk {
    let id: String
    let rowStart: Int
    let rowCount: Int
    let oldLineStart: Int
    let oldLineCount: Int
    let newLineStart: Int
    let newLineCount: Int
}

struct NativeDiffResult {
    let pairID: String
    let oldRevision: UInt64
    let newRevision: UInt64
    let oldPath: String
    let newPath: String
    let rows: [NativeDiffLine]
    let hunks: [NativeDiffHunk]

    func reconstructOldSource() -> String {
        rows.compactMap { line in
            guard let text = line.oldText else { return nil }
            return text + (line.oldLineEnding ?? "")
        }.joined()
    }

    func reconstructNewSource() -> String {
        rows.compactMap { line in
            guard let text = line.newText else { return nil }
            return text + (line.newLineEnding ?? "")
        }.joined()
    }
}

/// Engine-independent presentation model. Line terminators are retained as metadata
/// and are never represented by synthetic blank rows.
enum NativeDiffModel {
    private struct LineValue: Equatable {
        let text: String
        let terminator: String
    }

    private enum Operation {
        case equal(old: Int, new: Int)
        case delete(old: Int)
        case insert(new: Int)
    }

    private struct PendingRow {
        let kind: NativeDiffLineKind
        let oldIndex: Int?
        let newIndex: Int?
    }

    static func calculate(old: NativeDiffInput, new: NativeDiffInput, contextLines: Int = 3) -> NativeDiffResult {
        let pairID = "\(old.documentID)->\(new.documentID)"
        let oldLines = splitLines(old.content)
        let newLines = splitLines(new.content)
        let operations = myers(oldLines, newLines)
        var pendingRows: [PendingRow] = []
        var index = 0

        while index < operations.count {
            switch operations[index] {
            case let .equal(oldIndex, newIndex):
                pendingRows.append(.init(kind: .context, oldIndex: oldIndex, newIndex: newIndex))
                index += 1
            case .delete, .insert:
                var deleted: [Int] = []
                var inserted: [Int] = []
                while index < operations.count {
                    switch operations[index] {
                    case .equal:
                        break
                    case let .delete(oldIndex):
                        deleted.append(oldIndex)
                        index += 1
                        continue
                    case let .insert(newIndex):
                        inserted.append(newIndex)
                        index += 1
                        continue
                    }
                    break
                }
                for pairIndex in 0..<min(deleted.count, inserted.count) {
                    pendingRows.append(.init(kind: .replaced, oldIndex: deleted[pairIndex], newIndex: inserted[pairIndex]))
                }
                for oldIndex in deleted.dropFirst(min(deleted.count, inserted.count)) {
                    pendingRows.append(.init(kind: .removed, oldIndex: oldIndex, newIndex: nil))
                }
                for newIndex in inserted.dropFirst(min(deleted.count, inserted.count)) {
                    pendingRows.append(.init(kind: .added, oldIndex: nil, newIndex: newIndex))
                }
            }
        }

        var rows = pendingRows.enumerated().map { index, pending in
            NativeDiffLine(
                id: "\(pairID):row:\(index)",
                kind: pending.kind,
                oldLineNumber: pending.oldIndex.map { $0 + 1 },
                newLineNumber: pending.newIndex.map { $0 + 1 },
                oldText: pending.oldIndex.map { oldLines[$0].text },
                newText: pending.newIndex.map { newLines[$0].text },
                oldLineEnding: pending.oldIndex.map { oldLines[$0].terminator },
                newLineEnding: pending.newIndex.map { newLines[$0].terminator },
                hunkID: nil
            )
        }
        let hunks = makeHunks(rows: &rows, pairID: pairID, oldRevision: old.revision, newRevision: new.revision, contextLines: max(0, contextLines))
        return NativeDiffResult(pairID: pairID, oldRevision: old.revision, newRevision: new.revision, oldPath: old.path, newPath: new.path, rows: rows, hunks: hunks)
    }

    private static func splitLines(_ source: String) -> [LineValue] {
        guard !source.isEmpty else { return [] }
        var result: [LineValue] = []
        let scalars = source.unicodeScalars
        var lineStart = scalars.startIndex
        var cursor = scalars.startIndex
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            if scalar == "\n" || scalar == "\r" {
                let next = scalars.index(after: cursor)
                let terminator: String
                if scalar == "\r", next < scalars.endIndex, scalars[next] == "\n" {
                    terminator = "\r\n"
                    cursor = scalars.index(after: next)
                } else {
                    terminator = String(scalar)
                    cursor = next
                }
                let end = scalars.index(cursor, offsetBy: -terminator.unicodeScalars.count)
                result.append(.init(text: String(scalars[lineStart..<end]), terminator: terminator))
                lineStart = cursor
            } else {
                cursor = scalars.index(after: cursor)
            }
        }
        if lineStart < scalars.endIndex { result.append(.init(text: String(scalars[lineStart...]), terminator: "")) }
        return result
    }

    private static func myers(_ old: [LineValue], _ new: [LineValue]) -> [Operation] {
        let maxDistance = old.count + new.count
        guard maxDistance > 0 else { return [] }
        let offset = maxDistance
        var vector = [Int](repeating: 0, count: maxDistance * 2 + 1)
        var trace: [[Int]] = []
        for distance in 0...maxDistance {
            var next = vector
            var diagonal = -distance
            while diagonal <= distance {
                let vectorIndex = offset + diagonal
                let x: Int
                if diagonal == -distance || (diagonal != distance && vector[offset + diagonal - 1] < vector[offset + diagonal + 1]) {
                    x = vector[offset + diagonal + 1]
                } else {
                    x = vector[offset + diagonal - 1] + 1
                }
                var advancedX = x
                var advancedY = advancedX - diagonal
                while advancedX < old.count, advancedY < new.count, old[advancedX] == new[advancedY] {
                    advancedX += 1
                    advancedY += 1
                }
                next[vectorIndex] = advancedX
                if advancedX >= old.count, advancedY >= new.count {
                    trace.append(next)
                    return backtrack(trace: trace, distance: distance, oldCount: old.count, newCount: new.count, offset: offset)
                }
                diagonal += 2
            }
            trace.append(next)
            vector = next
        }
        return []
    }

    private static func backtrack(trace: [[Int]], distance: Int, oldCount: Int, newCount: Int, offset: Int) -> [Operation] {
        var oldIndex = oldCount
        var newIndex = newCount
        var reversed: [Operation] = []
        if distance > 0 {
            for currentDistance in stride(from: distance, through: 1, by: -1) {
                let previous = trace[currentDistance - 1]
                let diagonal = oldIndex - newIndex
                let previousDiagonal: Int
                if diagonal == -currentDistance || (diagonal != currentDistance && previous[offset + diagonal - 1] < previous[offset + diagonal + 1]) {
                    previousDiagonal = diagonal + 1
                } else {
                    previousDiagonal = diagonal - 1
                }
                let previousOldIndex = previous[offset + previousDiagonal]
                let previousNewIndex = previousOldIndex - previousDiagonal
                while oldIndex > previousOldIndex, newIndex > previousNewIndex {
                    reversed.append(.equal(old: oldIndex - 1, new: newIndex - 1))
                    oldIndex -= 1; newIndex -= 1
                }
                if oldIndex == previousOldIndex {
                    reversed.append(.insert(new: newIndex - 1)); newIndex -= 1
                } else {
                    reversed.append(.delete(old: oldIndex - 1)); oldIndex -= 1
                }
            }
        }
        while oldIndex > 0, newIndex > 0 { reversed.append(.equal(old: oldIndex - 1, new: newIndex - 1)); oldIndex -= 1; newIndex -= 1 }
        while oldIndex > 0 { reversed.append(.delete(old: oldIndex - 1)); oldIndex -= 1 }
        while newIndex > 0 { reversed.append(.insert(new: newIndex - 1)); newIndex -= 1 }
        return reversed.reversed()
    }

    private static func makeHunks(rows: inout [NativeDiffLine], pairID: String, oldRevision: UInt64, newRevision: UInt64, contextLines: Int) -> [NativeDiffHunk] {
        let changedRows = rows.indices.filter { rows[$0].kind != .context }
        guard let firstChanged = changedRows.first else { return [] }
        var spans: [(Int, Int)] = []
        var start = max(0, firstChanged - contextLines)
        var end = min(rows.count - 1, firstChanged + contextLines)
        for changedRow in changedRows.dropFirst() {
            let candidateStart = max(0, changedRow - contextLines)
            let candidateEnd = min(rows.count - 1, changedRow + contextLines)
            if candidateStart <= end + 1 { end = max(end, candidateEnd) }
            else { spans.append((start, end)); start = candidateStart; end = candidateEnd }
        }
        spans.append((start, end))
        return spans.enumerated().map { hunkIndex, span in
            let id = "\(pairID):old:\(oldRevision):new:\(newRevision):hunk:\(hunkIndex):\(span.0)-\(span.1)"
            let range = span.0...span.1
            let oldNumbers = range.compactMap { rows[$0].oldLineNumber }
            let newNumbers = range.compactMap { rows[$0].newLineNumber }
            let hunk = NativeDiffHunk(id: id, rowStart: span.0, rowCount: span.1 - span.0 + 1, oldLineStart: oldNumbers.min() ?? 0, oldLineCount: oldNumbers.count, newLineStart: newNumbers.min() ?? 0, newLineCount: newNumbers.count)
            for rowIndex in range {
                let row = rows[rowIndex]
                rows[rowIndex] = NativeDiffLine(id: row.id, kind: row.kind, oldLineNumber: row.oldLineNumber, newLineNumber: row.newLineNumber, oldText: row.oldText, newText: row.newText, oldLineEnding: row.oldLineEnding, newLineEnding: row.newLineEnding, hunkID: id)
            }
            return hunk
        }
    }
}

enum NativeDiffMode: String {
    case unified
    case split
}

enum DiffSyntaxHighlighter {
    private static let keywords = #"\b(?:class|struct|enum|func|let|var|if|else|for|while|return|import|public|private|internal|extension|protocol|switch|case|guard|in|true|false|nil|async|await)\b"#
    private static let strings = #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#
    private static let numbers = #"\b[0-9]+(?:\.[0-9]+)?\b"#

    static func attributed(text: String, language: String, foreground: NSColor = .labelColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: foreground])
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        func color(_ pattern: String, _ color: NSColor) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            expression.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                if let range = match?.range { result.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
        color(#"//.*$|#.*$"#, .systemGreen)
        color(strings, .systemRed)
        color(numbers, .systemOrange)
        if language != "plain" { color(keywords, .systemPurple) }
        return result
    }
}

final class DiffLineCellView: NSTableCellView {
    let lineNumber = NSTextField(labelWithString: "")
    let content = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        lineNumber.alignment = .right
        lineNumber.textColor = .secondaryLabelColor
        lineNumber.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        content.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        content.lineBreakMode = .byCharWrapping
        content.maximumNumberOfLines = 0
        content.usesSingleLineMode = false
        content.cell?.wraps = true
        content.cell?.isScrollable = false
        content.isEditable = false
        content.isSelectable = false
        for view in [lineNumber, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            lineNumber.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            lineNumber.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            lineNumber.widthAnchor.constraint(equalToConstant: 48),
            content.leadingAnchor.constraint(equalTo: lineNumber.trailingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class NativeDiffView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let modeControl = NSSegmentedControl(labels: ["Unified", "左右"], trackingMode: .selectOne, target: nil, action: nil)
    let pathLabel = NSTextField(labelWithString: "")
    let scrollView = NSScrollView()
    let table = NSTableView()
    private(set) var result: NativeDiffResult?
    private(set) var mode: NativeDiffMode = .split
    private(set) var generatedCellCount = 0
    private(set) var lastSelection: (rowID: String, hunkID: String?)?
    var language = "plain"
    var onSelection: ((String) -> Void)?
    var onModeChange: ((NativeDiffMode) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        modeControl.selectedSegment = 1
        modeControl.target = self
        modeControl.action = #selector(changeDiffMode)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.font = .systemFont(ofSize: 12)
        let toolbar = NSStackView(views: [modeControl, pathLabel])
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)
        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.intercellSpacing = NSSize(width: 1, height: 0)
        table.rowHeight = 22
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        rebuildColumns()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(result: NativeDiffResult, language: String, mode: NativeDiffMode = .split) {
        self.result = result
        self.language = language
        self.mode = mode
        modeControl.selectedSegment = mode == .split ? 1 : 0
        pathLabel.stringValue = "\(result.oldPath) → \(result.newPath) · \(result.rows.count) 行 · \(result.hunks.count) hunk"
        generatedCellCount = 0
        lastSelection = nil
        rebuildColumns()
        table.reloadData()
    }

    func setMode(_ mode: NativeDiffMode) {
        self.mode = mode
        modeControl.selectedSegment = mode == .split ? 1 : 0
        generatedCellCount = 0
        rebuildColumns()
        table.reloadData()
        onModeChange?(mode)
    }

    @objc private func changeDiffMode() {
        setMode(modeControl.selectedSegment == 0 ? .unified : .split)
    }

    private func rebuildColumns() {
        table.tableColumns.forEach { table.removeTableColumn($0) }
        if mode == .unified {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("unified"))
            column.title = "Diff"
            column.width = max(480, bounds.width - 20)
            table.addTableColumn(column)
        } else {
            for (identifier, title) in [("old", "Original"), ("new", "Proposed")] {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
                column.title = title
                column.width = max(300, (bounds.width - 22) / 2)
                table.addTableColumn(column)
            }
        }
    }

    override func layout() {
        super.layout()
        rebuildColumns()
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { result?.rows.count ?? 0 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let result else { return 22 }
        let diffRow = result.rows[row]
        if mode == .unified {
            let text = unifiedText(for: diffRow)
            return max(22, height(for: text, width: max(180, tableView.tableColumns.first?.width ?? 400) - 70))
        }
        let old = diffRow.oldText ?? ""
        let new = diffRow.newText ?? ""
        let oldHeight = height(for: old, width: max(180, tableView.tableColumns.first?.width ?? 400) - 70)
        let newHeight = height(for: new, width: max(180, tableView.tableColumns.last?.width ?? 400) - 70)
        return max(22, oldHeight, newHeight)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let result, let identifier = tableColumn?.identifier.rawValue else { return nil }
        generatedCellCount += 1
        let cell = DiffLineCellView(frame: .zero)
        let diffRow = result.rows[row]
        switch identifier {
        case "unified":
            cell.lineNumber.stringValue = ""
            cell.content.attributedStringValue = unifiedAttributed(for: diffRow)
        case "old":
            cell.lineNumber.stringValue = diffRow.oldLineNumber.map(String.init) ?? ""
            cell.content.attributedStringValue = attributed(text: diffRow.oldText ?? "", color: diffRow.kind == .removed || diffRow.kind == .replaced ? .systemRed : .labelColor)
        default:
            cell.lineNumber.stringValue = diffRow.newLineNumber.map(String.init) ?? ""
            cell.content.attributedStringValue = attributed(text: diffRow.newText ?? "", color: diffRow.kind == .added || diffRow.kind == .replaced ? .systemGreen : .labelColor)
        }
        cell.wantsLayer = true
        cell.layer?.backgroundColor = background(for: diffRow, column: identifier).cgColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard let result, row >= 0, row < result.rows.count else { return }
        let selected = result.rows[row]
        lastSelection = (selected.id, selected.hunkID)
        onSelection?("selected row \(selected.id) hunk \(selected.hunkID ?? "none")")
    }

    private func height(for text: String, width: CGFloat) -> CGFloat {
        let rect = NSString(string: text.isEmpty ? " " : text).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        return ceil(rect.height) + 6
    }

    private func unifiedText(for row: NativeDiffLine) -> String {
        switch row.kind {
        case .context: return "  \(row.newLineNumber ?? row.oldLineNumber ?? 0)  \(row.newText ?? row.oldText ?? "")"
        case .removed: return "- \(row.oldLineNumber.map(String.init) ?? "–")  \(row.oldText ?? "")"
        case .added: return "+ \(row.newLineNumber.map(String.init) ?? "–")  \(row.newText ?? "")"
        case .replaced: return "- \(row.oldLineNumber.map(String.init) ?? "–")  \(row.oldText ?? "")\n+ \(row.newLineNumber.map(String.init) ?? "–")  \(row.newText ?? "")"
        }
    }

    private func unifiedAttributed(for row: NativeDiffLine) -> NSAttributedString {
        let value = unifiedText(for: row)
        let color: NSColor = row.kind == .removed ? .systemRed : row.kind == .added ? .systemGreen : .labelColor
        return attributed(text: value, color: color)
    }

    private func attributed(text: String, color: NSColor) -> NSAttributedString {
        DiffSyntaxHighlighter.attributed(text: text, language: language, foreground: color)
    }

    private func background(for row: NativeDiffLine, column: String) -> NSColor {
        switch (row.kind, column) {
        case (.removed, "old"), (.replaced, "old"): return NSColor.systemRed.withAlphaComponent(0.10)
        case (.added, "new"), (.replaced, "new"): return NSColor.systemGreen.withAlphaComponent(0.10)
        case (.removed, "unified"): return NSColor.systemRed.withAlphaComponent(0.10)
        case (.added, "unified"): return NSColor.systemGreen.withAlphaComponent(0.10)
        default: return .clear
        }
    }
}
