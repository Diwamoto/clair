---
name: clair-release
description: Cut a Clair release — collect every change since the previous release tag, write them into CHANGELOG.md (Keep a Changelog), bump VERSION (SemVer), commit, and on the owner's confirmation push it and the v<version> tag so the Release workflow publishes the signed update. Use when the user asks to release Clair, cut/ship a version, bump the version, or write the changelog for a release. Not for ad hoc Clair work or task-queue work (use clair-task).
---

# Clair release

Clair ships the usual OSS way: `CHANGELOG.md` in
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format, SemVer in
`VERSION`, a `v<version>` tag and a GitHub Release. Publishing is automatic
once the `v<version>` tag is pushed (a plain push to `main` publishes
nothing): `.github/workflows/release.yml` → `scripts/release.sh` checks the
tag matches `VERSION`, runs `make test`, builds `Clair.app`, smoke-launches
it, signs `latest.json` and creates the Release with the CHANGELOG section as its notes.
Installed apps pick it up within an hour. Details:
[`docs/runbooks/release.md`](../../../docs/runbooks/release.md).

Report to the user in Japanese. The CHANGELOG itself and commit messages are
in English.

## Steps

1. **Preflight.** `git fetch origin main --tags`. Work on a branch or worktree
   created from `origin/main`. The main worktree is shared, so never stash,
   reset or commit other people's changes there; commit with explicit paths.
   Stop if `origin/main` has a `release.yml` run in progress
   (`gh run list --workflow release.yml -L 3`).

2. **Find the range.** The previous release is the newest tag that points into
   main: `git describe --tags --abbrev=0 --match 'v*' origin/main`. If there
   is none (first release), the range is all of history. Otherwise use
   `<tag>..origin/main`. If the range has no user-visible change, say so and
   stop.

3. **Collect the changes.** Read `git log --no-merges --format='%h %s%n%b' <range>`
   and look at diffs where a subject is unclear. Commits follow Conventional
   Commits, and they map to sections like this:

   | commit type | section |
   |---|---|
   | `feat` | Added (or Changed when it reworks something existing) |
   | `fix`, `perf` | Fixed / Changed |
   | removal (`refactor` that removes a feature, "remove"/"drop") | Removed |
   | security fix | Security |
   | `docs`, `test`, `build`, `ci`, `chore`, internal-only `refactor` | leave out |

   Write for users of the app, not for reviewers: one line per change, in
   plain words, merging commits that make up one feature. Leave out task IDs,
   commit hashes and internal names such as file paths. Keep only the sections
   that have entries, in this order: Added, Changed, Deprecated, Removed,
   Fixed, Security. Merge in anything already under `## [Unreleased]`.

4. **Pick the version.** Read the current `VERSION`, then apply SemVer (while
   the major is 0, a breaking change bumps the minor):
   - breaking change (`!` or `BREAKING CHANGE`) → major (minor while `0.x`)
   - any `feat` → minor
   - otherwise → patch

   First release exception: if no `v*` tag exists yet, release the current
   `VERSION` as it is. If the user named a version, use theirs.

5. **Write it.** In `CHANGELOG.md`, put the new section right below an empty
   `## [Unreleased]`:

   ```markdown
   ## [Unreleased]

   ## [0.2.0] - 2026-09-26

   ### Added
   - ...
   ```

   Keep the link references at the bottom of the file up to date:
   `[Unreleased]: https://github.com/Diwamoto/clair/compare/v0.2.0...HEAD` and
   `[0.2.0]: https://github.com/Diwamoto/clair/compare/v0.1.0...v0.2.0`. For
   the first release, use `.../releases/tag/v0.1.0` instead. Write the version
   to `VERSION`.

6. **Check.** Run the extraction that `release.sh` uses, and confirm it prints
   the section:

   ```bash
   v="$(tr -d '[:space:]' <VERSION)"
   awk -v h="## [$v]" 'index($0, "## [") == 1 { f = (index($0, h) == 1); next } f' CHANGELOG.md
   ```

   Run `make test`. Optionally, if you want to check the packaging too (it
   needs libghostty vendored, a few minutes), run
   `CLAIR_UPDATE_PRIVATE_KEY="$(security find-generic-password -s clair-update-signing -w)" scripts/release.sh --dry-run`.

7. **Commit.** Commit with explicit paths:
   `git commit -m "chore(release): v<version>" -- CHANGELOG.md VERSION`.

8. **User gate: publish.** Show the user the version, the CHANGELOG section
   and the commit, and ask for confirmation. Pushing publishes to every
   installed app, and a published version cannot be taken back. Only after
   they say yes:
   - push the commit to `main` (fast-forward; if `main` moved, rebase and
     re-check the range first). Do not force-push.
   - tag that exact commit and push the tag, which is what publishes:
     `git tag v<version> <commit> && git push origin v<version>`.
   - watch the run: `gh run watch "$(gh run list --workflow release.yml -L 1 --json databaseId -q '.[0].databaseId')"`.
   - confirm `gh release view v<version>` lists
     `Clair-<version>-macos-arm64.zip` and `latest.json`.

## When it fails

If the workflow fails, fix the cause and re-run it through `workflow_dispatch`
on the same tag. Do not bump `VERSION` again, since that would leave a
gap in the changelog. If a Release was half-created, it must be deleted
(`gh release delete v<version> --cleanup-tag`) before the re-run. Deleting a
Release is a user gate as well. Stop conditions are listed in the runbook.
