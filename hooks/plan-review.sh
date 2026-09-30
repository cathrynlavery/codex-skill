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
#   CODEX_SKILL_MODEL           Codex model for the review (default: from the Codex config)
#   CODEX_SKILL_EFFORT          reasoning effort for the review (default: from the Codex config)

INPUT=$(cat)

MODE=${CODEX_SKILL_PLAN_REVIEW:-advise}
case "$MODE" in
    off) exit 0 ;;
    advise|revise) ;;
    *) MODE=advise ;;
esac

TIMEOUT=${CODEX_SKILL_REVIEW_TIMEOUT:-240}
MODEL=${CODEX_SKILL_MODEL:-}
EFFORT=${CODEX_SKILL_EFFORT:-}
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

# Per-user state (never a shared /tmp path): the plugin data dir, or the XDG state dir
# for a manual install.
STATE_DIR=${CLAUDE_PLUGIN_DATA:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-skill}
mkdir -p "$STATE_DIR" 2>/dev/null

# Drop "already revised once" markers left behind by sessions that ended mid-revision
find "$STATE_DIR" -maxdepth 1 -name 'bounced-*' -mmin +1440 -delete 2>/dev/null

PLAN_KEY="${SESSION_ID:-nosession}-${PLAN_FILE##*/}"
PLAN_KEY="${PLAN_KEY//[^A-Za-z0-9._-]/_}"
# Keep the marker name well under the 255-byte filename limit
MARKER="$STATE_DIR/bounced-${PLAN_KEY:0:200}"

# The user sees why the review is missing; Claude is told not to claim it happened
skip() {
    jq -n --arg msg "Codex plan review skipped ($1; check installation, authentication, and configuration). Codex output: $STATE_DIR/last-failure.log" \
        --arg context "The automatic Codex plan review did not run ($1). Do not tell the user that Codex reviewed this plan." \
        --arg event "$EVENT" \
        '{systemMessage: $msg, hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
    exit 0
}

# Per-run files go in a private directory created by mktemp
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-skill.XXXXXX" 2>/dev/null) || skip "could not create a temporary directory"
trap 'rm -rf "$RUN_DIR"' EXIT
LAST_MESSAGE="$RUN_DIR/last-message.txt"
CODEX_LOG="$RUN_DIR/codex.log"

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
# Command-line values override both the user and the project Codex config
if [ -n "$MODEL" ]; then
    CODEX_ARGS+=(-m "$MODEL")
fi
if [ -n "$EFFORT" ]; then
    CODEX_ARGS+=(-c "model_reasoning_effort=\"$EFFORT\"")
fi

if ! command -v codex >/dev/null 2>&1; then
    skip "codex exited 127"
fi

# Stop Codex before the hook timeout so the user gets a clear skip message (exit 124 on
# timeout, like timeout(1)). Codex runs in its own process group so that the commands it
# spawned are stopped with it, on timeout and when this hook is cancelled.
# macOS has no timeout(1), so perl comes first; GNU timeout is the fallback.
if command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e '
        my $seconds = shift;
        my $pid = fork() // exit 126;
        if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
        setpgrp($pid, $pid);
        # TERM the whole group, give it 2 s, then KILL whatever is left
        sub stop_group {
            my $code = shift;
            kill "-TERM", $pid;
            for (1 .. 20) {
                last if waitpid($pid, POSIX::WNOHANG()) == $pid;
                select(undef, undef, undef, 0.1);
            }
            kill "-KILL", $pid;
            waitpid($pid, 0);
            exit $code;
        }
        $SIG{ALRM} = sub { stop_group(124) };
        $SIG{HUP} = sub { stop_group(129) };
        $SIG{INT} = sub { stop_group(130) };
        $SIG{TERM} = sub { stop_group(143) };
        alarm $seconds;
        waitpid($pid, 0);
        my $status = $?;
        kill "-KILL", $pid;    # commands Codex left behind
        exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
    ' "$TIMEOUT" codex "${CODEX_ARGS[@]}" "$PROMPT" </dev/null >"$CODEX_LOG" 2>&1
elif command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$TIMEOUT" codex "${CODEX_ARGS[@]}" "$PROMPT" </dev/null >"$CODEX_LOG" 2>&1
else
    codex "${CODEX_ARGS[@]}" "$PROMPT" </dev/null >"$CODEX_LOG" 2>&1
fi
REVIEW_STATUS=$?

# Model and effort as the Codex log header reports them. The header ends before the
# "user" line that starts the prompt.
RAN_MODEL=""
RAN_EFFORT=""
LINES_READ=0
while [ "$LINES_READ" -lt 40 ] && IFS= read -r line; do
    LINES_READ=$((LINES_READ + 1))
    [ "$line" = "user" ] && break
    case "$line" in
        "model: "*) [ -z "$RAN_MODEL" ] && RAN_MODEL=${line#model: } ;;
        "reasoning effort: "*) [ -z "$RAN_EFFORT" ] && RAN_EFFORT=${line#reasoning effort: } ;;
    esac
done < "$CODEX_LOG"
RAN=""
if [ -n "$RAN_MODEL" ]; then
    RAN=" ($RAN_MODEL${RAN_EFFORT:+, $RAN_EFFORT})"
fi

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

# Verdict: first non-empty line that is not a code fence. Anything else is "unknown",
# which never sends the plan back but is not reported as LGTM either.
VERDICT=unknown
while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [ -z "$trimmed" ] && continue
    case "$trimmed" in '```'*) continue ;; esac
    shopt -s nocasematch
    if [[ "$trimmed" =~ ^\**verdict:?\**[[:space:]]*\**concerns ]]; then
        VERDICT=concerns
    elif [[ "$trimmed" =~ ^\**verdict:?\**[[:space:]]*\**lgtm ]]; then
        VERDICT=lgtm
    fi
    shopt -u nocasematch
    break
done <<< "$REVIEW"

# Send the plan back only if the marker is recorded; otherwise it could be sent back forever
if [ "$MODE" = "revise" ] && [ "$VERDICT" = "concerns" ] && [ ! -e "$MARKER" ] &&
    touch "$MARKER" 2>/dev/null; then
    jq -n --arg review "$REVIEW" --arg ran "$RAN" '{
        systemMessage: ("Codex raised concerns about the plan" + $ran + "; Claude is revising it.\n\n" + $review),
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: ("Codex reviewed this plan independently and raised concerns. Check each concern against the code before acting on it; Codex can be wrong. Update the plan file to address them, or state in the plan why a concern does not apply, then call ExitPlanMode again.\n\nCodex review:\n" + $review)
        }
    }'
    exit 0
fi

# A marker here means this plan was already sent back once in this planning round
REVISED=0
if [ "$MODE" = "revise" ]; then
    [ -e "$MARKER" ] && REVISED=1
    rm -f "$MARKER"
fi

# Claude reads additionalContext together with the user's decision, so it must work
# whether the plan was approved or rejected.
case "$VERDICT" in
    lgtm)
        HEADLINE="Codex second opinion on the plan$RAN:"
        CONTEXT="Codex reviewed the plan before the user decided on it and found no significant concerns."
        ;;
    concerns)
        if [ "$REVISED" -eq 1 ]; then
            HEADLINE="Codex still has concerns after Claude revised the plan once$RAN:"
        else
            HEADLINE="Codex second opinion on the plan$RAN:"
        fi
        CONTEXT="The user saw this Codex review before deciding on the plan. If the plan was approved, it stands: do not change its scope silently. Check each concern against the code; Codex can be wrong. In your first reply, say in one line which concerns you will handle within the approved plan and which do not apply, and ask the user before any deviation."
        ;;
    *)
        HEADLINE="Codex review of the plan$RAN (no verdict line; read it in full):"
        CONTEXT="The user saw this Codex review before deciding on the plan. Codex gave no verdict line, so read the review for concerns. Check each one against the code; Codex can be wrong."
        ;;
esac

jq -n --arg review "$REVIEW" --arg event "$EVENT" --arg headline "$HEADLINE" --arg context "$CONTEXT" '{
    systemMessage: ($headline + "\n\n" + $review),
    hookSpecificOutput: {
        hookEventName: $event,
        additionalContext: ($context + "\n\nCodex review:\n" + $review)
    }
}'

exit 0
