import Foundation

/// ADR-0030: an agent's questions to the owner about one card (`ask.post`), answered all at once in a tab
/// (`ask.answer`). Kept next to the card as `<card>/ask.json`, so a restart or an hours-long wait loses nothing; the
/// answers also go to `<card>/decisions.md` and into the asking agent's pane.
public struct DecisionSheet: Codable, Equatable, Sendable {
  public struct Option: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var detail: String?
    /// A file in the card's folder, previewed inside the option. Absolute after validation.
    public var html: String?
  }

  public struct Question: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case single, multi, text }
    public var id: String
    public var kind: Kind
    public var prompt: String
    public var context: String?
    public var options: [Option]?
    /// Option id(s) selected when the sheet opens.
    public var recommended: [String]?

    // `recommended` may come as one id or a list.
    enum CodingKeys: String, CodingKey { case id, kind, prompt, context, options, recommended }
    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      id = try c.decode(String.self, forKey: .id)
      kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .single
      prompt = try c.decode(String.self, forKey: .prompt)
      context = try c.decodeIfPresent(String.self, forKey: .context)
      options = try c.decodeIfPresent([Option].self, forKey: .options)
      if let list = try? c.decodeIfPresent([String].self, forKey: .recommended) { recommended = list }
      else { recommended = try c.decodeIfPresent(String.self, forKey: .recommended).map { [$0] } }
    }
  }

  public enum State: String, Codable, Sendable { case pending, answered }

  public var title: String?
  public var questions: [Question]
  /// The terminal key of the agent that asked; the answers are typed into it.
  public var asker: String?
  public var state: State = .pending
  /// Question id → chosen option ids, or the typed text as one element.
  public var answers: [String: [String]] = [:]
  public var comment: String?
  /// Question id → the owner's free-text note beside a choice.
  public var notes: [String: String] = [:]

  enum CodingKeys: String, CodingKey { case title, questions, asker, state, answers, comment, notes }
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    title = try c.decodeIfPresent(String.self, forKey: .title)
    questions = try c.decode([Question].self, forKey: .questions)
    asker = try c.decodeIfPresent(String.self, forKey: .asker)
    state = try c.decodeIfPresent(State.self, forKey: .state) ?? .pending
    answers = try c.decodeIfPresent([String: [String]].self, forKey: .answers) ?? [:]
    comment = try c.decodeIfPresent(String.self, forKey: .comment)
    notes = try c.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
  }

  public static let maxQuestions = 20

  /// `~/.clair/todo/<name>/` — where the card's research.md / plan.md live.
  public static func folder(card: String) -> String { (card as NSString).deletingPathExtension }
  static func file(card: String) -> String { folder(card: card) + "/ask.json" }

  public static func load(card: String) -> DecisionSheet? {
    (try? Data(contentsOf: URL(fileURLWithPath: file(card: card)))).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
  }

  public static func pending(card: String) -> Bool { load(card: card)?.state == .pending }

  func save(card: String) throws {
    try FileManager.default.createDirectory(atPath: Self.folder(card: card), withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try enc.encode(self).write(to: URL(fileURLWithPath: Self.file(card: card)), options: .atomic)
  }

  /// Decodes an agent's sheet and checks it: unique ids, options where a choice is asked, recommendations that exist,
  /// and HTML previews that are files inside the card's folder.
  public static func validate(_ json: String, card: String) throws(CommandError) -> DecisionSheet {
    let sheet: DecisionSheet
    do { sheet = try JSONDecoder().decode(Self.self, from: Data(json.utf8)) } catch {
      throw CommandError(.invalidInput, #"questions must be JSON {"title":…,"questions":[{"id":…,"kind":"single|multi|text","prompt":…,"context":…,"options":[{"id":…,"label":…,"detail":…,"html":…}],"recommended":…}]}"#)
    }
    var s = sheet
    s.state = .pending; s.answers = [:]; s.comment = nil; s.notes = [:]; s.asker = nil
    guard !s.questions.isEmpty, s.questions.count <= maxQuestions else { throw CommandError(.invalidInput, "1 to \(maxQuestions) questions") }
    guard Set(s.questions.map(\.id)).count == s.questions.count else { throw CommandError(.invalidInput, "question ids must be unique") }
    // Symlinks resolved: the preview gets read access to this folder, so it must not lead elsewhere.
    let dir = URL(fileURLWithPath: folder(card: card)).standardizedFileURL.path
    for (qi, q) in s.questions.enumerated() {
      guard !q.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommandError(.invalidInput, "question \(q.id) has no prompt") }
      let options = q.options ?? []
      if q.kind == .text {
        guard options.isEmpty else { throw CommandError(.invalidInput, "text question \(q.id) takes no options") }
        continue
      }
      guard !options.isEmpty, Set(options.map(\.id)).count == options.count else {
        throw CommandError(.invalidInput, "question \(q.id) needs options with unique ids")
      }
      let rec = q.recommended ?? []
      guard rec.allSatisfy({ r in options.contains { $0.id == r } }), q.kind == .multi || rec.count <= 1 else {
        throw CommandError(.invalidInput, "question \(q.id): recommended must name its option(s)")
      }
      for (oi, o) in options.enumerated() {
        guard let html = o.html else { continue }
        let abs = URL(fileURLWithPath: html.hasPrefix("/") ? html : dir + "/" + html).standardizedFileURL.path
        let real = URL(fileURLWithPath: abs).resolvingSymlinksInPath().path
        let realDir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        let linked = (try? FileManager.default.destinationOfSymbolicLink(atPath: dir)) != nil
        guard abs.hasPrefix(dir + "/"), !linked, real.hasPrefix(realDir + "/"), FileManager.default.fileExists(atPath: abs) else {
          throw CommandError(.invalidInput, "\(html) is not a file in \(dir)")
        }
        s.questions[qi].options![oi].html = abs
      }
    }
    return s
  }

  /// Checks the owner's answers against the questions: every choice is an option, single takes at most one.
  public func checked(_ answers: [String: [String]]) throws(CommandError) -> [String: [String]] {
    var out: [String: [String]] = [:]
    for (id, values) in answers {
      guard let q = questions.first(where: { $0.id == id }) else { throw CommandError(.invalidInput, "no question \(id)") }
      switch q.kind {
      case .text:
        let text = values.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { out[id] = [text] }
      case .single, .multi:
        guard values.allSatisfy({ v in q.options?.contains { $0.id == v } == true }), q.kind == .multi || values.count <= 1 else {
          throw CommandError(.invalidInput, "question \(id): pick from its options")
        }
        if !values.isEmpty { out[id] = values }
      }
    }
    return out
  }

  /// Notes must name a question; blank ones are dropped.
  public func checked(notes: [String: String]) throws(CommandError) -> [String: String] {
    var out: [String: String] = [:]
    for (id, text) in notes {
      guard questions.contains(where: { $0.id == id }) else { throw CommandError(.invalidInput, "no question \(id)") }
      let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty { out[id] = t }
    }
    return out
  }

  /// The answers as Markdown: what goes to decisions.md and, flattened, into the agent's pane.
  public var summary: String {
    var lines: [String] = []
    for (i, q) in questions.enumerated() {
      let picked = answers[q.id] ?? []
      let value = q.kind == .text
        ? (picked.first ?? "(回答なし — agent が決める)")
        : picked.isEmpty ? "(回答なし — agent が決める)" : picked.compactMap { p in q.options?.first { $0.id == p }?.label }.joined(separator: " / ")
      let note = notes[q.id].map { " — 補足: \($0)" } ?? ""
      lines.append("\(i + 1). \(q.prompt) → \(value)\(note)")
    }
    if let c = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { lines.append("コメント: \(c)") }
    return lines.joined(separator: "\n")
  }

  /// One line for the asking agent's prompt (a newline would submit early).
  public func reply(card: String) -> String {
    "[判断シートの回答] \(summary.replacingOccurrences(of: "\n", with: " / ")) (記録: \(Self.folder(card: card))/decisions.md)"
  }

  /// Records the answers: the sheet, then a dated block appended to decisions.md.
  mutating func answer(_ answers: [String: [String]], comment: String?, notes: [String: String] = [:], card: String,
                       now: Date = .now) throws(CommandError) {
    guard state == .pending else { throw CommandError(.preconditionFailed, "the sheet is already answered") }
    self.answers = try checked(answers)
    self.notes = try checked(notes: notes)
    self.comment = comment
    state = .answered
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
    let block = "## \(title ?? "判断") (\(f.string(from: now)))\n\n\(summary)\n\n"
    let path = Self.folder(card: card) + "/decisions.md"
    do {
      try save(card: card)
      if let h = FileHandle(forWritingAtPath: path) {
        defer { try? h.close() }
        try h.seekToEnd(); try h.write(contentsOf: Data(block.utf8))
      } else {
        try Data(("# 判断の記録\n\n" + block).utf8).write(to: URL(fileURLWithPath: path))
      }
    } catch { throw CommandError(.preconditionFailed, error.localizedDescription) }
  }
}
