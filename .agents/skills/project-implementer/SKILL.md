---
name: project-implementer
description: Implement and verify a documented repository project selected by project code. Use when a project bundle already exists under docs/projects and code changes should follow its requirements, design, decisions, and plan; do not use to design an undocumented GitHub issue.
---

# Project Implementer

Implement one documented project from its `project_code`, preserve its decision trail, and leave the repository in a verified state. Treat the project bundle as the scoped handoff from design to implementation.

## Input

Require a project code such as `p0012-editor-foundation`. Resolve it only through `docs/projects/<project_code>/`; do not guess a different issue or silently substitute another project when the directory is missing. Additional instructions from the user override the project bundle when they explicitly change scope.

The project code is an identifier, not automatic permission to create or switch branches. Read `suggested_branch` from the project manifest. Preserve the current branch and worktree unless the user or repository instructions require branch setup; never move uncommitted user work merely to match the suggestion.

## Preflight

Before changing production code:

1. Read repository instructions and `docs/README.md`.
2. Read the project's `README.md`, `requirements.md`, `design.md`, and `plan.md` completely.
3. Follow links to accepted ADRs and only the architecture, investigations, benchmarks, plans, or runbooks needed to understand the project.
4. Inspect the relevant code, tests, dependencies, and current worktree. Treat existing changes as user-owned.
5. Check that the manifest status is `ready` or `in-progress` and that no blocking question remains.

Do not implement a `draft` or `blocked` project. Factual omissions may be repaired from unambiguous repository evidence, but a missing product, compatibility, security, destructive-data, or cross-component architecture decision must return the project to documentation work. Report the exact blocker and the document that needs revision.

## Implementation

Set the project status to `in-progress` when code changes begin. Work through `plan.md` in dependency order, completing coherent slices rather than mechanically following stale steps. For each slice:

- Keep changes within the documented goals and non-goals.
- Reuse repository conventions and maintain the documented component boundaries.
- Add or update tests that directly validate mapped acceptance criteria.
- Run the narrowest useful checks during development and the complete relevant checks before finishing.
- Mark a plan item complete only after its code and stated validation both succeed.

The issue and plan describe intent, not permission for unrelated refactors, external publishing, deployment, issue updates, commits, pushes, or pull requests. Perform those only when explicitly requested.

## Design changes discovered during implementation

Keep the documentation truthful while implementing:

- Update `plan.md` when ordering or implementation mechanics change without changing the promised result.
- Update `design.md` when an internal, reversible design detail changes and record why.
- Create a new ADR, or supersede an existing ADR with a new one, when a durable decision with meaningful alternatives changes. Never rewrite an accepted ADR to hide the earlier decision.
- Return the project to `draft` and stop the affected work when a discovery materially changes scope, acceptance criteria, a public or cross-component interface, compatibility, security, migration safety, or an accepted decision without sufficient authority.

Do not weaken acceptance criteria to make an implementation pass. If a criterion is no longer appropriate, document the proposed change and surface it as a decision.

## Completion

A project is `complete` only when:

1. Every acceptance criterion is implemented and has recorded validation evidence.
2. Relevant automated tests, builds, formatting, and static checks pass, or unavoidable failures are clearly distinguished from project regressions.
3. `plan.md` reflects what was actually completed and identifies any explicitly deferred follow-up.
4. `design.md`, current-state files under `docs/architecture/`, and affected runbooks match the implementation.
5. No blocking question or undocumented material deviation remains.
6. The final diff has been reviewed for unrelated or accidental changes.

Record a concise completion summary and validation commands/results in the project `README.md`, then set status to `complete`. If required work remains, keep `in-progress`; use `blocked` only for a genuine external or decision blocker and name it precisely.

Do not close or comment on the source GitHub issue unless the user explicitly asks. Return the project code, final status, implemented slices, tests and checks run, documentation or ADR changes, remaining follow-ups, and any known limitations.
