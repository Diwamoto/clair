#!/usr/bin/env python3
"""Functional tests for Clair v2 task leases in disposable Git worktrees."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("task_lease.py")
QUEUE_FIXTURE = """# Queue fixture

| ID | Status | Difficulty | Depends on | Task and completion evidence |
|---|---|---:|---|---|
| `B00` | `done` | `D2` | — | Frozen baseline. |
| `B01` | `next` | `D3` | `B00` | Build graph. |
| `B02` | `queued` | `D3` | `B00` | Native ADR. |
| `B03` | `queued` | `D5` | `B01`, `B02` | Protocol contract. |
| `H01` | `blocked` | `D4` | `B03` | Host lifecycle. |
"""


def run(*arguments: str, cwd: Path | None = None, check: bool = True):
    return subprocess.run(
        list(arguments),
        cwd=cwd,
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


class TaskLeaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "repo"
        self.root.mkdir()
        queue = self.root / "docs/plans/clair-v2-native-rewrite-queue.md"
        queue.parent.mkdir(parents=True)
        queue.write_text(QUEUE_FIXTURE, encoding="utf-8")
        run("git", "init", "-q", str(self.root))
        run("git", "config", "user.name", "Clair Skill Test", cwd=self.root)
        run("git", "config", "user.email", "skill-test@invalid", cwd=self.root)
        run("git", "add", str(queue.relative_to(self.root)), cwd=self.root)
        run("git", "commit", "-q", "-m", "test: add queue fixture", cwd=self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def helper(
        self,
        root: Path,
        command: str,
        selector: str | None = None,
        *extra: str,
        check: bool = True,
    ):
        arguments = [
            sys.executable,
            str(SCRIPT),
            "--repo",
            str(root),
            command,
        ]
        if selector is not None:
            arguments.append(selector)
        arguments.extend(extra)
        return run(*arguments, check=check)

    def test_validate_ready_and_inspect_blockers(self) -> None:
        validation = json.loads(self.helper(self.root, "validate").stdout)
        self.assertTrue(validation["valid"])
        self.assertEqual(validation["task_count"], 5)

        ready = json.loads(self.helper(self.root, "ready").stdout)
        self.assertEqual(
            [task["task_id"] for task in ready["ready"]], ["B01", "B02"]
        )

        blocked = json.loads(self.helper(self.root, "inspect", "B03").stdout)
        self.assertFalse(blocked["ready"])
        self.assertEqual(
            blocked["readiness_blockers"], ["B01=next", "B02=queued"]
        )

    def test_leases_are_exclusive_and_token_releasable(self) -> None:
        inactive_rejected = self.helper(
            self.root, "acquire", "B01", check=False
        )
        self.assertEqual(inactive_rejected.returncode, 2)
        self.assertIn("status=active", inactive_rejected.stderr)

        queue = self.root / "docs/plans/clair-v2-native-rewrite-queue.md"
        queue.write_text(
            QUEUE_FIXTURE.replace(
                "| `B01` | `next` |",
                "| `B01` | `active` |",
            ),
            encoding="utf-8",
        )
        run("git", "add", str(queue.relative_to(self.root)), cwd=self.root)
        run("git", "commit", "-q", "-m", "test: activate B01", cwd=self.root)

        primary_rejected = self.helper(
            self.root, "acquire", "B01", check=False
        )
        self.assertEqual(primary_rejected.returncode, 2)
        self.assertIn("linked isolated worktree", primary_rejected.stderr)

        worker_one = Path(self.temporary.name) / "worker-one"
        worker_two = Path(self.temporary.name) / "worker-two"
        run(
            "git",
            "worktree",
            "add",
            "-q",
            "-b",
            "worker-one",
            str(worker_one),
            cwd=self.root,
        )
        run(
            "git",
            "worktree",
            "add",
            "-q",
            "-b",
            "worker-two",
            str(worker_two),
            cwd=self.root,
        )

        acquired = json.loads(self.helper(worker_one, "acquire", "B01").stdout)
        lease_id = acquired["owner"]["lease_id"]
        self.assertTrue(acquired["acquired"])
        self.assertTrue(acquired["linked_worktree"])
        self.assertTrue(acquired["ready"])
        self.assertEqual(acquired["lease"]["lease_id"], lease_id)

        collision = self.helper(worker_two, "acquire", "B01", check=False)
        self.assertEqual(collision.returncode, 2)
        self.assertIn("is leased by", collision.stderr)

        wrong_token = self.helper(
            worker_two,
            "release",
            "B01",
            "--lease-id",
            "wrong",
            check=False,
        )
        self.assertEqual(wrong_token.returncode, 2)
        self.assertIn("exact --lease-id required", wrong_token.stderr)

        released = json.loads(
            self.helper(
                worker_two,
                "release",
                "B01",
                "--lease-id",
                lease_id,
            ).stdout
        )
        self.assertTrue(released["released"])

        peer = json.loads(self.helper(worker_two, "acquire", "B01").stdout)
        self.assertNotEqual(peer["owner"]["lease_id"], lease_id)
        self.helper(worker_two, "release", "B01")

    def test_rejects_unknown_dependencies_and_cycles(self) -> None:
        queue = self.root / "docs/plans/clair-v2-native-rewrite-queue.md"
        foundation_row = (
            "| `B00` | `done` | `D2` | — | Frozen baseline. |"
        )
        queue.write_text(
            QUEUE_FIXTURE.replace(
                foundation_row,
                "| `B00` | `queued` | `D2` | `B03` | Frozen baseline. |",
            ),
            encoding="utf-8",
        )
        cycle = self.helper(self.root, "validate", check=False)
        self.assertEqual(cycle.returncode, 2)
        self.assertIn("dependency cycle", cycle.stderr)

        queue.write_text(
            QUEUE_FIXTURE.replace(
                foundation_row,
                "| `B00` | `done` | `D2` | `T99` | Frozen baseline. |",
            ),
            encoding="utf-8",
        )
        unknown = self.helper(self.root, "validate", check=False)
        self.assertEqual(unknown.returncode, 2)
        self.assertIn("unknown dependencies: T99", unknown.stderr)


if __name__ == "__main__":
    unittest.main()
