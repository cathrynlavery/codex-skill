#!/bin/bash
# Codex Plan Review Hook
# Triggers when Claude exits plan mode to get a second opinion on the plan

# Read hook input from stdin
INPUT=$(cat)

# Extract the plan file path from the tool input
PLAN_FILE=$(echo "$INPUT" | jq -r '.tool_input.planFile // empty')

# If no plan file in input, try to find it in the project
if [ -z "$PLAN_FILE" ]; then
    PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // "."')
    PLAN_FILE=$(find "$PROJECT_DIR" -name "PLAN.md" -o -name "plan.md" 2>/dev/null | head -1)
fi

# Exit silently if no plan found (non-blocking)
if [ -z "$PLAN_FILE" ] || [ ! -f "$PLAN_FILE" ]; then
    exit 0
fi

# Read the plan content
PLAN_CONTENT=$(cat "$PLAN_FILE")

# Get Codex's review
REVIEW=$(codex exec --dangerously-bypass-approvals-and-sandbox "You are reviewing a plan that Claude Code created. Analyze it for:

1. Potential issues or risks
2. Missing steps or considerations
3. Better alternatives (if any)
4. Edge cases not addressed

Be concise. Only flag significant concerns.

PLAN:
$PLAN_CONTENT

Respond with:
- ✓ LGTM (if plan is solid)
- OR specific concerns (bullet points, max 5)")

# Output the review as context for the user
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 CODEX SECOND OPINION ON PLAN"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$REVIEW"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit 0
