# Codex Skill for Claude Code

Give Claude Code a "second opinion" by letting it consult OpenAI's Codex CLI for independent verification.

## What It Does

When Claude Code creates a plan, Codex automatically reviews it before you approve. Two AIs checking each other's work catches more edge cases.

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
    "PostToolUse": [
      {
        "matcher": "ExitPlanMode",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/plan-review.sh",
            "timeout": 120
          }
        ]
      }
    ]
  }
}
```

## How It Works

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Claude    │────>│ ExitPlanMode│────>│   Codex     │
│ creates plan│     │   (hook)    │     │  reviews    │
└─────────────┘     └─────────────┘     └─────────────┘
                                               │
                                               v
                                        ┌─────────────┐
                                        │ You approve │
                                        │ with context│
                                        └─────────────┘
```

The hook intercepts `ExitPlanMode` and reads the plan from `tool_response.plan` (the field where Claude Code stores the plan content). It passes the plan to Codex for review and displays the result before you approve.

Automatic plan reviews always use `codex exec --sandbox read-only` to restrict model-generated shell commands to read-only access. Manual consultations default to the same mode; explicit requests to implement changes use `--sandbox workspace-write`. If Codex fails, the hook reports that the review was skipped on stderr and exits successfully so your workflow can continue.

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
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CODEX SECOND OPINION ON PLAN
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
LGTM - Plan covers the main implementation steps.

Minor suggestions:
- Consider adding error handling for the API timeout case
- Step 3 could be split into separate DB migration and code changes
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Troubleshooting

**Plan review skipped:** The hook prints `codex-skill: plan review skipped (codex exited <status>; check installation, authentication, and configuration).` on stderr when Codex fails, while remaining non-blocking. Make sure Codex CLI is installed (`codex --version`), on your PATH, authenticated, and configured correctly. Exit status 127 usually means the executable could not be found.

**No plan content found:** The hook reads from `tool_response.plan` (primary) with fallbacks to `tool_response.filePath` and filesystem search. If you're seeing issues, check that you're using a current version of Claude Code.

## Development

Run the hook regression tests (requires Python 3, Bash, and `jq`; uses a stub Codex executable):

```bash
python3 -m unittest discover -s tests -v
```

## License

MIT
