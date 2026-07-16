<!-- Copyright 2026 Anthropic PBC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Phase 1: Eval health audit

Before trusting an eval to tell you which model or configuration is better, check that the eval itself is sound. A broken eval produces confident-looking numbers that point in the wrong direction, and a sweep over a broken eval just multiplies the misdirection. In practice, the most surprising eval results usually turn out to be bugs in the eval rather than facts about the model, so an hour of auditing upfront routinely saves days of chasing phantom differences.

The checks below are grouped into **task design** (are the questions right?), **harness design** (is the scaffolding right?), **metrics hygiene** (are cost and latency being measured correctly?), and **grader design** (is the scoring right?). They are written as direct instructions to Claude: for each, look at the eval's actual code, config, and data, not just its README. The final section, **Reporting findings to the user**, covers how to communicate what you find; the checks are declarative, but the report to the human should be framed as observations and suggestions, since the eval's author almost always has context that justifies choices an outsider would flag.

Before auditing further, consider running the eval once end-to-end on the cheapest available model, or search for previous trials results. A surprising number of eval-quality discussions turn out to be about code that does not currently run.

## 1. Task design

These checks concern the examples themselves: what is being asked, what counts as correct, and whether the set as a whole can distinguish between the systems being compared.

### Auditing task sets at scale

The harness and grader are code you can read end to end; the task set may be hundreds or thousands of items you cannot. Do not try to read every task inline. Work in three tiers:

**Tier 1: programmatic checks over the full set.** Consider writing a short script that loads every task and reports: exact- and near-duplicate rate; label or category balance; prompt-length and expected-answer-length distributions (when applicable); schema validity and missing-field counts; and any obviously malformed rows. The storage format varies per eval, so inspect two or three rows first and code to whatever schema you find. These checks are cheap, exhaustive, and catch skew, duplicates, truncation, and broken rows regardless of how large the set is.

**Tier 2: stratified sample for a close read.** Draw roughly twenty to fifty tasks, stratified across category or difficulty labels if they exist, otherwise uniformly at random, and apply the per-task checks below to those. Recommend that the user read a handful themselves as well; a second pair of human eyes on the raw tasks catches things no checklist does.

**Tier 3: per-task LLM auditor.** For sets beyond a few hundred items, run one isolated model call per task with a tight audit prompt, collect a structured verdict from each, and aggregate. This is the same approach behind public re-annotation efforts such as MMLU-Redux and SWE-bench Verified, automated. Ask the user before running it, the cost is roughly N cheap-model calls, usually small next to the eval's own inference cost, but it is their budget to spend. Offer it explicitly: "I can run a per-task auditor over all N tasks, estimated cost ~$X. Want me to?"

A per-task auditor prompt that works well (adapt the field names to the eval's schema):

```
You are auditing a single task from an evaluation suite. Given the task prompt, the reference answer, and a description of how the grader decides pass/fail, flag any of the following issues. Be conservative, only flag when you are reasonably confident.

TASK PROMPT:
{prompt}

REFERENCE ANSWER:
{gold}

GRADER BEHAVIOUR:
{grader_description}

For each issue below, answer yes/no and give a one-line reason if yes:
- ambiguous: could two careful experts reasonably disagree on the correct answer?
- gold_suspect: does the reference answer look wrong, incomplete, or arguable?
- answerable_from_memory: could a well-read model answer this from general knowledge without doing the intended work?
- grader_too_strict: are there clearly correct answers the grader as described would reject (format, phrasing, precision)?
- grader_too_lenient: are there clearly wrong answers the grader as described would accept?
- trivially_cheatable: is there a shortcut that satisfies the grader without solving the task?
- other: anything else that would make this task's result misleading.

Return JSON: {"task_id": "...", "flags": {"ambiguous": {"flagged": bool, "reason": "..."}, ...}, "overall": "ok" | "review" | "broken"}
```

After the run, cluster by flag type, surface the top issues with example task IDs, and feed the findings into the report (§5).

The checks that follow are the per-task checks referenced by tier 2, apply them to the sampled tasks, not the full set.

- **Unambiguous success criteria.** Read three or four tasks and their expected answers. For each, ask: would two independent domain experts, shown the same model output, agree on pass vs. fail? If the criteria admit reasonable disagreement ("write a *good* summary," "respond *helpfully*"), scores reflect grader opinion as much as model capability. Flag tasks whose pass condition is not crisply decidable. Note the dual failure mode: a task can be under-specified (no clear success criterion, or a required output, a filename, a format, a target, left unstated) or over-specified (the prompt is effectively a step-by-step recipe, leaving nothing for the model to decide).

- **Reference solution exists.** Check whether each task ships with at least one worked solution or gold answer that actually passes the grader. A task with no known passing answer may be unsolvable as posed, a 0% pass rate across all models is more often a broken task than a genuinely hard one. Spot-check by running the reference solution through the grader.

- **Ground-truth labels are correct.** Sample ten or so tasks and independently re-derive the expected answers. Public benchmarks routinely ship with a non-trivial fraction of wrong or arguable labels, community re-annotations of widely used reasoning and coding benchmarks have repeatedly found meaningful label error rates in the originals. Wrong labels put a ceiling on measurable accuracy that has nothing to do with the model.

- **No annotation artifacts.** Check whether a trivial baseline could score well by exploiting surface patterns rather than solving the task: can the answer be guessed from the question's length, its keywords, or the ordering of multiple-choice options alone? Natural-language inference datasets have famously leaked the label into the wording of one side of the pair, letting a model that never saw the other side score far above chance. If a no-op or majority-class baseline scores well above chance, the eval is at least partly measuring the artifact.

- **Label leakage in the prompt.** Check whether the expected answer, or a near-paraphrase of it, appears anywhere the model can see, in the prompt, the few-shot examples, the system message, a tool description, or a file the agent can read. Especially common in few-shot setups assembled by copy-pasting from the golden set.

- **Answerable from memory.** Check whether tasks about real, named entities (a specific person, repository, paper, or event) can be answered from a model's parametric memory even though the intent is to test a skill like retrieval or tool use. If the goal is to measure whether the model can *do the work*, the subjects need to be obscure enough, or synthetic enough, that recall alone does not carry the task.

- **Difficulty comes from the problem, not the prompt.** Check whether tasks that look hard are really just worded obscurely. If the underlying problem is easy once decoded, the score measures prompt-deciphering rather than the target skill. When difficulty lives mostly in the phrasing, suggest a rewrite that states the problem plainly and lets the problem itself be hard.

- **Agentic tasks: symptom, not investigation.** For tasks that ask an agent to diagnose or fix something, check how much of the investigation is handed over in the prompt. If the task description already includes the log line, the failing test name, or the relevant file, the eval measures whether the model can read a hint, not whether it can find one. Prefer giving the agent only what a user would plausibly report and letting it fetch the rest.

- **Realistic distribution and interaction shape.** Compare a handful of tasks to the user's actual production traffic or intended use case. Synthetic toy tasks often fail to predict behaviour on messy real inputs, and vice versa. Also check that the *shape* of the interaction matches: a single-turn question-answering eval will not capture gains (or regressions) that only appear in long multi-turn or agentic settings, and an agentic eval will not isolate single-step reasoning quality. Name any obvious divergence upfront so readers can calibrate how far the results will transfer.

- **Difficulty headroom.** If results exist, look at the score spread. If every strong model already scores ~95%+, the eval cannot discriminate at the top and any sweep will differentiate mainly on cost, still useful, but worth saying in advance. If every model scores ~0%, the eval reveals nothing about relative capability and more often than not has a task or grader bug.

- **Saturated evals and what they end up measuring.** Once an eval is near its ceiling, the remaining variance is often dominated by format quirks, tie-breaking in the grader, or mild reward-hacking rather than genuine capability differences. If a set has been near-saturated for a while, flag that the last few points may no longer measure what the eval was built for, and suggest adding harder items.

- **Class balance.** For classification-style evals, check the distribution of expected labels. A heavily skewed set lets a constant-prediction baseline look deceptively strong. Recommend reporting the majority-class baseline alongside model scores.

- **Both-directions coverage.** For evals that test a decision or behaviour, check that both the positive and the negative case are represented. An eval for "does the agent search when it should" also needs "does the agent *not* search when it shouldn't"; otherwise a model that always searches scores perfectly. One-sided evals produce one-sided optimisation. Apply the same check to refusals, tool use, escalation, and similar two-sided behaviours.

- **One capability per task.** Check whether a failing task tells you *what* failed. A task that requires retrieval *and* reasoning *and* formatting to pass will show 0 whenever any one of those breaks, which makes the score undiagnostic. Fine for a headline end-to-end number; flag it when the user wants to know *why* systems differ.

- **Inverted items as a smoke test.** When results are available, look for individual items where a clearly weaker system outscores a clearly stronger one. These items are far more often revealing a task or grader bug (an ambiguous label, an over-rigid match, a leaked hint) than a genuine capability inversion, and they make a good starting point for where to look closely.

- **Human baseline.** Ask whether anyone has measured what a competent human scores on this set. Without that anchor, it is hard to say whether 60% is impressive or embarrassing, or whether the remaining 40% reflect model limitations or task ambiguity.

- **Staleness.** If tasks reference live facts (prices, dates, API responses, current events, library versions), check when the golden answers were last verified. Correct answers drift; a model that gives the *currently* correct answer will be marked wrong against a stale key.

- **Dataset size vs. effect size.** Count the examples. Twenty to fifty realistic, fast-to-run examples are usually enough to start, early on, the differences you care about are large relative to noise. However, as the product matures more and more tasks should be added. For stable comparisons between closely matched systems, ~50+ cases per slice of interest with confidence intervals reported alongside the point estimate is a reasonable target. When the set is smaller, run multiple trials per example and report the spread.

- **For generated tasks: fix the generator, not the filter.** When tasks are produced by a pipeline (templated, synthetically generated, or model-written), problems found in the output are usually symptoms of something upstream. Patching individual bad items or adding a post-hoc filter tends to leave siblings of the same bug in place. Suggest adjusting the generator and regenerating.

## 2. Harness design

These checks concern the code that sets up, runs, and records each trial, everything around the model call. The central failure mode to watch for throughout this section is **conflation**: any time a non-model artifact (an infra error, a truncated response, a broken tool, a retry delay) lands in the same column as a genuine model result, the eval will attribute to the model something that belongs to the plumbing.

- **Clean, isolated state per trial.** Read the setup and teardown code. Check that each trial starts from a fresh environment: no files, database rows, git history, environment variables, or cached results left over from a previous trial or a previous task. Shared state lets one task's side effects leak into another's score, lets an agent read hints left behind by an earlier run, and makes results depend on execution order.

- **Environment is complete and functional.** Check that the environment the agent is placed in actually has what the task requires: dependencies installed, documentation present, services reachable, fixtures populated. A task that fails for every model because a package is missing or a fixture file was never committed is measuring the environment, not the model. Distinguish this from deliberate obstacles that are part of the task.

- **Deterministic setup.** Look for sources of nondeterminism outside the model: unseeded randomness, iteration over unordered sets or dicts where order matters, hash-randomised keys, timestamp-dependent paths, unordered directory listings, stochastic simulators without a fixed seed. These make scores vary run-to-run for reasons unrelated to the system under test. Recommend pinning a seed and sorting anything whose order reaches the model or the grader. This applies, for example, to adjacent ML systems that the agent might interact with. In the case of the LLM, it is good practice to set sampling parameters (e.g., temperature) to the same value you intend to use in production.

- **Infra failures distinguished from model failures.** Check how the harness handles a timeout, an out-of-memory kill, an API or rate-limit error, a parsing error on the model's output, a response truncated by the output-token cap, a tool that threw an exception, a sandbox that crashed, or a grader that itself failed to run. If any of these are silently scored as 0 (or as "pass," depending on the default) and mixed in with genuine model answers, the headline number is contaminated. The result schema should carry a separate status or error field, distinct from `passed=False`, so infra failures can be filtered, counted, and retried separately, and so the pass rate reflects only trials where the model actually produced a scorable answer.

- **"No answer" is not the same as "negative answer."** A specific and common conflation: check whether the harness and grader distinguish between the model *asserting a negative* ("there are no vulnerabilities in this code," "no matching records found") and the model *failing to produce an answer* (an empty response, a crash, a truncated stream, an unparseable output). If both paths land on the same label, an infra failure masquerades as a substantive model claim, and a model that errors out on every input can score identically to one that carefully analysed each case and correctly found nothing. Look for this especially in detection, classification, and retrieval evals where "none" is a valid answer.

- **Scaffold limitations are separated from model limitations.** When an agent scores poorly, check how much of that is the model and how much is the scaffold it was run in. A missing tool, an overly tight step or turn budget, a retry policy that gives up early, or a prompt template that drops part of the context can all look like capability gaps from the outside. Where practical, vary the scaffold while holding the model fixed (or vice versa) to attribute results to the right layer.

- **Token and context limits won't clip any task.** Find the longest prompt and the longest plausible correct answer in the set and compare against the configured context window and output-token cap. A model that runs out of output budget mid-answer is marked wrong for a harness-config reason, not a capability one, and the truncation is easy to misread as the model choosing to stop. Especially common in agentic evals where the trajectory grows over many turns.

- **Transient errors are retried.** Check whether the harness retries on rate-limit and overloaded responses. Unretried transient errors show up as spurious failures and can make one model, or one time of day, look systematically worse than another. Record the retry count per trial so retries can be excluded from latency metrics (see §3).

- **Eval config matches production config.** Compare the system prompt, tool definitions, model version, temperature, and any scaffolding in the eval against what actually runs in production. A very common failure mode is an eval that measures a different setup from the one being shipped, the eval says "fine," production says otherwise. Diff them explicitly.

- **Model and knobs are exposed, not hard-coded.** Locate where the model ID is set. If it is buried in the call site rather than passed in, the Phase 2 sweep will need a refactor first. Surface `model`, and ideally temperature, reasoning/thinking settings, and output-token cap, as top-level arguments to whatever "run the eval" entrypoint exists.

- **Full per-task trajectories are saved.** Check that the raw transcript, every message, every tool call and result, every error, is persisted per task, not just the final score. When a result is surprising, the transcript is what tells you whether it is a fact about the model or a bug in the eval; without it, a score is just a number. The grader's own inputs and outputs should be saved alongside pass/fail so failures can be spot-checked without re-running. This is the single highest-leverage habit for making an eval debuggable.

- **Multiple trials with variance reported.** Check whether the harness supports running the same task set several times (three or more is common) and reporting the spread. A single run gives a point estimate with no error bar; differences smaller than the run-to-run spread are not meaningful.

- **Statistical power for the question being asked.** Given the dataset size and per-trial variance, estimate the smallest pass-rate difference the eval can reliably detect. As a rough heuristic, a difference needs to be several multiples of the run-to-run standard deviation before it is worth acting on. If the user cares about 2-point differences and the eval's noise floor is 5 points, say so before any sweep.

- **Reproducible over time.** Check that dependency versions are pinned, the task set is versioned (so "v3 scored X" is a stable claim), and the environment is containerised or otherwise specified. Unpinned dependencies mean today's number and next month's number are not comparable even on the same model.

- **Harness tested on known-good and known-bad.** Check whether the harness has been run on (a) a model or oracle that *should* score near 100%, and (b) a random or null baseline that *should* score near chance. If the oracle doesn't pass, the harness or grader is broken; if random doesn't fail, the grader is too lenient.

## 3. Metrics hygiene

Pass rate alone rarely answers the question the user actually has, which is usually some form of "what is the best quality I can get for a given cost or latency?" Check that the harness captures the per-trial metrics below, and, just as importantly, that each one is computed in a way that reflects the model under test rather than the test rig around it.

- **Token accounting from the API, not estimated.** Check that input tokens, output tokens, and where the API exposes them, cache-read and cache-write tokens, are recorded per trial from the API response's usage block. Estimating token counts from string length is routinely off by enough to reverse a cost comparison.

- **Cost computed from recorded tokens.** Check that cost per trial is derived from the recorded token counts and the relevant per-token prices (including any separate rates for cached input, reasoning/thinking tokens, or tool use), rather than from a flat assumed rate. If the grader is itself an LLM, record its cost separately from the cost of the system under test so it does not dampen relative differences between sweep arms.

- **Prompt-cache hit rate is tracked and comparable.** If any arm of the comparison benefits from prompt caching, record cache-read tokens per trial and report the cache-hit rate per arm. When one configuration gets warm-cache pricing and latency while another runs cold, the cost and time-to-first-token differences are partly an artifact of run order or cache configuration, not model quality. Flag any comparison where cache-hit rates differ materially between arms.

- **TTFT and TTLT measured against the right boundaries.** Check that time-to-first-token is measured from when the *final, successful* request is sent to when its first token arrives, and time-to-last-token from that same send to when its last token arrives. Both should exclude: client-side retry loops and the backoff sleeps between them; time spent waiting in a local queue or semaphore before the request was actually sent; connection setup that would be amortised away in a real deployment; and any post-processing after the stream closes. If a request was retried three times with exponential backoff, the thirty seconds of sleeping is a fact about the test rig that day, not about the model, record it as wall-clock overhead, but keep it out of the model-latency column.

- **Output-tokens-per-second computed from clean interval.** Check that OTPS is computed as output tokens divided by (TTLT − TTFT) for the successful attempt, i.e., the decode phase only. Dividing by total wall-clock, including prefill, retries, and queueing, conflates throughput with everything else and will systematically penalise whichever arm happened to hit more transient errors.

- **Retries and errors recorded alongside, not inside, the core metrics.** Check that the per-trial record includes the number of attempts, the total wall-clock including retries and backoff, and the reason for each failed attempt, as *separate* fields from the clean TTFT/TTLT/OTPS above. Both views are useful, the clean metrics for comparing models, the wall-clock for understanding what a real user would experience, but collapsing them into one number loses the ability to tell which is which.

- **Per-turn and per-call breakdown for agentic evals.** For multi-turn or tool-using tasks, check that token counts, cost, and timing are recorded per model call and per tool call, not just as a single total for the episode. Otherwise a slow tool or an expensive retrieval step is indistinguishable from a slow or expensive model.

- **Metrics reported alongside quality.** Check that whatever report the eval produces puts pass rate, cost per success, and latency side by side (per arm), so quality-vs-cost and quality-vs-latency tradeoffs are visible rather than implied.

## 4. Grader design

These checks concern the function that turns a model output into a score, whether that is an exact match, a unit test, or an LLM judge.

- **Prompt-grader agreement.** Read a few prompt/grader pairs side by side and check that what the prompt asks for is what the grader rewards. A common drift: the prompt says "reach at least threshold X" but the grader only passes on strictly exceeding X; or the prompt asks for an explanation but the grader only checks the final number. Beyond mismeasurement, this penalises models that follow the instructions and rewards models that ignore them, which is the opposite of what most evals intend to encourage.

- **Grades outcomes, not paths.** Read the grader and check whether it rewards *reaching the right answer* or *taking a particular route*. A grader that requires an exact tool-call sequence, a specific phrasing, or a particular intermediate step will fail a model that solved the problem a different but valid way. Prefer checking that the answer is correct and appropriately grounded (the right source was consulted, say) without dictating the full trajectory.

- **Not overly rigid.** For exact-match or substring graders, check whether trivial surface differences cause false negatives: whitespace, casing, boolean or numeric formatting (`4` vs `4.0`, `96.12` vs `96.124991…`), markdown fences, units, thousands separators, or a full sentence wrapped around the answer. Re-audits of public benchmarks have moved reported accuracies by tens of points once grading rigidity was relaxed. Recommend normalising both sides before comparing, or accepting any of a small set of equivalent forms.

- **Not too lenient.** Conversely, for test-based or substring graders, check whether the checks are thorough enough to actually catch wrong answers. A function that passes three weak unit tests may still be wrong on every edge case, when community efforts added more tests to popular code-generation benchmarks, several models' scores dropped by double digits because subtly broken solutions had been slipping through. Write a deliberately wrong-but-plausible answer and confirm the grader fails it.

- **Cheat-resistant.** Think adversarially about how a model could satisfy the grader without solving the task: hard-coding the expected output, reading the answer key from disk, special-casing on test names, emitting an empty string that a lenient regex accepts, exploiting a loophole in a policy or rule set that the task author did not intend, finding a degenerate strategy that technically optimises the metric (a game-playing agent that pauses the game indefinitely to avoid ever losing), or injecting instructions into an LLM judge's input. Capable models stumble into these while searching for *any* passing path. Check that the grader and environment close them off.

- **Ground truth not reachable by the model.** Distinct from label leakage in the *task text*: check that the expected answers are not anywhere the model under test can read them, not in a file in the agent's sandbox, not in a repo the agent has checked out, not in commit history left over from task construction, not in a grader prompt the agent can see, and not in the web in case the agent has a web-search tool (unless that's the point of the task).

- **Spot-check the failures.** Sample a handful of predictions the grader marked wrong and read them. In many evals a surprising fraction of "failures" are correct answers the grader did not recognise. If more than roughly one in ten sampled failures look like grader errors, fix the grader before any sweep, otherwise the sweep partly measures which model happens to match the grader's blind spots.

- **Deterministic, or with measured variance.** Run the grader on the same prediction/expected pair two or three times. If the result changes, the eval has grader variance on top of model variance. Especially common with LLM judges. If grader nondeterminism is intentional, measure and report its variance separately.

- **Atomic checks over holistic scores.** Where the grader assesses multiple independent properties ("is it correct *and* well-formatted *and* concise"), check whether these are scored as separate binary checks rather than one blended number. Separate checks are more reproducible, easier to calibrate, and make failures diagnostic: {correct: yes, formatted: no, concise: yes} tells you much more than 0.6. Also, prefarably use separate independent LLM calls for each property/dimension.

- **Aggregation matches the question.** Check how per-item scores roll up into a headline number. Averaging is the right default for "typical-case quality," but for rare or high-stakes behaviours (safety violations, data deletion, irreversible actions), a fail-on-any-occurrence or worst-case aggregate often reflects what actually matters better than a mean diluted by many easy cases.

- **Partial credit and penalty structure.** When the grader awards partial credit or applies penalties (for extra steps, wrong tool calls, slow completion), check that the weights do not make a degenerate policy optimal. If the penalties for trying and stumbling outweigh the reward for eventually succeeding, "do nothing" becomes the highest-scoring strategy.

- **Handles large outputs.** Check that the grader will not truncate, time out, or crash on the longest output a model might produce. A grader that silently clips its input will mis-score long-but-correct answers; a grader that crashes is an infra failure and should be recorded as such (see §2), not as a model failure.

- **Grader is versioned with the tasks.** Check that the grader prompt, rubric, and any normalisation code are versioned alongside the task set. Scores from before and after a grader change are not comparable; if the eval reports trends over time, each data point should record which grader version produced it.

### When the grader is an LLM judge

LLM judges are convenient and often the only practical option for open-ended tasks, but they bring their own well-documented biases. When the grader calls a model, additionally check:

- **Position bias.** If the judge compares two responses side by side, check that A/B order is randomised per example (or each pair is scored twice with positions swapped and the results averaged). Judges systematically favour one position regardless of content.

- **Verbosity bias.** Check whether the rubric tells the judge not to reward length for its own sake, or whether outputs are length-normalised. Uncontrolled, judges reliably prefer longer answers even when the extra length adds nothing.

- **Self-preference.** Check whether the judge model is from the same family as any model under test. Judges tend to prefer outputs that resemble what they would have written. Using a judge from a different provider, or a jury of judges from different families with a majority vote, mitigates this.

- **Label deference.** Check that the judge is not told which response is the "reference," "baseline," or "human" answer. Judges defer to whatever is framed as authoritative, regardless of quality.

- **Concrete rubric, not vibes.** Read the judge prompt. "Which response is better?" leaves the criteria to the judge's priors and makes scores drift across judge versions. A rubric that lists specific, checkable properties ("Does the response include a runnable code block? Does it cite the requested source?") is more stable and easier to calibrate. (And again, separate independent LLM calls for each property is preferred)

- **Calibrated against human labels.** Check whether the judge has been validated on a sample (a few dozen examples is usually enough) that humans independently labelled, and what the agreement rate was. If judge-human agreement on clear-cut cases is well below ~90%, the judge prompt usually needs another iteration before its scores can be trusted for model comparisons.

- **Tested on known negatives.** Feed the judge a few obviously wrong answers (an empty string, "I don't know," a confident answer to the wrong question) and confirm it fails them. A judge that waves these through invalidates everything downstream.

## 5. Reporting findings to the user

The checks above are written as directives to Claude, but the audit report you hand to the human should not read as a list of directives. The person who built the eval almost always has context you lack, a constraint, a deadline, a deliberate tradeoff, and the purpose of the report is to surface things worth a second look, not to grade their work. Write accordingly:

- **Frame findings as observations and suggestions.** Prefer "something worth looking at is…", "you might consider…", "teams often find that…", "one thing that can cause trouble here is…" over "this is wrong" or "you must change this." State what you observed, why it might matter, and one concrete change that would address it, then let the user decide.

- **Distinguish severity.** Separate findings into (a) things likely to make the numbers actively misleading, e.g., infra errors scored as model failures, "no answer" conflated with "negative answer," ground truth the agent can reach, a non-deterministic judge, retries folded into latency, and (b) things that add noise or limit generality without flipping conclusions, e.g., a smallish dataset, a missing human baseline, a saturated item or two. Lead with (a).

- **Be specific and cite evidence.** Point at the actual file, function, task ID, or transcript line you are talking about. "Task 14's expected answer looks stale, the library changed its default in v3" is actionable; "some labels may be stale" is not.

- **Say when things are fine.** An audit that finds nothing wrong is a valid and useful result. If a section of the eval is in good shape, say so plainly rather than manufacturing a concern, and move on to the sweep with confidence.

- **Do not be preachy or exhaustive.** Report the handful of things that matter most for the decision the user is trying to make. Resist the urge to list every minor deviation from an ideal, it buries the important findings and reads as nitpicking.

- **Offer to fix, not just to flag.** Where a finding is a small code change (pin a seed, add a status field, normalise a string before comparison, log the usage block), offer to make the change rather than just describing it.

Two practices worth suggesting to the user as part of the report, regardless of what the audit finds:

- **Treat the eval as a living suite.** The most reliable evals are maintained like test suites: new failure modes discovered in production become new cases, saturated items are retired or hardened, and the grader is re-calibrated when it drifts. Frame the audit as the start of that loop rather than a one-time gate.

- **Use a strong model as a second pair of eyes on the eval itself.** Having a capable model read the tasks, the rubric, and a handful of graded transcripts, and asking it where a reasonable person might disagree with the label, is a cheap way to surface ambiguity the eval's authors have become blind to. The tier-3 per-task auditor in §1 is the scaled-up version of this idea: one isolated judgement per task, aggregated into a shortlist for human review rather than a substitute for it.
