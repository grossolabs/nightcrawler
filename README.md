# Nightcrawler

> Headless coding-agent GitHub Action. Label a GitHub issue, wake up to a draft PR.

A composite GitHub Action that runs Claude Code in headless mode (`claude -p`) on a self-hosted runner whenever you label an issue with `agent-ready`. It checks out a new branch, lets the agent implement the issue per your repo's `AGENT_GUIDE.md`, optionally verifies with your lint/build/test command, retries with `git reset --hard` if a run fails, then commits, pushes, and opens a draft PR.

Built for `grossolabs/*` repos. Uses your **Claude Pro/Max subscription** by default (no API key required) when the runner has a cached `claude /login` session.

---

## Architecture

```
                            ┌─ on: issues.labeled ──────────────────┐
                            │   if: label == 'agent-ready'           │
   GitHub issue ──label──▶  │   runs-on: [self-hosted, linux, gcp]   │
                            │                                        │
                            │   uses: grossolabs/nightcrawler@v1     │
                            │     ├─ ensures status labels exist     │
                            │     ├─ creates branch off main         │
                            │     ├─ runs claude -p (retry 3x)       │
                            │     ├─ runs verify-command             │
                            │     ├─ commits + pushes                │
                            │     └─ opens draft PR                  │
                            └────────────────────────────────────────┘
```

Inspired by [`nilbuild/claude-queue`](https://github.com/nilbuild/claude-queue), restructured as a per-issue GitHub Action with subscription-auth support.

## Usage

### 1. One-time runner setup

On your self-hosted runner VM, install the Claude CLI and pre-auth:

```sh
# As root or with sudo:
npm install -g @anthropic-ai/claude-code

# As the runner user (so the cached creds are readable in CI jobs):
sudo -u <runner-user> claude /login
# follow the browser flow ONCE; creds cached at ~runner/.claude/.credentials.json
```

The runner also needs `gh`, `jq`, `git`, and whatever toolchain your `verify-command` calls (pnpm, node, etc.).

### 2. Wire your repo

Drop this at `.github/workflows/agent.yml` (full example: [`examples/consumer-workflow.yml`](examples/consumer-workflow.yml)):

```yaml
name: Coding Agent
on:
  issues:
    types: [labeled]
permissions:
  contents: write
  issues: write
  pull-requests: write
concurrency:
  group: nightcrawler-${{ github.event.issue.number }}
jobs:
  agent:
    if: github.event.label.name == 'agent-ready'
    runs-on: [self-hosted, linux, gcp]
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 24, cache: 'pnpm' }
      - uses: grossolabs/nightcrawler@v1
        with:
          issue-number: ${{ github.event.issue.number }}
          model: 'sonnet'
          verify-command: |
            pnpm install --frozen-lockfile
            pnpm -r --if-present build
            pnpm -r --if-present lint:ci
            pnpm -r --if-present test
```

### 3. Add an `AGENT_GUIDE.md`

Copy [`AGENT_GUIDE.template.md`](AGENT_GUIDE.template.md) to `.github/AGENT_GUIDE.md` in your repo and fill in the `EDITME:` markers. This is the contract the agent reads on every run — branch conventions, forbidden actions, codebase conventions, anti-patterns, etc.

### 4. Trigger a run

Open an issue, structure the body per the schema in your `AGENT_GUIDE.md`, then add the `agent-ready` label. The workflow fires, the agent works, and (if successful) a draft PR shows up linked to the issue.

The issue gets one of these status labels as the run progresses:
- `nightcrawler:in-progress` — agent is working
- `nightcrawler:solved` — PR opened
- `nightcrawler:failed` — gave up after `max-retries`

## Inputs

| Input | Default | Description |
|---|---|---|
| `issue-number` | _(required)_ | Issue to implement. |
| `use-subscription` | `true` | `true` uses cached `claude /login` creds. `false` uses `ANTHROPIC_API_KEY` env. |
| `model` | `sonnet` | Claude model alias or full id (`sonnet`, `opus`, `claude-opus-4-7`). |
| `max-turns` | `30` | Max agent turns per attempt. |
| `max-retries` | `3` | Retry attempts; each resets the working tree to the branch tip. |
| `agent-guide-path` | `.github/AGENT_GUIDE.md` | Path inside the consumer repo to the guide. |
| `verify-command` | _(empty)_ | Shell command run AFTER the agent and BEFORE commit. Non-zero exit triggers a retry. |
| `branch-prefix` | `agent/issue-` | Prefix for the branch the agent pushes to. |
| `draft-pr` | `true` | Open the PR as draft. |
| `base-branch` | `main` | Branch the agent forks from and the PR targets. |
| `allowed-tools` | `Bash,Read,Write,Edit,Grep,Glob` | Comma-separated tool allowlist passed to `claude --allowed-tools`. |
| `agent-author-name` | `nightcrawler[bot]` | git user.name for the commit. |
| `agent-author-email` | `nightcrawler@users.noreply.github.com` | git user.email for the commit. |
| `label-progress` | `nightcrawler:in-progress` | Label applied while the agent is working. |
| `label-solved` | `nightcrawler:solved` | Label applied when a PR is opened. |
| `label-failed` | `nightcrawler:failed` | Label applied when the agent gives up. |

## Outputs

| Output | Description |
|---|---|
| `branch` | Name of the branch the agent pushed (empty on no-op). |
| `pr-url` | URL of the opened PR (empty if no PR was opened). |
| `status` | `success`, `no-changes`, `verify-failed`, or `error`. |

## Sentinel markers in agent output

The agent is instructed to emit one of these as its last line. If present, the workflow short-circuits gracefully:

| Marker | Meaning | Workflow action |
|---|---|---|
| `SUMMARY: <text>` | Success | Commit + PR; summary embedded in PR body and commit message. |
| `BLOCKED: <reason>` | Agent can't satisfy the issue | No commit; comment on issue, label `:failed`. No retry. |
| `NO_CODE: <text>` | Issue doesn't need code | No commit; comment on issue, remove `:in-progress`. No retry. |

## Cost & quota

When `use-subscription: true`, runs draw from your Claude Pro/Max quota (5-hour rolling window). Heavier issues that retry can burn the window quickly — start with a couple of issues per night, scale up as you learn the rhythm.

When `use-subscription: false`, set `ANTHROPIC_API_KEY` in the calling job's env. Pay-per-token, no quota.

## Security notes

- The action runs `claude --dangerously-skip-permissions` (the agent runs every tool call without prompting). This is required for headless mode and only safe because the runner is dedicated and the AGENT_GUIDE forbids destructive operations.
- The composite action requests `contents: write`, `issues: write`, `pull-requests: write` on the consumer repo. It does not need any GH App secrets — uses `${{ github.token }}`.
- The action **never** writes to `main` directly. It always branches and opens a PR.

## Limitations

- One agent run per issue trigger. To re-run, remove and re-add the `agent-ready` label.
- The action assumes a self-hosted runner (subscription auth requires a persistent credentials file). For ephemeral cloud runners, use `use-subscription: false` and set `ANTHROPIC_API_KEY`.
- The agent does not respond to PR review comments yet. Iteration happens by closing the PR + re-labeling the issue.

## Roadmap

- Optional final review-and-fix pass (second `claude -p` call to self-review changes).
- PR-comment-driven iteration (`@nightcrawler please address X`).
- Issue creation subcommand (`nightcrawler create` to bulk-generate structured issues).
- Stream-json output mode + cost reporting per run.

## License

Internal grossolabs tooling. No license granted for external use.
