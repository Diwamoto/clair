---
name: issue-to-project-docs
description: Create implementation-ready repository documentation from a GitHub issue. Use when an issue must be converted into a durable project brief, requirements, technical design, implementation plan, and any supporting ADR or investigation record; do not use to implement the resulting project.
---

# Issue to Project Docs

Turn one GitHub issue into a durable, reviewable project bundle and return its `project_code`. The repository documentation is canonical for intent and design; the issue remains the tracker for discussion and execution.

## Input

Require an issue number or GitHub issue URL. Resolve the repository from the current checkout unless the URL names another repository. Read the issue body, comments that change scope or decisions, linked issues or pull requests that materially affect the work, repository instructions, existing docs, and relevant code. Do not modify the issue, labels, projects, or milestones unless the user explicitly asks.

## Project identity

Assign a unique, stable code in the form `pNNNN-short-kebab-slug`, using the zero-padded issue number when available, for example `p0012-editor-foundation`. Prefer the issue's outcome over its ticket category when choosing the slug. If the code already exists for the same issue, update that project instead of creating another. If it belongs to another issue, choose a disambiguated slug.

The code is an identifier, not automatic permission to create or switch branches. Record `project/<project_code>` as the suggested branch.

## Required output

Read `docs/README.md` and the templates under `docs/_templates/` before writing. Create or update:

```text
docs/projects/<project_code>/
├── README.md
├── requirements.md
├── design.md
└── plan.md
```

Keep the four files useful even for a small project; be concise instead of dropping required information. Link rather than duplicate existing architecture, decisions, investigations, benchmarks, plans, and runbooks.

- `README.md` is the manifest: source issue, status, owners if known, suggested branch, one-paragraph outcome, document links, blocking questions, and readiness.
- `requirements.md` records motivation, goals, non-goals, user-visible behavior, constraints, acceptance criteria, and explicit out-of-scope choices.
- `design.md` records current context, proposed design, boundaries and interfaces, data or control flow when relevant, alternatives and rejected approaches, risks, rollout or migration, and affected durable docs.
- `plan.md` breaks implementation into ordered, independently verifiable slices with dependencies, tests, observability or recovery work, and completion checks. It is not a copy of the issue checklist.

Create an ADR under `docs/decisions/` when the project makes a durable choice with meaningful alternatives or cross-project consequences. Create an investigation record under `docs/investigations/` when a spike, measurement, or comparison is necessary before deciding. Store reproducible performance evidence under `docs/benchmarks/`.

## Decision policy

Distinguish facts, decisions, assumptions, and unresolved questions. Make reversible implementation choices when evidence and repository conventions support them. Do not silently decide product scope, irreversible migration behavior, security boundaries, compatibility promises, or destructive data handling when the issue does not resolve them.

An ADR may be `accepted` only when the issue, an existing accepted decision, or explicit user direction supports the decision. Otherwise use `proposed`. Record rejected options inside the relevant ADR or design, not in a separate rejected-documents folder.

Set project status to:

- `ready` when an implementer can complete the acceptance criteria without making a material product or architecture decision.
- `draft` when useful work is documented but blocking decisions remain.
- `blocked` only when the issue cannot be resolved into a coherent project from available evidence.

Open questions can remain in a `ready` project only when their answers cannot materially change scope, interfaces, safety, or acceptance criteria.

## Quality checks

Before finishing:

1. Verify every acceptance criterion maps to one or more plan steps and a validation method.
2. Verify every plan step supports a stated goal or necessary risk reduction.
3. Verify non-goals and rejected alternatives are explicit enough to prevent accidental implementation.
4. Verify links and repository-relative paths resolve.
5. Verify the project does not contradict accepted ADRs; supersede decisions with a new ADR instead of rewriting history.
6. Review the diff and ensure no production code was changed.

Return the `project_code`, project status, created or updated documents, accepted/proposed decisions, and any blocking questions. The `project_code` must be easy to copy as the sole input to `$project-implementer`.
