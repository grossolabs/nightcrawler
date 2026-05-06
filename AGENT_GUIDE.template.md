# Coding Agent Guide — TEMPLATE

> Copy this file into your consumer repo at `.github/AGENT_GUIDE.md` and edit the `EDITME:` markers. Every section below is loaded into the agent's prompt before it touches code, so be precise.

The agent runs headless, in your repo's checkout, on your self-hosted runner. Its only goal is to **fulfill exactly what the labeled issue describes** and leave the working tree ready for the workflow to commit. It must NOT improvise scope, refactor unrelated code, or make architectural decisions outside the issue.

---

## 1. Branch + commit conventions

- The workflow has already created your branch and based it on `main`. You should NOT switch branches.
- The workflow will commit + push for you. **Do NOT run `git commit` or `git push`** — just leave files in place.
- One logical change per run. Don't bundle the issue's deliverable with unrelated cleanup.

## 2. Hard verification gate

Before you stop, you **must** run these commands and they **must** pass. If any fail, fix the underlying issue and re-run — never disable, skip, or mock around a failing test.

```sh
# EDITME: replace with your repo's actual lint/build/test commands.
# Example for a pnpm workspace:
#   pnpm install --frozen-lockfile
#   pnpm -r build
#   pnpm -r lint:ci
#   pnpm -r test
```

The workflow will also run a final consumer-side `verify-command` (set in the workflow yaml) as a sanity check. If your run leaves the repo in a state that fails verification, the commit is aborted and the issue is commented with the error.

## 3. Where to find context

| Need | Look here |
|---|---|
| Architecture overview | EDITME: e.g. `docs/architecture.md` |
| Per-feature spec / wave plans | EDITME: e.g. `plan.md` §X |
| Shared types / contracts | EDITME: e.g. `packages/contracts/src/` |
| Module patterns + conventions | EDITME: e.g. `src/modules/<example>/` for reference |
| DB migration workflow | EDITME |
| Repo-wide conventions | EDITME: link to your `CLAUDE.md` |

If the issue references a spec section like "plan §5.8", read that section first.

## 4. Forbidden actions (hard stop — exit with `BLOCKED:` line)

The agent must NOT:

- **Touch branches other than its own.** The workflow owns branch creation.
- **Run database migrations** or modify production state. Write the migration file but do NOT execute it; a human applies it.
- **Add or upgrade dependencies** beyond what the issue explicitly authorizes. If the lockfile would change in a way the issue didn't specify, stop and surface the question.
- **Disable, skip, or mock around failing tests.** If a test fails after the change, the change is wrong — fix the change.
- **Commit secrets, .env files, or anything matching `.gitignore`.** (The workflow stages `git add -A`, so anything you create gets committed.)
- **Touch EDITME-protected paths.** EDITME: list any directories/files the agent must leave alone (e.g., legacy modules scheduled for deletion, vendor code).
- **Open PRs or comment on issues yourself.** The workflow handles GitHub interactions.

If you can't satisfy the issue's acceptance criteria within the constraints above:

1. Do NOT make any changes (revert anything you started).
2. Print a single line starting with `BLOCKED:` followed by a one-sentence reason.
3. Print a longer explanation below.
4. Exit cleanly. The workflow will surface the explanation on the issue.

## 5. Issue body schema (what to expect)

Issues triggered by the `agent-ready` label should have this shape:

```markdown
**Goal.** One paragraph stating the deliverable.

**Files.**

| File | Action | LOC | Notes |
|---|---|---|---|
| path/to/file.ts | new | ~80 | What it does |

**Tasks (in order).**

1. Step one
2. Step two

**Acceptance criteria.**

- [ ] X is true
- [ ] Y is true

**Dependencies.** Other issues that must land first.

**Risks / open decisions.** Things to watch for.

**Plan §:** EDITME spec reference (or "n/a")
```

If the issue doesn't follow this shape, do your best to extract intent. If intent is unclear, exit with `BLOCKED:`.

## 6. Cost & runtime budget

- Default: 30 turns, the model passed in by the workflow (sonnet by default, opus for hard issues).
- Hard timeout: 60 minutes (set on the workflow job).
- Concurrency: one agent per issue, serial across issues on the runner.

## 7. House style

EDITME: short paragraph on house style — naming conventions, error handling philosophy, comment policy, etc. Keep it concrete; vague style guides waste tokens.

## 8. Anti-patterns the agent must avoid

EDITME: list specific anti-patterns this codebase has seen. Examples:

- "Don't add try/catch around code that already has framework-level error handling."
- "Don't add comments restating what the code does."
- "Don't introduce new abstractions; mirror the existing module's structure."

These are the hardest rules to enforce via the prompt — be specific.
