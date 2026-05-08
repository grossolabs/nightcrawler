#!/usr/bin/env bash
# nightcrawler/scripts/run-agent.sh
#
# Orchestrates a single autonomous coding-agent run against a labeled GitHub
# issue in the consumer repo. Invoked by action.yml on a self-hosted runner
# that has Claude Code pre-authed (subscription) OR ANTHROPIC_API_KEY set.
#
# Required env (set by action.yml):
#   ISSUE_NUMBER, AGENT_MODEL, MAX_TURNS, MAX_RETRIES, AGENT_GUIDE_PATH,
#   VERIFY_COMMAND, BRANCH_PREFIX, DRAFT_PR, BASE_BRANCH, ALLOWED_TOOLS,
#   USE_SUBSCRIPTION, AGENT_AUTHOR_NAME, AGENT_AUTHOR_EMAIL,
#   LABEL_PROGRESS, LABEL_SOLVED, LABEL_FAILED, GH_TOKEN.

set -euo pipefail

: "${ISSUE_NUMBER:?ISSUE_NUMBER required}"
: "${GH_TOKEN:?GH_TOKEN required}"
: "${BASE_BRANCH:=main}"
: "${BRANCH_PREFIX:=agent/issue-}"
: "${AGENT_MODEL:=sonnet}"
: "${MAX_TURNS:=30}"
: "${MAX_RETRIES:=3}"
: "${AGENT_GUIDE_PATH:=.github/AGENT_GUIDE.md}"
: "${ALLOWED_TOOLS:=Bash,Read,Write,Edit,Grep,Glob}"
: "${USE_SUBSCRIPTION:=true}"
: "${DRAFT_PR:=true}"
: "${AGENT_AUTHOR_NAME:=nightcrawler[bot]}"
: "${AGENT_AUTHOR_EMAIL:=nightcrawler@users.noreply.github.com}"
: "${VERIFY_COMMAND:=}"
: "${LABEL_PROGRESS:=nightcrawler:in-progress}"
: "${LABEL_SOLVED:=nightcrawler:solved}"
: "${LABEL_FAILED:=nightcrawler:failed}"

OUTPUT_DIR="${RUNNER_TEMP:-/tmp}/nightcrawler-${ISSUE_NUMBER}-$(date +%H%M%S)"
mkdir -p "$OUTPUT_DIR"
PROMPT_FILE="$OUTPUT_DIR/prompt.txt"
VERIFY_LOG="$OUTPUT_DIR/verify.log"

CHILD_PID=""
WATCHDOG_PID=""
START_TS=$(date +%s)
# id of the rolling status comment posted on the issue. Set by status_init,
# patched by status_update + the watchdog, finalized by status_finalize.
ANCHOR_ID=""
# Path to the in-progress attempt's stdout log. Set inside the retry loop
# before each `claude --print` invocation so the watchdog can tail it.
CURRENT_ATTEMPT_LOG=""
# Mirror of the current attempt counter and ceiling for the watchdog format.
CURRENT_ATTEMPT=0

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "status=${1:-error}"
      echo "branch=${2:-}"
      echo "pr_url=${3:-}"
    } >> "$GITHUB_OUTPUT"
  fi
}

# ---------------------------------------------------------------------------
# Status comment (anchor-edit pattern, per issue grossolabs/serafin#148)
#
# Post a single comment on the GitHub issue when nightcrawler claims it,
# edit it in place every ~30s with a status digest from the running agent's
# stdout log + git working-tree diff. Finalize on completion (success,
# blocked, no_code, or failure) and stop editing. Never spawn a second
# comment per run — the rule is "one anchor edited in place, no comment-
# per-update spam."
# ---------------------------------------------------------------------------

# Format the rolling status body. State is one of: STARTED, IN PROGRESS,
# SOLVED, FAILED, BLOCKED, NO_CODE. attempt + max_attempts are integers.
# The body is markdown — GitHub renders it in the issue thread.
status_body() {
  local state="$1"
  local attempt="$2"
  local max_attempts="$3"
  local extra="${4:-}"

  local now elapsed mm ss
  now=$(date +%s)
  elapsed=$((now - START_TS))
  mm=$((elapsed / 60))
  ss=$((elapsed % 60))

  local emoji
  case "$state" in
    STARTED|"IN PROGRESS") emoji="🤖" ;;
    SOLVED) emoji="✅" ;;
    FAILED) emoji="❌" ;;
    BLOCKED) emoji="⏸️" ;;
    NO_CODE) emoji="ℹ️" ;;
    *) emoji="🤖" ;;
  esac

  local recent_output="(no output yet)"
  if [ -n "$CURRENT_ATTEMPT_LOG" ] && [ -f "$CURRENT_ATTEMPT_LOG" ]; then
    # Last 8 non-blank lines of the agent's stdout. Truncate per-line at
    # 200 chars to keep the comment compact — full logs land in the PR
    # body's "tail 30 lines" block on success.
    local tail_lines
    tail_lines=$(tail -n 40 "$CURRENT_ATTEMPT_LOG" 2>/dev/null \
      | grep -v '^$' \
      | tail -n 8 \
      | awk '{ if (length > 200) print substr($0, 1, 200) "…"; else print }')
    if [ -n "$tail_lines" ]; then
      recent_output="$tail_lines"
    fi
  fi

  local files_touched="(none yet)"
  # `git status -s` shows working-tree changes since the agent's checkpoint.
  # Only meaningful inside the consumer-repo checkout (after step 3 in the
  # main flow). Suppress errors silently if not a git repo yet.
  local file_lines
  file_lines=$(git status -s 2>/dev/null | head -n 12 || true)
  if [ -n "$file_lines" ]; then
    files_touched="$file_lines"
  fi

  cat <<EOF
${emoji} **Nightcrawler — ${state}**  ·  ${mm}m ${ss}s elapsed  ·  \`${AGENT_MODEL}\`  ·  attempt ${attempt}/${max_attempts}

### Recent output
\`\`\`
${recent_output}
\`\`\`

### Files touched
\`\`\`
${files_touched}
\`\`\`
${extra}
EOF
}

# Post the initial anchor comment. Stores the comment id in ANCHOR_ID for
# subsequent patches. Failure is non-fatal — if GitHub is having a moment
# we still want the agent to run.
status_init() {
  local body
  body=$(status_body "STARTED" 1 "$MAX_RETRIES")
  ANCHOR_ID=$(printf '%s' "$body" \
    | gh api -X POST "/repos/$GITHUB_REPOSITORY/issues/$ISSUE_NUMBER/comments" \
        -F body=@- --jq '.id' 2>/dev/null || echo "")
  if [ -n "$ANCHOR_ID" ]; then
    echo "Status anchor comment: $ANCHOR_ID"
  else
    echo "::warning::Failed to create status anchor comment; status updates will be skipped."
  fi
}

# PATCH the anchor comment with a fresh body. Silent on failure — never
# crash the agent run because GitHub returned a 5xx on a status update.
status_update() {
  local state="$1"
  local extra="${2:-}"
  if [ -z "$ANCHOR_ID" ]; then return 0; fi
  local body
  body=$(status_body "$state" "$CURRENT_ATTEMPT" "$MAX_RETRIES" "$extra")
  printf '%s' "$body" \
    | gh api -X PATCH "/repos/$GITHUB_REPOSITORY/issues/comments/$ANCHOR_ID" \
        -F body=@- >/dev/null 2>&1 || true
}

# Background watchdog. Polls every 30s and patches the anchor comment with
# the current state. Started before each `claude --print` invocation,
# killed when the agent exits.
status_watchdog() {
  while sleep 30; do
    status_update "IN PROGRESS"
  done
}

cleanup() {
  local exit_code=$?
  # Stop the watchdog FIRST so it doesn't race with the finalize patch.
  if [ -n "$WATCHDOG_PID" ] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=""
  fi
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  if [ "$exit_code" -ne 0 ]; then
    gh issue edit "$ISSUE_NUMBER" --remove-label "$LABEL_PROGRESS" 2>/dev/null || true
    # If we exited unexpectedly (process killed, set -e tripped) AND the
    # anchor exists but no terminal status was posted, mark it FAILED so
    # the issue isn't left showing "IN PROGRESS" forever.
    if [ -n "$ANCHOR_ID" ]; then
      status_update "FAILED" $'\n'"_(run terminated unexpectedly with exit $exit_code — see workflow logs)_"
    fi
  fi
}
handle_interrupt() {
  echo "::warning::Received interrupt; cleaning up child process."
  exit 130
}
trap handle_interrupt INT TERM
trap cleanup EXIT

ensure_labels() {
  gh label create "$LABEL_PROGRESS" --color "fbca04" --description "Nightcrawler agent is working on this" --force >/dev/null 2>&1 || true
  gh label create "$LABEL_SOLVED"   --color "0e8a16" --description "Solved by Nightcrawler agent"          --force >/dev/null 2>&1 || true
  gh label create "$LABEL_FAILED"   --color "d93f0b" --description "Nightcrawler agent could not solve this" --force >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 1. Fetch issue
# ---------------------------------------------------------------------------
echo "::group::Fetch issue #$ISSUE_NUMBER"
ISSUE_JSON=$(gh issue view "$ISSUE_NUMBER" --json title,body,labels,url)
ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // ""')
ISSUE_URL=$(echo "$ISSUE_JSON" | jq -r '.url')
echo "Title: $ISSUE_TITLE"
echo "URL:   $ISSUE_URL"
echo "::endgroup::"

ensure_labels
gh issue edit "$ISSUE_NUMBER" --remove-label "$LABEL_SOLVED" --remove-label "$LABEL_FAILED" 2>/dev/null || true
gh issue edit "$ISSUE_NUMBER" --add-label "$LABEL_PROGRESS" 2>/dev/null || true

# Post the rolling status anchor comment. From here on, status_update
# patches the same comment in place — no new comments per state change.
status_init

# ---------------------------------------------------------------------------
# 2. Branch name
# ---------------------------------------------------------------------------
SLUG=$(echo "$ISSUE_TITLE" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9' '-' \
  | sed -E 's/-+/-/g; s/^-//; s/-$//' \
  | cut -c1-40 \
  | sed -E 's/-+$//')
BRANCH="${BRANCH_PREFIX}${ISSUE_NUMBER}-${SLUG}"
echo "Branch: $BRANCH"

# ---------------------------------------------------------------------------
# 3. Setup git + branch
# ---------------------------------------------------------------------------
echo "::group::Prepare branch"
git config user.name "$AGENT_AUTHOR_NAME"
git config user.email "$AGENT_AUTHOR_EMAIL"
git fetch origin "$BASE_BRANCH" --depth=1
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  echo "::error::Branch $BRANCH already exists on origin. Refusing to overwrite. Delete it or change branch-prefix."
  gh issue edit "$ISSUE_NUMBER" --remove-label "$LABEL_PROGRESS" --add-label "$LABEL_FAILED" 2>/dev/null || true
  emit "error" "" ""
  exit 1
fi
git checkout -B "$BRANCH" "origin/$BASE_BRANCH"
CHECKPOINT=$(git rev-parse HEAD)
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 4. Build prompt
# ---------------------------------------------------------------------------
AGENT_GUIDE_CONTENT=""
if [ -f "$AGENT_GUIDE_PATH" ]; then
  AGENT_GUIDE_CONTENT=$(cat "$AGENT_GUIDE_PATH")
else
  echo "::warning::No agent guide found at $AGENT_GUIDE_PATH. The agent will run without consumer-specific conventions."
fi

cat > "$PROMPT_FILE" <<PROMPT
You are a headless coding agent operating on GitHub issue #${ISSUE_NUMBER} in the current repository checkout. Branch ${BRANCH} is already checked out, based on origin/${BASE_BRANCH}.

# Your job
1. Read the issue (below) and the AGENT_GUIDE.md (below).
2. Implement EXACTLY what the issue describes — no scope creep, no unrelated refactors.
3. Run any verification the AGENT_GUIDE tells you to run, until clean.
4. STOP. Do NOT \`git commit\`, do NOT \`git push\` — the workflow handles that. Just leave the working tree dirty with your final changes.
5. As your LAST line of output, print one of:
   - \`SUMMARY: <2-3 sentence description of what you changed and why>\` on success
   - \`BLOCKED: <one-sentence reason>\` if you cannot satisfy the issue (and revert any partial changes first)
   - \`NO_CODE: <explanation>\` if the issue does not require a code change

# Issue title
${ISSUE_TITLE}

# Issue body
${ISSUE_BODY}

# AGENT_GUIDE (consumer repo conventions — follow to the letter)
${AGENT_GUIDE_CONTENT}
PROMPT

# ---------------------------------------------------------------------------
# 5. Run agent (with retry loop)
# ---------------------------------------------------------------------------
if [ "$USE_SUBSCRIPTION" = "true" ]; then
  unset ANTHROPIC_API_KEY || true
fi

attempt=0
solved=false
final_summary=""
last_log=""

while [ "$attempt" -lt "$MAX_RETRIES" ] && [ "$solved" = false ]; do
  attempt=$((attempt + 1))
  CURRENT_ATTEMPT=$attempt
  echo "::group::Agent run — attempt $attempt of $MAX_RETRIES (model=$AGENT_MODEL, max-turns=$MAX_TURNS)"

  # Reset to checkpoint between retries
  git reset --hard "$CHECKPOINT" >/dev/null 2>&1
  git clean -fd >/dev/null 2>&1

  attempt_log="$OUTPUT_DIR/attempt-${attempt}.log"
  CURRENT_ATTEMPT_LOG="$attempt_log"
  # Make sure the file exists before the watchdog tails it.
  : > "$attempt_log"

  # Refresh the anchor immediately so the issue shows the new attempt
  # number even if the watchdog hasn't ticked yet.
  status_update "IN PROGRESS"

  # Background watchdog patches the anchor every 30s with the latest
  # tail-of-log + git-status digest. Stopped after `wait $CHILD_PID`
  # so the post-attempt logic has a stable file system view.
  status_watchdog &
  WATCHDOG_PID=$!

  # Claude Code refuses --dangerously-skip-permissions as root (security check added
  # in recent versions). When running as root (Docker CI runner), delegate to a
  # throwaway non-root user that has access to the Claude credentials.
  if [ "$(id -u)" = "0" ]; then
    useradd -m -s /bin/bash _nc 2>/dev/null || true
    if [ -d "$HOME/.claude" ]; then
      cp -rp "$HOME/.claude" /home/_nc/ 2>/dev/null || true
      chown -R _nc:_nc /home/_nc/.claude 2>/dev/null || true
    fi
    _NC_HOME=/home/_nc
    _NC_ENVS="HOME=${_NC_HOME}"
    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && _NC_ENVS="$_NC_ENVS CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}"
    [ -n "${ANTHROPIC_API_KEY:-}" ]       && _NC_ENVS="$_NC_ENVS ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
    [ -n "${GH_TOKEN:-}" ]                && _NC_ENVS="$_NC_ENVS GH_TOKEN=${GH_TOKEN}"
  fi

  set +e
  if [ "$(id -u)" = "0" ]; then
    su -s /bin/bash _nc -c "env $_NC_ENVS claude \
      --print \
      --max-turns \"$MAX_TURNS\" \
      --model \"$AGENT_MODEL\" \
      --allowed-tools \"$ALLOWED_TOOLS\" \
      --dangerously-skip-permissions \
      --output-format text \
      \"$(cat "$PROMPT_FILE")\"" 2>&1 | tee "$attempt_log" &
  else
    claude \
      --print \
      --max-turns "$MAX_TURNS" \
      --model "$AGENT_MODEL" \
      --allowed-tools "$ALLOWED_TOOLS" \
      --dangerously-skip-permissions \
      --output-format text \
      "$(cat "$PROMPT_FILE")" 2>&1 | tee "$attempt_log" &
  fi
  CHILD_PID=$!
  wait "$CHILD_PID"
  AGENT_EXIT=${PIPESTATUS[0]}
  CHILD_PID=""
  set -e

  # Stop the watchdog before evaluating attempt outcome so the next
  # status_update we emit (in the success/blocked/no_code finalizers)
  # races against nothing.
  if [ -n "$WATCHDOG_PID" ] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
  fi
  WATCHDOG_PID=""

  last_log="$attempt_log"
  echo "Agent exit code: $AGENT_EXIT"
  echo "::endgroup::"

  if [ "$AGENT_EXIT" -ne 0 ]; then
    echo "::warning::Agent exited with $AGENT_EXIT on attempt $attempt"
    continue
  fi

  # NO_CODE → not a coding issue; close gracefully
  if grep -qE '^NO_CODE:' "$attempt_log"; then
    REASON=$(grep -E '^NO_CODE:' "$attempt_log" | head -1 | sed 's/^NO_CODE:[[:space:]]*//')
    echo "::warning::Agent reported NO_CODE: $REASON"
    gh issue edit "$ISSUE_NUMBER" --remove-label "$LABEL_PROGRESS" 2>/dev/null || true
    status_update "NO_CODE" "$(cat <<EOF


### Reason
> ${REASON}

This issue does not appear to need code changes.
EOF
)"
    emit "no-changes" "$BRANCH" ""
    exit 0
  fi

  # BLOCKED → agent self-aborted; do not retry
  if grep -qE '^BLOCKED:' "$attempt_log"; then
    REASON=$(grep -E '^BLOCKED:' "$attempt_log" | head -1 | sed 's/^BLOCKED:[[:space:]]*//')
    echo "::warning::Agent reported BLOCKED: $REASON"
    gh issue edit "$ISSUE_NUMBER" --remove-label "$LABEL_PROGRESS" --add-label "$LABEL_FAILED" 2>/dev/null || true
    status_update "BLOCKED" "$(cat <<EOF


### Reason
> ${REASON}

Agent reported it could not satisfy the issue. Re-label or rewrite the spec to retry.
EOF
)"
    emit "no-changes" "$BRANCH" ""
    exit 0
  fi

  # Did the agent change anything?
  if git diff --quiet HEAD -- && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    echo "::warning::No file changes on attempt $attempt"
    continue
  fi

  # Optional consumer-side verification
  if [ -n "$VERIFY_COMMAND" ]; then
    echo "::group::Verification (attempt $attempt)"
    set +e
    bash -lc "$VERIFY_COMMAND" 2>&1 | tee "$VERIFY_LOG"
    VERIFY_EXIT=${PIPESTATUS[0]}
    set -e
    echo "Verification exit: $VERIFY_EXIT"
    echo "::endgroup::"
    if [ "$VERIFY_EXIT" -ne 0 ]; then
      echo "::warning::Verification failed on attempt $attempt; will retry if budget remains"
      continue
    fi
  fi

  # All good
  solved=true
  if grep -qE '^SUMMARY:' "$attempt_log"; then
    final_summary=$(grep -E '^SUMMARY:' "$attempt_log" | head -1 | sed 's/^SUMMARY:[[:space:]]*//')
  fi
done

if [ "$solved" = false ]; then
  echo "::error::Failed after $MAX_RETRIES attempts."
  gh issue edit "$ISSUE_NUMBER" --remove-label "$LABEL_PROGRESS" --add-label "$LABEL_FAILED" 2>/dev/null || true

  # Build the FAILED finalization block. Verification log is included
  # only when a verify-command was configured AND its log exists.
  FAIL_EXTRA=$'\n\n### Last attempt log (tail 80)\n```\n'
  FAIL_EXTRA+="$(tail -n 80 "$last_log" 2>/dev/null || echo '(log unavailable)')"
  FAIL_EXTRA+=$'\n```'
  if [ -n "$VERIFY_COMMAND" ] && [ -f "$VERIFY_LOG" ]; then
    FAIL_EXTRA+=$'\n\n### Verification log (tail 50)\n```\n'
    FAIL_EXTRA+="$(tail -n 50 "$VERIFY_LOG" 2>/dev/null || echo '(verify log unavailable)')"
    FAIL_EXTRA+=$'\n```'
  fi
  status_update "FAILED" "$FAIL_EXTRA"

  emit "verify-failed" "$BRANCH" ""
  exit 1
fi

# ---------------------------------------------------------------------------
# 6. Commit + push
# ---------------------------------------------------------------------------
echo "::group::Commit + push"
git add -A
COMMIT_MSG=$(cat <<EOF
agent: ${ISSUE_TITLE}

Implements #${ISSUE_NUMBER} via the nightcrawler coding agent.

${final_summary:-See PR description for details.}

Closes #${ISSUE_NUMBER}
EOF
)
git commit -m "$COMMIT_MSG"
git push -u origin "$BRANCH"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# 7. Open PR
# ---------------------------------------------------------------------------
echo "::group::Open PR"
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

PR_BODY=$(cat <<EOF
Implements #${ISSUE_NUMBER} via [nightcrawler](https://github.com/grossolabs/nightcrawler).

## Run summary

- Model: \`${AGENT_MODEL}\`
- Branch: \`${BRANCH}\`
- Duration: ${ELAPSED_MIN}m ${ELAPSED_SEC}s
- Attempts: ${attempt} / ${MAX_RETRIES}
- Verification: $([ -n "$VERIFY_COMMAND" ] && echo "✅ \`$VERIFY_COMMAND\`" || echo "(none configured)")
- Issue: ${ISSUE_URL}

## Agent summary

${final_summary:-_(agent did not emit a SUMMARY: line — see logs)_}

## Last 30 lines of agent output

\`\`\`
$(tail -30 "$last_log")
\`\`\`

Closes #${ISSUE_NUMBER}
EOF
)

DRAFT_FLAG=""
if [ "$DRAFT_PR" = "true" ]; then
  DRAFT_FLAG="--draft"
fi

PR_URL=$(gh pr create $DRAFT_FLAG \
  --base "$BASE_BRANCH" \
  --head "$BRANCH" \
  --title "agent: ${ISSUE_TITLE}" \
  --body "$PR_BODY")
echo "PR: $PR_URL"
echo "::endgroup::"

gh issue edit "$ISSUE_NUMBER" --remove-label "$LABEL_PROGRESS" --add-label "$LABEL_SOLVED" 2>/dev/null || true

# Finalize the anchor with PR + run stats. Replaces the previous
# `gh issue comment "✅ Nightcrawler run complete..."` post — same info,
# delivered by editing the rolling anchor instead of posting a new
# comment.
SUCCESS_EXTRA=$'\n\n### PR\n'"${PR_URL}"
SUCCESS_EXTRA+=$'\n\n### Agent summary\n'"${final_summary:-_(agent did not emit a SUMMARY: line — see logs)_}"
SUCCESS_EXTRA+=$'\n\n### Run stats\n'
SUCCESS_EXTRA+="- Duration: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"$'\n'
SUCCESS_EXTRA+="- Attempts: ${attempt}/${MAX_RETRIES}"$'\n'
if [ -n "$VERIFY_COMMAND" ]; then
  SUCCESS_EXTRA+="- Verification: ✅ \`${VERIFY_COMMAND}\`"$'\n'
else
  SUCCESS_EXTRA+="- Verification: (none configured)"$'\n'
fi
status_update "SOLVED" "$SUCCESS_EXTRA"

emit "success" "$BRANCH" "$PR_URL"

