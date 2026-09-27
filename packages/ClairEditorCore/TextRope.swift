// All nodes and leaf payloads are immutable. Path copying shares untouched
// subtrees across snapshots without locks or @unchecked Sendable.
struct TextMetrics: Sendable, Equatable {
  var utf8 = 0
  var utf16 = 0
  var scalars = 0
  var graphemes = 0
  var breaks = 0

  subscript(space: TextCoordinateSpace) -> Int {
    switch space {
    case .utf8: return utf8
    case .utf16: return utf16
    case .scalar: return scalars
    case .grapheme: return graphemes
    }
  }

  static func + (lhs: Self, rhs: Self) -> Self {
    Self(
      utf8: lhs.utf8 + rhs.utf8, utf16: lhs.utf16 + rhs.utf16,
      scalars: lhs.scalars + rhs.scalars, graphemes: lhs.graphemes + rhs.graphemes,
      breaks: lhs.breaks + rhs.breaks
    )
  }

  static func character(_ text: Substring) -> Self {
    Self(
      utf8: text.utf8.count, utf16: text.utf16.count,
      scalars: text.unicodeScalars.count, graphemes: 1,
      breaks: TextLineEnding.classify(text.first!) == nil ? 0 : 1
    )
  }
}

struct TextBreak: Sendable {
  let offset: Int
  let length: Int
  let id: TextLineID
  let ending: TextLineEnding

  func shifted(by delta: Int) -> Self {
    Self(offset: offset + delta, length: length, id: id, ending: ending)
  }
}

struct TextLeaf: Sendable {
  let text: String
  let metrics: TextMetrics
  let breaks: [TextBreak]

  init(_ text: String, breaks: [TextBreak]) {
    self.text = text
    self.breaks = breaks
    metrics = TextMetrics(
      utf8: text.utf8.count, utf16: text.utf16.count,
      scalars: text.unicodeScalars.count, graphemes: text.count, breaks: breaks.count
    )
  }

  func slice(_ range: Range<Int>) -> Self {
    let lower = text.utf8.index(text.startIndex, offsetBy: range.lowerBound)
    let upper = text.utf8.index(text.startIndex, offsetBy: range.upperBound)
    return Self(
      String(text[lower..<upper]),
      breaks: breaks.filter { range.contains($0.offset) }.map {
        $0.shifted(by: -range.lowerBound)
      }
    )
  }

  func boundary(
    at offset: Int, in space: TextCoordinateSpace, rounding: TextBoundaryRounding
  ) throws -> TextMetrics {
    if offset == 0 { return TextMetrics() }
    if offset == metrics[space] { return metrics }
    // ASCII without CRLF has one byte per grapheme in every coordinate space.
    if metrics.utf8 == metrics.graphemes {
      var lower = 0
      var upper = breaks.count
      while lower < upper {
        let middle = (lower + upper) / 2
        if breaks[middle].offset < offset { lower = middle + 1 } else { upper = middle }
      }
      return TextMetrics(
        utf8: offset, utf16: offset, scalars: offset, graphemes: offset, breaks: lower
      )
    }
    var prefix = TextMetrics()
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(after: index)
      let end = prefix + TextMetrics.character(text[index..<next])
      if offset == end[space] { return end }
      if offset < end[space] {
        switch rounding {
        case .strict: throw TextStorageError.invalidBoundary
        case .down: return prefix
        case .up: return end
        }
      }
      prefix = end
      index = next
    }
    preconditionFailure("validated leaf coordinate must be reachable")
  }
}

final class TextNode: Sendable {
  let leaf: TextLeaf?
  let left: TextNode?
  let right: TextNode?
  let height: Int
  let metrics: TextMetrics

  init(_ leaf: TextLeaf) {
    self.leaf = leaf
    left = nil
    right = nil
    height = 1
    metrics = leaf.metrics
  }

  init(_ left: TextNode, _ right: TextNode) {
    leaf = nil
    self.left = left
    self.right = right
    height = max(left.height, right.height) + 1
    metrics = left.metrics + right.metrics
  }

  static func join(_ left: TextNode?, _ right: TextNode?) -> TextNode? {
    guard let left else { return right }
    guard let right else { return left }
    if left.height > right.height + 1 {
      return balanced(left.left!, join(left.right!, right)!)
    }
    if right.height > left.height + 1 {
      return balanced(join(left, right.left!)!, right.right!)
    }
    return TextNode(left, right)
  }

  private static func balanced(_ left: TextNode, _ right: TextNode) -> TextNode {
    if left.height > right.height + 1 {
      let a = left.left!
      let b = left.right!
      if a.height >= b.height { return TextNode(a, TextNode(b, right)) }
      return TextNode(TextNode(a, b.left!), TextNode(b.right!, right))
    }
    if right.height > left.height + 1 {
      let a = right.left!
      let b = right.right!
      if b.height >= a.height { return TextNode(TextNode(left, a), b) }
      return TextNode(TextNode(left, a.left!), TextNode(a.right!, b))
    }
    return TextNode(left, right)
  }

  func split(at offset: Int) -> (TextNode?, TextNode?) {
    if offset == 0 { return (nil, self) }
    if offset == metrics.utf8 { return (self, nil) }
    if let leaf {
      return (
        TextNode(leaf.slice(0..<offset)),
        TextNode(leaf.slice(offset..<metrics.utf8))
      )
    }
    let left = left!
    let right = right!
    if offset < left.metrics.utf8 {
      let (prefix, suffix) = left.split(at: offset)
      return (prefix, Self.join(suffix, right))
    }
    let (prefix, suffix) = right.split(at: offset - left.metrics.utf8)
    return (Self.join(left, prefix), suffix)
  }

  var firstLeaf: TextLeaf { leaf ?? left!.firstLeaf }
  var lastLeaf: TextLeaf { leaf ?? right!.lastLeaf }

  func removingFirst() -> (TextLeaf, TextNode?) {
    if let leaf { return (leaf, nil) }
    let (first, rest) = left!.removingFirst()
    return (first, Self.join(rest, right))
  }

  func removingLast() -> (TextNode?, TextLeaf) {
    if let leaf { return (nil, leaf) }
    let (rest, last) = right!.removingLast()
    return (Self.join(left, rest), last)
  }

  func boundary(
    at offset: Int, in space: TextCoordinateSpace, rounding: TextBoundaryRounding
  ) throws -> TextMetrics {
    if offset == 0 { return TextMetrics() }
    if offset == metrics[space] { return metrics }
    if let leaf { return try leaf.boundary(at: offset, in: space, rounding: rounding) }
    let prefix = left!.metrics
    if offset <= prefix[space] {
      return try left!.boundary(at: offset, in: space, rounding: rounding)
    }
    return try prefix
      + right!.boundary(at: offset - prefix[space], in: space, rounding: rounding)
  }

  func lineBreak(at index: Int) -> TextBreak {
    if let leaf { return leaf.breaks[index] }
    if index < left!.metrics.breaks { return left!.lineBreak(at: index) }
    return right!.lineBreak(at: index - left!.metrics.breaks).shifted(by: left!.metrics.utf8)
  }

  /// Range and leaf edges are already validated grapheme boundaries.
  func visit(_ range: Range<Int>, _ body: (Substring) -> Void) {
    if range.isEmpty { return }
    if let leaf {
      let lower = leaf.text.utf8.index(leaf.text.startIndex, offsetBy: range.lowerBound)
      let upper = leaf.text.utf8.index(leaf.text.startIndex, offsetBy: range.upperBound)
      body(leaf.text[lower..<upper])
      return
    }
    let pivot = left!.metrics.utf8
    if range.lowerBound < pivot {
      left!.visit(range.lowerBound..<min(range.upperBound, pivot), body)
    }
    if range.upperBound > pivot {
      right!.visit(max(0, range.lowerBound - pivot)..<(range.upperBound - pivot), body)
    }
  }
}
