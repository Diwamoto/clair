import Foundation

extension WorkbenchState {
  /// Where a card without a Project (`none`) starts its agent.
  static var workdir: String { URL.homeDirectory.appending(path: "Projects").path }

  /// #82: the card agent's first message. The third line is the card's fixed identity (`cardAgent`).
  static func cardPrompt(_ t: ClairTodo, body: String) -> String {
    let dir = (t.path as NSString).deletingPathExtension
    return [
      "あなたは Clair の看板のカード1枚の担当です。skill `\(ClairCardSkill.name)` に従い、調査から実装・確認まで1人で最後まで進めてください。", "",
      "カード: \(t.path)", "成果物の置き場: \(dir)/", "", "# \(t.title)", body, "",
      "ユーザーに確認したいことは文章で聞かず `clair ask post card=\(t.path) questions='<JSON>' --compact` の判断シートで聞き、ターンを終えて回答を待ってください。",
      "終わったら `clair todo update path=\(t.path) result=ok|failed note=\"<1行>\" --compact` で報告してください。",
    ].joined(separator: "\n")
  }

  /// `key` is a live pane `todo.run` started for the card at `path`. Older cards' agents carry the card only in
  /// their opening's fixed third line, never in a substring a card body could forge.
  func cardAgent(_ key: String, path: String) -> Bool {
    guard let t = terminal(key), let l = withLayoutCopy(t.project).launches[t.pane] else { return false }
    if l.card == path { return true }
    return l.opening?.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(2).first == "カード: \(path)"
  }

  /// #82: starts the card's one agent: interactive `claude` in the card's Project (no worktree), resuming the card's
  /// conversation when it has one. A card whose agent still runs keeps it (`agentOpen`); one that exited is replaced.
  mutating func runTodo(path: String, home: URL = .homeDirectory) throws(CommandError) {
    guard ClairTodo.isTodoFile(path, home: home), let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      throw CommandError(.preconditionFailed, "no TODO file \(path) in ~/.clair/todo")
    }
    var t = ClairTodo.parse(path: path, text: text)
    if let key = t.agent, cardAgent(key, path: path), let pane = terminal(key) {
      let exited = agentSessions.first { $0.project == pane.project && $0.pane == pane.pane }?.status.isExited ?? true
      guard exited else { throw CommandError(.preconditionFailed, "agentOpen: the card's agent \(key) is still open") }
      closeTerminal(key)
    }
    guard let name = t.project else { throw CommandError(.preconditionFailed, "needsProject: the card has no project; set one with todo.update project=") }
    let before = projects  // a launch that fails its preflight must not leave a Project it opened
    let launchProject: WorkbenchProject
    if name == ClairTodo.noProject {
      guard let dir = WorkbenchProject.normalized(Self.workdir) else { throw CommandError(.preconditionFailed, "\(Self.workdir) is not a folder") }
      launchProject = addProject(WorkbenchProject(name: URL(fileURLWithPath: dir).lastPathComponent, path: dir))
    } else {
      guard let p = projects.first(where: { $0.origin == nil && ($0.name == name || $0.path == name) }) else {
        throw CommandError(.preconditionFailed, "no project \(name)")
      }
      launchProject = p
    }
    var input: CommandInput = ["project": .string(launchProject.name), "profile": .string("claude")]
    if let session = t.session, AgentProfile.isSessionID(session) {
      input["resume"] = .string(session)
    } else {
      input["opening"] = .string(Self.cardPrompt(t, body: ClairTodo.split(text).body.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    if case .failure(let e) = CommandRegistry.workbench.preflight("agent.launch", input, self) { projects = before; throw e }
    let result = CommandRegistry.workbench.execute("agent.launch", input, confirmed: true, state: &self)
    guard case .success(.pane(let pane)) = result else {
      projects = before
      if case .failure(let e) = result { throw e }
      throw CommandError(.preconditionFailed, "agent.launch did not open a pane")
    }
    withLayout(launchProject.name) { $0.launches[pane]?.card = path }
    t.agent = Self.terminalKey(launchProject.path, pane)
    t.result = nil; t.note = nil; t.doneAt = nil; t.done = false
    do { try t.save() } catch { throw CommandError(.preconditionFailed, error.localizedDescription) }
  }
}
