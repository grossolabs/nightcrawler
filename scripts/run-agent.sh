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
START_TS=$(date +%s)

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "status=${1:-error}"
      echo "branch=${2:-}"
      echo "pr_url=${3:-}"
    } >> "$GITHUB_OUTPUT"
  fi
}

cleanup() {
  local exit_code=$?
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  if [ "$exit_code" -ne 0 ]; then
    gh issue edit "$ISSUE_NUMBER" --remove-label "$LABEL_PROGRESS" 2>/dev/null || true
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
  echo "::group::Agent run — attempt $attempt of $MAX_RETRIES (model=$AGENT_MODEL, max-turns=$MAX_TURNS)"

  # Reset to checkpoint between retries
  git reset --hard "$CHECKPOINT" >/dev/null 2>&1
  git clean -fd >/dev/null 2>&1

  attempt_log="$OUTPUT_DIR/attempt-${attempt}.log"
  set +e
  claude \
    --print \
    --max-turns "$MAX_TURNS" \
    --model "$AGENT_MODEL" \
    --allowed-tools "$ALLOWED_TOOLS" \
    --dangerously-skip-permissions \
    --output-format text \
    "$(cat "$PROMPT_FILE")" 2>&1 | tee "$attempt_log" &
  CHILD_PID=$!
  wait "$CHILD_PID"
  AGENT_EXIT=${PIPESTATUS[0]}
  CHILD_PID=""
  set -e
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
    gh issue comment "$ISSUE_NUMBER" --body "$(cat <<EOF
ℹ️ **Nightcrawler:** this issue does not appear to need code changes.

> $REASON

\`\`\`
$(tail -30 "$attempt_log")
\`\`\`
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
    gh issue comment "$ISSUE_NUMBER" --body "$(cat <<EOF
⏸️ **Nightcrawler aborted:** agent could not satisfy the issue.

> $REASON

\`\`\`
$(tail -50 "$attempt_log")
\`\`\`
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
  gh issue comment "$ISSUE_NUMBER" --body "$(cat <<EOF
❌ **Nightcrawler failed** after $MAX_RETRIES attempts.

Last attempt log (tail 80):
\`\`\`
$(tail -80 "$last_log")
\`\`\`

$([ -n "$VERIFY_COMMAND" ] && echo "Verification (tail 50):" || echo "")
$([ -n "$VERIFY_COMMAND" ] && [ -f "$VERIFY_LOG" ] && echo "\`\`\`" || echo "")
$([ -n "$VERIFY_COMMAND" ] && [ -f "$VERIFY_LOG" ] && tail -50 "$VERIFY_LOG" || echo "")
$([ -n "$VERIFY_COMMAND" ] && [ -f "$VERIFY_LOG" ] && echo "\`\`\`" || echo "")
EOF
)"
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
gh issue comment "$ISSUE_NUMBER" --body "✅ **Nightcrawler run complete** (attempt ${attempt}/${MAX_RETRIES}). PR: ${PR_URL}"

emit "success" "$BRANCH" "$PR_URL"
