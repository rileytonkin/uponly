---
name: wrap-up
description: Finish this workspace with a scope check, verification, independent review, commit, push, a PR and CI when Riley asks to wrap up or ship. After a merge, install the build on his Mac as AGENTS.md says.
---

# Wrap-up: the end-of-task shipping ritual for Up Only

One invocation replaces "commit and push" → "make a PR" → "what should I check?". Run the steps in order. If one
doesn't apply, say so in the report rather than skipping it silently. AGENTS.md is the policy; this is the order.

## Step 0: Scope check
- `git status` and `git diff origin/main... --stat`: the diff must be ONE coherent change. Anything you didn't mean
  to commit (stray `.context/` files, abandoned drafts, generated caches) is resolved before committing.
- Unrelated changes go in separate PRs, without asking. A title that needs "and" or a comma is the tell. Dependent
  pieces that must land in order can be a stack (`gh stack`), two or three layers at most.
- Never work on, check out or start a session on a branch from a fork (AGENTS.md → Safety).
- A change to `.claude/amora-switch.sh` must update its pinned hash in `.claude/settings.json` in the same commit,
  and needs Riley's review: say so in the report.

## Step 1: Preflight on the files in the diff
- `bash .github/scripts/guard.sh` passes (no build-time scripts, packages, extra entitlements or secrets).
- Privacy: nothing the change adds sends holdings, balances or vault contents anywhere new. A new network host,
  a new outside service or a logged value is called out in the PR and the report.
- The README describes what the app does: update it in the same PR when behaviour changes.
- Tests: new behaviour has a test in `Tests/` where it can be tested without the UI.

## Step 2: Verify
- The cloud workspace can't build the app. CI does, on the self-hosted mini (`workhorse-uponly`): the PR's
  "Test and build" check is the build and test verification. Pure logic can also be compiled and run standalone
  (a Linux Swift toolchain works for Foundation-only code) to catch mistakes before CI.
- Checks that sit queued mean the runner is down: tell Riley. Never move jobs to hosted runners, and never add
  secrets, `pull_request_target`, `workflow_run` or `workflow_dispatch` to the workflow (the repository is public).
- Visible changes: say plainly that nothing was seen on screen until the build is installed, and list what Riley
  should look at. Never run anything on his Mac beyond AGENTS.md's documented steps without asking.

## Step 3: Commit and push
Branch off `main` if on it. Commit messages say what changed and why; end them with the attribution lines the
session gives. Push with `-u`.

## Step 4: Independent review (skip only for docs-only changes, and say so)
Use the `code-review` skill on the branch, or run it by hand: freeze the diff in `.context/`, launch independent
reviewer agents (one per lens: correctness, privacy/security, repository guidance), validate every candidate with a
separate agent, and keep only high-confidence findings. Fix what's real, then re-run the relevant checks.

## Step 5: Pull request and CI
- `gh pr create --base main`. The body holds the detail: what changed, verification, review findings and how
  each was handled, anything unverified. End it with the session's attribution line.
- Wait for the PR's checks (Guard, Test and build). Report failures with their output; fix and push again.

## Step 6: Merge (only when Riley asks) and install
- Merge when Riley asks, then confirm the merge landed on `main`, check CI on `main`, and delete the branch.
- A merge that changes `UpOnly/`, `Tests/` or `UpOnly.xcodeproj/` is installed on Riley's Mac with AGENTS.md's
  steps, in order and in the background: back up the vault and app, run `build-personal.sh`, confirm it's running
  with no new crash report, and report the build time, the backup path and the `get-task-allow` result (lead with
  it if PRESENT).

## Step 7: Report (the final message)
At most 150 words plus screenshots, in three blocks:
1. **What shipped**, in plain words a user would notice. If the requested behaviour still doesn't work, lead with that.
2. **What Riley must decide or check**, one short line each, including every gap ("Not seen on screen yet",
   "Code review did not run"). Silence must never imply coverage.
3. **The PR link.**

Everything else (verification numbers, review findings, housekeeping) goes in the PR body. Then end with the
**Loose ends** section AGENTS.md requires: only what still needs Riley, or "Loose ends: None — safe to archive."
