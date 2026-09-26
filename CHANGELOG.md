# Changelog

All notable changes to Clair are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-26

First public release of Clair, a native macOS workbench for coding with AI agents.

### Added

- **Editor**: native text editor with multi-cursor, word/line motions, undo/redo, literal and regex search and replace, IME and accessibility support.
- **Syntax and language features**: tree-sitter highlighting (Swift, Go, TypeScript/JavaScript, Python, JSON, Markdown, Rust, shell, Ruby, Java, PHP, Terraform) in Atom One Dark, language-server diagnostics, go to definition with back/forward history, code folding and soft wrap.
- **Markdown preview**: live preview pane next to the editor.
- **Terminal**: Ghostty-powered terminal in panes and titlebar tabs; shells keep running in a background daemon, so closing a window or updating the app reattaches the same session.
- **AI agents**: launch profiles for Claude Code, Codex and OpenCode, an agent session list, past chat history grouped by day and project, and agents that can fan out child agents through the `clair` CLI.
- **Review**: AI review of a file, folder or Project from the explorer, review threads on diff lines, and sending open threads back to an agent as a prompt.
- **Git**: Source Control sidebar with stage, commit, branch switch, pull and push, managed worktrees, a commit graph, inline blame for the selected line, and diffs in the diff editor.
- **Explorer**: Project file tree with new file/folder, rename and delete, quick open and project-wide search and replace.
- **Approvals and notifications**: in-window approval cards for agent tool calls (MCP), notification history with badges and mute, and agent bell/OSC notifications.
- **Status bar**: branch, agent state, and Claude Code / Codex / OpenCode usage windows.
- **Commands**: command palette, assignable shortcuts, and the `clair` command (`clair open path:line`), installable from Settings.
- **Local history**: preview and restore earlier versions of a file.
- **Mobile companion (preview)**: iOS app that pairs with the Mac to follow agent conversations, review diffs and attach to terminal sessions.
- **Updates**: installed apps check for signed updates and install them on restart.

[Unreleased]: https://github.com/Diwamoto/clair/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Diwamoto/clair/releases/tag/v0.1.0
