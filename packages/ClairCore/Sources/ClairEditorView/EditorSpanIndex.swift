import ClairEditorCore

/// Keeps document-wide spans searchable by byte range without visiting every
/// span whenever a new line enters the viewport. Results retain input order,
/// which matters when overlapping syntax colors are applied.
struct EditorSpanIndex<Span> {
  private struct Entry {
    let span: Span
    let range: TextUTF8Range
    let order: Int
  }

  private var entries: [Entry] = []
  private var maximumEnds: [Int] = []

  init(_ spans: [Span], range: (Span) -> TextUTF8Range) {
    entries = spans.enumerated().map { Entry(span: $0.element, range: range($0.element), order: $0.offset) }
    entries.sort {
      $0.range.lowerBound.value == $1.range.lowerBound.value
        ? $0.order < $1.order : $0.range.lowerBound.value < $1.range.lowerBound.value
    }
    var maximum = 0
    for entry in entries {
      maximum = max(maximum, entry.range.upperBound.value)
      maximumEnds.append(maximum)
    }
  }

  func overlapping(_ range: TextUTF8Range) -> [Span] {
    let lower = range.lowerBound.value
    let upper = range.upperBound.value
    guard lower < upper else { return [] }
    var lo = 0
    var hi = entries.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if entries[mid].range.lowerBound.value < upper { lo = mid + 1 } else { hi = mid }
    }
    var matches: [Entry] = []
    var index = lo
    while index > 0 {
      index -= 1
      if maximumEnds[index] <= lower { break }
      let entry = entries[index]
      if entry.range.upperBound.value > lower { matches.append(entry) }
    }
    matches.sort { $0.order < $1.order }
    return matches.map(\.span)
  }
}
