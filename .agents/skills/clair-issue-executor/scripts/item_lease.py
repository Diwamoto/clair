#!/usr/bin/env python3
"""Validate and atomically lease one Clair queue item across Git worktrees."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


QUEUE_PATH = Path("docs/plans/clair-poc-queue.md")
ITEM_ID_PATTERN = re.compile(r"^(?:P|L)\d+[A-Z]?$")
HEADING_PATTERN = re.compile(r"^### ((?:P|L)\d+[A-Z]?) (.+)$", re.MULTILINE)
STATUS_PATTERN = re.compile(r"^- Status: `([^`]+)`$", re.MULTILINE)
DEPENDS_PATTERN = re.compile(r"^- Depends on: (.+)$", re.MULTILINE)
DEPENDENCY_ID_PATTERN = re.compile(r"(?:P|L)\d+[A-Z]?")


class ItemLeaseError(RuntimeError):
    """A deterministic selection, readiness, or lease failure."""


@dataclass(frozen=True)
class QueueItem:
    item_id: str
    title: str
    status: str
    dependencies: tuple[str, ...]


def git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "git command failed"
        raise ItemLeaseError(detail)
    return result.stdout.strip()


def repository_root(explicit_root: str | None) -> Path:
    candidate = Path(explicit_root).resolve() if explicit_root else Path.cwd()
    root = Path(git(candidate, "rev-parse", "--show-toplevel")).resolve()
    queue = root / QUEUE_PATH
    if not queue.is_file():
        raise ItemLeaseError(f"queue not found: {queue}")
    return root


def parse_queue(queue_path: Path) -> dict[str, QueueItem]:
    text = queue_path.read_text(encoding="utf-8")
    headings = list(HEADING_PATTERN.finditer(text))
    items: dict[str, QueueItem] = {}

    for index, heading in enumerate(headings):
        item_id = heading.group(1)
        end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
        entry = text[heading.start() : end]
        status_match = STATUS_PATTERN.search(entry)
        if status_match is None:
            raise ItemLeaseError(f"{item_id} has no status")
        depends_match = DEPENDS_PATTERN.search(entry)
        dependencies = (
            tuple(DEPENDENCY_ID_PATTERN.findall(depends_match.group(1)))
            if depends_match
            else ()
        )
        if item_id in items:
            raise ItemLeaseError(f"duplicate queue item: {item_id}")
        items[item_id] = QueueItem(
            item_id=item_id,
            title=heading.group(2).strip(),
            status=status_match.group(1),
            dependencies=dependencies,
        )

    if not items:
        raise ItemLeaseError("queue has no executable items")
    unknown = sorted(
        dependency
        for item in items.values()
        for dependency in item.dependencies
        if dependency not in items
    )
    if unknown:
        raise ItemLeaseError(f"unknown dependencies: {', '.join(unknown)}")
    return items


def resolve_item(selector: str, items: dict[str, QueueItem]) -> QueueItem:
    normalized = selector.strip()
    if normalized.lower() == "next":
        candidates = [item for item in items.values() if item.status == "next"]
        if len(candidates) != 1:
            raise ItemLeaseError(
                f"expected exactly one next item, found {len(candidates)}"
            )
        return candidates[0]

    item_id = normalized.upper()
    if not ITEM_ID_PATTERN.fullmatch(item_id) or item_id not in items:
        raise ItemLeaseError(f"unknown queue item: {selector}")
    return items[item_id]


def validate_ready(item: QueueItem, items: dict[str, QueueItem]) -> None:
    dependency_states = {
        dependency: items[dependency].status for dependency in item.dependencies
    }
    incomplete = [
        f"{dependency}={status}"
        for dependency, status in dependency_states.items()
        if status != "done"
    ]
    if incomplete:
        raise ItemLeaseError(
            f"{item.item_id} has incomplete dependencies: {', '.join(incomplete)}"
        )

    allowed = {"next", "queued", "active", "final-only"}
    if item.status not in allowed:
        raise ItemLeaseError(f"{item.item_id} is {item.status}, not executable")
    if item.status == "final-only" and item.item_id != "L01":
        raise ItemLeaseError(f"unexpected final-only item: {item.item_id}")


def current_identity(root: Path) -> dict[str, str]:
    branch = git(root, "branch", "--show-current")
    if not branch:
        raise ItemLeaseError("detached HEAD is not allowed for item execution")
    return {
        "worktree": str(root),
        "branch": branch,
        "head": git(root, "rev-parse", "HEAD"),
    }


def common_git_directory(root: Path) -> Path:
    raw = Path(git(root, "rev-parse", "--git-common-dir"))
    return raw.resolve() if raw.is_absolute() else (root / raw).resolve()


def git_directory(root: Path) -> Path:
    raw = Path(git(root, "rev-parse", "--git-dir"))
    return raw.resolve() if raw.is_absolute() else (root / raw).resolve()


def lease_root(root: Path) -> Path:
    return common_git_directory(root) / "clair-item-leases"


@contextmanager
def locked_lease_root(root: Path):
    leases = lease_root(root)
    leases.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = leases / ".lock"
    with lock_path.open("a+", encoding="utf-8") as lock_file:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            yield leases
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def read_owner(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ItemLeaseError(f"invalid lease owner at {path}: {error}") from error
    if not isinstance(value, dict):
        raise ItemLeaseError(f"invalid lease owner at {path}")
    return value


def all_leases(root: Path) -> list[dict[str, Any]]:
    leases = lease_root(root)
    if not leases.is_dir():
        return []
    result: list[dict[str, Any]] = []
    for item_directory in sorted(leases.iterdir(), key=lambda path: path.name):
        owner_path = item_directory / "owner.json"
        if item_directory.is_dir() and owner_path.is_file():
            owner = read_owner(owner_path)
            owner["item_id"] = item_directory.name
            result.append(owner)
    return result


def details(root: Path, selector: str) -> tuple[QueueItem, dict[str, Any]]:
    items = parse_queue(root / QUEUE_PATH)
    item = resolve_item(selector, items)
    validate_ready(item, items)
    dependency_states = {
        dependency: items[dependency].status for dependency in item.dependencies
    }
    identity = current_identity(root)
    payload: dict[str, Any] = {
        "item_id": item.item_id,
        "title": item.title,
        "status": item.status,
        "dependencies": dependency_states,
        "ready": True,
        **identity,
        "git_directory": str(git_directory(root)),
        "common_git_directory": str(common_git_directory(root)),
        "linked_worktree": git_directory(root) != common_git_directory(root),
        "other_leases": all_leases(root),
    }
    return item, payload


def acquire(root: Path, selector: str) -> dict[str, Any]:
    item, payload = details(root, selector)
    identity = current_identity(root)
    with locked_lease_root(root) as leases:
        existing_leases = all_leases(root)
        payload["other_leases"] = existing_leases
        same_worktree = next(
            (
                existing
                for existing in existing_leases
                if existing.get("worktree") == identity["worktree"]
            ),
            None,
        )
        if same_worktree is not None:
            raise ItemLeaseError(
                f"worktree already owns {same_worktree.get('item_id', '?')} on "
                f"{same_worktree.get('branch', '?')}"
            )

        item_directory = leases / item.item_id
        owner_path = item_directory / "owner.json"
        if item_directory.exists():
            existing = read_owner(owner_path)
            raise ItemLeaseError(
                f"{item.item_id} is leased by "
                f"{existing.get('branch', '?')} at {existing.get('worktree', '?')}"
            )

        item_directory.mkdir(mode=0o700)
        owner = {
            **identity,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        try:
            owner_path.write_text(
                json.dumps(owner, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            os.chmod(owner_path, 0o600)
        except Exception:
            if owner_path.exists():
                owner_path.unlink()
            item_directory.rmdir()
            raise

    payload.update({"acquired": True, "owner": owner})
    return payload


def release(root: Path, selector: str, force: bool) -> dict[str, Any]:
    items = parse_queue(root / QUEUE_PATH)
    item = resolve_item(selector, items)
    if not lease_root(root).exists():
        return {"item_id": item.item_id, "released": False, "reason": "not leased"}
    with locked_lease_root(root) as leases:
        item_directory = leases / item.item_id
        owner_path = item_directory / "owner.json"
        if not item_directory.exists():
            return {
                "item_id": item.item_id,
                "released": False,
                "reason": "not leased",
            }

        owner = read_owner(owner_path)
        identity = current_identity(root)
        same_owner = all(
            owner.get(field) == identity[field] for field in ("worktree", "branch")
        )
        if not same_owner and not force:
            raise ItemLeaseError(
                f"{item.item_id} is leased by "
                f"{owner.get('branch', '?')} at {owner.get('worktree', '?')}"
            )

        entries = list(item_directory.iterdir())
        if entries != [owner_path]:
            unexpected = ", ".join(sorted(path.name for path in entries))
            raise ItemLeaseError(f"unexpected lease contents: {unexpected}")
        owner_path.unlink()
        item_directory.rmdir()
    return {"item_id": item.item_id, "released": True, "owner": owner}


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", help="repository/worktree root; defaults to cwd")
    commands = parser.add_subparsers(dest="command", required=True)

    inspect_parser = commands.add_parser("inspect", help="validate one queue item")
    inspect_parser.add_argument("selector", help="explicit item ID or next")

    acquire_parser = commands.add_parser("acquire", help="atomically lease one item")
    acquire_parser.add_argument("selector", help="explicit item ID or next")

    release_parser = commands.add_parser("release", help="release one owned lease")
    release_parser.add_argument("selector", help="explicit item ID or next")
    release_parser.add_argument(
        "--force",
        action="store_true",
        help="release another owner's lease; requires explicit user authorization",
    )
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        root = repository_root(arguments.repo)
        if arguments.command == "inspect":
            _, payload = details(root, arguments.selector)
        elif arguments.command == "acquire":
            payload = acquire(root, arguments.selector)
        else:
            payload = release(root, arguments.selector, arguments.force)
        emit(payload)
        return 0
    except ItemLeaseError as error:
        print(f"item lease error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
