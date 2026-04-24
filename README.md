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

| Model | Context | Speed | Best for |
|-------|---------|-------|----------|
| `gpt-5.5` | 400k | Standard | Most capable frontier model — deepest analysis, architecture, novel problems (use with `high`/`xhigh` reasoning) |
| `gpt-5.4` | 1M (272k standard tier) | Standard, text+image | Default — capable enough for most reviews, faster than 5.5 |
| `gpt-5.3-codex-spark` | 128k | ~1200 tok/s (Cerebras) | Quick fact checks, trivial queries |
| `gpt-5.3-codex` | 272k | ~65 tok/s | General-purpose coding tasks |
| `gpt-5.2-codex` | 272k | Standard | Older alternative |
| `gpt-5.1-codex-max` | 272k | Standard | Older alternative |
| `gpt-5.1-codex-mini` | 272k | Fast | Budget option |

> Note: for `gpt-5.4`, inputs beyond the 272k standard tier trigger a pricing surcharge (input cost doubles).

## Installation

### Option A: Install as Claude Code plugin (recommended)

```bash
claude plugin add cathrynlavery/codex-skill
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

The skill uses `gpt-5.4` by default — capable enough for most reviews and faster than the frontier model. For the hardest questions (novel architecture, deep analysis), it escalates to `gpt-5.5` with high reasoning effort. For trivial fact checks, it can drop to `gpt-5.3-codex-spark`.

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

**Hook doesn't fire:** Make sure Codex CLI is installed (`codex --version`) and on your PATH. The hook exits silently on errors to avoid blocking your workflow.

**No plan content found:** The hook reads from `tool_response.plan` (primary) with fallbacks to `tool_response.filePath` and filesystem search. If you're seeing issues, check that you're using a current version of Claude Code.

## License

MIT
