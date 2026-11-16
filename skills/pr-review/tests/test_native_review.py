"""Exercise review routing, preserved failures, timeouts, and checkout drift without API calls."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[1] / "scripts" / "run-pr-review.sh"
FAKE_CODEX = r"""#!/usr/bin/env python3
import json, os, pathlib, sys, time
args = sys.argv[1:]
pathlib.Path(os.environ["TEST_ARG_LOG"]).write_text(json.dumps(args))
assert args[:3] == ["exec", "--sandbox", "read-only"], args
assert args[args.index("--disable") + 1] == "memories", args
assert "review" in args
out = pathlib.Path(args[args.index("-o") + 1])
repo = pathlib.Path(args[args.index("-C") + 1])
print('{"type":"thread.started"}', flush=True)
print("diagnostic from fake Codex", file=sys.stderr, flush=True)
mode = os.environ.get("TEST_REVIEW_MODE", "ok")
if mode == "timeout": time.sleep(60)
if mode == "fail":
    out.write_text("Partial finding")
    sys.exit(7)
if mode == "empty": sys.exit(0)
if mode == "drift": (repo / "new.py").write_text("changed during review")
out.write_text("Native review findings without custom wrapper headings.\n")
print('{"type":"turn.completed"}')
"""


class NativeReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="native-review-test.")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo with spaces"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Review Test")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", "/dev/null")
        (self.repo / "app.py").write_text("VALUE = 1\n")
        self.git("add", "app.py")
        self.git("commit", "-qm", "initial")
        (self.repo / "app.py").write_text("VALUE = 2\n")
        (self.repo / "new.py").write_text("new untracked content\n")
        self.fakebin = self.root / "fakebin"
        self.fakebin.mkdir()
        fake = self.fakebin / "codex"
        fake.write_text(FAKE_CODEX)
        fake.chmod(0o755)
        self.arg_log = self.root / "args.json"
        self.report = self.root / "report.md"

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.repo), *args], stderr=subprocess.PIPE
        )

    def run_review(self, *args, mode="ok", report=None):
        self.report = report or self.report
        env = dict(
            os.environ,
            PATH=f"{self.fakebin}:{os.environ['PATH']}",
            TEST_ARG_LOG=str(self.arg_log),
            TEST_REVIEW_MODE=mode,
        )
        return subprocess.run(
            [
                "bash",
                str(RUNNER),
                str(self.repo),
                "--output-file",
                str(self.report),
                *args,
            ],
            env=env,
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )

    def artifacts(self):
        return next(self.report.parent.glob(f"{self.report.name}.artifacts.*"))

    def test_default_is_one_native_uncommitted_review(self):
        result = self.run_review()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.report))
        self.assertEqual(
            json.loads(self.arg_log.read_text())[-2:], ["review", "--uncommitted"]
        )
        self.assertIn("without custom wrapper headings", self.report.read_text())
        self.assertEqual((self.repo / "new.py").read_text(), "new untracked content\n")
        self.assertEqual(
            json.loads((self.artifacts() / "run.json").read_text())["status"],
            "complete",
        )
        self.assertIn("diagnostic", (self.artifacts() / "stderr.log").read_text())

    def test_explicit_base_and_commit(self):
        for target in (["--base", "main"], ["--commit", "HEAD"]):
            with self.subTest(target=target):
                result = self.run_review(*target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    json.loads(self.arg_log.read_text())[-3:], ["review", *target]
                )

    def test_conflicting_scopes_fail_before_launch(self):
        result = self.run_review("--uncommitted", "--base", "main")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.arg_log.exists())

    def test_unknown_legacy_option_requires_explicit_deep_mode(self):
        result = self.run_review("--range", "main...HEAD")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.arg_log.exists())

    def test_invalid_revision_fails_before_launch(self):
        result = self.run_review("--commit", "missing-revision")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.arg_log.exists())

    def test_failure_preserves_partial_response_and_diagnostics(self):
        result = self.run_review(mode="fail")
        self.assertEqual(result.returncode, 3)
        self.assertIn("FAILED REVIEW", self.report.read_text())
        self.assertEqual(
            (self.artifacts() / "review.md").read_text(), "Partial finding"
        )
        self.assertIn("thread.started", (self.artifacts() / "events.jsonl").read_text())
        self.assertEqual(
            json.loads((self.artifacts() / "run.json").read_text())["exit_code"], 7
        )

    def test_empty_response_is_not_success(self):
        result = self.run_review(mode="empty")
        self.assertEqual(result.returncode, 3)
        self.assertIn("no final review", self.report.read_text())

    def test_timeout_is_enforced(self):
        result = self.run_review("--timeout", "1", mode="timeout")
        self.assertEqual(result.returncode, 3)
        self.assertIn("timed out", self.report.read_text())

    def test_untracked_content_drift_invalidates_report(self):
        result = self.run_review(mode="drift")
        self.assertEqual(result.returncode, 3)
        self.assertIn("checkout changed", self.report.read_text())

    def test_artifacts_inside_checkout_do_not_cause_false_drift(self):
        result = self.run_review(report=self.repo / "review.md")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
