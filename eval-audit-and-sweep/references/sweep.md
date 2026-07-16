<!-- Copyright 2026 Anthropic PBC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Phase 2: Parameter sweep and analysis

> **Harness-specific companions.** This file is framework-agnostic. If the eval under test has a companion file in this directory, read it after this one for the concrete patch locations, CLI flags, and result-file fields:
> - `tau2-bench.md` for Sierra's tau2-bench (including the workshop's pre-selected 20-task airline subset).

The goal of the sweep is to answer one question for the user: **for this task, which (model, parameters) cell gives the best quality per dollar and per second?** The answer is almost never "the biggest model with everything turned on," and the only way to know is to measure.

## 1. Choosing the grid

Use the latest release in each model family and cross the two reasoning knobs fully. They are independent: `output_config.effort` is a behavioural signal (how proactively the model explores, gathers context, and invests in thoroughness) that applies whether or not `thinking` is on, while `thinking: {"type": "adaptive"}` toggles the extended-thinking block. As of early 2026:

| Dimension | Values | Notes |
|---|---|---|
| `model` | `claude-haiku-4-5`, `claude-sonnet-4-6`, `claude-opus-4-7` | Latest per family. |
| `thinking` | off, adaptive | Sent as `thinking: {"type": "adaptive"}`. Haiku does not accept adaptive, so its "on" cell uses `{"type": "enabled", "budget_tokens": 4096}`, the one place `budget_tokens` is still required. |
| `effort` | `low`, `medium`, `high` | Sent as top-level `output_config: {"effort": ...}`. Sonnet and Opus only; Haiku has no effort parameter. `max` exists but is model-specific (currently Opus 4.6 only), so leave it out unless the user asks. |
| trials | 3 | Independent repeats of the same task set, averaged. |

That gives 2 Haiku cells + 6 Sonnet cells + 6 Opus cells = 14 per trial. Send the native Anthropic parameters; avoid LiteLLM's generic `reasoning_effort` kwarg, which maps to the legacy `thinking.type.enabled` form that Opus-4-7 rejects and that mislabels cells on older models. This surface has moved between releases, so it is usually worth re-checking the extended-thinking and effort docs (https://platform.claude.com/docs/en/build-with-claude/extended-thinking) before patching a harness.

Confirm model access with the user (all three families pre-selected by default; only drop one if they lack API access to it) and how many trials to average. Do not ask them to prune the grid. If only one model is left after the access check, flag before launching that the sweep will rank parameter settings within that model but will not produce a cross-model comparison.

### Holding everything else constant

A sweep is only meaningful if every cell sees the same tasks under the same conditions. In practice that usually means pinning a seed or an explicit task-ID list so each cell runs the identical examples, and, for evals with a simulated user or judge model, fixing that model across all cells. When adding trials, vary the seed but first read the harness source to confirm the seed only perturbs sampling randomness and not which tasks are selected; if task selection is seed-dependent, hold the seed fixed and rely on the harness's own `--num-trials` instead.

### When the harness only exposes `--model`

Most third-party eval CLIs let you swap the model but not `thinking` or `effort`. When the user wants those dimensions, the lightest-touch approach is usually to find the one place the harness calls the LLM (grep for `litellm`, `anthropic`, `client.messages`, or `completion(`), and add a few lines that read the extra parameters from environment variables and merge them into the call kwargs. The sweep runner then sets those env vars per cell. Keep the patch confined to the agent-side call so judge or user-simulator calls are unaffected, and prefer env vars over new CLI flags since they require no argparser surgery.

After patching, run two or three tasks with the knob on versus off and check that output-token counts (or latency) actually differ before launching the full grid. If they don't, the parameter is probably being dropped somewhere in the call chain.

## 2. Instrumenting the run

For each (cell, example) pair, capture at minimum:

- `passed` (bool) from the judge
- `input_tokens`, `output_tokens` (sum across all turns if agentic)
- `agent_generation_seconds`: the sum of per-turn model generation time for the agent. Prefer this over raw wall-clock, which also captures retry backoff, user-simulator turns, and tool execution and is therefore sensitive to how much parallelism the run happened to be under.

Then aggregate per cell:

- `pass_rate = passes / n_examples`
- `cost_per_task` = mean of `(input_tokens * price_in + output_tokens * price_out) / 1e6` using current per-model $/MTok pricing
- `cost_per_success = total_cost / passes` (infinity if zero passes)
- `seconds_per_success = total_agent_generation_seconds / passes` (infinity if zero passes)
- `p50_latency` = median `agent_generation_seconds` per task

`cost_per_success` and `seconds_per_success` are usually the two numbers that matter most, because they fold quality and efficiency into one figure. A model that is 3x cheaper per call but passes half as often is not actually cheaper.

When the eval is a CLI rather than a library, the wrapper usually becomes a subprocess launcher. A few things tend to make that smoother: check whether the CLI already has a `--save-to` or `--output-dir` flag before resorting to diffing a results directory; read tokens and cost from the harness's own results file (many already record per-turn `usage` and a computed cost) rather than re-deriving from price tables; and make the runner resumable by skipping a cell only when its results file contains the expected number of examples, not merely when the file exists, so a crashed run can be restarted without re-paying for finished cells or accepting half-finished ones.

Launch the sweep itself from the main session as a background process. Delegating it to a subagent that then exits tends to get the process tree reaped mid-run.

Parallelise aggressively: run every cell of every trial concurrently (fan out trials as separate processes and give each a generous worker pool and per-harness concurrency). The API will rate-limit if needed and most harnesses already retry on 429s, so err on the side of more parallelism and let it self-throttle. One caveat: if cells are run under different concurrency loads (for example some added later at higher parallelism), their wall-clock latency is not comparable, since retry backoff inflates duration. Tokens and cost are unaffected, but treat the TTLT plot as indicative unless every cell ran under the same load.

It usually pays to keep the runner and the plotter as two separate scripts. The runner takes a trial identifier (an env var is fine), writes one `sweep_results_<trial>.json` per trial, and is safe to re-invoke since completed cells skip. The plotter just globs those JSONs, averages across trials, and draws; that way plot iterations cost nothing and adding or swapping a model later only reruns the missing cells.

Example of the minimal wrapper pattern (adapt to the user's framework; do not copy verbatim):

```python
import time

def run_cell(model, thinking, effort, examples, run_one, judge, price):
    passes, in_tok, out_tok, secs = 0, 0, 0, 0.0
    lats = []
    for ex in examples:
        t0 = time.monotonic()
        pred, usage = run_one(ex, model=model, thinking=thinking, effort=effort)
        dt = time.monotonic() - t0
        secs += dt; lats.append(dt)
        in_tok += usage.input_tokens
        out_tok += usage.output_tokens
        passes += judge(pred, ex.expected)
    cost = in_tok / 1e6 * price[0] + out_tok / 1e6 * price[1]
    n = len(examples)
    return {
        "pass_rate": passes / n,
        "cost_per_task": cost / n,
        "cost_per_success": cost / passes if passes else float("inf"),
        "secs_per_success": secs / passes if passes else float("inf"),
        "p50_latency": sorted(lats)[n // 2],
    }
```

## 3. Plotting

Produce three PNGs, all with pass rate (%) on the y-axis and a per-task average on the x-axis:

1. average **output tokens** per task (not total tokens; in multi-turn agents the repeated system prompt dominates totals and collapses every cell into a narrow band),
2. average **agent cost** per task,
3. average **time to last token** per task.

Use the same layout for all three so they read as a set. Encode every grid dimension as a visual channel rather than a text annotation, so nothing can overlap:

- **Colour = model.** One colour per family.
- **Line style = thinking.** Solid for thinking off, dashed for thinking on.
- **Marker size = effort.** Small, medium, large for low, medium, high. Connect them in effort order (not x-value order, otherwise the line zigzags whenever cost or tokens aren't monotone in effort). Avoid text labels on the points; in practice several cells land on top of each other on at least one axis and text always ends up colliding.
- **Models without an effort axis** (Haiku) appear as standalone points, one per thinking state, with their own legend entries.
- Two legends: the series legend (one entry per model x thinking, titled "dashed = thinking on" since that is the only non-obvious encoding), and a small grey marker-size legend for effort. Keep legend titles to what a reader can't infer from the entries themselves.
- Plot the mean across trials; leave error bars off unless the user asks for them.
- Drop redundant baseline cells (e.g. a model's "no thinking, no effort" point when its full effort line is already plotted).

After generating, read the PNGs back and sanity-check them as a first-time viewer would: is anything on the canvas not explained by a legend? Does any legend text state something already obvious from the entries? Fix before showing the user.

In addition to the PNGs, emit a self-contained `sweep_report.html` containing the per-cell data table and the three plots inlined as base64 `<img>` tags. Terminal image rendering is unreliable across harnesses and clients; an HTML file opens in any browser and is trivial to share. The change is small — write each figure to an `io.BytesIO` buffer, `base64.b64encode` it, and drop it into `<img src="data:image/png;base64,...">`.

Example skeleton (adapt, do not copy verbatim):

```python
LINESTYLE = {"off": "-", "on": "--"}
EFFORT_SIZE = {"low": 7, "medium": 11, "high": 16}
for model in COLORS:
    for thinking in ("off", "on"):
        pts = sorted(cells_for(model, thinking), key=lambda r: EFFORT_ORDER[r.effort])
        xs, ys = [p.x for p in pts], [p.pass_rate for p in pts]
        ax.plot(xs, ys, LINESTYLE[thinking], color=COLORS[model],
                label=f"{model}, thinking {thinking}")
        for p, x, y in zip(pts, xs, ys):
            ax.plot([x], [y], "o", color=COLORS[model],
                    markersize=EFFORT_SIZE[p.effort],
                    markeredgecolor="white", markeredgewidth=1.2)
leg1 = ax.legend(loc="lower right", title="dashed = thinking on")
ax.add_artist(leg1)
ax.legend(handles=[plt.Line2D([], [], marker="o", color="grey", ls="",
                              markersize=EFFORT_SIZE[e], label=f"effort = {e}")
                   for e in EFFORT_SIZE], loc="center left")
```

## 4. Stating the recommendation

End with one or two sentences, not a table. Something like:

> For this eval, `claude-sonnet-4-6` with `effort=medium` and thinking off reaches the same 94% pass rate as Opus at roughly one-third the cost per success ($0.021 vs $0.068) and half the latency. Consider Opus only if the 6% it additionally solves are disproportionately high-value.

If two cells are genuinely tied, say so and name the tiebreaker (usually latency or the user's cost sensitivity). If the cheapest model already hits the ceiling, say that explicitly; it is the most actionable finding a sweep can produce. Always state the noise floor alongside the headline: at n=20 a single task is 5 percentage points, so differences smaller than that are usually not meaningful.
