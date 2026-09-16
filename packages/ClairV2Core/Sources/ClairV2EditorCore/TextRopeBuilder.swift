import Foundation

struct TextLineIDSource {
  let documentID: UUID
  var next: UInt64 = 1
  var preservingBefore: UInt64 = 1

  mutating func allocate() throws -> TextLineID {
    guard next < UInt64.max else { throw TextStorageError.identityExhausted }
    defer { next += 1 }
    return TextLineID(documentID: documentID, serial: next)
  }
}

/// Structural work evidence, independent of machine speed. Initial load is
/// separate; an edit counts only text passed through the segmentation builder.
struct TextEditWork {
  var resegmentedUTF8 = 0
  var repairedSeams = 0
}

enum TextRopeBuilder {
  static let leafTarget = 2_048

  static func build(
    _ text: String, preserving markers: [TextBreak] = [],
    ids: inout TextLineIDSource, work: inout TextEditWork
  ) throws -> TextNode? {
    if text.isEmpty { return nil }
    work.resegmentedUTF8 += text.utf8.count
    var nodes: [TextNode] = []
    var chunkStart = text.startIndex
    var chunkByteStart = 0
    var chunkBreaks: [TextBreak] = []
    var byteOffset = 0
    var markerIndex = 0
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(after: index)
      let width = text[index..<next].utf8.count
      if let ending = TextLineEnding.classify(text[index]) {
        while markerIndex < markers.count && markers[markerIndex].offset < byteOffset {
          markerIndex += 1
        }
        // A newly formed CRLF can contain two surviving terminators. The
        // leftmost surviving identity wins; the other is permanently retired.
        var inheritedID: TextLineID?
        while markerIndex < markers.count && markers[markerIndex].offset < byteOffset + width {
          let candidate = markers[markerIndex].id
          // A terminator surviving from the old revision takes precedence
          // over an inserted CR/LF, even when that new scalar is on its left.
          if inheritedID == nil
            || (inheritedID!.serial >= ids.preservingBefore
              && candidate.serial < ids.preservingBefore)
          {
            inheritedID = candidate
          }
          markerIndex += 1
        }
        let id = try inheritedID ?? ids.allocate()
        chunkBreaks.append(
          TextBreak(offset: byteOffset - chunkByteStart, length: width, id: id, ending: ending)
        )
      }
      byteOffset += width
      if byteOffset - chunkByteStart >= leafTarget || next == text.endIndex {
        nodes.append(TextNode(TextLeaf(String(text[chunkStart..<next]), breaks: chunkBreaks)))
        chunkStart = next
        chunkByteStart = byteOffset
        chunkBreaks = []
      }
      index = next
    }
    return balanced(nodes, in: nodes.indices)
  }

  private static func balanced(_ nodes: [TextNode], in range: Range<Int>) -> TextNode {
    if range.count == 1 { return nodes[range.lowerBound] }
    let middle = range.lowerBound + range.count / 2
    return TextNode(
      balanced(nodes, in: range.lowerBound..<middle),
      balanced(nodes, in: middle..<range.upperBound)
    )
  }

  /// Concatenation must repair Unicode boundaries, not merely add cached counts.
  /// The trailing Character carries the grapheme context (including RI parity,
  /// prepend, Indic conjunct and emoji ZWJ sequences). If the seam changes,
  /// stream forward one leaf at a time until an unchanged boundary is reached.
  /// We never flatten a long line or the untouched suffix to do this repair.
  static func concatenate(
    _ left: TextNode?, _ right: TextNode?,
    ids: inout TextLineIDSource, work: inout TextEditWork
  ) throws -> TextNode? {
    guard let left else { return right }
    guard let right else { return left }
    if left.lastLeaf.metrics.utf8 + right.firstLeaf.metrics.utf8 > leafTarget,
      stableBoundary(left.lastLeaf, right.firstLeaf)
    {
      return TextNode.join(left, right)
    }
    var (prefix, pending) = left.removingLast()
    var (next, remainder) = right.removingFirst()
    while true {
      work.repairedSeams += 1
      let markers = pending.breaks + next.breaks.map { $0.shifted(by: pending.metrics.utf8) }
      let rebuilt = try build(
        pending.text + next.text, preserving: markers, ids: &ids, work: &work
      )!
      let (complete, last) = rebuilt.removingLast()
      prefix = TextNode.join(prefix, complete)
      pending = last
      guard let suffix = remainder else { return TextNode.join(prefix, TextNode(pending)) }
      if stableBoundary(pending, suffix.firstLeaf) {
        return TextNode.join(TextNode.join(prefix, TextNode(pending)), suffix)
      }
      (next, remainder) = suffix.removingFirst()
    }
  }

  private static func stableBoundary(_ left: TextLeaf, _ right: TextLeaf) -> Bool {
    let tail = String(left.text.last!)
    let head = String(right.text.first!)
    let joined = tail + head
    return joined.count == 2 && String(joined.first!).utf8.count == tail.utf8.count
  }
}
