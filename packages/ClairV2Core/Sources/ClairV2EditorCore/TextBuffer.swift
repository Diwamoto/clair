import Foundation

/// Single-owner storage primitive for E03's future transaction layer. Deliberately
/// not Sendable: keep the writer on its owning actor and hand readers snapshots.
/// This is a reference type so copying the writer cannot fork/reuse revisions.
public final class TextBuffer {
  public private(set) var snapshot: TextSnapshot
  private var lineIDs: TextLineIDSource
  private(set) var lastEditWork = TextEditWork()

  public init(_ text: String = "") throws {
    let documentID = UUID()
    var ids = TextLineIDSource(documentID: documentID)
    var work = TextEditWork()
    let root = try TextRopeBuilder.build(text, ids: &ids, work: &work)
    snapshot = TextSnapshot(
      revision: TextRevision(documentID: documentID, sequence: 0),
      firstLineID: TextLineID(documentID: documentID, serial: 0), root: root
    )
    lineIDs = ids
  }

  /// Invalid UTF-8 is refused as a whole; never decoded using replacement bytes.
  public convenience init(utf8: [UInt8]) throws {
    try self.init(Self.decodeLosslessly(utf8))
  }

  /// One atomic storage replacement, not a multi-edit transaction/undo API.
  /// The endpoints must be grapheme boundaries in the stated current revision.
  @discardableResult
  public func replace(
    _ range: TextUTF8Range, with replacement: String, basedOn revision: TextRevision
  ) throws -> TextSnapshot {
    guard revision == snapshot.revision else { throw TextStorageError.staleRevision }
    let bytes = try snapshot.validated(range)
    if snapshot.matches(bytes, replacement) {
      lastEditWork = TextEditWork()
      return snapshot
    }
    guard revision.sequence < UInt64.max else { throw TextStorageError.identityExhausted }
    // All state, including ID allocation, stays local until the complete new
    // root exists. Any validation/allocation failure leaves the writer intact.
    var ids = lineIDs
    ids.preservingBefore = ids.next
    var work = TextEditWork()
    let (prefix, rest) = snapshot.root?.split(at: bytes.lowerBound) ?? (nil, nil)
    let (_, suffix) = rest?.split(at: bytes.count) ?? (nil, nil)
    let inserted = try TextRopeBuilder.build(replacement, ids: &ids, work: &work)
    let first = try TextRopeBuilder.concatenate(prefix, inserted, ids: &ids, work: &work)
    let root = try TextRopeBuilder.concatenate(first, suffix, ids: &ids, work: &work)
    let result = TextSnapshot(
      revision: TextRevision(documentID: revision.documentID, sequence: revision.sequence + 1),
      firstLineID: snapshot.firstLineID, root: root
    )
    lineIDs = ids
    lastEditWork = work
    snapshot = result
    return result
  }

  @discardableResult
  public func replace(
    _ range: TextUTF8Range, withUTF8 bytes: [UInt8], basedOn revision: TextRevision
  ) throws -> TextSnapshot {
    try replace(range, with: Self.decodeLosslessly(bytes), basedOn: revision)
  }

  private static func decodeLosslessly(_ bytes: [UInt8]) throws -> String {
    // Foundation's String(bytes:encoding:) strips a leading BOM. The standard
    // library preserves it; reject any repaired sequence before accepting text.
    // This also works on macOS 14 / iOS 17, before init(validating:as:).
    let text = String(decoding: bytes, as: UTF8.self)
    guard text.utf8.elementsEqual(bytes) else {
      throw TextStorageError.invalidUTF8
    }
    return text
  }
}
