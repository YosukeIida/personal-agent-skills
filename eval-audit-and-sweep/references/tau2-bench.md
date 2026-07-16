<!-- Copyright 2026 Anthropic PBC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# tau2-bench specifics for the sweep

> **Prerequisites.** This file assumes tau2-bench is already installed and the 1-task smoke test passes. If not, follow the workshop's `TAU_BENCH_SETUP.md`, or in short: `git clone https://github.com/sierra-research/tau2-bench`, `cd tau2-bench`, `pip install -e .` in a fresh Python 3.12+ venv, then put `ANTHROPIC_API_KEY` in `.env`. On Python 3.13 you also need `pip install audioop-lts`, or every `tau2 run` crashes in `voice.utils.audio_preprocessing`. The plotter needs `pip install matplotlib` (not in tau2's deps).

Read this alongside `sweep.md` when the eval under test is Sierra's `tau2-bench`. Everything here is a concrete instantiation of the generic guidance for that harness and the workshop demo; none of it changes the general method.

## Task set (workshop demo)

For the sake of time, instead of running all 50 airline tasks, use a difficulty-stratified 20-task subset (ranked by Haiku baseline pass rate across 3 trials). Pass it via `--task-ids`:

```
0 1 2 6 8 9 10 11 14 15 16 17 18 19 20 22 31 33 41 42
```

The set is 5 hard-but-solvable tasks (Haiku 0/3, Opus-high 2-3/3), all 5 Haiku-1/3 tasks, all 8 Haiku-2/3 tasks, and 2 easy anchors; task 7 is excluded because no configuration solves it. If the user wants to regenerate this list, the procedure is: run Haiku-off on all 50 tasks a few times, bucket by pass count, and sample across buckets.

## Injecting thinking/effort

tau2's CLI only exposes `--agent-llm`. The agent-side completion call lives in `src/tau2/agent/llm_agent.py` inside `_generate_next_message`. Add a helper that reads two env vars and merges them into the kwargs:

```python
def _sweep_extra_kwargs() -> dict:
    import json, os
    extra = {}
    thinking = os.environ.get("TAU2_AGENT_THINKING", "").strip()
    effort = os.environ.get("TAU2_AGENT_EFFORT", "").strip()
    if thinking:
        extra["thinking"] = json.loads(thinking)
    if effort:
        extra["output_config"] = {"effort": effort}
    if thinking or effort:
        extra["temperature"] = 1
        extra["max_tokens"] = 16000
    return extra
```

Then change every `generate(...)` call in the file to pass `**{**self.llm_args, **_sweep_extra_kwargs()}`. The file defines three agent classes (`LLMAgent`, `LLMGTAgent`, `LLMSoloAgent`) and each spreads `**self.llm_args,` into its own `generate(` call; patch all three (a `replace_all` on `**self.llm_args,\n        )` is the path of least resistance). This keeps the user-simulator and judge paths untouched, since those live in different modules.

Do not use LiteLLM's `reasoning_effort` here; it maps to `thinking.type.enabled`, which Opus-4-7 rejects.

The file also has ~15 pre-existing Pyright diagnostics (list-invariance `APICompatibleMessage` vs `Message`, Optional `actions` attribute access) that trigger the moment you touch it. They are unrelated to the patch; ignore them.

## Runner wiring

The cell list with the per-model thinking and effort constraints already encoded (Haiku rejects `adaptive` and has no `effort` parameter; Sonnet and Opus take both):

```python
CELLS = []
# Haiku: 2 cells (no effort axis; "on" uses budget_tokens, not adaptive)
for thinking_label, thinking_json in [("toff", ""), ("ton", '{"type":"enabled","budget_tokens":4096}')]:
    CELLS.append({"model": "claude-haiku-4-5", "thinking_label": thinking_label,
                  "thinking_json": thinking_json, "effort": ""})
# Sonnet and Opus: 6 cells each
for model in ["claude-sonnet-4-6", "claude-opus-4-7"]:
    for thinking_label, thinking_json in [("toff", ""), ("ton", '{"type":"adaptive"}')]:
        for effort in ["low", "medium", "high"]:
            CELLS.append({"model": model, "thinking_label": thinking_label,
                          "thinking_json": thinking_json, "effort": effort})
```

Drop a model from this list only if the user lacks API access to it; do not trim for cost or time.

- Models are addressed through LiteLLM as `anthropic/claude-<id>`.
- Fix the user simulator across all cells: `--user-llm anthropic/claude-haiku-4-5`.
- `--save-to <name>` takes a **slug, not a path**: tau2 always writes under `data/simulations/<name>/results.json`, so pass `--save-to sonnet_ton_ehigh_tr0`, not `--save-to data/simulations/sonnet_ton_ehigh_tr0` (the latter double-nests). Use a slug that encodes model, thinking, effort, and trial so reruns skip complete cells.
- `--max-concurrency 10` inside tau2, and launch all cells of all trials as parallel subprocesses from the sweep script.
- `--seed` is forwarded to the LLM call but Anthropic ignores it, so don't pass it; a "trial" is just an independent rerun.
- `--num-tasks N` takes `tasks[:N]`; prefer `--task-ids ...` so the set is explicit.

## Reading results

Each `results.json` has a `simulations` list. Per simulation:

- `reward_info.reward` (1.0 = pass)
- `agent_cost` (pre-computed $; no need to re-price)
- `messages[*].usage.completion_tokens` with `role == "assistant"` for output-token totals
- `messages[*].generation_time_seconds` with `role == "assistant"` summed gives agent generation time per task (the latency metric; do not use the top-level `duration`, which includes retry backoff and user-sim turns)

For the pre-sweep sanity check (running 2-3 tasks with knobs on vs off to confirm the patch is actually plumbed through), the quickest signal is the cost in the terminal's `Agent Performance Metrics` panel: haiku-4-5 no-knobs on task 0 runs ~$0.018, opus-4-7 thinking-adaptive+effort-high on the same task runs ~$0.12. Anything in between with thinking/effort set means the env vars didn't reach the call. If you want to read it from the file instead:

```bash
python3 -c "import json,glob; p=sorted(glob.glob('data/simulations/*/results.json'))[-1]; d=json.load(open(p)); s=d['simulations'][0]; out=sum((m.get('usage') or {}).get('completion_tokens',0) for m in s['messages'] if m.get('role')=='assistant'); print('file:',p); print('output_tokens:',out); print('cost:',s['agent_cost'])"
```

## Outputs

Write `sweep_results_<trial>.json` per trial, then a separate `plot.py` that globs them, averages, and emits `sweep_tokens.png`, `sweep_cost.png`, `sweep_latency.png` plus a self-contained `sweep_report.html` (data table + the three plots inlined as base64), using the encoding in `sweep.md` section 3. The HTML file is the deliverable to point the user at; the PNGs are for embedding elsewhere.

## Launching the sweep as a background process

Do **not** launch the runner with `nohup python sweep_runner.py > out &` from a shell-out tool: the `&` makes the shell fork and return exit 0 immediately, which shows up as a "background task completed" notification the instant the sweep starts and can look identical to a real completion. Prefer the harness's native background-launch (`run_in_background: true` on the Bash tool) so the notification fires when the sweep actually exits. If you must use `nohup ... &`, always follow up with `pgrep -f sweep_runner` before trusting any completion signal.

Note that the Bash tool has a hard 10-minute timeout even on background tasks. A subset of the grid (e.g. one model at low concurrency) may finish under that, but the full 14-cell × 3-trial grid usually will not. This is why the runner must be resumable: if the timeout fires, just relaunch it. A cell is "done" only when its results file contains the expected number of simulations, so a relaunch skips finished cells, reruns partials, and picks up where it left off without re-paying for completed work.
