---
name: clair-mock-implement
description: Implement native Clair app changes (apple/ClairApp, apple/ClairMobileApp, packages/ClairMobileKit) to match a screen or interaction already established in the Clair interaction-lab mock, which itself mirrors the Clair UI Design canvas. Use once a mock screen is ready to become real native functionality. Do not use this to change the mock or the Design canvas themselves — that is clair-design-sync's job.
---

# Clair Mock Implement

The mock is the UI/behavior reference for native work, not something this
skill edits. If implementing reveals the mock is wrong, incomplete, or
underspecified, stop and say so rather than improvising a native-only
answer — the fix belongs in the Design canvas, propagated back down
through [`clair-design-sync`](../clair-design-sync/SKILL.md), not invented
here.

## User-facing language

Use Japanese for every user-facing commentary update, plan/status
explanation, clarifying or decision question, warning, blocker, error
summary, and final report. Keep item IDs, file paths, API/type names,
commands, and raw tool/test output in their original form.

## Fixed context

- Reference mock: `/Users/daiki/Projects/clair/prototypes/clair-interaction-lab`
  (`app/page.tsx`, `app/mock-data.ts`, `app/globals.css`). It mirrors the
  Clair UI Design canvas; treat it as ground truth for exact copy,
  spacing, color, and interaction states.
- Native targets: `apple/ClairApp` (macOS), `apple/ClairMobileApp` and
  `packages/ClairMobileKit` (mobile control surface), `crates/clair-cli`
  where a change needs CLI-side wiring.
- For a change large enough to need its own requirements/design/plan
  bundle, use `issue-to-project-docs` then `project-implementer` instead
  of freehanding it here. For a small, well-scoped slice, implement
  directly in this skill and commit with
  [`clair-session-commit`](../clair-session-commit/SKILL.md).

## Workflow

1. Identify the target mock screen or interaction and read its exact
   implementation (JSX structure, CSS rules, literal copy, state
   transitions) in the mock source — not from memory of an earlier
   conversation.
2. Read the current native SwiftUI/Rust code for the equivalent area
   before changing anything.
3. Implement the native change to match the mock's visual result and
   behavior, using this codebase's existing architecture and state
   patterns — do not port React/CSS patterns literally (e.g. no
   className-driven styling, no DOM-shaped state machines).
4. Verify:
   - macOS `ClairApp`: build the target and confirm it compiles; this
     session has no macOS app simulator control, so say plainly that
     visual verification needs the user to run the app manually.
   - `ClairMobileApp`: build, then use the iOS Simulator tools
     (`mcp__Claude_Code_iOS_Simulator__control`) to attach and visually
     confirm the screen matches the mock.
   - `ClairMobileKit`: run `swift test --package-path packages/ClairMobileKit`.
   - Run any other directly relevant existing tests
     (e.g. `ClairTests`) before finishing.
5. Keep changes scoped to the mapped mock behavior; do not refactor,
   redesign, or add functionality the mock doesn't show.
6. Report in Japanese: which mock screen/interaction this implements,
   what changed natively, verification performed, and any gap still open
   between the mock and the native result.
