import Foundation

// `TextBuffer` is the editor half of the engine's model layer. The shared
// surface above it never sees this type; it is the storage that
// `ProjectEditorDocumentModel` applies transactions to, and the bridge between
// the five coordinate spaces the p0028 design fixes: UTF-8 bytes for storage,
// UTF-16 for the document contract and AppKit, grapheme clusters for caret
// motion, and line/column for gutters, LSP, and `clair open path:line:column`.

/// Failures the buffer reports instead of applying part of an edit.
///
/// The document contract rejects a whole transaction rather than leaving the
/// text half-edited, so every failure here happens before any mutation.
enum TextBufferError: Error, Equatable {
  case invalidUTF8
  case invalidUTF16Range(location: Int, length: Int, utf16Length: Int)
}

/// A 1-based line and column pair. Columns count UTF-16 units inside the line,
/// which is the unit the document contract and AppKit already use.
struct TextBufferPosition: Equatable, Hashable, Sendable {
  let line: Int
  let column: Int
}

/// Storage facts a test or the Dev harness can assert on.
///
/// `appendedByteCount` is the evidence that an edit costs the size of the edit
/// rather than the size of the document: editing a 10MB file only ever appends
/// the inserted text.
struct TextBufferMetrics: Equatable, Sendable {
  let pieceCount: Int
  let originalByteCount: Int
  let appendedByteCount: Int
  let utf16Length: Int
  let lineCount: Int

  var storedByteCount: Int {
    originalByteCount + appendedByteCount
  }
}

/// Append-only byte storage with fixed-size block summaries.
///
/// A piece table never rewrites stored bytes, so a block summary stays true once
/// written. The summaries are what keep every conversion bounded by one block
/// instead of by the document length: counting UTF-16 units or line feeds in any
/// byte range is a table lookup plus a scan of at most `blockSize` bytes.
private final class TextByteStore {
  static let blockSize = 1024

  private(set) var bytes: [UInt8] = []
  /// UTF-16 units contained in `[0, index * blockSize)`.
  private var utf16Prefix: [Int] = [0]
  /// Line feeds contained in `[0, index * blockSize)`.
  private var newlinePrefix: [Int] = [0]

  init() {}

  init(bytes: [UInt8]) {
    append(bytes)
  }

  var byteCount: Int {
    bytes.count
  }

  func append(_ newBytes: [UInt8]) {
    guard !newBytes.isEmpty else {
      return
    }
    bytes.append(contentsOf: newBytes)
    summarizeCompleteBlocks()
  }

  func copyBytes(in range: Range<Int>) -> ArraySlice<UInt8> {
    bytes[range]
  }

  func utf16Count(in range: Range<Int>) -> Int {
    utf16Count(upTo: range.upperBound) - utf16Count(upTo: range.lowerBound)
  }

  func newlineCount(in range: Range<Int>) -> Int {
    newlineCount(upTo: range.upperBound) - newlineCount(upTo: range.lowerBound)
  }

  /// Byte offset reached by advancing `utf16Units` from `start`.
  ///
  /// Returns `nil` when the offset would land between the two halves of a
  /// surrogate pair or would run past `limit`. That is how a UTF-16 offset that
  /// splits a scalar is rejected without materializing the text.
  func byteOffset(advancing utf16Units: Int, from start: Int, limit: Int) -> Int? {
    guard utf16Units >= 0, start <= limit else {
      return nil
    }
    let target = utf16Count(upTo: start) + utf16Units
    let block = Self.lastIndex(in: utf16Prefix, notGreaterThan: target)
    var offset = block * Self.blockSize
    var running = utf16Prefix[block]
    if offset < start {
      offset = start
      running = utf16Count(upTo: start)
    }

    while running < target {
      guard offset < limit else {
        return nil
      }
      running += Self.utf16Weight(bytes[offset])
      offset += 1
    }
    guard running == target, offset <= limit else {
      return nil
    }
    while offset < limit, Self.isContinuation(bytes[offset]) {
      offset += 1
    }
    return offset
  }

  /// Byte offset just after the `count`-th line feed at or after `start`.
  func byteOffset(afterNewlines count: Int, from start: Int, limit: Int) -> Int? {
    guard count >= 0 else {
      return nil
    }
    guard count > 0 else {
      return start
    }
    let target = newlineCount(upTo: start) + count
    let block = Self.lastIndex(in: newlinePrefix, notGreaterThan: target - 1)
    var offset = block * Self.blockSize
    var running = newlinePrefix[block]
    if offset < start {
      offset = start
      running = newlineCount(upTo: start)
    }

    while offset < limit {
      let byte = bytes[offset]
      offset += 1
      if byte == 0x0A {
        running += 1
        if running == target {
          return offset
        }
      }
    }
    return nil
  }

  private func utf16Count(upTo offset: Int) -> Int {
    let block = offset / Self.blockSize
    var total = utf16Prefix[block]
    for index in (block * Self.blockSize)..<offset {
      total += Self.utf16Weight(bytes[index])
    }
    return total
  }

  private func newlineCount(upTo offset: Int) -> Int {
    let block = offset / Self.blockSize
    var total = newlinePrefix[block]
    for index in (block * Self.blockSize)..<offset where bytes[index] == 0x0A {
      total += 1
    }
    return total
  }

  private func summarizeCompleteBlocks() {
    var recorded = utf16Prefix.count - 1
    while (recorded + 1) * Self.blockSize <= bytes.count {
      let start = recorded * Self.blockSize
      var units = 0
      var newlines = 0
      for index in start..<(start + Self.blockSize) {
        let byte = bytes[index]
        units += Self.utf16Weight(byte)
        if byte == 0x0A {
          newlines += 1
        }
      }
      utf16Prefix.append(utf16Prefix[recorded] + units)
      newlinePrefix.append(newlinePrefix[recorded] + newlines)
      recorded += 1
    }
  }

  /// UTF-16 units a single UTF-8 byte contributes.
  ///
  /// The weight only depends on the byte itself, so block sums stay additive
  /// even when a block boundary falls inside a scalar.
  private static func utf16Weight(_ byte: UInt8) -> Int {
    if byte < 0x80 {
      return 1
    }
    if byte < 0xC0 {
      return 0
    }
    if byte < 0xF0 {
      return 1
    }
    return 2
  }

  private static func isContinuation(_ byte: UInt8) -> Bool {
    byte & 0xC0 == 0x80
  }

  private static func lastIndex(in prefix: [Int], notGreaterThan target: Int) -> Int {
    var low = 0
    var high = prefix.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if prefix[middle] <= target {
        low = middle
      } else {
        high = middle - 1
      }
    }
    return low
  }
}

/// Piece-table text storage with an incremental line index.
///
/// The document is a list of pieces that point into two append-only stores: the
/// text the buffer was created with, and everything inserted since. An edit
/// therefore appends only the inserted bytes and rewrites only the piece list,
/// which is what keeps editing a 10MB file the same cost as editing a small one.
///
/// Storage is UTF-8 and the public API is UTF-16, matching the document contract
/// and AppKit. Caret motion goes through the grapheme-boundary API; callers must
/// never add or subtract UTF-16 offsets to move by a character.
final class TextBuffer {
  private enum StoreKind {
    case original
    case add
  }

  private struct Piece {
    var store: StoreKind
    var byteOffset: Int
    var byteCount: Int
    var utf16Count: Int
    var newlineCount: Int
  }

  /// Counts accumulated *before* the piece at the same index, so the list always
  /// holds `pieces.count + 1` entries and its last entry is the document total.
  /// This is the line index: line starts are located by searching
  /// `newlineOffset` and then scanning one block inside a single piece.
  private struct PiecePrefix {
    var byteOffset: Int
    var utf16Offset: Int
    var newlineOffset: Int
  }

  private struct BoundaryWindow {
    let text: String
    let startUTF16: Int
  }

  /// Bytes of context a grapheme query reaches for on each side of an offset.
  /// The window is what keeps caret motion independent of the line length.
  private static let boundaryWindowBudget = 512

  private var original: TextByteStore
  private var add = TextByteStore()
  private var pieces: [Piece] = []
  private var prefixes: [PiecePrefix] = [
    PiecePrefix(byteOffset: 0, utf16Offset: 0, newlineOffset: 0)
  ]

  init(_ text: String = "") {
    original = TextByteStore(bytes: Array(text.utf8))
    resetPieces()
  }

  /// Loads file bytes, rejecting anything that is not valid UTF-8.
  init(utf8 data: Data) throws {
    guard String(data: data, encoding: .utf8) != nil else {
      throw TextBufferError.invalidUTF8
    }
    original = TextByteStore(bytes: Array(data))
    resetPieces()
  }

  var utf16Length: Int {
    prefixes[prefixes.count - 1].utf16Offset
  }

  var byteLength: Int {
    prefixes[prefixes.count - 1].byteOffset
  }

  /// Lines are terminated by a line feed, so a trailing newline leaves one empty
  /// final line, exactly as the editor and every line-numbered tool expect.
  var lineCount: Int {
    prefixes[prefixes.count - 1].newlineOffset + 1
  }

  /// Materializes the whole document. This is the only operation whose cost is
  /// proportional to the document, so callers keep it at load, save, and diff
  /// boundaries rather than on the editing path.
  var content: String {
    text(inByteRange: 0..<byteLength)
  }

  var metrics: TextBufferMetrics {
    TextBufferMetrics(
      pieceCount: pieces.count,
      originalByteCount: original.byteCount,
      appendedByteCount: add.byteCount,
      utf16Length: utf16Length,
      lineCount: lineCount
    )
  }

  // MARK: - Editing

  /// Replaces a UTF-16 range, returning the range the inserted text now covers.
  ///
  /// The range is validated before anything is mutated, so a rejected edit
  /// leaves the buffer exactly as it was.
  @discardableResult
  func replace(utf16Range range: Range<Int>, with text: String) throws -> Range<Int> {
    guard range.lowerBound >= 0, range.upperBound <= utf16Length,
      let startByte = byteOffset(forUTF16Offset: range.lowerBound),
      let endByte = byteOffset(forUTF16Offset: range.upperBound),
      startByte <= endByte
    else {
      throw TextBufferError.invalidUTF16Range(
        location: range.lowerBound,
        length: range.upperBound - range.lowerBound,
        utf16Length: utf16Length
      )
    }

    let startIndex = split(atByteOffset: startByte)
    let endIndex = split(atByteOffset: endByte)
    let inserted = Array(text.utf8)
    let appendStart = add.byteCount
    // Consecutive typing keeps extending one piece instead of growing the piece
    // list once per keystroke.
    let extendsPreviousPiece =
      !inserted.isEmpty && startIndex > 0
      && pieces[startIndex - 1].store == .add
      && pieces[startIndex - 1].byteOffset + pieces[startIndex - 1].byteCount == appendStart
    add.append(inserted)
    let insertedRange = appendStart..<(appendStart + inserted.count)
    let insertedUnits = add.utf16Count(in: insertedRange)
    let insertedNewlines = add.newlineCount(in: insertedRange)

    if extendsPreviousPiece {
      pieces.removeSubrange(startIndex..<endIndex)
      pieces[startIndex - 1].byteCount += inserted.count
      pieces[startIndex - 1].utf16Count += insertedUnits
      pieces[startIndex - 1].newlineCount += insertedNewlines
      rebuildPrefixes(from: startIndex - 1)
    } else {
      var replacement: [Piece] = []
      if !inserted.isEmpty {
        replacement.append(
          Piece(
            store: .add,
            byteOffset: appendStart,
            byteCount: inserted.count,
            utf16Count: insertedUnits,
            newlineCount: insertedNewlines
          )
        )
      }
      pieces.replaceSubrange(startIndex..<endIndex, with: replacement)
      rebuildPrefixes(from: startIndex)
    }

    return range.lowerBound..<(range.lowerBound + insertedUnits)
  }

  /// Replaces the whole document, as an external reload or a host restore does.
  /// The old pieces are dropped, so the appended-text store starts over.
  func replaceAll(with text: String) {
    original = TextByteStore(bytes: Array(text.utf8))
    resetPieces()
  }

  // MARK: - Coordinate conversion

  func byteOffset(forUTF16Offset offset: Int) -> Int? {
    guard offset >= 0, offset <= utf16Length else {
      return nil
    }
    guard offset < utf16Length else {
      return byteLength
    }
    let index = pieceIndex(forUTF16Offset: offset)
    let piece = pieces[index]
    let prefix = prefixes[index]
    guard
      let byte = store(for: piece.store).byteOffset(
        advancing: offset - prefix.utf16Offset,
        from: piece.byteOffset,
        limit: piece.byteOffset + piece.byteCount
      )
    else {
      return nil
    }
    return prefix.byteOffset + (byte - piece.byteOffset)
  }

  func utf16Offset(forByteOffset offset: Int) -> Int? {
    guard offset >= 0, offset <= byteLength else {
      return nil
    }
    guard offset < byteLength else {
      return utf16Length
    }
    let index = pieceIndex(forByteOffset: offset)
    let piece = pieces[index]
    let prefix = prefixes[index]
    let within = offset - prefix.byteOffset
    let counted = store(for: piece.store).utf16Count(
      in: piece.byteOffset..<(piece.byteOffset + within)
    )
    return prefix.utf16Offset + counted
  }

  /// Whether the offset sits between two Unicode scalars.
  func isScalarBoundary(utf16Offset offset: Int) -> Bool {
    byteOffset(forUTF16Offset: offset) != nil
  }

  /// Whether the offset sits between two grapheme clusters, which is the
  /// boundary the document contract validates every edit against.
  func isCharacterBoundary(utf16Offset offset: Int) -> Bool {
    guard offset >= 0, offset <= utf16Length else {
      return false
    }
    guard offset > 0, offset < utf16Length else {
      return true
    }
    guard let byte = byteOffset(forUTF16Offset: offset),
      let window = boundaryWindow(aroundByteOffset: byte)
    else {
      return false
    }
    let local = offset - window.startUTF16
    guard
      let utf16Index = window.text.utf16.index(
        window.text.utf16.startIndex,
        offsetBy: local,
        limitedBy: window.text.utf16.endIndex
      )
    else {
      return false
    }
    return String.Index(utf16Index, within: window.text) != nil
  }

  /// First grapheme boundary after the offset. Caret motion uses this instead of
  /// adding UTF-16 units, so a family emoji moves the caret once.
  func characterBoundary(after offset: Int) -> Int? {
    guard offset >= 0, offset < utf16Length, let byte = byteOffset(forUTF16Offset: offset),
      let window = boundaryWindow(aroundByteOffset: byte)
    else {
      return nil
    }
    let local = offset - window.startUTF16
    var running = 0
    for character in window.text {
      let next = running + character.utf16.count
      if next > local {
        return window.startUTF16 + next
      }
      running = next
    }
    return nil
  }

  /// Last grapheme boundary before the offset.
  func characterBoundary(before offset: Int) -> Int? {
    guard offset > 0, offset <= utf16Length, let byte = byteOffset(forUTF16Offset: offset),
      let window = boundaryWindow(aroundByteOffset: byte)
    else {
      return nil
    }
    let local = offset - window.startUTF16
    var running = 0
    var previous = 0
    for character in window.text {
      if running >= local {
        break
      }
      previous = running
      running += character.utf16.count
    }
    return window.startUTF16 + previous
  }

  // MARK: - Lines

  /// 1-based line containing the offset.
  func lineIndex(forUTF16Offset offset: Int) -> Int? {
    guard let byte = byteOffset(forUTF16Offset: offset) else {
      return nil
    }
    return newlineCount(beforeByteOffset: byte) + 1
  }

  func position(forUTF16Offset offset: Int) -> TextBufferPosition? {
    guard let line = lineIndex(forUTF16Offset: offset),
      let lineStart = utf16Offset(forLine: line)
    else {
      return nil
    }
    return TextBufferPosition(line: line, column: offset - lineStart + 1)
  }

  func utf16Offset(for position: TextBufferPosition) -> Int? {
    guard position.column >= 1, let range = lineUTF16Range(line: position.line) else {
      return nil
    }
    let offset = range.lowerBound + position.column - 1
    guard offset <= range.upperBound else {
      return nil
    }
    return offset
  }

  /// UTF-16 offset where the 1-based line starts.
  func utf16Offset(forLine line: Int) -> Int? {
    guard line >= 1, line <= lineCount else {
      return nil
    }
    guard line > 1 else {
      return 0
    }
    let target = line - 1
    var low = 0
    var high = pieces.count
    while low < high {
      let middle = (low + high) / 2
      if prefixes[middle + 1].newlineOffset < target {
        low = middle + 1
      } else {
        high = middle
      }
    }
    guard low < pieces.count else {
      return nil
    }
    let piece = pieces[low]
    let prefix = prefixes[low]
    guard
      let byte = store(for: piece.store).byteOffset(
        afterNewlines: target - prefix.newlineOffset,
        from: piece.byteOffset,
        limit: piece.byteOffset + piece.byteCount
      )
    else {
      return nil
    }
    return utf16Offset(forByteOffset: prefix.byteOffset + (byte - piece.byteOffset))
  }

  /// Content range of the 1-based line, excluding its terminator. A CRLF file
  /// keeps its carriage returns in storage; they are simply not part of the
  /// line's content range.
  func lineUTF16Range(line: Int) -> Range<Int>? {
    guard let start = utf16Offset(forLine: line) else {
      return nil
    }
    guard line < lineCount else {
      return start..<utf16Length
    }
    guard let nextStart = utf16Offset(forLine: line + 1) else {
      return nil
    }
    var end = nextStart - 1
    if end > start, let byte = byteOffset(forUTF16Offset: end), byte > 0,
      bytes(in: (byte - 1)..<byte).first == 0x0D
    {
      end -= 1
    }
    return start..<end
  }

  func lineText(line: Int) -> String? {
    guard let range = lineUTF16Range(line: line) else {
      return nil
    }
    return text(inUTF16Range: range)
  }

  func text(inUTF16Range range: Range<Int>) -> String? {
    guard let lower = byteOffset(forUTF16Offset: range.lowerBound),
      let upper = byteOffset(forUTF16Offset: range.upperBound),
      lower <= upper
    else {
      return nil
    }
    return text(inByteRange: lower..<upper)
  }

  // MARK: - Piece list

  private func resetPieces() {
    add = TextByteStore()
    pieces = []
    if original.byteCount > 0 {
      let range = 0..<original.byteCount
      pieces.append(
        Piece(
          store: .original,
          byteOffset: 0,
          byteCount: original.byteCount,
          utf16Count: original.utf16Count(in: range),
          newlineCount: original.newlineCount(in: range)
        )
      )
    }
    prefixes = [PiecePrefix(byteOffset: 0, utf16Offset: 0, newlineOffset: 0)]
    rebuildPrefixes(from: 0)
  }

  /// Recomputes the prefix table from the first piece an edit touched. Entries
  /// before that index cannot have moved, so an append-shaped edit rewrites
  /// nothing.
  private func rebuildPrefixes(from index: Int) {
    let start = max(0, min(index, min(pieces.count, prefixes.count - 1)))
    if prefixes.count > start + 1 {
      prefixes.removeSubrange((start + 1)...)
    }
    var current = prefixes[start]
    for piece in pieces[start...] {
      current.byteOffset += piece.byteCount
      current.utf16Offset += piece.utf16Count
      current.newlineOffset += piece.newlineCount
      prefixes.append(current)
    }
  }

  /// Ensures a piece starts exactly at the byte offset and returns its index.
  private func split(atByteOffset offset: Int) -> Int {
    guard offset < byteLength else {
      return pieces.count
    }
    let index = pieceIndex(forByteOffset: offset)
    let prefix = prefixes[index]
    let within = offset - prefix.byteOffset
    guard within > 0 else {
      return index
    }
    let piece = pieces[index]
    let source = store(for: piece.store)
    let splitOffset = piece.byteOffset + within
    let leftRange = piece.byteOffset..<splitOffset
    let rightRange = splitOffset..<(piece.byteOffset + piece.byteCount)
    let left = Piece(
      store: piece.store,
      byteOffset: piece.byteOffset,
      byteCount: within,
      utf16Count: source.utf16Count(in: leftRange),
      newlineCount: source.newlineCount(in: leftRange)
    )
    let right = Piece(
      store: piece.store,
      byteOffset: splitOffset,
      byteCount: piece.byteCount - within,
      utf16Count: source.utf16Count(in: rightRange),
      newlineCount: source.newlineCount(in: rightRange)
    )
    pieces.replaceSubrange(index...index, with: [left, right])
    rebuildPrefixes(from: index)
    return index + 1
  }

  private func pieceIndex(forUTF16Offset offset: Int) -> Int {
    var low = 0
    var high = pieces.count
    while low < high {
      let middle = (low + high) / 2
      if prefixes[middle + 1].utf16Offset <= offset {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return low
  }

  private func pieceIndex(forByteOffset offset: Int) -> Int {
    var low = 0
    var high = pieces.count
    while low < high {
      let middle = (low + high) / 2
      if prefixes[middle + 1].byteOffset <= offset {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return low
  }

  private func store(for kind: StoreKind) -> TextByteStore {
    switch kind {
    case .original:
      return original
    case .add:
      return add
    }
  }

  private func newlineCount(beforeByteOffset offset: Int) -> Int {
    guard offset > 0 else {
      return 0
    }
    guard offset < byteLength else {
      return prefixes[prefixes.count - 1].newlineOffset
    }
    let index = pieceIndex(forByteOffset: offset)
    let piece = pieces[index]
    let prefix = prefixes[index]
    let within = offset - prefix.byteOffset
    let counted = store(for: piece.store).newlineCount(
      in: piece.byteOffset..<(piece.byteOffset + within)
    )
    return prefix.newlineOffset + counted
  }

  private func bytes(in range: Range<Int>) -> [UInt8] {
    guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= byteLength else {
      return []
    }
    var result: [UInt8] = []
    result.reserveCapacity(range.count)
    var index = pieceIndex(forByteOffset: range.lowerBound)
    while index < pieces.count, prefixes[index].byteOffset < range.upperBound {
      let piece = pieces[index]
      let prefix = prefixes[index]
      let lower = max(range.lowerBound, prefix.byteOffset)
      let upper = min(range.upperBound, prefix.byteOffset + piece.byteCount)
      if lower < upper {
        let shift = piece.byteOffset - prefix.byteOffset
        result.append(
          contentsOf: store(for: piece.store).copyBytes(in: (lower + shift)..<(upper + shift))
        )
      }
      index += 1
    }
    return result
  }

  private func text(inByteRange range: Range<Int>) -> String {
    String(decoding: bytes(in: range), as: UTF8.self)
  }

  // MARK: - Grapheme windows

  private func boundaryWindow(aroundByteOffset byte: Int) -> BoundaryWindow? {
    let lower = windowStart(before: byte)
    let upper = windowEnd(after: byte)
    guard let start = utf16Offset(forByteOffset: lower) else {
      return nil
    }
    return BoundaryWindow(text: text(inByteRange: lower..<upper), startUTF16: start)
  }

  private func windowStart(before byte: Int) -> Int {
    guard byte > 0 else {
      return 0
    }
    let lower = max(0, byte - Self.boundaryWindowBudget)
    let window = bytes(in: lower..<byte)
    var index = window.count - 1
    while index >= 0 {
      if Self.isClusterAnchor(window[index]) {
        return lower + index
      }
      index -= 1
    }
    var start = lower
    while start < byte, Self.isContinuationByte(window[start - lower]) {
      start += 1
    }
    return start
  }

  private func windowEnd(after byte: Int) -> Int {
    guard byte < byteLength else {
      return byteLength
    }
    let probeEnd = min(byteLength, byte + Self.boundaryWindowBudget + 4)
    let probe = bytes(in: byte..<probeEnd)
    var index = 1
    while index < probe.count {
      if Self.isClusterAnchor(probe[index]) {
        return byte + index
      }
      index += 1
    }
    var end = min(byteLength, byte + Self.boundaryWindowBudget)
    while end > byte + 1, end < byteLength, Self.isContinuationByte(probe[end - byte]) {
      end -= 1
    }
    return end
  }

  /// A printable ASCII byte always begins a new grapheme cluster: none of the
  /// joining rules (combining marks, ZWJ sequences, regional-indicator pairs,
  /// Hangul jamo, CR+LF) can attach it to what precedes it. The one exception is
  /// a Prepend character such as U+0600, which is absent from source code and
  /// from terminal output in practice. Anchoring the window on such a byte keeps
  /// grapheme queries bounded even inside a one-megabyte line.
  private static func isClusterAnchor(_ byte: UInt8) -> Bool {
    (byte >= 0x20 && byte < 0x7F) || byte == 0x09
  }

  private static func isContinuationByte(_ byte: UInt8) -> Bool {
    byte & 0xC0 == 0x80
  }
}
