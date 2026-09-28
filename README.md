# Codex Skill for Claude Code

Give Claude Code a "second opinion" by letting it consult OpenAI's Codex CLI for independent verification.

## What It Does

When Claude Code finishes a plan, Codex reviews it before you are asked to approve it. You see the review before the approval prompt, and Claude gets it too. Two AIs checking each other's work catches more edge cases.

**Automatic review on:**
- Every plan Claude creates (via hook)
- Architecture decisions
- Implementation approaches

**Manual use for:**
- Researching unfamiliar APIs or libraries
- Verifying complex code patterns
- Getting alternative perspectives

## Prerequisites

Install [Codex CLI](https://github.com/openai/codex):

```bash
npm install -g @openai/codex
```

Configure your OpenAI API key.

## Supported Models

The skill supports the current visible Codex lineup. Automatic plan reviews do not pin a model; they inherit your configured Codex default.

| Model | Default effort | Supported efforts | Best for |
|-------|----------------|-------------------|----------|
| `gpt-6-astra` | `low` | `low`–`ultra` | Most capable option for difficult architecture, debugging, security, and long-horizon work |
| `gpt-5.6-sol` | `medium` | `low`–`ultra` | Reliable everyday agentic workhorse |
| `gpt-5.6-terra` | `medium` | `low`–`ultra` | Balanced everyday coding and review |
| `gpt-5.6-luna` | `medium` | `low`–`max` | Fast and affordable checks |
| `gpt-5.5` | `xhigh` | `low`–`xhigh` | Previous-generation coding and general work |

## Installation

### Option A: Install as Claude Code plugin (recommended)

```bash
claude plugin marketplace add cathrynlavery/codex-skill
claude plugin install codex-skill@codex-skill
```

This auto-registers both the `/codex` skill and the automatic plan review hook. No manual configuration needed.

### Option B: Manual installation

#### 1. Install the skill

```bash
git clone https://github.com/cathrynlavery/codex-skill.git
mkdir -p ~/.claude/skills/codex
cp codex-skill/skills/codex/SKILL.md ~/.claude/skills/codex/
```

#### 2. Set up automatic plan review

Copy the hook script:

```bash
mkdir -p ~/.claude/hooks
cp codex-skill/hooks/plan-review.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/plan-review.sh
```

Add to your `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "ExitPlanMode",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/plan-review.sh",
            "timeout": 300
          }
        ]
      }
    ]
  }
}
```

## How It Works

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐     ┌─────────────┐
│   Claude    │────>│ ExitPlanMode │────>│   Codex     │────>│ You approve │
│ writes plan │     │ (PreToolUse) │     │  reviews    │     │ with review │
└─────────────┘     └──────────────┘     └─────────────┘     └─────────────┘
```

The hook runs on `PreToolUse` for `ExitPlanMode`, so it runs before the approval prompt. Claude Code injects the plan into `tool_input.plan` (and its path into `tool_input.planFilePath`). The hook passes the plan to `codex exec` and returns hook JSON:

- `systemMessage`: the review, shown to you before the approval prompt.
- `hookSpecificOutput.additionalContext`: the same review, so Claude can take it into account when it implements the plan.

A `PostToolUse` hook cannot do this: it runs only after you have approved the plan, and its plain stdout goes to the debug log, where neither you nor Claude sees it.

### Review modes

Set `CODEX_SKILL_PLAN_REVIEW` in the hook command or in your environment:

| Mode | Behavior |
|------|----------|
| `advise` (default) | Show the review to you and to Claude, then ask for approval as usual. |
| `revise` | If Codex's verdict is `CONCERNS`, send the plan back to Claude with the review (a `deny` decision). Claude revises the plan and calls `ExitPlanMode` again. That second review is shown to you, and the approval prompt follows. The plan goes back at most once before each approval prompt. |
| `off` | Skip the review. |

For example, in `hooks.json` or `settings.json`: `"command": "CODEX_SKILL_PLAN_REVIEW=revise bash ${CLAUDE_PLUGIN_ROOT}/hooks/plan-review.sh"`.

`CODEX_SKILL_REVIEW_TIMEOUT` (default 240 seconds) stops a Codex run that takes too long. It stays below the 300-second hook timeout, so you get a clear message and not a hook error.

Automatic plan reviews always use `codex exec --sandbox read-only --skip-git-repo-check --ephemeral` to restrict model-generated shell commands to read-only access. The read-only sandbox is what makes it safe to also review plans outside git repositories. Only Codex's final answer (`--output-last-message`) is shown. Manual consultations default to read-only mode too; explicit requests to implement changes use `--sandbox workspace-write`. If Codex fails, the hook shows a `Codex plan review skipped (...)` message and lets the plan through.

Codex reviews for:
- Potential issues or risks
- Missing steps
- Better alternatives
- Edge cases not addressed

## Manual Usage

Invoke directly:

```
/codex
```

Or ask Claude:

> "Can you verify this approach with Codex?"
> "Get a second opinion on this architecture"

These consultation requests use read-only mode. To have Codex make changes, explicitly request implementation, for example:

> "Have Codex review and fix the parser bug, then run the relevant tests."

An explicit implementation request uses `--sandbox workspace-write` for edits and checks within the requested scope. No additional confirmation is needed for that same scope. Reviews do not automatically switch modes when a check needs to write files; they report the limitation. The automatic plan-review hook stays read-only even when the plan describes future edits.

The skill uses your configured Codex default. For the hardest questions (novel architecture, deep analysis, or security review), explicitly select `gpt-6-astra` with high or greater reasoning effort. For trivial fact checks, select `gpt-5.6-luna`.

## Example Output

```
Codex second opinion on the plan:

VERDICT: CONCERNS
- Deploying directly to production without tests risks shipping regressions. Add a test
  verifying `GET /health` returns 200 and define a post-deployment smoke check and rollback.
```

## Troubleshooting

**Plan review skipped:** The hook shows `Codex plan review skipped (codex exited <status>; ...)` when Codex fails, and lets the plan through. Codex's output from the failed run is kept in `last-failure.log` in the plugin data directory (the message gives the path). Make sure Codex CLI is installed (`codex --version`), on your PATH, authenticated, and configured correctly. Exit status 127 usually means the executable could not be found. `timed out` means the review took longer than `CODEX_SKILL_REVIEW_TIMEOUT`.

**No review appears:** Run `/hooks` and check for a `PreToolUse` entry with matcher `ExitPlanMode`. A manual install from an older version may still register the hook under `PostToolUse`; move it to `PreToolUse`. Plugin hooks load when a session starts, so restart Claude Code after installing or updating.

## Development

Run the hook regression tests (requires Python 3, Bash, and `jq`; uses a stub Codex executable):

```bash
python3 -m unittest discover -s tests -v
```

## License

MIT
