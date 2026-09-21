import Foundation

/// A search query over a `TextSnapshot`: a literal substring or a regular
/// expression. Both compile through the same ICU-backed `NSRegularExpression`
/// engine (a literal is its own escaped pattern), so there is one matching
/// code path to reason about.
public enum SearchPattern: Sendable {
  case literal(String, caseSensitive: Bool = true)
  case regex(String, caseSensitive: Bool = true)
}

public enum SearchError: Error, Sendable, Equatable {
  case invalidRegex
}

/// One match, tied to the revision it was found in. `EditorTransactionManager`
/// refuses to apply a replacement whose revision no longer matches the live
/// buffer: per `INV-REV-004`, a stale match is rejected outright rather than
/// re-applied against text that has since moved.
public struct SearchMatch: Sendable, Hashable {
  public let range: TextUTF8Range
  public let revision: TextRevision
}

/// A match paired with the text that should replace it.
public struct SearchReplacement: Sendable {
  public let match: SearchMatch
  public let replacement: String

  public init(match: SearchMatch, replacement: String) {
    self.match = match
    self.replacement = replacement
  }
}

public enum TextSearch {
  /// Finds every non-overlapping match, snapped to grapheme boundaries so a
  /// match never splits a combining-character cluster. `scope` restricts the
  /// search to a selection's non-empty ranges; a nil scope, or one holding
  /// only cursors, searches the whole document.
  ///
  /// ponytail: regex replacement is a fixed string, not a `$1`-style
  /// backreference template — add capture-group substitution if the product
  /// needs it.
  public static func find(
    _ pattern: SearchPattern, in snapshot: TextSnapshot, scope: TextSelectionSet? = nil
  ) throws -> [SearchMatch] {
    let regex = try compile(pattern)
    var matches: [SearchMatch] = []
    for scopeRange in searchRanges(scope, in: snapshot) {
      let text = try snapshot.text(in: scopeRange)
      let nsText = text as NSString
      let scopeStartUTF16 = try snapshot.convert(scopeRange.lowerBound, to: UTF16Unit.self).value
      for result in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
        let start = UTF16Offset(scopeStartUTF16 + result.range.location)
        let end = UTF16Offset(scopeStartUTF16 + result.range.location + result.range.length)
        // NSRegularExpression matches at UTF-16 code-unit granularity, which
        // can land inside a multi-scalar grapheme cluster (e.g. a bare base
        // letter next to its own combining mark). Round each bound out to
        // the nearest grapheme boundary — except a zero-length match, which
        // rounds both ends the same direction so it stays a single point
        // instead of ballooning into the whole enclosing cluster.
        let range: TextUTF8Range
        if start == end {
          let point = try snapshot.convert(start, to: UTF8Unit.self, rounding: .down)
          range = TextUTF8Range(point, point)
        } else {
          range = try TextUTF8Range(
            snapshot.convert(start, to: UTF8Unit.self, rounding: .down),
            snapshot.convert(end, to: UTF8Unit.self, rounding: .up)
          )
        }
        // Grapheme snapping can pull two distinct raw matches onto the same
        // boundary (most visibly with zero-length regexes); keep matches
        // non-overlapping and duplicate-free the way `apply` requires.
        if let last = matches.last,
          range.lowerBound.value < last.range.upperBound.value || range == last.range
        {
          continue
        }
        matches.append(SearchMatch(range: range, revision: snapshot.revision))
      }
    }
    return matches
  }

  /// `find`, paired with a constant replacement string for every match.
  public static func preview(
    _ pattern: SearchPattern, replacingWith replacement: String, in snapshot: TextSnapshot,
    scope: TextSelectionSet? = nil
  ) throws -> [SearchReplacement] {
    try find(pattern, in: snapshot, scope: scope).map {
      SearchReplacement(match: $0, replacement: replacement)
    }
  }

  private static func searchRanges(_ scope: TextSelectionSet?, in snapshot: TextSnapshot)
    -> [TextUTF8Range]
  {
    guard let scope else { return [snapshot.fullRange] }
    let ranges = scope.selections.filter { !$0.isEmpty }.map(\.range)
    return ranges.isEmpty ? [snapshot.fullRange] : ranges
  }

  private static func compile(_ pattern: SearchPattern) throws -> NSRegularExpression {
    let (text, caseSensitive): (String, Bool)
    switch pattern {
    case .literal(let literal, let sensitive):
      (text, caseSensitive) = (NSRegularExpression.escapedPattern(for: literal), sensitive)
    case .regex(let expression, let sensitive):
      (text, caseSensitive) = (expression, sensitive)
    }
    do {
      return try NSRegularExpression(pattern: text, options: caseSensitive ? [] : [.caseInsensitive])
    } catch {
      throw SearchError.invalidRegex
    }
  }
}

extension EditorTransactionManager {
  /// Applies search-derived replacements as one transaction (one undo unit).
  /// Every match must still be at the buffer's current revision; a stale
  /// match is rejected rather than reapplied by re-searching for its text.
  @discardableResult
  public func apply(replacements: [SearchReplacement]) throws -> TextSnapshot {
    guard replacements.allSatisfy({ $0.match.revision == buffer.snapshot.revision }) else {
      throw TextStorageError.staleRevision
    }
    return try apply(replacements.map { TextEdit(range: $0.match.range, replacement: $0.replacement) })
  }
}
