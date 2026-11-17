import CryptoKit
import Foundation

// ADR-0020: Clair's concierge chats, each kept in its folder Project's `launches` under a negative pane id no tree uses,
// so none shows in a layout. Each is an ordinary raw-PTY agent terminal (daemon shell `root#-1`, `root#-2`, …); the GUI draws
// its official Claude Code transcript (found by the session id fixed at launch) as chat, and types the
// composer's text into its PTY. Children are agents launched with `parent` = the concierge's terminal key.
// ponytail: Claude Code only — it is the one provider whose session id can be fixed at launch
// (`--session-id`); Codex/OpenCode need a session-discovery step before they can be a concierge.

public enum Concierge {
  /// The first concierge chat's pane id. Every concierge pane is negative: off every tree (`PaneTree` ids start at 1),
  /// so no layout draws it. The chat mounts its surface.
  public static let pane = -1
  public static func isPane(_ id: Int) -> Bool { id < 0 }

  static let basePrompt = """
    あなたは Clair 全体のコンシェルジュです。ユーザーの依頼を受け、Clair の操作と作業の割り振りを担当します。自分で大きな実装はしません。

    ## できること
    - `clair` CLI で Clair を操作する(ファイルを開く、ペイン、git、プレビューなど)。使い方は clair-agents / clair-preview skill を参照。
    - 作業は子 agent に任せる。子は必ず先にカードを作り、下の「TODO(カード)と看板」の通り `stage=` で列に置いて起動する。`clair agent launch` を直接使うのは、カードにできない例外だけ。
    - `project=` を省くと子はコンシェルジュの作業フォルダで動く。リポジトリでの作業は必ず `project=` を付ける。値は `clair project list --compact` の `name`(パスではない)。
    - 別の会話のコンシェルジュも同時に子を起動している。リポジトリを変更する子を起動する前に `clair agent list --compact` を見て、同じ Project で終了していない agent がいるときだけ `branch=` を付ける。いなければ付けずに起動する。

    ## TODO(カード)と看板
    ユーザーの言う「todo」「TODO」「やること」「あとで」は Clair の TODO(`~/.clair/todo/*.md`、看板ではカード)を指す。Claude Code 内蔵の TodoWrite やリポジトリ内の TODO コメントではない。操作は clair-todo skill の通り `clair todo ...` コマンドで行い、ファイルを直接書かない。
    看板の列は inbox / plan / impl / review / done。列を移すと Clair がその列の agent を新しく起動する。終わったらその列で止まり、次の列へ移すのは人。あなたが列を進め続けない。
    - 一覧: `clair todo list done=false --compact`。
    - 追加: `clair todo add title="..." [priority=1-3] [due=YYYY-MM-DD] body="..."`。確認せずに追加し、body に依頼の言葉と対象リポジトリのパスを書く。
    - 更新: `clair todo update path=<list の path> [project=<Project 名|none>] [stage=<列>] [title=...] [appendBody="..."]`。`project=` の値は `clair project list --compact` の `name`。Project に属さない作業は `none`。
    依頼の意図を自分で判断する:
    - 「調べといて」「やっといて」のように実行を頼まれた: `clair todo add` でカードを作り、`clair todo update path=<path> project=<名> stage=plan` で置く。やることが明確な小さな修正なら `stage=impl`(plan.md の代わりに本文が依頼として渡る)。`stage=` を付けると Clair が agent を起動する。自分で `clair agent launch` しない。
    - 「やるか判断したい」「調べて結果を教えて」のように、やるかどうかを決める前の調査を頼まれた: カードを作り `stage=research` で置く。カードは inbox のまま調査の子が起動し、research.md と note に結論材料を残す。やる・やらないを決めるのはユーザー。
    - 「todo に追加して」のように溜めておく意図: カードを作って inbox に置き、止める(`stage` を付けない)。
    - 意図がどうしても分からない、または危険な操作(削除、push、force など)を伴う: inbox に置き、進めてよいかをチャットで聞く。
    - 起動する子は必ず先にカードを作る。看板の外で動く子を作らない。
    - `stage` を付けて `needsProject` と返ったら、Project を決めて `project=` を付けて再実行する。分からなければ1問だけ聞く。
    - 承認なしで起動できるのはチャットの依頼1件につき3体まで。超えると承認カードが出る。
    - あなたは Web 検索と WebFetch を使えない。Web とリポジトリの調査は子(research か plan)に任せる。

    ## トークン節約のルール(重要)
    - `clair` は必ず `--compact` を付けて実行する(色なしの1行の JSON になる)。
    - 子 agent の出力を逐一読まない。進み具合は Clair の看板が表示している。
    - 起動したら、どの子に何を任せたかを1〜2行で報告して手を止める。
    - 結果が必要なときだけ、`clair agent status` で終了を確認してから `clair agent output lines=40` で末尾だけ読み、要点を3行以内でまとめる。
    - 詳細はユーザーがリンクから実際のターミナルで見る。長いログを貼らない。

    ## 振る舞い
    - 返答は短く、日本語で。
    - 依頼が曖昧なら、起動する前に1問だけ確認する。
    - 危険な操作(削除、push、force など)は子にもさせず、ユーザーに確認する。
    - 子が「入力待ち」になったら、何を聞かれているかを1行で伝える。代わりに答えてよいのは、明らかに安全な場合だけ。
    - 終わった子のペインは、ユーザーが見終えたら `clair agent close` で閉じてよい。
    """

  /// Where the concierge runs when `concierge.cwd` is empty: a folder of its own, so it reads only its own CLAUDE.md and skills.
  public static func defaultCwd(home: URL = .homeDirectory) -> String { home.appending(path: ".clair/concierge").path }

  /// The system prompt: the fixed role plus the user's `settings.concierge` prompt.
  public static func prompt(extra: String) -> String {
    let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
    return extra.isEmpty ? basePrompt : basePrompt + "\n\n## ユーザーの指示\n" + extra
  }

  /// What the concierge reads at launch besides its prompt: Claude Code's project files in `cwd`.
  // ponytail: cwd only; ~/.claude (user-level skills, settings) is not covered — add it if the user wants that gated too.
  static let readPaths = ["CLAUDE.md", "CLAUDE.local.md", ".mcp.json", ".claude"]
  static let readDirs = ["skills", "agents", "commands", "hooks", "rules"]

  /// #76: a hash of everything that steers the concierge. The user approves this; any change asks again.
  public static func fingerprint(prompt: String, cwd: String) -> String {
    var hasher = SHA256()
    func add(_ s: String) { hasher.update(data: Data((s + "\u{1f}").utf8)) }
    add(prompt); add(cwd)
    let fm = FileManager.default
    var files: [String] = []
    for p in readPaths.dropLast() { files.append(cwd + "/" + p) }
    // Claude Code also loads CLAUDE.md from every parent directory.
    var parent = (cwd as NSString).deletingLastPathComponent
    while parent != "/" && !parent.isEmpty {
      files.append(parent + "/CLAUDE.md"); parent = (parent as NSString).deletingLastPathComponent
    }
    for f in ["CLAUDE.md", "settings.json", "settings.local.json"] { files.append(cwd + "/.claude/" + f) }
    for d in readDirs {
      let root = cwd + "/.claude/" + d
      files += (fm.subpaths(atPath: root) ?? []).map { root + "/" + $0 }
    }
    for f in files.sorted() {
      var dir: ObjCBool = false
      guard fm.fileExists(atPath: f, isDirectory: &dir), !dir.boolValue else { continue }
      add(f); add((try? Data(contentsOf: URL(fileURLWithPath: f))).map { SHA256.hash(data: $0).description } ?? "")
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Approvals live in the GUI's defaults, like `ClairSchedule.approvals`.
  // ponytail: advisory, same ceiling as schedules (an agent with a shell can `defaults write`).
  nonisolated(unsafe) public static var approvals: UserDefaults = .standard
  static let approvalKey = "approvedConcierge"
  public static func isApproved(_ fingerprint: String) -> Bool { approvals.string(forKey: approvalKey) == fingerprint }
  public static func approve(_ fingerprint: String) { approvals.set(fingerprint, forKey: approvalKey) }

  /// Claude Code's `--effort` / `/effort` levels.
  public static let efforts = ["low", "medium", "high", "xhigh", "max"]

  /// Claude Code keeps each session at `~/.claude/projects/<cwd slug>/<id>.jsonl`; the slug is not
  /// something to re-derive, so look the id up one level down.
  public static func transcriptFile(session: String, home: URL = .homeDirectory) -> URL? {
    let root = home.appending(path: ".claude/projects")
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return dirs.lazy.map { $0.appending(path: "\(session).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// `opening` rides as Claude's initial prompt, so a request sent before the TUI was up is never lost.
  /// `resumed`: launched onto an existing chat (the previous concierge's), so the request that woke it rides along.
  /// A fresh one flips to `--resume` once its transcript exists and must not repeat its opening then.
  static func command(session: String, extra: String, opening: String? = nil, resumed: Bool = false, model: String? = nil, effort: String? = nil) -> String {
    let fresh = !resumed && transcriptFile(session: session) == nil
    let first = fresh || resumed ? opening.map { " " + AgentRun.quote($0) } ?? "" : ""
    let picked = (model.map { " --model \(AgentRun.quote($0))" } ?? "") + (effort.map { " --effort \(AgentRun.quote($0))" } ?? "")
    return "claude \(fresh ? "--session-id" : "--resume") \(session)\(picked) --disallowedTools WebFetch,WebSearch --append-system-prompt \(AgentRun.quote(prompt(extra: extra)))\(first)"
  }
}

extension WorkbenchState {
  /// The folder the next concierge starts in.
  public var conciergeDir: String { conciergeCwd.isEmpty ? Concierge.defaultCwd() : conciergeCwd }

  /// The chats of `conciergeDir`, oldest first, each by its current session id; shown before any of them runs.
  public var conciergeChats: [String] { conciergeSessions[WorkbenchProject.normalized(conciergeDir) ?? conciergeDir] ?? [] }

  /// The closed chats of `conciergeDir`, oldest first; picking one and sending resumes it.
  public var conciergeHistory: [String] { conciergeClosed[WorkbenchProject.normalized(conciergeDir) ?? conciergeDir] ?? [] }

  /// Running concierge terminals, first chat first.
  public func concierges() -> [(project: String, pane: Int, session: String, key: String, launch: AgentLaunch)] {
    projects.flatMap { p in
      withLayoutCopy(p.name).launches.filter { Concierge.isPane($0.key) }.compactMap { pane, l in
        l.concierge.map { (p.name, pane, $0, Self.terminalKey(p.path, pane), l) }
      }.sorted { $0.pane > $1.pane }
    }
  }

  /// The running terminal of `chat` (its current session id), or the first running one.
  public func concierge(chat: String? = nil) -> (project: String, pane: Int, session: String, key: String, launch: AgentLaunch)? {
    concierges().first { c in chat.map { (c.launch.session ?? c.session) == $0 } ?? true }
  }

  /// The concierge terminal key whose request started this card's live column agent; nil when the owner moved it.
  public func boardConcierge(_ card: TodoBoardCard) -> String? {
    guard let key = card.todo.agent, let t = terminal(key), let parent = withLayoutCopy(t.project).launches[t.pane]?.parent,
          isConcierge(parent) else { return nil }
    return parent
  }

  /// Agents a concierge launched (their `parent` is a concierge terminal).
  public func conciergeChildren() -> [(session: AgentSession, launch: AgentLaunch)] {
    let keys = Set(concierges().map(\.key))
    // Children can live in the worktree Projects agent.launch creates, so search every Project.
    return agentSessions.compactMap { s in
      guard let l = withLayoutCopy(s.project).launches[s.pane], let parent = l.parent, keys.contains(parent) else { return nil }
      return (s, l)
    }
  }
}
