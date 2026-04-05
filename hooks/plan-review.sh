#!/bin/bash
# Codex Plan Review Hook
# Triggers when Claude exits plan mode to get a second opinion on the plan
#
# PostToolUse hook for ExitPlanMode. Receives JSON on stdin with:
#   tool_response.plan       — plan content (direct string)
#   tool_response.filePath   — path to plan file on disk
#   tool_response.isAgent    — whether this is an agent plan
#   tool_input               — typically empty object {}
#   cwd                      — working directory

# Read hook input from stdin
INPUT=$(cat)

PLAN_CONTENT=""

# Strategy 1: Get plan content directly from tool_response.plan (primary — this is
# where ExitPlanMode always puts the plan content)
PLAN_CONTENT=$(echo "$INPUT" | jq -r '.tool_response.plan // empty' 2>/dev/null)

# Strategy 2: Read plan file from tool_response.filePath
if [ -z "$PLAN_CONTENT" ]; then
    PLAN_FILE=$(echo "$INPUT" | jq -r '.tool_response.filePath // empty' 2>/dev/null)
    if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
        PLAN_CONTENT=$(cat "$PLAN_FILE")
    fi
fi

# Strategy 3: tool_response might be a plain string in some versions
if [ -z "$PLAN_CONTENT" ]; then
    PLAN_CONTENT=$(echo "$INPUT" | jq -r 'if .tool_response | type == "string" then .tool_response else empty end' 2>/dev/null)
fi

# Strategy 4: Try tool_input fields (fallback for future schema changes)
if [ -z "$PLAN_CONTENT" ]; then
    PLAN_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.plan // empty' 2>/dev/null)
fi

if [ -z "$PLAN_CONTENT" ]; then
    PLAN_FILE=$(echo "$INPUT" | jq -r '.tool_input.planFilePath // .tool_input.planFile // empty' 2>/dev/null)
    if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
        PLAN_CONTENT=$(cat "$PLAN_FILE")
    fi
fi

# Strategy 5: Search for PLAN.md in the project directory
if [ -z "$PLAN_CONTENT" ]; then
    PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // "."')
    PLAN_FILE=$(find "$PROJECT_DIR" -maxdepth 2 \( -name "PLAN.md" -o -name "plan.md" \) 2>/dev/null | head -1)
    if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
        PLAN_CONTENT=$(cat "$PLAN_FILE")
    fi
fi

# Exit silently if no plan found (non-blocking)
if [ -z "$PLAN_CONTENT" ]; then
    exit 0
fi

# Get Codex's review — exit silently if Codex fails (non-blocking)
if ! REVIEW=$(codex exec --dangerously-bypass-approvals-and-sandbox "You are reviewing a plan that Claude Code created. Analyze it for:

1. Potential issues or risks
2. Missing steps or considerations
3. Better alternatives (if any)
4. Edge cases not addressed

Be concise. Only flag significant concerns.

PLAN:
$PLAN_CONTENT

Respond with:
- LGTM (if plan is solid)
- OR specific concerns (bullet points, max 5)" 2>&1); then
    exit 0
fi

# Output the review as context for the user
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CODEX SECOND OPINION ON PLAN"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$REVIEW"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit 0
