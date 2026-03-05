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
| `gpt-5.4` | 272k | Standard | Most capable — deep analysis, architecture, novel problems |
| `gpt-5.3-codex-spark` | 128k | Ultra-fast (1000+ tok/s) | Quick queries, fact checks (default) |
| `gpt-5.3-codex` | 272k | Standard | General-purpose coding tasks |
| `gpt-5.2-codex` | 272k | Standard | Older alternative |
| `gpt-5.1-codex-max` | 272k | Standard | Older alternative |
| `gpt-5.1-codex-mini` | 272k | Fast | Budget option |

## Installation

### 1. Install the skill

Clone and copy the skill to your Claude Code skills directory:

```bash
git clone https://github.com/cathrynlavery/codex-skill.git
mkdir -p ~/.claude/skills/codex
cp codex-skill/skills/codex/SKILL.md ~/.claude/skills/codex/
```

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

The skill uses `gpt-5.3-codex-spark` by default for speed. For complex questions, it switches to `gpt-5.4` with high reasoning effort automatically.

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
