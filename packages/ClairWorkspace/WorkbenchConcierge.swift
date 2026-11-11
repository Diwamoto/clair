import CryptoKit
import Foundation

// ADR-0020: one concierge agent for all of Clair, kept in some Project's `launches` under `Concierge.pane`, a pane id no tree uses,
// so it never shows in a layout. It is an ordinary raw-PTY agent terminal (daemon shell `root#-1`); the GUI draws
// its official Claude Code transcript (found by the session id fixed at launch) as chat, and types the
// composer's text into its PTY. Children are agents launched with `parent` = the concierge's terminal key.
// ponytail: Claude Code only — it is the one provider whose session id can be fixed at launch
// (`--session-id`); Codex/OpenCode need a session-discovery step before they can be a concierge.

public enum Concierge {
  /// The concierge's pane id: off every tree (`PaneTree` ids start at 1), so no layout draws it. The chat mounts its surface.
  public static let pane = -1

  static let basePrompt = """
    あなたは Clair 全体のコンシェルジュです。ユーザーの依頼を受け、Clair の操作と作業の割り振りを担当します。自分で大きな実装はしません。

    ## できること
    - `clair` CLI で Clair を操作する(ファイルを開く、ペイン、git、プレビューなど)。使い方は clair-agents / clair-preview skill を参照。
    - 作業は子 agent に任せる: `clair agent launch profile=<claude|codex|opencode> prompt="<依頼>" [project=<Project 名>] [branch=<名前>]`。互いに独立した作業は別々の branch で並列に起動する。
    - `project=` を省くと子はコンシェルジュの作業フォルダで動く。リポジトリでの作業は必ず `project=` を付ける。値は `clair project list --compact` の `name`(パスではない)。

    ## TODO
    ユーザーの言う「todo」「TODO」「やること」「あとで」は Clair の TODO(`~/.clair/todo/*.md`、サイドバーとボードに出るもの)を指す。Claude Code 内蔵の TodoWrite やタスク機能、リポジトリ内の TODO コメントではない。操作は clair-todo skill の通り `clair todo ...` コマンドで行い、ファイルを直接書かない。
    - 一覧: `clair todo list done=false --compact`。番号やタイトルの一部で指されたら、この結果から特定する。
    - 追加: `clair todo add title="..." [priority=1-3] [due=YYYY-MM-DD] body="..."`。確認せずに追加し、body に依頼の言葉と対象リポジトリのパスを書く。
    - 更新: `clair todo update path=<list の path> [done=true] [title=...] [priority=...] [due=...] [appendBody="..."]`。
    - 「この TODO をやって」と言われたら:
      1. list の `path` のファイルを読み(list は本文を返さない)、対象リポジトリを決める。front matter の `project:` があればそれ、無ければ本文に書かれたパス。
      2. `clair project list --compact` で、そのパスと一致するかそのパスを含む Project の `name` を探す。無ければ `clair project open path=<パス>` で開いてから(ユーザーの承認が出る)name を取り直す。パスもどこにも書かれていなければ1問だけ聞く。
      3. `clair agent launch ... project=<name> prompt="<TODO のタイトルと本文>"` で子を起動する。自分の cwd で起動しない。
      4. `clair todo update path=<path> agent=<返った terminal key> appendBody="- <terminal key> 着手"` で担当を記録する。終わったら `done=true` と結果1行を `appendBody` で残す。

    ## トークン節約のルール(重要)
    - `clair` は必ず `--compact` を付けて実行する(色なしの1行の JSON になる)。
    - 子 agent の出力を逐一読まない。進み具合は Clair のサイドバーが表示している。
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

  /// Claude Code keeps each session at `~/.claude/projects/<cwd slug>/<id>.jsonl`; the slug is not
  /// something to re-derive, so look the id up one level down.
  public static func transcriptFile(session: String, home: URL = .homeDirectory) -> URL? {
    let root = home.appending(path: ".claude/projects")
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return dirs.lazy.map { $0.appending(path: "\(session).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// `opening` rides as Claude's initial prompt, so a request sent before the TUI was up is never lost.
  static func command(session: String, extra: String, opening: String? = nil) -> String {
    // A restored pane reopens the same chat; a new one starts it under the fixed id.
    let start = transcriptFile(session: session) == nil ? "--session-id" : "--resume"
    let first = start == "--session-id" ? opening.map { " " + AgentRun.quote($0) } ?? "" : ""
    return "claude \(start) \(session) --append-system-prompt \(AgentRun.quote(prompt(extra: extra)))\(first)"
  }
}

extension WorkbenchState {
  /// The folder the next concierge starts in.
  public var conciergeDir: String { conciergeCwd.isEmpty ? Concierge.defaultCwd() : conciergeCwd }

  /// Clair's concierge terminal, in whichever Project's `launches` holds it.
  public func concierge() -> (project: String, pane: Int, session: String, key: String, launch: AgentLaunch)? {
    projects.lazy.compactMap { p in
      withLayoutCopy(p.name).launches[Concierge.pane].flatMap { l in
        l.concierge.map { (p.name, Concierge.pane, $0, Self.terminalKey(p.path, Concierge.pane), l) }
      }
    }.first
  }

  /// Agents the concierge launched (their `parent` is the concierge terminal).
  public func conciergeChildren() -> [(session: AgentSession, launch: AgentLaunch)] {
    guard let key = concierge()?.key else { return [] }
    // Children can live in the worktree Projects agent.launch creates, so search every Project.
    return agentSessions.compactMap { s in
      guard let l = withLayoutCopy(s.project).launches[s.pane], l.parent == key else { return nil }
      return (s, l)
    }
  }
}
