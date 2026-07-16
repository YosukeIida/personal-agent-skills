<!-- Copyright 2026 Anthropic PBC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

---
name: eval-audit-and-sweep
description: This skill should be used when a user wants to (a) audit the quality and reliability of an existing LLM evaluation suite, or (b) determine which Claude model and inference parameters give the best quality-per-dollar and quality-per-second for their specific task by running a parameter sweep over that eval. Applicable to any eval framework (custom harnesses, tau-bench, inspect-ai, pytest-based, etc.) since the guidance is framework-agnostic.
---

# Eval Audit and Sweep

This skill is an example exercise for the "Picking the Right Model" workshop during Code with Claude. It is a two-phase playbook for getting trustworthy cost-quality numbers out of an existing LLM eval. Phase 1 audits the eval for common reliability issues. Phase 2 wraps it in a model/parameter sweep and produces a recommendation. The phases are independent: a user may ask for only the audit, only the sweep, or both.

The skill contains guidance and example snippets only; it ships no runnable scripts, because every eval framework is structured differently. Claude is expected to read the user's eval code, apply the principles in the reference files, and write whatever glue code that specific codebase needs.

## How to use this skill

1. **Locate the eval.** Find the golden set, the judge/scoring function, and the entrypoint that runs one full pass. If the user has not pointed at a specific directory, ask.

2. **Decide which phase(s) apply.** If the user says "is my eval any good" or "review my eval," run Phase 1. If they say "which model should I use" or "what's the cheapest config that still passes," run Phase 2. If they say both or it is ambiguous, run Phase 1 first (a sweep over a broken eval produces misleading numbers).

3. **Read the relevant reference file before acting:**
   - `references/audit.md` for Phase 1: the health-check checklist (task design, harness design, metrics hygiene, and grader design including LLM-judge biases) and how to report findings in measured, non-dogmatic language.
   - `references/sweep.md` for Phase 2: choosing the grid, instrumenting per-cell metrics, plotting, and stating a one-sentence recommendation. That file links out to harness-specific companions where they exist.

4. **Check in before launching.** Use `AskUserQuestion` to confirm in one pass: model access (default to all three families pre-selected, phrased as "deselect any model you don't have API access to" rather than "which do you want"), how many examples per cell, how many trials to average over, and a concurrency cap if they're worried about rate limits. The grid is the full cross-product of every model the user can call and all applicable parameter dimensions; do not invite the user to trim it. If fewer than two models survive the access check, say so before launching — the result will only rank parameter settings within one model, not answer "which model."

5. **Adapt, do not transplant.** The reference files contain example code fragments. They are illustrations of the pattern, not drop-in scripts; reshape them to fit the user's framework.
