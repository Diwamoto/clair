# Security Policy

## Supported versions

Clair is pre-release software. Only the latest commit on the default branch
receives security fixes.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through GitHub's
[private vulnerability reporting](https://github.com/Diwamoto/clair/security/advisories/new)
("Report a vulnerability" on the Security tab). Include:

- the affected component and commit,
- steps to reproduce or a proof of concept,
- the impact you expect (what an attacker gains).

You can expect an acknowledgement within 7 days. This is a personal project, so
fix timelines are best effort; you will be kept informed and credited in the
advisory unless you prefer otherwise. Please give us a reasonable window to ship
a fix before public disclosure.

Reports in English or Japanese are both welcome.

## Scope

Of particular interest:

- the remote-client transport and mobile pairing (host key, device grants,
  TLS pinning, revoke) in `ClairDaemon` / `ClairTransport` / `ClairMobileKit`;
- the local CLI and stdio MCP command surface and its risk gating;
- update manifest signature verification;
- anything that lets untrusted file contents, terminal output, or a remote peer
  execute commands or read data outside the opened project.

Out of scope: issues that require an already-compromised local user account,
and vulnerabilities in third-party agents (Claude Code, Codex, OpenCode) or in
upstream dependencies — report those upstream.
