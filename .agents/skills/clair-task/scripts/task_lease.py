#!/usr/bin/env python3
"""Validate, inspect, and atomically lease Clair tasks."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import uuid
from collections import Counter
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


QUEUE_PATH = Path("docs/clair-tasks.md")
TASK_ID_PATTERN = re.compile(r"^[BHNETUV]\d{2}$")
TASK_REFERENCE_PATTERN = re.compile(r"[BHNETUV]\d{2}")
TASK_ROW_START_PATTERN = re.compile(r"^\| `([BHNETUV]\d{2})` \|", re.MULTILINE)
TASK_ROW_PATTERN = re.compile(
    r"^\| `(?P<task_id>[BHNETUV]\d{2})` "
    r"\| `(?P<status>next|queued|active|blocked|done)` "
    r"\| `(?P<difficulty>D[1-5])` "
    r"\| (?P<depends>.*?) "
    r"\| (?P<outcome>.*?) \|$",
    re.MULTILINE,
)
EXECUTABLE_STATUSES = {"next", "queued", "active"}


class TaskLeaseError(RuntimeError):
    """A deterministic queue, readiness, or lease failure."""


@dataclass(frozen=True)
class QueueTask:
    task_id: str
    status: str
    difficulty: str
    dependencies: tuple[str, ...]
    outcome: str
    order: int


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
        raise TaskLeaseError(detail)
    return result.stdout.strip()


def repository_root(explicit_root: str | None) -> Path:
    candidate = Path(explicit_root).resolve() if explicit_root else Path.cwd()
    root = Path(git(candidate, "rev-parse", "--show-toplevel")).resolve()
    queue = root / QUEUE_PATH
    if not queue.is_file():
        raise TaskLeaseError(f"queue not found: {queue}")
    return root


def parse_queue(queue_path: Path) -> dict[str, QueueTask]:
    text = queue_path.read_text(encoding="utf-8")
    starts = TASK_ROW_START_PATTERN.findall(text)
    matches = list(TASK_ROW_PATTERN.finditer(text))
    if len(starts) != len(matches):
        parsed = {match.group("task_id") for match in matches}
        malformed = [task_id for task_id in starts if task_id not in parsed]
        detail = ", ".join(malformed) or "unknown row"
        raise TaskLeaseError(f"malformed task table row: {detail}")

    tasks: dict[str, QueueTask] = {}
    for order, match in enumerate(matches):
        task_id = match.group("task_id")
        if task_id in tasks:
            raise TaskLeaseError(f"duplicate task: {task_id}")
        dependencies = tuple(
            dict.fromkeys(TASK_REFERENCE_PATTERN.findall(match.group("depends")))
        )
        tasks[task_id] = QueueTask(
            task_id=task_id,
            status=match.group("status"),
            difficulty=match.group("difficulty"),
            dependencies=dependencies,
            outcome=match.group("outcome").strip(),
            order=order,
        )

    if not tasks:
        raise TaskLeaseError("queue has no tasks")

    unknown = sorted(
        {
            dependency
            for task in tasks.values()
            for dependency in task.dependencies
            if dependency not in tasks
        }
    )
    if unknown:
        raise TaskLeaseError(f"unknown dependencies: {', '.join(unknown)}")

    validate_acyclic(tasks)
    return tasks


def validate_acyclic(tasks: dict[str, QueueTask]) -> None:
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(task_id: str, trail: tuple[str, ...]) -> None:
        if task_id in visited:
            return
        if task_id in visiting:
            cycle_start = trail.index(task_id) if task_id in trail else 0
            cycle = (*trail[cycle_start:], task_id)
            raise TaskLeaseError(f"dependency cycle: {' -> '.join(cycle)}")
        visiting.add(task_id)
        for dependency in tasks[task_id].dependencies:
            visit(dependency, (*trail, task_id))
        visiting.remove(task_id)
        visited.add(task_id)

    for task_id in tasks:
        visit(task_id, ())


def resolve_task(selector: str, tasks: dict[str, QueueTask]) -> QueueTask:
    normalized = selector.strip().upper()
    if normalized == "NEXT":
        candidates = [task for task in tasks.values() if task.status == "next"]
        if len(candidates) != 1:
            raise TaskLeaseError(
                f"expected exactly one next task, found {len(candidates)}"
            )
        return candidates[0]
    if not TASK_ID_PATTERN.fullmatch(normalized) or normalized not in tasks:
        raise TaskLeaseError(f"unknown task: {selector}")
    return tasks[normalized]


def dependency_states(
    task: QueueTask, tasks: dict[str, QueueTask]
) -> dict[str, str]:
    return {dependency: tasks[dependency].status for dependency in task.dependencies}


def readiness(task: QueueTask, tasks: dict[str, QueueTask]) -> tuple[bool, list[str]]:
    reasons = [
        f"{dependency}={tasks[dependency].status}"
        for dependency in task.dependencies
        if tasks[dependency].status != "done"
    ]
    if task.status not in EXECUTABLE_STATUSES:
        reasons.append(f"status={task.status}")
    return not reasons, reasons


def current_identity(root: Path) -> dict[str, str]:
    branch = git(root, "branch", "--show-current")
    if not branch:
        raise TaskLeaseError("detached HEAD is not allowed for task execution")
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
    return common_git_directory(root) / "clair-task-leases"


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
        raise TaskLeaseError(f"invalid lease owner at {path}: {error}") from error
    if not isinstance(value, dict):
        raise TaskLeaseError(f"invalid lease owner at {path}")
    return value


def all_leases(root: Path) -> list[dict[str, Any]]:
    leases = lease_root(root)
    if not leases.is_dir():
        return []
    result: list[dict[str, Any]] = []
    for task_directory in sorted(leases.iterdir(), key=lambda path: path.name):
        owner_path = task_directory / "owner.json"
        if task_directory.is_dir() and owner_path.is_file():
            owner = read_owner(owner_path)
            owner["task_id"] = task_directory.name
            result.append(owner)
    return result


def task_payload(
    root: Path,
    task: QueueTask,
    tasks: dict[str, QueueTask],
    leases: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    current_leases = leases if leases is not None else all_leases(root)
    lease = next(
        (entry for entry in current_leases if entry.get("task_id") == task.task_id),
        None,
    )
    is_ready, reasons = readiness(task, tasks)
    return {
        "task_id": task.task_id,
        "status": task.status,
        "difficulty": task.difficulty,
        "dependencies": dependency_states(task, tasks),
        "outcome": task.outcome,
        "ready": is_ready and lease is None,
        "readiness_blockers": reasons + (["leased"] if lease else []),
        "lease": lease,
    }


def validate_payload(root: Path, tasks: dict[str, QueueTask]) -> dict[str, Any]:
    counts = Counter(task.status for task in tasks.values())
    return {
        "valid": True,
        "queue": str(root / QUEUE_PATH),
        "task_count": len(tasks),
        "status_counts": dict(sorted(counts.items())),
        "lease_count": len(all_leases(root)),
    }


def ready_payload(root: Path, tasks: dict[str, QueueTask]) -> dict[str, Any]:
    leases = all_leases(root)
    leased_ids = {entry.get("task_id") for entry in leases}
    ready = [
        task_payload(root, task, tasks, leases)
        for task in sorted(tasks.values(), key=lambda task: task.order)
        if task.status in {"next", "queued"}
        and all(tasks[dependency].status == "done" for dependency in task.dependencies)
        and task.task_id not in leased_ids
    ]
    return {"ready": ready, "count": len(ready), "leases": leases}


def acquire(root: Path, selector: str) -> dict[str, Any]:
    tasks = parse_queue(root / QUEUE_PATH)
    task = resolve_task(selector, tasks)
    if task.status != "active":
        raise TaskLeaseError(
            f"{task.task_id} cannot be leased until status=active; "
            f"current status={task.status}"
        )
    is_ready, reasons = readiness(task, tasks)
    if not is_ready:
        raise TaskLeaseError(
            f"{task.task_id} is not ready: {', '.join(reasons)}"
        )
    identity = current_identity(root)
    linked_worktree = git_directory(root) != common_git_directory(root)
    if not linked_worktree:
        raise TaskLeaseError("task leases require a linked isolated worktree")

    with locked_lease_root(root) as leases:
        existing_leases = all_leases(root)
        same_worktree = next(
            (
                existing
                for existing in existing_leases
                if existing.get("worktree") == identity["worktree"]
            ),
            None,
        )
        if same_worktree is not None:
            raise TaskLeaseError(
                f"worktree already owns {same_worktree.get('task_id', '?')} on "
                f"{same_worktree.get('branch', '?')}"
            )

        task_directory = leases / task.task_id
        owner_path = task_directory / "owner.json"
        if task_directory.exists():
            existing = read_owner(owner_path)
            raise TaskLeaseError(
                f"{task.task_id} is leased by "
                f"{existing.get('branch', '?')} at {existing.get('worktree', '?')}"
            )

        task_directory.mkdir(mode=0o700)
        owner = {
            **identity,
            "lease_id": str(uuid.uuid4()),
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
            task_directory.rmdir()
            raise

    return {
        **task_payload(root, task, tasks),
        "ready": True,
        "readiness_blockers": [],
        "lease": owner,
        "acquired": True,
        "owner": owner,
        "linked_worktree": linked_worktree,
    }


def release(root: Path, selector: str, lease_id: str | None) -> dict[str, Any]:
    tasks = parse_queue(root / QUEUE_PATH)
    task = resolve_task(selector, tasks)
    leases_path = lease_root(root)
    if not leases_path.exists():
        return {"task_id": task.task_id, "released": False, "reason": "not leased"}

    with locked_lease_root(root) as leases:
        task_directory = leases / task.task_id
        owner_path = task_directory / "owner.json"
        if not task_directory.exists():
            return {
                "task_id": task.task_id,
                "released": False,
                "reason": "not leased",
            }

        owner = read_owner(owner_path)
        identity = current_identity(root)
        same_owner = (
            owner.get("worktree") == identity["worktree"]
            and owner.get("branch") == identity["branch"]
        )
        token_matches = lease_id is not None and owner.get("lease_id") == lease_id
        if not same_owner and not token_matches:
            raise TaskLeaseError(
                f"{task.task_id} is leased by {owner.get('branch', '?')} at "
                f"{owner.get('worktree', '?')}; exact --lease-id required"
            )

        entries = list(task_directory.iterdir())
        if entries != [owner_path]:
            unexpected = ", ".join(sorted(path.name for path in entries))
            raise TaskLeaseError(f"unexpected lease contents: {unexpected}")
        owner_path.unlink()
        task_directory.rmdir()

    return {"task_id": task.task_id, "released": True, "owner": owner}


def emit(payload: Any) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", help="repository/worktree root; defaults to cwd")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("validate", help="validate the queue and dependencies")
    commands.add_parser("ready", help="list dependency-ready unleased tasks")
    commands.add_parser("leases", help="list active task leases")

    inspect_parser = commands.add_parser("inspect", help="inspect one task")
    inspect_parser.add_argument("selector", help="explicit task ID or next")

    acquire_parser = commands.add_parser("acquire", help="atomically lease one task")
    acquire_parser.add_argument("selector", help="explicit task ID or next")

    release_parser = commands.add_parser("release", help="release one task lease")
    release_parser.add_argument("selector", help="explicit task ID or next")
    release_parser.add_argument(
        "--lease-id",
        help="exact random lease ID; required when releasing from another worktree",
    )
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        root = repository_root(arguments.repo)
        tasks = parse_queue(root / QUEUE_PATH)
        if arguments.command == "validate":
            payload = validate_payload(root, tasks)
        elif arguments.command == "ready":
            payload = ready_payload(root, tasks)
        elif arguments.command == "leases":
            leases = all_leases(root)
            payload = {"leases": leases, "count": len(leases)}
        elif arguments.command == "inspect":
            task = resolve_task(arguments.selector, tasks)
            payload = task_payload(root, task, tasks)
        elif arguments.command == "acquire":
            payload = acquire(root, arguments.selector)
        else:
            payload = release(root, arguments.selector, arguments.lease_id)
        emit(payload)
        return 0
    except TaskLeaseError as error:
        print(f"task lease error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
