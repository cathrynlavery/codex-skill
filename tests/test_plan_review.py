import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "hooks" / "plan-review.sh"


class PlanReviewTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.project = Path(temp.name)
        self.bin_dir = self.project / "bin"
        self.bin_dir.mkdir()
        # Keep PATH isolated so the tests never invoke a real Codex executable.
        for name in ("cat", "jq", "find", "head"):
            executable = shutil.which(name)
            if executable is None:
                self.skipTest(f"{name} is required")
            (self.bin_dir / name).symlink_to(executable)
        self.env = {**os.environ, "PATH": str(self.bin_dir)}
        self.codex = self.bin_dir / "codex"
        self.codex.write_text(
            '#!/bin/bash\n'
            'printf "%s\\0" "$@" > "$PWD/codex-args"\n'
            'printf "%s\\n" "$STUB_REVIEW"\n'
            'printf "%s" "$STUB_ERROR" >&2\n'
            'exit "$STUB_STATUS"\n'
        )
        self.codex.chmod(0o755)

    def run_hook(self, plan="Inspect the parser and report findings.", **stub):
        return subprocess.run(
            ["/bin/bash", str(HOOK)],
            input=json.dumps({"tool_response": {"plan": plan}, "cwd": str(self.project)}),
            text=True,
            capture_output=True,
            cwd=self.project,
            env={
                **self.env,
                "STUB_REVIEW": "LGTM",
                "STUB_ERROR": "",
                "STUB_STATUS": "0",
                **stub,
            },
            timeout=10,
        )

    def test_reviews_are_read_only_and_preserve_plan_as_one_argument(self):
        plan = "Check quoting: $(touch injected) `touch injected`\nThen review."
        result = self.run_hook(plan)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertIn("CODEX SECOND OPINION ON PLAN", result.stdout)
        self.assertIn("LGTM", result.stdout)
        args = (self.project / "codex-args").read_bytes().split(b"\0")[:-1]
        self.assertEqual(args[:3], [b"exec", b"--sandbox", b"read-only"])
        self.assertEqual(len(args), 4)
        self.assertIn(plan, args[3].decode())
        self.assertFalse((self.project / "injected").exists())

    def test_review_concerns_are_displayed_as_a_successful_review(self):
        result = self.run_hook(STUB_REVIEW="- Missing rollback steps.")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertIn("- Missing rollback steps.", result.stdout)

    def test_codex_failures_are_visible_and_non_blocking(self):
        for status in ("1", "2", "126", "130"):
            with self.subTest(status=status):
                result = self.run_hook(
                    STUB_STATUS=status,
                    STUB_REVIEW="Incomplete review",
                    STUB_ERROR="Internal diagnostic details",
                )
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(
                    result.stderr,
                    "codex-skill: plan review skipped "
                    f"(codex exited {status}; check installation, authentication, "
                    "and configuration).\n",
                )

    def test_missing_codex_is_visible_and_non_blocking(self):
        self.codex.unlink()
        result = self.run_hook()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("plan review skipped (codex exited 127;", result.stderr)

    def test_no_plan_remains_silent_and_does_not_invoke_codex(self):
        result = self.run_hook(plan="")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")
        self.assertFalse((self.project / "codex-args").exists())


if __name__ == "__main__":
    unittest.main()
