import Foundation

/// The skill the owner chose for one Project x column, with the repo's skill folder names at that time.
struct ColumnSkillChoice: Codable, Equatable {
  var skill: String
  var present: [String]
}

/// `~/.clair/todo/.skills.json`: project name → column → choice. A changed skill folder list makes a choice stale.
enum ClairColumnSkills {
  static func file(home: URL = .homeDirectory) -> URL { ClairTodo.dir(home: home).appending(path: ".skills.json") }

  static func load(home: URL = .homeDirectory) -> [String: [String: ColumnSkillChoice]] {
    (try? JSONDecoder().decode([String: [String: ColumnSkillChoice]].self, from: Data(contentsOf: file(home: home)))) ?? [:]
  }

  static func names(in dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
  }

  static func present(root: String) -> [String] { names(in: root + "/.claude/skills") }

  /// `none`, a skill of the repo, or one installed for the user (the bundled defaults included).
  static func isValid(_ skill: String, root: String, home: URL = .homeDirectory) -> Bool {
    skill == "none" || present(root: root).contains(skill) || names(in: home.appending(path: ".claude/skills").path).contains(skill)
      || ClairColumnSkill.all.contains { $0.name == skill }
  }

  static func record(project: String, stage: String, skill: String, root: String, home: URL = .homeDirectory) throws {
    var all = load(home: home)
    all[project, default: [:]][stage] = ColumnSkillChoice(skill: skill, present: present(root: root))
    try FileManager.default.createDirectory(at: ClairTodo.dir(home: home), withIntermediateDirectories: true)
    try JSONEncoder().encode(all).write(to: file(home: home), options: .atomic)
  }

  /// The recorded skill (`none` included), or nil when nothing is recorded or the repo's skill folders changed since.
  static func choice(project: String, stage: String, root: String, home: URL = .homeDirectory) -> String? {
    guard let c = load(home: home)[project]?[stage], c.present == present(root: root) else { return nil }
    return c.skill
  }
}

extension WorkbenchState {
  /// Where a card without a Project starts its agent.
  var workdir: String { conciergeWorkdir.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Projects").path : conciergeWorkdir }

  /// The folder behind a card's `project:` (`none` = the work folder), without opening it.
  func columnRoot(_ project: String) -> String? {
    project == ClairTodo.noProject ? WorkbenchProject.normalized(workdir) : projects.first { $0.name == project || $0.path == project }?.path
  }

  static func branchName(for path: String) -> String {
    let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
    let slug = String(base.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
      .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    return "todo-" + (slug.isEmpty ? "card" : String(slug.prefix(40)))
  }

  /// What a worktree would lose when removed: uncommitted files, or commits no other branch or remote has.
  static func worktreeLoss(_ wt: String, branch: String, root: String) -> String? {
    if !WorkbenchGit.run(wt, ["status", "--porcelain"]).out.isEmpty { return "uncommitted changes" }
    let r = WorkbenchGit.run(root, ["rev-list", "--count", branch, "--not", "--exclude=refs/heads/\(branch)", "--branches", "--remotes"])
    return r.ok && r.out == "0" ? nil : "unpushed commits"
  }

  private static func columnInstruction(_ stage: String, branch: String?) -> String {
    switch stage {
    case "plan": "あなたは看板の Plan 列の担当です。コードは変更せず、調べて実装計画を plan.md に書いてください。"
    case "impl": "あなたは看板の Impl 列の担当です。下の計画に従って、この worktree で実装してください。"
    default: "あなたは看板の Review 列の担当です。branch \(branch ?? "(なし)") の diff を自己検証し、review.md を書いてください。"
    }
  }

  private func columnPrompt(_ t: ClairTodo, body: String, stage: String, project: String, root: String, branch: String?, home: URL) -> String {
    let dir = (t.path as NSString).deletingPathExtension
    var out = [Self.columnInstruction(stage, branch: branch), "", "カード: \(t.path)", "成果物の置き場: \(dir)/", "", "# \(t.title)", body]
    if stage == "impl" {
      let plan = try? String(contentsOfFile: dir + "/plan.md", encoding: .utf8)
      out += ["", "## 計画(plan.md)", plan ?? "(plan.md はありません。上の本文が依頼です)"]
    }
    let skill = "clair-" + stage
    out.append("")
    switch ClairColumnSkills.choice(project: project, stage: stage, root: root, home: home) {
    case nil:
      out.append("この Project の \(stage) 列で使う skill がまだ決まっていません。最初に \(root)/.claude/skills/ を調べ、使う skill(または使わない)を理由つきでユーザーに提案し、ターミナルでの回答を待ってください。Clair の既定は \(skill) です。決まったら `clair todo.skill project=\(project) stage=\(stage) skill=<名前|none>` で記録してから作業を始めてください。")
    case "none"?: out.append("skill は使わず、上の指示だけで進めてください。")
    case let name?: out.append("skill `\(name)` を使って進めてください。")
    }
    out.append("終わったら `clair todo update path=\(t.path) result=ok|failed note=\"<1行>\" --compact` で報告してください。")
    return out.joined(separator: "\n")
  }

  /// The single entry point that starts column agents. `concierge` is the calling concierge's terminal key, counted against its cap.
  mutating func moveTodo(path: String, stage: String, force: Bool = false, concierge: String? = nil, home: URL = .homeDirectory) throws(CommandError) {
    guard ClairTodo.columns.contains(stage) else { throw CommandError(.invalidInput, "stage must be one of \(ClairTodo.columns.joined(separator: ", "))") }
    guard ClairTodo.isTodoFile(path, home: home), let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      throw CommandError(.preconditionFailed, "no TODO file \(path) in ~/.clair/todo")
    }
    var t = ClairTodo.parse(path: path, text: text)
    let launching = ["plan", "impl", "review"].contains(stage)
    let origin = t.project.flatMap { p in projects.first { $0.origin == nil && ($0.name == p || $0.path == p) } }
    let worktree = t.branch.flatMap { b in projects.first { $0.branch == b && $0.origin != nil && $0.origin == origin?.path } }
    var live: String? = t.agent.flatMap { terminal($0) != nil ? $0 : nil }

    var input: CommandInput = [:]
    var launchProject: WorkbenchProject?
    var branch = t.branch
    if launching {
      guard let name = t.project else { throw CommandError(.preconditionFailed, "needsProject: the card has no project; set one with todo.update project=") }
      if name == ClairTodo.noProject {
        guard let dir = WorkbenchProject.normalized(workdir) else { throw CommandError(.preconditionFailed, "concierge.workdir is not a folder") }
        launchProject = addProject(WorkbenchProject(name: URL(fileURLWithPath: dir).lastPathComponent, path: dir))
        branch = nil
      } else {
        guard let p = origin else { throw CommandError(.preconditionFailed, "no project \(name)") }
        launchProject = (stage == "plan" ? nil : worktree) ?? p
        input["project"] = .string(launchProject!.name)
        if stage == "impl", worktree == nil {
          let base = Self.branchName(for: path)
          branch = (1...).lazy.map { $0 == 1 ? base : "\(base)-\($0)" }.first { !WorkbenchGit.branchExists(p.path, $0) }!
          input["branch"] = .string(branch!)
        }
      }
      if input["project"] == nil { input["project"] = .string(launchProject!.name) }
      let root = origin?.path ?? launchProject!.path
      input["profile"] = .string("claude")
      input["opening"] = .string(columnPrompt(t, body: ClairTodo.split(text).body.trimmingCharacters(in: .whitespacesAndNewlines),
                                              stage: stage, project: name, root: root, branch: branch, home: home))
      if case .failure(let e) = CommandRegistry.workbench.preflight("agent.launch", input, self) { throw e }
    }
    if stage == "done", let wt = worktree, let o = origin, let b = t.branch {
      if let loss = Self.worktreeLoss(wt.path, branch: b, root: o.path), !force {
        throw CommandError(.preconditionFailed, "dirtyWorktree: \(loss) in \(wt.path); move with force=true to discard")
      }
    }

    if let key = live { closeTerminal(key); live = nil }
    t.agent = nil; t.result = nil; t.note = nil; t.doneAt = nil
    t.done = stage == "done"
    t.stage = stage == "inbox" ? nil : stage
    var history: String?
    switch stage {
    case "done":
      if let wt = worktree, let o = origin, let b = t.branch {
        let r = WorkbenchGit.run(o.path, ["worktree", "remove"] + (force ? ["--force"] : []) + [wt.path], merge: true)
        guard r.ok else { throw CommandError(.preconditionFailed, r.out) }
        WorkbenchGit.run(o.path, ["branch", "-D", b])
        layouts[wt.name] = nil
        projects.removeAll { $0.name == wt.name }
        if project == wt.name { project = ""; switchProject(to: o) }
        t.branch = nil
      }
      t.doneAt = ISO8601DateFormatter().string(from: .now)
    case "inbox": break
    default:
      let result = CommandRegistry.workbench.execute("agent.launch", input, confirmed: true, state: &self)
      guard case .success(.pane(let pane)) = result else {
        if case .failure(let e) = result { throw e }
        throw CommandError(.preconditionFailed, "agent.launch did not open a pane")
      }
      let key = Self.terminalKey(launchProject!.path, pane)
      t.agent = key; t.branch = branch
      let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
      history = "- \(stage) \(key) \(f.string(from: .now))"
      if let concierge { conciergeLaunches[concierge, default: 0] += 1 }
    }
    do { try t.save(appendBody: history) } catch { throw CommandError(.preconditionFailed, error.localizedDescription) }
  }
}
