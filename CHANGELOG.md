# Changelog

All notable changes to Clair are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-09-28

### Changed

- **Status bar**: the quota meter is shown by default; the settings toggle now hides it.
- **Panes**: the pane header title is inset from the left edge.

### Removed

- **Settings**: the update channel card.

### Fixed

- **Window**: traffic lights are laid out correctly for a window that is already focused at launch.
- **Usage**: hover moves freely across the activity grid, and totals are kept between openings.

## [0.2.0] - 2026-09-28

### Added

- **Editor**: CSV/TSV files open as an editable, spreadsheet-like table; Markdown files get preview and table-editor buttons.
- **Appearance**: dark and light colour schemes across chrome, editor and terminal, and language logos as file icons in the tree, tabs, search, quick open and review.
- **Explorer and changes**: changed files and folders are coloured, with a status letter on files and a dot on folders; rows are larger.
- **Diffs**: side-by-side diff view (remembered app-wide), unchanged lines beyond three of context are folded, and a commit shows every file diff stacked with pinned file headers.
- **Commit graph and diffs** open as reorderable titlebar tabs; the commit graph opens maximized.
- **Tab groups**: context menu to change colour (with a full colour picker), rename, move, close and add folders; new projects get a random colour.
- **Branches**: branch switcher opens as a centred palette that can also create branches.
- **Past chats**: redesigned like a chat app and grouped by repository.
- **Usage**: recent totals with a per-day breakdown by provider.
- **Keyboard**: Cmd+Shift+P opens the command palette, Cmd+B toggles the sidebar, Ctrl-Tab / Ctrl-Shift-Tab cycle titlebar tabs.
- **Terminal**: each pane shows its title at the top-left; untitled terminals are labelled "Terminal".
- The sidebar width is draggable and remembered; any activity-bar button reopens a hidden sidebar.
- Each preview pane stays bound to the file it was opened for.

### Changed

- Past chats load faster.
- Settings typography is tighter.
- Agent menu items read "Send to Agent".

### Fixed

- Split diffs: long lines no longer overlap, both halves scroll sideways together, and the divider stays centred.
- The explorer rescans after commits made in the terminal, watches newly added folders, and no longer hides folders behind ignored caches; deleted files are hidden while their folders stay red.
- A terminal whose background daemon died restarts on attach and redraws correctly after a resize.
- Dragging a titlebar tab no longer moves the window.
- Command-Return inserts a newline in the commit message box, which is now a proper multi-line field.
- Palette and search selections stay scrolled into view.
- Various alignment and sizing fixes in the explorer, change tree, status bar, diff view and commit graph.

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

[Unreleased]: https://github.com/Diwamoto/clair/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/Diwamoto/clair/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Diwamoto/clair/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Diwamoto/clair/releases/tag/v0.1.0
