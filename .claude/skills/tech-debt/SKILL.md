---
name: tech-debt
description: Measure the technical debt one change adds or pays down, before it merges. Runs inside every wrap-up, and on request for any branch or PR ("tech debt check", "/tech-debt", "does this PR add debt?"). A free mechanical scan first, then at most one fresh reviewer, then fix, register or note every item. Not a whole-repo audit and not a bug hunt.
---

# Tech debt: what this change costs later

Code review asks "is this change wrong?". This asks "will this change make the
next change slower, riskier or more confusing?", which a review rubric
deliberately throws away as style or "add tests" noise. The answer goes in the
PR, and anything left unpaid goes in a register so it cannot quietly vanish.

**Scope is the diff.** Debt this change adds, debt it pays down, and debt it
touches in files it edits. Never a repo-wide audit, never a defect hunt (code
review owns defects), never a reason to grow the PR.

`SKILL_DIR` below is the folder holding this file (`.claude/skills/tech-debt`
or `.agents/skills/tech-debt`, whichever this repo has).

## Why it works this way (research, 2026-10-12)

- **Metrics alone do not find debt.** Google tested 117 metrics against what
  its engineers reported as debt; no single metric predicted it (Jaspan and
  Green, IEEE Software 2023). So: cheap signals as evidence, one judgment on top.
- **Judgment works best as a filter over mechanical signals.** In an
  industrial study, LLM filtering removed 94 to 98 percent of a static bug
  detector's false alarms (Tencent, ICSE 2026). That study is about bug
  alarms, not debt; it is why the judge confirms or rejects each scanner
  signal with a reason instead of free-styling.
- **Interest is churn.** Debt in code that changes weekly costs far more than
  debt in code nobody touches (CodeScene's hotspot model). The scan reports
  each file's commits in the last 90 days.
- **AI-written code duplicates.** Copied blocks of five or more lines rose
  eightfold in 2024 while moved (refactored) code fell (GitClear 2025). The
  scan flags copies of six or more meaningful lines, and says when a very
  large change was too big to check in full.
- **Half-done migrations and dead code** are among Google's top ten debt
  causes: two versions of one thing, a flag nobody removes, an old path left
  behind. The scan flags versioned names (`ChatViewV2`) and new flags.

## The eight categories

| Category | Debt looks like | Not debt |
|---|---|---|
| Code | copy-pasted blocks, a reinvented helper, suppressed lint or type checks, force unwraps, commented-out code, TODO/FIXME/HACK | a style preference |
| Design | a second version of something that already exists, logic in the wrong layer, a file that keeps growing, a flag or deprecation with no removal plan | a deliberate, explained boundary |
| Test | changed behaviour with no test, a skipped or focused test, fixed sleeps where polling works, fewer test cases than before | UI layout with nothing testable |
| Docs | a new setting nobody wrote down, a link to nothing, a doc naming a removed file, a rule that contradicts another, a stale line left beside its replacement | missing prose for obvious code |
| Dependency | a new library for something an existing one covers, a moving version (`latest`, `*`), a manifest change without its lockfile | a routine version bump (noted, not debt) |
| Infra | CI allowed to fail, an action pinned to `main`, an unpinned image, hooks bypassed, a new scheduled job with no alert | |
| Security | disabled TLS, `eval`, HTML built from data, a table without row-level security, `SECURITY DEFINER` without `search_path`, a credential-shaped string | |
| Knowledge | a non-obvious decision or magic number with no comment or PR rationale, code the author cannot explain, a workaround with no "why" | |

## Step 1: scan (free, about one second)

```bash
python3 "$SKILL_DIR/scripts/debt_scan.py" --committed
```

- `--committed` scans exactly the committed branch, which is what reviewers
  see. Without it, uncommitted and new files count too. `--head <branch>`
  scans another branch or a fetched PR without checking it out.
- The JSON and the exact diff it scanned land in the git directory (the
  `json:` and `diff:` lines), so they are never committed and the judge reads
  the same diff the scan did. `--json <path>` moves both.
- **Any non-zero exit means no analysis, never "no debt".** 2 is "could not
  scan" and 3 is "empty change"; report either plainly. A stale base and a
  clean change look alike. Exit 0 must print a `measured:` line naming files
  and lines.
- Rule tables and fixtures can carry `debt-scan: ignore-file` in their first
  30 lines. The scan reports the opt-out itself, so it is never silent: adding
  the marker is a signal for the judge, and every later edit to that file is
  listed as lines the rules did not read.

## Step 2: one judge, only when the scan says so

The scan ends `judge: recommended` or `judge: not needed`. It recommends one
when any signal says debt was added, when an opted-out file changed, when 40
or more code lines changed, when
20 or more lines of agent guidance (CLAUDE.md, AGENTS.md, skills, rules)
changed, or when a register entry is deleted (a claimed payment needs a
witness). Not needed means the scan is the whole analysis. That is a machine
decision; do not argue it down. A register entry that is only touched gets a
one-line status from you instead (Step 3).

When recommended, launch **one fresh, read-only reviewer** that never sees the
author's reasoning, from the model family the repo's review rules require (in
Amora, wrap-up's reviewer table). In a wrap-up that also runs code review,
launch it in the same wave as the reviewers so it adds no wall-clock time.
Give it only this prompt, filled in:

```text
You are a technical-debt reviewer. Read-only: do not edit, build or run tests.
Repo: <abs path>. Head: <sha>. Diff: <path to diff file>. Scan: <path to scan JSON>.
Change summary (factual): <one paragraph, or "none">. Guidance: <CLAUDE.md/AGENTS.md paths>.
Read <SKILL_DIR>/SKILL.md section "The eight categories". Read only the context
you need to confirm a signal or to name an existing helper.

1. Every scan signal with direction "added": confirm or reject it with a reason.
   Group repeats of one kind ("14 force unwraps in fixtures: reject, literals").
   At most 15 lines here, highest interest first; every signal must fall under
   a line or a group, and say how many you grouped. Every "removed" signal is
   a claimed paydown: confirm the debt is really gone, not just its marker.
   For a "scan-opt-out" signal, read those lines yourself: no rule did.
2. Add at most 6 items the scan cannot see (design, knowledge, a reinvented
   helper: name the existing one with its path; for guidance files, a rule
   that contradicts or duplicates another). Each must cite a changed line.
   No style nits. No "add tests" without naming the untested behaviour.
3. For each confirmed or added item give: category, direction (added |
   worsened | paid | touched), path:line, one-sentence evidence, interest
   (high/medium/low from the scan's churn), principal (S under 30 minutes of
   agent work, M under half a day, L more), deliberate or inadvertent, and a
   recommendation: fix-now | register | note.
4. End with: net = added minus paid, and one sentence a non-engineer would
   understand about what this change makes harder or easier later.
Return plain text, under 500 words.
```

Wait for its completion notification. A reviewer that has not returned has
produced nothing, not "no debt". If no judge ran, the report says "scan only",
never "reviewed".

## Step 3: dispositions (no item may disappear)

**The judge's recommendation is the disposition.** The author wrote the code
and cannot grade it, so it may only make a call stricter (note to register,
register to fix-now), reject an item it can show is wrong, or move fix-now to
register when the fix would leave the diff's files or change the review lane.
The PR table shows the judge's call beside every outcome.

1. **Fixed now**: S principal, introduced by this change, and fixable inside
   files already in the diff without moving the change to a heavier review
   lane. Fix it with the review fixes, one push.
2. **Registered**: everything else this change introduces that is not fixed:
   deliberate shortcuts and M/L principal. One file in the register (below),
   in this PR. Wrap-up's "an enlarging fix becomes its own PR" does not apply
   here; registering is the answer.
3. **Noted**: debt that already existed in touched files. Never fixed or
   registered in this PR (one concern per PR). Three lines at most, then
   "and N more: <kinds>".
4. **Rejected**: with the reason. For wrong items, never for inconvenient ones.

A register entry the scan reports as touched gets one line: paid down here,
still true, or now false (delete it and say why). Deleting an entry, moving
it out of the register, or dropping a file from its `files:` makes the rescan
recommend the judge: run it on that rescan before the PR is ready, so no
payment goes unwitnessed. A `register-stale` signal means this change deleted or renamed
the files an entry names: update the entry's `files:` in this PR.

**After any fix, scan again** so the PR reports the final head. A signal that
appears only in the second scan is listed as "post-review, not judged"; it is
never folded into a reviewed result.

## The register: `docs/tech-debt/`

One small file per item, so parallel branches never conflict. The scan reads
`files:` to tell later changes when they touch registered debt, which is how
recorded debt gets paid instead of forgotten, and flags an entry when a change
removes or renames the files it names. Deleting the file is paying it. Create the folder with the first
entry; a repo can point elsewhere with `--register <dir>`.

```markdown
---
title: Chat has two timelines until v3 reaches everyone
category: design
files: [ios/Features/Chat/ChatTimelineV3.swift, ios/Features/Chat/ChatTimeline.swift]
introduced: 2026-10-12, <PR link or branch>
interest: high (14 commits in 90 days)
principal: M
pay_down_when: the v3 flag has been at 100 percent for two weeks
---
Two sentences: what the shortcut is, why it was taken, and what paying it
down means.
```

## Step 4: report

PR body, inside the collapsed details block:

```markdown
**Tech debt:** net +1 (2 added, 1 paid). Fixed 1, registered 1, noted 1. Judge: ran.
| Item | Category | Where | Interest | Judge said | Outcome |
|---|---|---|---|---|---|
| Copied price rounding from billing | code | src/checkout.js:12 | high | fix-now | fixed: calls `roundPrice` |
| Second chat timeline | design | ChatTimelineV3.swift | high | register | registered: docs/tech-debt/chat-two-timelines.md |
| Old TODO in sync loop | code | SyncEngine.kt:88 | medium | note | noted |
Scan: 14 files, +412/-90 lines, duplicate check complete.
```

Chat: one line, plain words, saying whether a reviewer looked. "Tech debt:
adds one thing to clean up later, written down." "Tech debt: none added,
pays down one." "Tech debt: scan found none (small change, scan only)."
"Tech debt: scan found 2, not reviewed (the judge did not run)." "Tech debt
scan could not run." Never silent, and a judge that did not return is never
reported as "none".

## Testing the scanner

`python3 "$SKILL_DIR/scripts/test_debt_scan.py"` builds throwaway repos for
every signal, with "must not fire" cases that keep the trigger word present.
A new rule needs a fixture that fails when the rule is removed. Bump `VERSION`
in the scan with every rule change: copies in other repos are compared by it.

## Using this in another repo

Copy the whole `tech-debt` folder into that repo's skills folder and call
Steps 1 to 4 from its wrap-up. Amora's copy (`Tonkin-Apps/amora`) is the
source: improve it there, then copy it out again. The scan prints its version
on its first line; a copy whose version differs from Amora's is out of date.
