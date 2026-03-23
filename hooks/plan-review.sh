#!/bin/bash
# Codex Plan Review Hook
# Triggers when Claude exits plan mode to get a second opinion on the plan
#
# PostToolUse hook for ExitPlanMode. Receives JSON on stdin with:
#   tool_input.plan          — plan content (direct)
#   tool_input.planFilePath  — path to plan file on disk
#   tool_response            — may contain plan content or file path
#   cwd                      — working directory

# Read hook input from stdin
INPUT=$(cat)

PLAN_CONTENT=""

# Strategy 1: Get plan content directly from tool_input.plan (fastest — no file I/O)
PLAN_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.plan // empty' 2>/dev/null)

# Strategy 2: Read plan file from tool_input.planFilePath
if [ -z "$PLAN_CONTENT" ]; then
    PLAN_FILE=$(echo "$INPUT" | jq -r '.tool_input.planFilePath // empty' 2>/dev/null)
    if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
        PLAN_CONTENT=$(cat "$PLAN_FILE")
    fi
fi

# Strategy 3: Try tool_response (may contain plan content or file path)
if [ -z "$PLAN_CONTENT" ]; then
    # tool_response might be a string with plan content
    PLAN_CONTENT=$(echo "$INPUT" | jq -r 'if .tool_response | type == "string" then .tool_response else empty end' 2>/dev/null)
fi

if [ -z "$PLAN_CONTENT" ]; then
    # tool_response might be an object with .plan or .filePath
    PLAN_CONTENT=$(echo "$INPUT" | jq -r '.tool_response.plan // empty' 2>/dev/null)
fi

if [ -z "$PLAN_CONTENT" ]; then
    PLAN_FILE=$(echo "$INPUT" | jq -r '.tool_response.filePath // empty' 2>/dev/null)
    if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
        PLAN_CONTENT=$(cat "$PLAN_FILE")
    fi
fi

# Strategy 4: Search for PLAN.md in the project directory
if [ -z "$PLAN_CONTENT" ]; then
    PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // "."')
    PLAN_FILE=$(find "$PROJECT_DIR" -maxdepth 2 -name "PLAN.md" -o -name "plan.md" 2>/dev/null | head -1)
    if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
        PLAN_CONTENT=$(cat "$PLAN_FILE")
    fi
fi

# Exit silently if no plan found (non-blocking)
if [ -z "$PLAN_CONTENT" ]; then
    exit 0
fi

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
- LGTM (if plan is solid)
- OR specific concerns (bullet points, max 5)" 2>&1)

# Exit silently if Codex fails (non-blocking)
if [ $? -ne 0 ]; then
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
