---
name: code-review
description: "Review a GitHub pull request with Claude's multi-agent process: eligibility gating, repository-guidance discovery, five independent review passes, per-finding confidence validation, and one high-confidence PR comment. Use only when the user explicitly invokes $code-review, optionally with a PR number or URL. Do not use for ordinary local-diff reviews, implementation, or fixing findings."
---

# Code Review

Review a GitHub pull request with the same process and visible result as Anthropic's [official `code-review` command](https://github.com/anthropics/claude-plugins-official/blob/main/plugins/code-review/commands/code-review.md), adapted to Codex subagents and repository guidance. Treat explicit invocation as authorization to post one top-level GitHub comment only when at least one finding survives the confidence filter.

Keep the repository read-only throughout the review. Do not edit files, apply fixes, switch branches, build, typecheck, lint, or run tests. The coordinator alone may post the final PR comment.

## Parity Contract

Preserve this sequence:

1. Check review eligibility with one lightweight subagent.
2. Discover relevant guidance paths with another lightweight subagent.
3. Summarize the PR with another lightweight subagent.
4. Run five independent review subagents.
5. Validate every candidate with a separate confidence-scoring subagent.
6. Keep only scores of 80 or higher and collapse duplicate survivors.
7. Recheck eligibility and the frozen head SHA with a final lightweight subagent.
8. Post one brief top-level PR comment, or post nothing when no findings survive.

Use the fastest suitable subagent for lightweight stages and the strongest available subagent for review stages when the surface supports model selection. Otherwise use the available subagent type while preserving role separation. Run independent reviewers and validators concurrently when capacity permits; otherwise run isolated batches. Never expose one reviewer's findings to another reviewer or one validator's score to another validator.

Treat subagent thread lifecycle as part of the workflow. After recording a completed setup result, release or close that thread before the review wave. After recording every reviewer result, release or close reviewer threads before validation. Release validators before the final recheck. On surfaces with a lower thread cap, size each batch to available capacity and release completed threads before starting the next batch. Never let a reviewer validate its own candidate or let the coordinator replace an independent validator. If the surface cannot release enough threads to preserve independence, stop and report the capacity blocker instead of silently skipping a role.

## 0. Create a Checklist

Create a concise checklist before doing any review work. Track target resolution, eligibility, guidance discovery, summary, five review passes, validation, final recheck, and posting. Do not omit a stage silently.

## 1. Resolve and Freeze the Target

Require an authenticated `gh` CLI and a GitHub-backed git repository. Stop with the exact missing prerequisite if either is unavailable.

Resolve the target as follows:

- If the invocation includes a PR number or GitHub PR URL, use that exact PR.
- Otherwise use `gh pr view` without a number to resolve the PR associated with the current branch.
- Never use `gh pr list`, recency, or "most recent open PR" to infer the target.
- If the current branch has no PR, stop and report that no associated pull request exists.

Record and freeze all of the following before spawning any subagent:

- absolute working directory
- repository root
- repository `owner/name` and canonical URL
- current authenticated GitHub actor
- PR number and URL
- PR title, body, author, state, and draft status
- base branch and head branch
- full `headRefOid`
- changed-file paths and the complete PR diff

Pass the same frozen values, including the absolute working directory and PR number, to every subagent. Tell every subagent to work from that directory and inspect only that PR.

Do not checkout the PR or change the current branch. If historical inspection needs the head commit and it is absent locally, fetch the PR commit without creating or switching branches, verify that it matches the frozen `headRefOid`, and address it by the frozen SHA thereafter.

## 2. Check Eligibility

Spawn one lightweight subagent with the frozen PR context. Ask it to decide only whether the target PR is eligible. It may inspect PR metadata, the diff, comments, and reviews.

Skip the review when any condition is true:

- the PR is not open
- the PR is a draft
- the PR is automated, such as a dependency-update bot PR
- the change is trivial and obviously correct enough not to merit review
- the current GitHub actor has already posted a Codex review on this PR

Recognize a previous Codex review as a comment or review by the current actor whose body contains both the `### Code review` heading and the Codex generation footer defined below. Do not treat another person's review as the current actor's review.

Require the subagent to return `eligible: yes` or `eligible: no` with one short reason. If it returns `no`, stop without spawning later agents or posting a comment.

## 3. Discover Guidance Paths

Spawn a different lightweight subagent. Give it the repository root and changed-file list. Ask it to return paths only, never file contents.

Collect existing guidance files that apply to at least one changed file:

- root `AGENTS.md` and root `CLAUDE.md`
- any `AGENTS.md` or `CLAUDE.md` in an ancestor directory from the repository root through a changed file's parent directory

Deduplicate and sort the paths. Treat `AGENTS.md` as Codex-native guidance and `CLAUDE.md` as compatible project guidance. Later agents may follow files explicitly linked from those documents when the linked rule directly governs changed code.

## 4. Summarize the Change

Spawn a third lightweight subagent with the frozen PR context. Ask it to inspect the PR description and complete diff, then return a concise factual summary of the change's purpose, affected subsystems, and behavior. Do not ask it for findings.

## 5. Run Five Independent Reviews

Spawn exactly five review subagents. Give each subagent the frozen PR context, the summary, the relevant guidance-path list, and the common finding schema. Instruct every reviewer to remain read-only, not post comments, and return only concrete candidate findings from its assigned lens.

Use these five lenses exactly:

1. **Repository guidance** — Read the relevant `AGENTS.md` and `CLAUDE.md` files and audit the change for direct violations. Apply only guidance relevant to review; ignore instructions that require editing, fixing, building, or shipping.
2. **Diff-only bugs** — Perform a shallow scan of the changed lines for obvious, high-impact bugs. Read only the minimum surrounding context needed to understand the diff. Avoid nitpicks and likely false positives.
3. **History and blame** — Inspect git blame and history for the modified regions. Identify regressions revealed by why the old code existed or by earlier fixes and design decisions.
4. **Previous pull requests** — Find earlier PRs that touched the changed files and inspect their review comments. Report only earlier feedback that demonstrably applies to the current change.
5. **Code comments** — Read comments and documentation near modified code. Identify changes that violate explicit invariants, contracts, warnings, or usage requirements in those comments.

Require each candidate to use this schema:

```text
title: brief imperative-free description of the defect
path: repository-relative changed file
start_line: first relevant line in the head revision
end_line: last relevant line in the head revision
changed_line: numeric head-revision line number that introduces the defect
changed_code: exact modified code at changed_line
reason_kind: guidance | bug | history | previous-pr | code-comment
explanation: concrete failure and when it occurs
evidence: code, history, PR comment, or invariant that proves the concern
guidance_path: applicable AGENTS.md or CLAUDE.md path, if any
guidance_lines: applicable line or line range, if any
```

Return no candidate unless `changed_line` is part of the PR diff. A candidate may cite surrounding unmodified context as evidence, but the defect must be introduced by a modified line.

## High-Signal Standard

Report only issues a senior engineer would expect the author to fix before merge. Reject:

- pre-existing problems
- problems that occur only on unmodified lines
- intentional behavior changes that match the PR's purpose
- speculative or purely theoretical concerns
- style preferences and pedantic nitpicks
- formatting, imports, type errors, broken builds, broken tests, or other issues a compiler, typechecker, linter, formatter, or CI will catch
- generic requests for tests, documentation, security hardening, or code quality unless repository guidance explicitly requires them or the diff introduces a concrete functional defect
- guidance violations that are explicitly suppressed at the relevant line

Do not build, typecheck, lint, or test to search for findings. Assume CI handles those signals separately.

## 6. Validate Every Candidate

For every raw candidate from the five reviewers, spawn a separate lightweight validation subagent. Run validators concurrently when possible and in isolated batches otherwise. Give each validator only:

- the frozen PR context and diff
- the one candidate under review
- the relevant guidance-path list
- the confidence rubric below

Ask the validator to inspect surrounding code, call sites, history, and guidance as needed. Require it to verify that the issue is real, introduced by this PR, attached to a modified line, practically important, and not covered by the false-positive exclusions. For guidance findings, require it to read the cited guidance and confirm that it calls out the issue specifically.

Score confidence from 0 to 100 using these anchors:

- **0** — Not confident. The candidate is false, pre-existing, or fails light scrutiny.
- **25** — Somewhat confident. It might be real, but the evidence does not verify it; stylistic concerns not explicitly required by guidance belong here.
- **50** — Moderately confident. It is real, but minor, rare, or a relative nitpick.
- **75** — Highly confident. It is very likely real and important in practice, or directly named in applicable guidance, but the evidence is not conclusive enough for the publication threshold.
- **100** — Absolutely certain. Direct evidence confirms a real issue introduced by the PR that will occur frequently or has definite functional impact.

Allow intermediate integer scores, but do not round up to clear the threshold. Require this response:

```text
score: 0-100
verdict: real | false-positive
reason: concise verification result
confirmed_path: repository-relative path or none
confirmed_changed_line: modified line number or none
```

Discard every candidate scoring below 80. After scoring, collapse survivors with the same root cause and affected code into one finding. Keep the strongest evidence and highest score; do not repeat the same issue for multiple occurrences.

If no findings remain, stop without posting to GitHub. Report in chat: `No issues scored 80 or higher; no PR comment was posted.`

## 7. Recheck Before Posting

Spawn one final lightweight subagent with the frozen context. Repeat the eligibility check from step 2 against the exact same PR number. Also verify that the current `headRefOid` equals the frozen full SHA.

Stop without posting when the PR is no longer eligible, another Codex review from the current actor appeared, or the head SHA changed during review. If the SHA changed, tell the user to run the review again against the updated PR.

## 8. Render and Post One Comment

Render one brief Markdown comment containing all surviving findings. Do not post inline review threads or suggestion blocks. Do not post more than one comment.

Use this format exactly, adjusting singular/plural grammar when needed:

```markdown
### Code review

Found N issues:

1. <brief description of the bug> (<reason it is a bug, or a linked guidance citation>)

<full-SHA GitHub link to the affected code and line range>

2. <next finding>

<full-SHA GitHub link>

🤖 Generated with [Codex](https://openai.com/codex/)

<sub>- If this code review was useful, please react with 👍. Otherwise, react with 👎.</sub>
```

For each finding:

- Keep the description brief and concrete.
- Cite an applicable guidance file with a full-SHA Markdown link when guidance is the reason.
- Link code as `<repo-url>/blob/<full-head-sha>/<path>#L<start>-L<end>`.
- Use the frozen full 40-character SHA, never an abbreviated SHA, branch name, variable, or shell substitution.
- Include at least one line of context before and after the defect when the file boundaries allow it.
- Center the linked range on the confirmed changed line.
- URL-encode path characters when required.

Pass the generated Markdown to `gh pr comment` using a safe body-file or equivalent input mechanism. Never interpolate generated Markdown as executable shell syntax. Post to the frozen PR number, then return the PR URL and number of posted findings.

## Final Chat Response

Return one of these outcomes concisely:

- `Posted a code review with N high-confidence issues to <PR URL>.`
- `No issues scored 80 or higher; no PR comment was posted.`
- `Skipped code review: <eligibility reason>.`
- `Stopped before posting because the PR head changed; run $code-review again.`

Never claim a comment was posted unless `gh pr comment` succeeded.
