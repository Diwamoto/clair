import ClairV2EditorCore
import Foundation

/// On-disk form of a single-file line thread (U05). The line is fixed at creation; anchors are not rebased on reload.
public struct ReviewThreadRecord: Codable, Equatable {
  public var id: UUID
  public var line: Int
  public var lower: Int
  public var upper: Int
  public var author: String
  public var agent: Bool
  public var body: String
  public var resolved: Bool

  public init(_ t: ReviewThread, line: Int) {
    let c = t.comments[0]
    (id, self.line, body, resolved) = (t.id, line, c.body, t.state == .resolved)
    (lower, upper) = (c.anchor.range.lowerBound.value, c.anchor.range.upperBound.value)
    (author, agent) = (c.author.displayName, c.author.kind == .agent)
  }

  public var thread: ReviewThread {
    let a = ReviewAnchor(range: TextUTF8Range(UTF8Offset(lower), UTF8Offset(upper)))
    let c = ReviewComment(author: ReviewAuthor(displayName: author, kind: agent ? .agent : .human), body: body, anchor: a)
    return ReviewThread(id: id, comments: [c], state: resolved ? .resolved : .open)
  }
}
