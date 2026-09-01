#!/usr/bin/env python3
"""Functional tests for item_lease.py using disposable repositories and worktrees."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("item_lease.py")
QUEUE_FIXTURE = """# Queue fixture

### P00 Foundation

- Status: `done`

### P01 Serial next

- Status: `next`
- Depends on: P00。

### P02 Parallel sibling

- Status: `queued`
- Depends on: P00。

### L01 Final load

- Status: `final-only`
- Depends on: P02。
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


class ItemLeaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "repo"
        self.root.mkdir()
        queue = self.root / "docs/plans/clair-poc-queue.md"
        queue.parent.mkdir(parents=True)
        queue.write_text(QUEUE_FIXTURE, encoding="utf-8")
        run("git", "init", "-q", str(self.root))
        run("git", "config", "user.name", "Clair Skill Test", cwd=self.root)
        run("git", "config", "user.email", "skill-test@invalid", cwd=self.root)
        run("git", "add", "docs/plans/clair-poc-queue.md", cwd=self.root)
        run("git", "commit", "-q", "-m", "test: add queue fixture", cwd=self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def helper(self, root: Path, command: str, selector: str, check: bool = True):
        return run(
            sys.executable,
            str(SCRIPT),
            "--repo",
            str(root),
            command,
            selector,
            check=check,
        )

    def test_resolves_next_and_rejects_incomplete_dependency(self) -> None:
        payload = json.loads(self.helper(self.root, "inspect", "next").stdout)
        self.assertEqual(payload["item_id"], "P01")
        blocked = self.helper(self.root, "inspect", "L01", check=False)
        self.assertEqual(blocked.returncode, 2)
        self.assertIn("P02=queued", blocked.stderr)

    def test_one_worktree_and_one_item_are_exclusive(self) -> None:
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

        primary = json.loads(self.helper(self.root, "acquire", "P01").stdout)
        self.assertTrue(primary["acquired"])
        self.assertFalse(primary["linked_worktree"])

        first = json.loads(self.helper(worker_one, "acquire", "P02").stdout)
        self.assertTrue(first["acquired"])
        self.assertTrue(first["linked_worktree"])

        repeated = self.helper(worker_one, "acquire", "P02", check=False)
        self.assertEqual(repeated.returncode, 2)
        self.assertIn("worktree already owns P02", repeated.stderr)
        second_item = self.helper(worker_one, "acquire", "P01", check=False)
        self.assertEqual(second_item.returncode, 2)
        self.assertIn("worktree already owns P02", second_item.stderr)

        collision = self.helper(worker_two, "acquire", "P02", check=False)
        self.assertEqual(collision.returncode, 2)
        self.assertIn("is leased by", collision.stderr)

        released = json.loads(self.helper(worker_one, "release", "P02").stdout)
        self.assertTrue(released["released"])
        peer_acquired = json.loads(self.helper(worker_two, "acquire", "P02").stdout)
        self.assertTrue(peer_acquired["acquired"])
        peer_released = json.loads(self.helper(worker_two, "release", "P02").stdout)
        self.assertTrue(peer_released["released"])
        primary_released = json.loads(self.helper(self.root, "release", "P01").stdout)
        self.assertTrue(primary_released["released"])

    def test_independent_items_can_be_leased_in_parallel(self) -> None:
        worker_one = Path(self.temporary.name) / "parallel-one"
        worker_two = Path(self.temporary.name) / "parallel-two"
        run(
            "git",
            "worktree",
            "add",
            "-q",
            "-b",
            "parallel-one",
            str(worker_one),
            cwd=self.root,
        )
        run(
            "git",
            "worktree",
            "add",
            "-q",
            "-b",
            "parallel-two",
            str(worker_two),
            cwd=self.root,
        )
        first = json.loads(self.helper(worker_one, "acquire", "P01").stdout)
        second = json.loads(self.helper(worker_two, "acquire", "P02").stdout)
        self.assertEqual(first["item_id"], "P01")
        self.assertEqual(second["item_id"], "P02")
        self.assertEqual(second["other_leases"][0]["item_id"], "P01")
        self.helper(worker_one, "release", "P01")
        self.helper(worker_two, "release", "P02")


if __name__ == "__main__":
    unittest.main()
