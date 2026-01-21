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

## Installation

### 1. Install the skill

```bash
claude add-skill https://github.com/cathrynlavery/codex-skill
```

Or manually copy `skills/codex/SKILL.md` to `~/.claude/skills/codex/`

### 2. Set up automatic plan review (recommended)

Copy the hook script:

```bash
cp hooks/plan-review.sh ~/.claude/hooks/
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

Now every time Claude finishes a plan, Codex reviews it before you approve.

## How It Works

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Claude    │────▶│ ExitPlanMode│────▶│   Codex     │
│ creates plan│     │   (hook)    │     │  reviews    │
└─────────────┘     └─────────────┘     └─────────────┘
                                               │
                                               ▼
                                        ┌─────────────┐
                                        │ You approve │
                                        │ with context│
                                        └─────────────┘
```

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

## Example Output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔍 CODEX SECOND OPINION ON PLAN
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ LGTM - Plan covers the main implementation steps.

Minor suggestions:
• Consider adding error handling for the API timeout case
• Step 3 could be split into separate DB migration and code changes
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## License

MIT
