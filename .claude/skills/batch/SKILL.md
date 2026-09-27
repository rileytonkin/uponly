---
name: batch
description: Plan and execute batches of repetitive work, such as many similar edits or a repeated migration step.
---

# Batch

1. Identify independent chunks before editing.
2. Group work by risk and dependency.
3. Execute independent reads/checks in parallel whenever tools allow it.
4. Sequence only the dependent edits.
5. Track chunk status visibly while working.
6. Verify each chunk, then run one final integrated verification.

## Batching Rules

- Prefer parallel reads: file discovery, grep/ripgrep, logs, and diff checks.
- Keep each batch narrow and reversible.
- Land high-confidence mechanical changes first.
- Isolate risky logic changes into separate steps.
- If blocked in one batch, continue with unblocked batches.

## Output Contract

- Report the batch plan briefly before major implementation.
- Report what was parallelized and what remained sequential.
- Call out residual risks between batches.
