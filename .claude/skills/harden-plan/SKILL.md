---
name: harden-plan
description: Run an explicit adversarial review loop over an implementation plan after brainstorming and writing-plans. Use only when the user invokes $harden-plan, /harden-plan, or directly asks to harden, adversarially audit, or iterate an existing plan before implementation.
---

# Harden Plan

Strengthen an existing implementation plan with adversarial reviewers. Keep reviewers read-only; only the coordinating chat may revise the spec or plan.

**Reviewers use the workspace's own agent (Riley, 2026-09-23).** Launch two
fresh native in-chat reviewers on the coordinating chat's agent and model, one
per lens below, and follow the Native round procedure. A Claude chat uses
Claude, a Codex chat uses its own Codex model, a Grok chat uses Grok. Use
another model only when Riley asks; the cross-model runner (`review_plan.py`,
Claude Opus 5 plus GPT-6 Astra) exists for that request. Keep the same risk
classification, round counts, finding schema, resolve loop and stop
conditions.
This routing is not permission to skip hardening or start implementation.

**Rounds (Riley, 2026-08-27):** if Riley names a round ("round 2", "make round 4 the last"), that named round is the **last**. Do not auto-chain the skill's 3–5 high-risk cadence. A bare "harden this" in Grok is **one round**, then stop and ask. Do not start the next round unprompted.

## Inputs

Resolve the implementation-plan path from the invocation or current conversation. Resolve its source spec when one exists. If more than one plan or spec is plausible, ask the user for the path instead of choosing by modification time.

Run this workflow in normal agent mode. If the current harness prevents plan/spec file updates, explain that constraint and stop before launching reviewers.

Invocation variants:

- Bare invocation: classify risk and use the risk-based cadence.
- `standard`: minimum 2 rounds, maximum 3.
- `high-risk`: minimum 3 rounds, maximum 5.
- `rounds N`: run exactly `N` rounds, where `N` is 1 through 10.

Treat payments, authentication, production data, migrations, destructive operations, concurrency, releases, and cross-platform contracts as high risk.

Before launching anything, state in one message: the plan and spec paths, the risk classification, how many rounds that implies, and both reviewer models. A round takes 5 to 30 minutes, so a run of several rounds occupies Riley's screen for a long time — he must know what he is waiting for before the first silence.

## Review Round

### Native round (the default)

In a Claude chat, the reviewers are two `Agent` calls on the chat's own model,
one lens each. The `Agent` tool has no effort setting, so an effort level
cannot be applied or proven; say so in the round report rather than claiming it.

Freeze the current spec, plan and repository revision in a private
`.context/` review packet. Start each reviewer with only that packet and its
lens, not the author's reasoning or previous reviews. Keep the working tree
unchanged until both return; only write review artifacts in gitignored
`.context/`. Before and after the round, call `_snapshot_repo(Path(repo))`
from `scripts/review_plan.py`: it fingerprints the branch, tracked diff and
untracked file contents. Git status/diff alone misses edits to an existing
untracked file. Also fingerprint the actual plan/spec bytes separately if
they are gitignored, since the repository snapshot excludes ignored files.
Compare the fingerprints and invalidate the round on any mismatch; report
the integrity failure without reverting changes. Native tools do not run
these checks automatically: the coordinator must execute and save them.

Require the runner's result shape:

```json
{"status":"approved|issues_found","summary":"...","findings":[{"id":"...","severity":"blocker|major|minor","category":"...","location":"...","evidence":"...","problem":"...","required_decision":null,"recommended_change":"..."}]}
```

Validate with `_validate_review` in `scripts/review_plan.py` (importing it does
not start the runner). Save both complete outputs and their dispositions in
the private packet. Retry a failed or malformed role once in a fresh native
agent; a still-missing role leaves the round incomplete, never approved.
Continue at Resolve Findings below. All round and approval rules still apply.

### Cross-model runner round (only when Riley asks for another model)

A round is far longer than any agent harness allows a single foreground command to run, and a blocked caller cannot report progress. **Never run a round in the foreground.** Start it detached, then poll.

Start the round:

```bash
python3 .claude/skills/harden-plan/scripts/review_plan.py \
  --plan <plan-path> \
  --spec <spec-path-if-any> \
  --round <round-number> \
  --risk <auto|standard|high-risk> \
  --start
```

For an explicit iteration count, add `--rounds <N>`. The cloud backend talks to `https://api.conductor.build/v0`; the runner appends `/v0` when `CONDUCTOR_API_URL` lacks a version (measured 2026-09-08: the bare base returned 404 on every route). It also retries a transient socket reset on GET up to four times, because one reset used to kill a reviewer that was still working. `--start` returns in seconds and prints a run directory. The runner automatically selects local Conductor CLIs or the cloud Conductor API from `CONDUCTOR_IS_LOCAL`. Never launch the two reviewers yourself when the runner is available.

Then poll that run directory until it stops reporting `state=running`:

```bash
python3 .claude/skills/harden-plan/scripts/review_plan.py --status <run-dir>
```

**Post a one-line update to Riley after every poll**, carrying the elapsed time and which reviewers have returned — for example `Round 1: 6m12s elapsed, Claude back with 2 majors, GPT still running.` Never leave more than about three minutes without one, and never state a remaining time; elapsed is a fact, remaining is a guess. The run directory's `progress.log` carries the same detail if you need more than the status line.

Collect the result once the run is no longer running:

```bash
python3 .claude/skills/harden-plan/scripts/review_plan.py --result <run-dir>
```

`--result` exits 2 while the round is still running and never invents a verdict. Exit 1 means the round ended without one, and prints the reason.

**Do not touch the working tree while a round is in flight.** The round compares repository state before and after to prove the reviewers stayed read-only. On the local backend it cannot tell your edit from theirs, so any commit or file save discards the round. On the cloud backend (reviewers run in their own workspaces) a local change is named in the log and the verdicts stand, EXCEPT an edit to the plan or spec under review, which still discards the round because the verdicts would describe a revision no longer on disk (2026-09-11). Keep talking to Riley during the wait, but make edits between rounds, never during one. If Riley asks for a change mid-round, either wait for the round to land or say plainly that applying it now restarts the round.

The runner starts two independent reviewers concurrently:

- Claude Opus 5 at xhigh: intent, ambiguity, scope, edge cases, security, migration, and operational risk.
- GPT-6 Astra at high (Riley, 2026-09-11; never Sol, never xhigh for this lens): buildability, interfaces, types, data flow, concurrency, compatibility, and verification.

Every invocation creates fresh sessions and passes only the current spec, current plan, and repository. Never pass earlier reviews into a later round.

## Resolve Findings

After each round, first report what came back: each reviewer's blocker/major/minor counts and the round number, in one short message. Do this before re-reading anything, so every round produces a visible outcome rather than another silent stretch of tool calls.

Then:

1. Re-read every cited source location yourself.
2. Reject false positives, duplicates, style-only comments, and optional enhancements that do not affect correctness or buildability.
3. Resolve discoverable repository facts without asking the user.
4. Ask one user question at a time only when a preference or product decision materially changes the result. Lead with the reviewers' recommended option and tradeoff.
5. When a decision changes requirements, update the spec first and then make the plan consistent with it.
6. Apply all verified blocker and major corrections before launching the next round.

Do not edit application source code. This skill changes only the spec and plan being reviewed.

## Harden again / next round

The loop is **review → fix the plan → review**, never “run N reviews then fix.”

When the user asks to harden again (or starts a new `$harden-plan` after a prior round in the same chat):

1. If the previous round’s verified blocker/major corrections are **not yet** in the plan/spec, apply them first.
2. Only then launch the next review round against that updated plan.
3. If those corrections were already applied at the end of the previous round, skip straight to the next review — do not re-litigate settled edits.

Tell the user which case applied (“round 1 fixes already in plan; starting round 2” vs “applying round N fixes, then starting round N+1”).

## Stop Conditions

Complete only after the cadence minimum has been reached and both reviewers return no blocker or major findings. Minor findings may remain only when they are explicitly non-blocking and do not create ambiguity.

If material findings remain at the cadence maximum, mark the plan **not ready** and ask whether to extend the loop. Do not silently exceed the maximum and do not claim the plan is implementation-ready.

On approval:

- Ensure the plan has no placeholders, contradictory interfaces, or unresolved decisions.
- Remove or replace any handoff to unavailable Superpowers execution skills with this repository's own implementation and verification workflow (its AGENTS.md, CLAUDE.md or README).
- Report the number of rounds, the material decisions resolved, and the final plan path.

## Failure Handling

- The runner retries one failed or malformed reviewer once in a fresh session. The retry appears in the status line and `progress.log`; say so when it fires rather than letting the round silently take twice as long.
- A run directory that git can see is refused up front, because the round's own progress log would otherwise be hashed into the repository-integrity snapshot and reported as a reviewer mutation. Add `.context/` to `.gitignore` rather than working around it.
- If a requested model resolves to another model, stop; never accept a silent downgrade.
- If either reviewer changes repository state (local backend), or the plan or spec under review changes mid-round (either backend), stop and report the integrity failure. Never auto-revert. Other local edits during a cloud round are logged by path and do not void the round.
- For the Claude runner in cloud, if the workspace-scoped API key or current session id is unavailable, stop with the runner's setup error rather than falling back to a single model. Native Codex review does not require this runner's credentials.
