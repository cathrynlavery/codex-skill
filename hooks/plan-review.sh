#!/bin/bash
# Codex Plan Review Hook
# Gets a second opinion from Codex on a plan before the user is asked to approve it.
#
# PreToolUse hook for ExitPlanMode. Receives JSON on stdin with:
#   tool_input.plan          — plan content (injected by Claude Code from the plan file)
#   tool_input.planFilePath  — path to the plan file on disk
#   session_id, cwd, hook_event_name
#
# Output is hook JSON: systemMessage is shown to the user, additionalContext and a
# deny reason reach Claude. Plain stdout from this event would only reach the debug log.
#
# Environment:
#   CODEX_SKILL_PLAN_REVIEW     advise (default) | revise | off
#       advise: show the review to the user and to Claude, then ask for approval as usual.
#       revise: when Codex raises concerns, send the plan back to Claude once to revise
#               before the user sees it. The revised plan is reviewed again and shown.
#   CODEX_SKILL_REVIEW_TIMEOUT  seconds before the Codex run is stopped (default 240)

INPUT=$(cat)

MODE=${CODEX_SKILL_PLAN_REVIEW:-advise}
case "$MODE" in
    off) exit 0 ;;
    advise|revise) ;;
    *) MODE=advise ;;
esac

TIMEOUT=${CODEX_SKILL_REVIEW_TIMEOUT:-240}
MAX_REVIEW_CHARS=9000

EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "PreToolUse"' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# Deny is only a PreToolUse decision; anywhere else, fall back to showing the review.
if [ "$EVENT" != "PreToolUse" ]; then
    MODE=advise
fi

# Plan content: injected into tool_input for PreToolUse, tool_response for PostToolUse.
PLAN_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.plan // empty' 2>/dev/null)
PLAN_FILE=$(echo "$INPUT" | jq -r '.tool_input.planFilePath // .tool_response.filePath // empty' 2>/dev/null)

if [ -z "$PLAN_CONTENT" ] && [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
    PLAN_CONTENT=$(cat "$PLAN_FILE")
fi

if [ -z "$PLAN_CONTENT" ]; then
    PLAN_CONTENT=$(echo "$INPUT" | jq -r '.tool_response.plan // empty' 2>/dev/null)
fi

# Exit silently if no plan found (non-blocking)
if [ -z "$PLAN_CONTENT" ]; then
    exit 0
fi

STATE_DIR=${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/codex-skill}
mkdir -p "$STATE_DIR" 2>/dev/null

# Drop "already revised once" markers left behind by sessions that ended mid-revision
find "$STATE_DIR" -maxdepth 1 -name 'bounced-*' -mmin +1440 -delete 2>/dev/null

PLAN_KEY="${SESSION_ID:-nosession}-${PLAN_FILE##*/}"
MARKER="$STATE_DIR/bounced-${PLAN_KEY//[^A-Za-z0-9._-]/_}"

LAST_MESSAGE="$STATE_DIR/last-message-$$.txt"
CODEX_LOG="$STATE_DIR/codex-$$.log"
trap 'rm -f "$LAST_MESSAGE" "$CODEX_LOG"' EXIT

skip() {
    jq -n --arg msg "Codex plan review skipped ($1; check installation, authentication, and configuration). Codex output: $STATE_DIR/last-failure.log" \
        '{systemMessage: $msg}'
    exit 0
}

PROMPT="You are reviewing an implementation plan that Claude Code wrote, before the user approves it.
You may read files in the working directory to check the plan against the code.

Look for:
1. Potential issues or risks
2. Missing steps or considerations
3. Better alternatives (if any)
4. Edge cases not addressed

Be concise. Only flag significant concerns; ignore style and nitpicks.

The first line of your answer must be exactly one of:
VERDICT: LGTM
VERDICT: CONCERNS
After VERDICT: CONCERNS, list the concerns as bullet points (max 5), each specific and actionable.

PLAN:
$PLAN_CONTENT"

CODEX_ARGS=(exec --sandbox read-only --skip-git-repo-check --ephemeral -o "$LAST_MESSAGE")
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
    CODEX_ARGS+=(-C "$PROJECT_DIR")
fi

if ! command -v codex >/dev/null 2>&1; then
    skip "codex exited 127"
fi

# Stop Codex before the hook timeout so the user gets a clear skip message.
# macOS has no timeout(1), so perl stands in for it (exit 124 on timeout, like timeout(1)).
if command -v perl >/dev/null 2>&1; then
    perl -e '
        my $seconds = shift;
        my $pid = fork() // exit 126;
        if ($pid == 0) { exec @ARGV or exit 127 }
        $SIG{ALRM} = sub { kill "TERM", $pid; sleep 2; kill "KILL", $pid; waitpid($pid, 0); exit 124 };
        alarm $seconds;
        waitpid($pid, 0);
        exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
    ' "$TIMEOUT" codex "${CODEX_ARGS[@]}" "$PROMPT" </dev/null >"$CODEX_LOG" 2>&1
else
    codex "${CODEX_ARGS[@]}" "$PROMPT" </dev/null >"$CODEX_LOG" 2>&1
fi
REVIEW_STATUS=$?

REVIEW=""
if [ -f "$LAST_MESSAGE" ]; then
    REVIEW=$(cat "$LAST_MESSAGE")
fi

# Report failures without blocking the workflow or presenting them as a review
if [ "$REVIEW_STATUS" -ne 0 ] || [ -z "$REVIEW" ]; then
    mv -f "$CODEX_LOG" "$STATE_DIR/last-failure.log" 2>/dev/null
    if [ "$REVIEW_STATUS" -eq 124 ]; then
        skip "codex timed out after ${TIMEOUT}s"
    elif [ "$REVIEW_STATUS" -ne 0 ]; then
        skip "codex exited $REVIEW_STATUS"
    else
        skip "codex returned an empty review"
    fi
fi

if [ "${#REVIEW}" -gt "$MAX_REVIEW_CHARS" ]; then
    REVIEW="${REVIEW:0:$MAX_REVIEW_CHARS}
[review truncated]"
fi

# Verdict: first non-empty line that is not a code fence. Anything unrecognised counts as LGTM.
VERDICT=lgtm
while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [ -z "$trimmed" ] && continue
    case "$trimmed" in '```'*) continue ;; esac
    shopt -s nocasematch
    [[ "$trimmed" =~ ^\**verdict:?\**[[:space:]]*\**concerns ]] && VERDICT=concerns
    shopt -u nocasematch
    break
done <<< "$REVIEW"

if [ "$MODE" = "revise" ] && [ "$VERDICT" = "concerns" ] && [ ! -e "$MARKER" ]; then
    touch "$MARKER"
    jq -n --arg review "$REVIEW" '{
        systemMessage: ("Codex raised concerns about the plan; Claude is revising it.\n\n" + $review),
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: ("Codex reviewed this plan independently and raised concerns. Update the plan file to address them, or state in the plan why a concern does not apply, then call ExitPlanMode again.\n\nCodex review:\n" + $review)
        }
    }'
    exit 0
fi

if [ "$MODE" = "revise" ]; then
    rm -f "$MARKER"
fi

jq -n --arg review "$REVIEW" --arg event "$EVENT" '{
    systemMessage: ("Codex second opinion on the plan:\n\n" + $review),
    hookSpecificOutput: {
        hookEventName: $event,
        additionalContext: ("Codex reviewed this plan independently before the user was asked to approve it. Take its review into account:\n\n" + $review)
    }
}'

exit 0
