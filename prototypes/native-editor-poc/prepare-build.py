#!/usr/bin/env python3
"""Apply the PoC-only dependency adjustments inside SwiftPM's checkout.

Swift CLI does not synthesize Bundle.module for implicit xcassets (Xcode does),
so the Symbols catalog is declared as a resource. The pinned SourceEditor
revision also receives the small lifecycle patch used by NE-05. Both changes
are confined to `.build`; the original Clair checkout is never modified.
"""
from pathlib import Path
import stat
import subprocess


ROOT = Path(__file__).parent
SOURCE_EDITOR = ROOT / ".build/checkouts/CodeEditSourceEditor"
SOURCE_EDITOR_REVISION = "1fa4d3c3ffba007482111466cb9721416f97ae00"
SOURCE_EDITOR_PATCH = ROOT / "upstream-patches/CodeEditSourceEditor-lifecycle.patch"
SOURCE_EDITOR_FILES = (
    SOURCE_EDITOR / "Sources/CodeEditSourceEditor/TreeSitter/TreeSitterClient.swift",
    SOURCE_EDITOR / "Sources/CodeEditSourceEditor/TreeSitter/TreeSitterExecutor.swift",
)


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(SOURCE_EDITOR), *args],
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def ensure_source_editor_lifecycle_patch() -> None:
    if not SOURCE_EDITOR.is_dir() or not SOURCE_EDITOR_PATCH.is_file():
        raise SystemExit(
            "SourceEditor checkout or lifecycle patch is missing; run `swift package resolve` first."
        )

    revision = git("rev-parse", "HEAD").stdout.strip()
    if revision != SOURCE_EDITOR_REVISION:
        raise SystemExit(
            "CodeEditSourceEditor revision mismatch: "
            f"expected {SOURCE_EDITOR_REVISION}, found {revision}."
        )

    already_applied = git(
        "apply", "--check", "--unidiff-zero", "--reverse", "-p0", str(SOURCE_EDITOR_PATCH), check=False
    ).returncode == 0
    if not already_applied:
        can_apply = git(
            "apply", "--check", "--unidiff-zero", "-p0", str(SOURCE_EDITOR_PATCH), check=False
        )
        if can_apply.returncode != 0:
            raise SystemExit(
                "CodeEditSourceEditor lifecycle patch does not apply cleanly:\n"
                + can_apply.stderr.strip()
            )
        for path in SOURCE_EDITOR_FILES:
            path.chmod(path.stat().st_mode | stat.S_IWUSR)
        git("apply", "--unidiff-zero", "-p0", str(SOURCE_EDITOR_PATCH))


def ensure_symbols_resources() -> None:
    symbols_package = ROOT / ".build/checkouts/CodeEditSymbols/Package.swift"
    source = symbols_package.read_text()
    old = 'name: "CodeEditSymbols",\n            dependencies: []'
    new = old + ',\n            resources: [.copy("Symbols.xcassets")]'
    if new not in source:
        if old not in source:
            raise SystemExit("CodeEditSymbols Package.swift has an unexpected layout.")
        symbols_package.chmod(symbols_package.stat().st_mode | stat.S_IWUSR)
        symbols_package.write_text(source.replace(old, new))


ensure_source_editor_lifecycle_patch()
ensure_symbols_resources()
