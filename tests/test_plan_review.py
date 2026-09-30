import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "hooks" / "plan-review.sh"
SESSION = "3f2c9a4e-session"
PLAN_NAME = "refactor-parser.md"


class PlanReviewTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.project = Path(temp.name)
        self.bin_dir = self.project / "bin"
        self.bin_dir.mkdir()
        self.data_dir = self.project / "plugin-data"
        self.plan_file = self.project / PLAN_NAME
        # Keep PATH isolated so the tests never invoke a real Codex executable.
        for name in ("cat", "jq", "find", "mkdir", "mktemp", "rm", "touch", "mv", "perl", "sleep"):
            executable = shutil.which(name)
            if executable is None:
                self.skipTest(f"{name} is required")
            (self.bin_dir / name).symlink_to(executable)
        self.env = {
            **os.environ,
            "PATH": str(self.bin_dir),
            "CLAUDE_PLUGIN_DATA": str(self.data_dir),
        }
        self.env.pop("CODEX_SKILL_PLAN_REVIEW", None)
        self.env.pop("CODEX_SKILL_REVIEW_TIMEOUT", None)
        self.env.pop("CODEX_SKILL_MODEL", None)
        self.env.pop("CODEX_SKILL_EFFORT", None)
        self.codex = self.bin_dir / "codex"
        self.codex.write_text(
            '#!/bin/bash\n'
            'printf "%s\\0" "$@" > "$PWD/codex-args"\n'
            'out=""\n'
            'while [ $# -gt 0 ]; do\n'
            '  if [ "$1" = "-o" ]; then out="$2"; shift; fi\n'
            '  shift\n'
            'done\n'
            'echo "$$ $PPID" > "$PWD/codex-pids"\n'
            'if [ -n "$STUB_GRANDCHILD" ]; then sleep 30 & echo $! > "$PWD/grandchild-pid"; fi\n'
            'if [ -n "$STUB_SLEEP" ]; then sleep "$STUB_SLEEP"; fi\n'
            'echo "OpenAI Codex banner noise"\n'
            'if [ -n "$STUB_MODEL" ]; then\n'
            '  printf "model: %s\\nreasoning effort: %s\\n" "$STUB_MODEL" "$STUB_EFFORT"\n'
            'fi\n'
            'printf "user\\nmodel: from-the-prompt\\n"\n'
            'if [ -n "$out" ] && [ -n "$STUB_REVIEW" ]; then printf "%s\\n" "$STUB_REVIEW" > "$out"; fi\n'
            'printf "%s" "$STUB_ERROR" >&2\n'
            'exit "$STUB_STATUS"\n'
        )
        self.codex.chmod(0o755)

    def hook_input(self, plan="Inspect the parser and report findings.", tool_input=None):
        if tool_input is None:
            tool_input = {"plan": plan, "planFilePath": str(self.plan_file)}
        return json.dumps(
            {
                "session_id": SESSION,
                "hook_event_name": "PreToolUse",
                "tool_name": "ExitPlanMode",
                "tool_input": tool_input,
                "cwd": str(self.project),
            }
        )

    def hook_env(self, **env):
        return {
            **self.env,
            "STUB_REVIEW": "VERDICT: LGTM",
            "STUB_ERROR": "",
            "STUB_STATUS": "0",
            "STUB_SLEEP": "",
            "STUB_GRANDCHILD": "",
            "STUB_MODEL": "stub-model",
            "STUB_EFFORT": "stub-effort",
            **env,
        }

    def run_hook(self, plan="Inspect the parser and report findings.", tool_input=None, **env):
        result = subprocess.run(
            ["/bin/bash", str(HOOK)],
            input=self.hook_input(plan, tool_input),
            text=True,
            capture_output=True,
            cwd=self.project,
            env=self.hook_env(**env),
            timeout=20,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        return result

    def output(self, result):
        return json.loads(result.stdout)

    def codex_args(self):
        return (self.project / "codex-args").read_bytes().split(b"\0")[:-1]

    def assert_process_gone(self, pid):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        os.kill(pid, signal.SIGKILL)
        self.fail(f"process {pid} was left running")

    def markers(self):
        if not self.data_dir.exists():
            return []
        return sorted(p.name for p in self.data_dir.glob("bounced-*"))

    def test_reviews_are_read_only_and_preserve_plan_as_one_argument(self):
        plan = "Check quoting: $(touch injected) `touch injected`\nThen review."
        self.run_hook(plan)
        args = self.codex_args()
        self.assertEqual(
            args[:5],
            [b"exec", b"--sandbox", b"read-only", b"--skip-git-repo-check", b"--ephemeral"],
        )
        self.assertIn(b"-o", args)
        self.assertEqual(args[args.index(b"-C") + 1], str(self.project).encode())
        self.assertIn(plan, args[-1].decode())
        self.assertEqual(sum(plan in a.decode() for a in args), 1)
        self.assertFalse((self.project / "injected").exists())

    def test_lgtm_review_is_shown_to_user_and_claude_without_a_decision(self):
        result = self.run_hook(CODEX_SKILL_PLAN_REVIEW="revise")
        out = self.output(result)
        self.assertIn("VERDICT: LGTM", out["systemMessage"])
        self.assertNotIn("banner noise", out["systemMessage"])
        specific = out["hookSpecificOutput"]
        self.assertEqual(specific["hookEventName"], "PreToolUse")
        self.assertIn("VERDICT: LGTM", specific["additionalContext"])
        self.assertNotIn("permissionDecision", specific)
        self.assertEqual(self.markers(), [])

    def test_plan_file_is_read_when_plan_is_not_injected(self):
        self.plan_file.write_text("Plan from disk: migrate the schema.")
        self.run_hook(tool_input={"planFilePath": str(self.plan_file)})
        self.assertIn("Plan from disk: migrate the schema.", self.codex_args()[-1].decode())

    def test_revise_mode_sends_plan_back_once_then_shows_the_review(self):
        concerns = "VERDICT: CONCERNS\n- Missing rollback steps."
        first = self.output(
            self.run_hook(CODEX_SKILL_PLAN_REVIEW="revise", STUB_REVIEW=concerns)
        )
        specific = first["hookSpecificOutput"]
        self.assertEqual(specific["permissionDecision"], "deny")
        self.assertIn("- Missing rollback steps.", specific["permissionDecisionReason"])
        self.assertIn("call ExitPlanMode again", specific["permissionDecisionReason"])
        self.assertIn("- Missing rollback steps.", first["systemMessage"])
        self.assertEqual(len(self.markers()), 1)

        second = self.output(
            self.run_hook(CODEX_SKILL_PLAN_REVIEW="revise", STUB_REVIEW=concerns)
        )
        self.assertIn("Check each concern against the code", specific["permissionDecisionReason"])
        self.assertTrue(first["systemMessage"].startswith("Codex raised concerns about the plan ("))

        self.assertNotIn("permissionDecision", second["hookSpecificOutput"])
        self.assertIn("- Missing rollback steps.", second["hookSpecificOutput"]["additionalContext"])
        self.assertIn("say in one line", second["hookSpecificOutput"]["additionalContext"])
        self.assertIn("- Missing rollback steps.", second["systemMessage"])
        self.assertTrue(
            second["systemMessage"].startswith(
                "Codex still has concerns after Claude revised the plan once ("
            )
        )
        self.assertEqual(self.markers(), [])

        # After the user has seen the plan, a new planning round may be sent back once more.
        third = self.output(
            self.run_hook(CODEX_SKILL_PLAN_REVIEW="revise", STUB_REVIEW=concerns)
        )
        self.assertEqual(third["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_verdict_is_parsed_after_blank_lines_and_markdown(self):
        review = "\n```\n**Verdict:** concerns\n- Race condition in step 2."
        out = self.output(self.run_hook(CODEX_SKILL_PLAN_REVIEW="revise", STUB_REVIEW=review))
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_unrecognised_verdict_is_shown_without_a_decision(self):
        review = "The migration drops the index before copying rows.\n- Reorder steps 2 and 3."
        out = self.output(self.run_hook(CODEX_SKILL_PLAN_REVIEW="revise", STUB_REVIEW=review))
        specific = out["hookSpecificOutput"]
        self.assertNotIn("permissionDecision", specific)
        self.assertIn("no verdict line", out["systemMessage"])
        self.assertIn("Reorder steps 2 and 3.", out["systemMessage"])
        self.assertIn("no verdict line", specific["additionalContext"])
        self.assertNotIn("no significant concerns", specific["additionalContext"])
        self.assertEqual(self.markers(), [])

    def test_model_and_effort_are_passed_only_when_set(self):
        self.run_hook(CODEX_SKILL_MODEL="gpt-6-astra", CODEX_SKILL_EFFORT="medium")
        args = self.codex_args()
        self.assertEqual(args[args.index(b"-m") + 1], b"gpt-6-astra")
        self.assertEqual(args[args.index(b"-c") + 1], b'model_reasoning_effort="medium"')
        self.assertIn(b"Inspect the parser", args[-1])

        self.run_hook(CODEX_SKILL_MODEL="", CODEX_SKILL_EFFORT="")
        args = self.codex_args()
        self.assertNotIn(b"-m", args)
        self.assertNotIn(b"-c", args)

    def test_headline_shows_the_model_codex_reported(self):
        out = self.output(self.run_hook())
        self.assertTrue(
            out["systemMessage"].startswith(
                "Codex second opinion on the plan (stub-model, stub-effort):"
            )
        )
        self.assertNotIn("from-the-prompt", out["systemMessage"])
        self.assertIn("no significant concerns", out["hookSpecificOutput"]["additionalContext"])

        out = self.output(self.run_hook(STUB_MODEL=""))
        self.assertTrue(out["systemMessage"].startswith("Codex second opinion on the plan:"))

    def test_advise_is_the_default_and_never_denies_or_touches_markers(self):
        self.data_dir.mkdir()
        marker = self.data_dir / f"bounced-{SESSION}-{PLAN_NAME}"
        marker.touch()
        out = self.output(self.run_hook(STUB_REVIEW="VERDICT: CONCERNS\n- Missing tests."))
        self.assertNotIn("permissionDecision", out["hookSpecificOutput"])
        self.assertIn("- Missing tests.", out["hookSpecificOutput"]["additionalContext"])
        self.assertTrue(out["systemMessage"].startswith("Codex second opinion on the plan ("))
        self.assertTrue(marker.exists())

    def test_off_mode_does_not_invoke_codex(self):
        result = self.run_hook(CODEX_SKILL_PLAN_REVIEW="off")
        self.assertEqual(result.stdout, "")
        self.assertFalse((self.project / "codex-args").exists())

    def test_stale_markers_are_removed(self):
        self.data_dir.mkdir()
        stale = self.data_dir / "bounced-old-session-plan.md"
        stale.touch()
        old = time.time() - 2 * 24 * 3600
        os.utime(stale, (old, old))
        self.run_hook()
        self.assertFalse(stale.exists())

    def test_long_reviews_are_truncated_below_the_hook_output_cap(self):
        out = self.output(self.run_hook(STUB_REVIEW="VERDICT: LGTM\n" + "x" * 20000))
        self.assertLess(len(out["systemMessage"]), 10000)
        self.assertLess(len(out["hookSpecificOutput"]["additionalContext"]), 10000)
        self.assertIn("[review truncated]", out["systemMessage"])

    def test_codex_failures_are_visible_and_non_blocking(self):
        for status in ("1", "2", "126", "130"):
            with self.subTest(status=status):
                out = self.output(
                    self.run_hook(
                        STUB_STATUS=status,
                        STUB_REVIEW="Incomplete review",
                        STUB_ERROR="Internal diagnostic details",
                    )
                )
                self.assertEqual(sorted(out), ["hookSpecificOutput", "systemMessage"])
                self.assertIn(
                    "did not run (codex exited", out["hookSpecificOutput"]["additionalContext"]
                )
                self.assertNotIn("permissionDecision", out["hookSpecificOutput"])
                self.assertIn(
                    f"Codex plan review skipped (codex exited {status};", out["systemMessage"]
                )
                self.assertNotIn("Internal diagnostic details", out["systemMessage"])
                self.assertIn(
                    "Internal diagnostic details",
                    (self.data_dir / "last-failure.log").read_text(),
                )

    def test_empty_review_is_reported_as_skipped(self):
        out = self.output(self.run_hook(STUB_REVIEW=""))
        self.assertIn("codex returned an empty review", out["systemMessage"])

    def test_missing_codex_is_visible_and_non_blocking(self):
        self.codex.unlink()
        out = self.output(self.run_hook())
        self.assertIn("plan review skipped (codex exited 127;", out["systemMessage"])

    def test_slow_codex_is_stopped_and_reported(self):
        start = time.monotonic()
        out = self.output(self.run_hook(STUB_SLEEP="10", CODEX_SKILL_REVIEW_TIMEOUT="1"))
        self.assertLess(time.monotonic() - start, 8)
        self.assertIn("codex timed out after 1s", out["systemMessage"])

    def test_timeout_stops_commands_codex_started(self):
        out = self.output(
            self.run_hook(STUB_SLEEP="10", STUB_GRANDCHILD="1", CODEX_SKILL_REVIEW_TIMEOUT="1")
        )
        self.assertIn("codex timed out after 1s", out["systemMessage"])
        self.assert_process_gone(int((self.project / "grandchild-pid").read_text()))

    def test_cancelled_hook_stops_codex_and_its_commands(self):
        proc = subprocess.Popen(
            ["/bin/bash", str(HOOK)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=self.project,
            env=self.hook_env(STUB_SLEEP="10", STUB_GRANDCHILD="1"),
        )
        proc.stdin.write(self.hook_input())
        proc.stdin.close()
        pids = self.project / "codex-pids"
        grandchild = self.project / "grandchild-pid"
        deadline = time.monotonic() + 5
        while not (pids.exists() and grandchild.exists()) and time.monotonic() < deadline:
            time.sleep(0.05)
        codex_pid, watchdog_pid = map(int, pids.read_text().split())
        os.kill(watchdog_pid, signal.SIGTERM)
        proc.wait(timeout=10)
        stdout = proc.stdout.read()
        proc.stdout.close()
        proc.stderr.close()
        self.assertEqual(proc.returncode, 0)
        self.assertIn("codex exited 143", json.loads(stdout)["systemMessage"])
        self.assert_process_gone(codex_pid)
        self.assert_process_gone(int(grandchild.read_text()))

    def test_without_perl_timeout_is_used(self):
        (self.bin_dir / "perl").unlink()
        stub = self.bin_dir / "timeout"
        stub.write_text('#!/bin/bash\necho "$1 $2 $3" > "$PWD/timeout-args"\nshift 3\nexec "$@"\n')
        stub.chmod(0o755)
        out = self.output(self.run_hook())
        self.assertIn("VERDICT: LGTM", out["systemMessage"])
        self.assertEqual((self.project / "timeout-args").read_text().split(), ["-k", "5", "240"])

    def test_without_perl_or_timeout_codex_still_runs(self):
        (self.bin_dir / "perl").unlink()
        out = self.output(self.run_hook())
        self.assertIn("VERDICT: LGTM", out["systemMessage"])

    def test_plan_is_not_sent_back_when_the_marker_cannot_be_written(self):
        self.data_dir.mkdir()
        self.data_dir.chmod(0o500)
        self.addCleanup(self.data_dir.chmod, 0o700)
        out = self.output(
            self.run_hook(CODEX_SKILL_PLAN_REVIEW="revise", STUB_REVIEW="VERDICT: CONCERNS\n- x")
        )
        self.assertNotIn("permissionDecision", out["hookSpecificOutput"])
        self.assertIn("- x", out["systemMessage"])

    def test_long_plan_file_names_are_sent_back_only_once(self):
        long_plan = self.project / ("p" * 245 + ".md")
        tool_input = {"plan": "Long name plan.", "planFilePath": str(long_plan)}
        env = {"CODEX_SKILL_PLAN_REVIEW": "revise", "STUB_REVIEW": "VERDICT: CONCERNS\n- x"}
        first = self.output(self.run_hook(tool_input=tool_input, **env))
        self.assertEqual(first["hookSpecificOutput"]["permissionDecision"], "deny")
        second = self.output(self.run_hook(tool_input=tool_input, **env))
        self.assertNotIn("permissionDecision", second["hookSpecificOutput"])

    def test_manual_install_keeps_state_in_the_home_directory(self):
        home = self.project / "home"
        home.mkdir()
        self.env.pop("CLAUDE_PLUGIN_DATA")
        self.env.pop("XDG_STATE_HOME", None)
        self.env["HOME"] = str(home)
        self.run_hook(CODEX_SKILL_PLAN_REVIEW="revise", STUB_REVIEW="VERDICT: CONCERNS\n- x")
        state = home / ".local" / "state" / "codex-skill"
        self.assertEqual(len(list(state.glob("bounced-*"))), 1)

    def test_no_plan_remains_silent_and_does_not_invoke_codex(self):
        result = self.run_hook(plan="")
        self.assertEqual(result.stdout, "")
        self.assertFalse((self.project / "codex-args").exists())


if __name__ == "__main__":
    unittest.main()
