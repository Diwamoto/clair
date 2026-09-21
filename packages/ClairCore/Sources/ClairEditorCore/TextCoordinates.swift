import Foundation

public enum TextCoordinateSpace: Sendable {
  case utf8, utf16, scalar, grapheme
}

public protocol TextCoordinateUnit: Sendable {
  static var space: TextCoordinateSpace { get }
}

public enum UTF8Unit: TextCoordinateUnit {
  public static let space = TextCoordinateSpace.utf8
}

public enum UTF16Unit: TextCoordinateUnit {
  public static let space = TextCoordinateSpace.utf16
}

public enum ScalarUnit: TextCoordinateUnit {
  public static let space = TextCoordinateSpace.scalar
}

public enum GraphemeUnit: TextCoordinateUnit {
  public static let space = TextCoordinateSpace.grapheme
}

/// An unvalidated, zero-based coordinate. A snapshot validates it before use.
public struct TextOffset<Unit: TextCoordinateUnit>: Sendable, Hashable, Comparable {
  public let value: Int

  public init(_ value: Int) { self.value = value }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

public typealias UTF8Offset = TextOffset<UTF8Unit>
public typealias UTF16Offset = TextOffset<UTF16Unit>
public typealias ScalarOffset = TextOffset<ScalarUnit>
public typealias GraphemeOffset = TextOffset<GraphemeUnit>

public struct TextLineIndex: Sendable, Hashable, Comparable {
  public let value: Int

  public init(_ value: Int) { self.value = value }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

/// Columns count units in the line's content, excluding its terminator.
public struct TextLinePosition<Unit: TextCoordinateUnit>: Sendable, Hashable {
  public let line: TextLineIndex
  public let column: TextOffset<Unit>

  public init(line: TextLineIndex, column: TextOffset<Unit>) {
    self.line = line
    self.column = column
  }
}

/// Half-open UTF-8 range. Unlike Swift.Range, construction also permits a reversed
/// range so the core can reject untrusted input with an error instead of a trap.
public struct TextUTF8Range: Sendable, Hashable {
  public let lowerBound: UTF8Offset
  public let upperBound: UTF8Offset

  public init(_ lowerBound: UTF8Offset, _ upperBound: UTF8Offset) {
    self.lowerBound = lowerBound
    self.upperBound = upperBound
  }
}

public enum TextBoundaryRounding: Sendable {
  case strict
  case down
  case up
}

public enum TextStorageError: Error, Sendable, Equatable {
  case invalidUTF8
  case outOfBounds
  case invalidBoundary
  case reversedRange
  case staleRevision
  case identityExhausted
}

/// Equality includes document identity; two buffers at sequence 0 are not equal.
public struct TextRevision: Sendable, Hashable, Comparable {
  public let documentID: UUID
  public let sequence: UInt64

  /// Documents sort by identity; revisions within one document sort by sequence.
  /// Ordering is never a substitute for exact equality when accepting an edit.
  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.documentID == rhs.documentID { return lhs.sequence < rhs.sequence }
    return lhs.documentID.uuidString < rhs.documentID.uuidString
  }
}

/// BOF or a surviving line terminator owns this identity, not the line's text.
public struct TextLineID: Sendable, Hashable {
  public let documentID: UUID
  public let serial: UInt64
}

public enum TextLineEnding: Sendable, Equatable {
  case lf, crlf, cr, nel, lineSeparator, paragraphSeparator

  static func classify(_ character: Character) -> Self? {
    switch character {
    case "\n": return .lf
    case "\r\n": return .crlf
    case "\r": return .cr
    case "\u{85}": return .nel
    case "\u{2028}": return .lineSeparator
    case "\u{2029}": return .paragraphSeparator
    default: return nil
    }
  }
}

public struct TextLine: Sendable, Equatable {
  public let index: TextLineIndex
  public let id: TextLineID
  public let contentRange: TextUTF8Range
  public let terminatorRange: TextUTF8Range
  public let ending: TextLineEnding?
}
