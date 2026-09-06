# Design

## Current state

Clairはnative macOS applicationへの移行を設計中であり、Interaction LabはProject Group、terminal、Activity、review panelをbrowser-local fixtureとして示している。#6はPTY lifecycle、#14はGit/review collection、#15はagent workflow、#20はremote accessを扱うが、並列agentの共通所有モデルは未定義だった。

[ADR-0005](../../decisions/0005-adopt-worktree-first-agent-orchestration.md)により、worktreeをagent orchestrationの第一級所有単位とする。

## Proposed design

`Repository`の下に複数の`Worktree`を置く。`Worktree`はfilesystem rootとGit stateを持ち、Project Group、editor layout、terminal session、review collection、adoption candidateのscopeになる。Agent conversationはworktreeが所有するterminalで継続し、Activityはsession catalogの要約とhandoffだけを提供する。

```text
Repository
  -> Worktree (stable ID, root, branch, base revision, lifecycle)
       -> Project Group / editor layout / breakpoints
       -> AgentSession (PTY + optional semantic adapter)
       -> Git state + ReviewCollection
       -> AdoptionCandidate
```

## Components and responsibilities

| Component | Responsibility | Changed interface |
|---|---|---|
| Rust `WorktreeService` | create/list/inspect/cleanup、Git guard | `create`, `list`, `inspect`, `prepare_cleanup` |
| Rust `OrchestrationService` | fan-out plan、session attach、candidate catalog | `launch_fanout`, `list_candidates` |
| `clair-ptyhost` / broker | `WorktreeID`付きPTY/session catalog、reattach | session metadata extension |
| SwiftUI Project Group store | worktree-scoped layoutとsurface復元 | `WorkspaceGroup(worktreeID:)` |
| Activity view model | session status、attention、terminal handoff | session catalog subscription |
| Git review workflow | worktree-scoped anchor/brief/destination | `ReviewCollection(worktreeID:)` |
| Adoption coordinator | compare、merge/adopt、cleanup confirmation | `prepare_adoption`, `confirm_operation` |

## Data and control flow

```text
user selects repository + base revision + prompt + launch profiles
  -> WorktreeService creates isolated worktrees
  -> OrchestrationService starts one AgentSession per worktree
  -> ptyhost publishes session catalog and output
  -> Activity summarizes state; terminal remains execution surface
  -> Git review creates WorktreeID-scoped ReviewCollection
  -> previewed ReviewBrief is handed to an explicit AgentSession
  -> AdoptionCoordinator compares candidate state and confirms merge/cleanup
```

## Interfaces and contracts

- `WorktreeID` is immutable while the worktree exists. `RepositoryID` plus canonical root, branch, and base/head revision are attributes recorded with it.
- `AgentSession` is attached to exactly one`WorktreeID`; reattach may restore the same session but may not silently retarget it.
- `ReviewAnchor` and `ReviewCollection` include `WorktreeID` in addition to repository-relative path and revision identity.
- fan-out creates an immutable launch manifest containing prompt digest, base revision, launch profile IDs, requested count, and individual result/error records.
- adoption/cleanup use typed prepare/confirm operations. A UI cannot infer successful mutation from optimistic local state.
- generic CLI agents use raw PTY. Semantic controls follow [ADR-0002](../../decisions/0002-layered-agent-remote-control.md) only when a supported adapter exposes the capability.

## State, persistence, and migration

Persist `Repository`, `Worktree`, layout, session metadata, and review collection in versioned local records. Existing project-group data migrates by resolving its saved root to one current worktree; unresolved records remain visible as detached/recovery entries and must not attach to the first same-named branch or file.

## Failure handling and recovery

- worktree create conflict: return the conflicting root/branch and no partially registered worktree.
- fan-out partial failure: retain successful worktrees and per-target error; offer retry only for failed targets.
- missing/deleted worktree: mark sessions and layouts detached; keep diagnostic metadata without offering terminal input.
- stale base/head or dirty state: adoption/cleanup prepare returns a blocking guard and requires refresh or explicit user action.
- session adapter failure: retain raw PTY if it survives; only semantic controls degrade.

## Security and privacy

Agent prompts, review notes, and diffs can contain source or secrets. The local catalog stores stable IDs and only necessary display metadata. A handoff serializes the previewed worktree-scoped review brief, not a broad repository dump. Remote use remains subject to #20's pairing, scope, and E2EE constraints.

## Observability

Record worktree create/delete, fan-out result, session attach/detach, adoption prepare/confirm, and cleanup guard as source-free structured diagnostics. Measure create latency, catalog reconciliation latency, reattach result, and partial-failure rate.

## Test strategy

- Rust/unit: identity allocation, duplicate root/branch guard, launch manifest, cleanup guard, migration resolver.
- integration: create/fan-out/reattach/adopt flow using fixture repositories and deterministic fake agents.
- UI: group switching, Activity-to-terminal handoff, review brief preview, confirmation/error states.
- recovery: process restart, deleted worktree, branch rename, stale base revision, partial fan-out failure.

## Options considered

### Option A: one shared project working tree for all agents

- Advantages: fewest records and UI surfaces.
- Disadvantages: concurrent writes, review ownership, and cleanup cannot be made safe.
- Evidence: rejected by ADR-0005.

### Option B: a new central Agent dashboard owns sessions

- Advantages: simple fleet visualization.
- Disadvantages: duplicates terminal interactions and violates the terminal-first product contract.
- Evidence: Activity needs status and handoff, not a second conversation surface.

### Option C: worktree-owned terminal sessions with Activity summaries

- Advantages: isolates code and keeps the execution context visible where work happens.
- Disadvantages: needs a stronger catalog and restoration model.
- Evidence: adopted by ADR-0005.

## Decision and rationale

Adopt Option C. It gives a consistent identity boundary across Git, terminal, editor, review, and later remote use while preserving Clair's native terminal-first interaction model.

## Risks and mitigations

| Risk | Impact | Mitigation or exit condition |
|---|---|---|
| worktree identity leaks across UI state | wrong code/review context | stable IDs plus scoping tests for every persisted feature |
| fan-out consumes too many local resources | degraded daily-driver experience | explicit concurrency limit and per-target launch status |
| adoption loses uncommitted work | data loss | dirty/active/unresolved guards and typed confirmation |
| agent adapter changes | semantic workflow breaks | raw PTY fallback and capability negotiation |

## Rollout and rollback

Start with local worktree catalog and one manual create/attach flow behind a feature flag. Add fan-out and Activity summaries next, then review handoff and adoption guards. Disable orchestration without deleting worktrees or sessions when a regression occurs; normal local editor, terminal, and Git workflows remain available.

## Documentation impact

- [Git review requirements](../p0014-git-review-workflow/requirements.md) gain worktree-scoped review identity.
- #15 and #20 gain dependency links to this ownership model.
- architecture documentation will be updated when the Rust/Swift interfaces exist.

## Open questions

None.
