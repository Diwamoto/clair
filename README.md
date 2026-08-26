# clair
Native macOS IDE for Claude Code, Codex CLI, and opencode

## Development documentation

Technical intent, decisions, evidence, and implementation handoffs live under
[`docs/`](docs/README.md).

Project-local Codex skills provide the standard workflow:

- `$issue-to-project-docs <GitHub issue>` creates a documented project and
  returns a project code such as `p0012-editor-foundation`.
- `$project-implementer <project code>` implements and verifies that documented
  project.
