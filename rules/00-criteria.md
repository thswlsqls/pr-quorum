# 00. Common rules — what all three stages follow

This file holds the rules that Stage 1, 2, and 3 **all** follow.
The seven things that vary by stage (target, axes, budget, challengers, dedup priority, extra invalidation conditions, exit) are in `01-stages.md`.
Axis definitions and each judge's "look at / do not look at" are in `profiles/<profile>.md`.

> **Path notation** — paths that point to harness files, such as `rules/00-criteria.md` or `scripts/…`, are relative to the plugin folder (rule documents live under `rules/`).
> Rule documents refer to each other by file name and section only (same `rules/` folder).
> Paths that point to state files, such as `runs/…`, `profiles/…`, or `learnings.md`, are relative to `~/.pr-quorum/`.
> Rule documents name scripts by name only. The skill body gives the actual path. Paths that point to the evaluation target, such as `api/auth/…` or `README.md`,
> are relative to the root of the target repository.

---

## 0. Invariants — read these first

> **The evaluation target is the PR. Do not change a single character of it.**
>
> The only place you may write is under `~/.pr-quorum/runs/<repo>-pr<N>/`. `~/.pr-quorum/learnings.md` is read-only; write what you learned as candidates in the same run's `learning-candidates.md`.
> The target repository's code, docs, and config are all read-only. This holds even when they are checked out in a worktree.
>
> **Only `scripts/pr-quorum.sh` writes to GitHub.** The session does not post directly with `gh api`.
> The session does not hold the bot token — the script reads it internally.
>
> **Judges and verifiers write no files.** Their only job is to return results as text.
> Use `Bash` only for lookups such as `grep`, `wc`, `jq`. Do not use redirection, `sed -i`, `mv`, or `rm`.

---

## 1. Invalidation conditions — a finding that meets any of these is invalid

**These 8 apply to every stage.** Extra per-stage conditions are in the `Invalidation conditions` row of the spec table in `01-stages.md`.

| # | Condition | Result |
|---|---|---|
| **I-1** | **No evidence.** Every finding carries a `file:line` anchor. You must have actually opened that line and checked it | invalid |
| **I-2** | **Anchor outside the diff.** A line not in the pinned-SHA diff cannot carry an inline comment. If the finding holds, move it to the summary body. **If one anchor is off, GitHub rejects the whole review with 422** (measured) — it does not just drop that one comment | inline invalid |
| **I-3** | **Claim exceeds its source grade.** A claim beyond what the A–D grades in §4 allow is invalid. In particular, use **grade B (official docs) only where the quoted text alone supports the conclusion**. Do not quote from memory | invalid |
| **I-4** | **On the frozen list.** To overturn a fact settled in `runs/<…>/frozen.md`, you must give *new evidence that the settlement was wrong* | invalid |
| **I-5** | **Belongs to another axis.** Follow each axis's "do not look at" in the profile | invalid |
| **I-6** | **Taste without grounds.** If `CLAUDE.md` or the eslint config supports it, it can be `suggestion` or higher. Pure preference with no grounds goes up to `nitpick` at most | grade cap |
| **I-7** | **Something the file never set out to contain.** Follow the adjustment table by file type in §5 | invalid |
| **I-8** | **The author can show it is an equivalent alternative.** If data or engineering grounds show the two are equivalent, accept the author's preference | invalid |

> **Invalidation conditions in the original that we do not use** — the original's `§4 five forbidden claims` and `sources.md ⚠ citation strength cap`
> are tied to assignment-specific assets and cannot be carried over. **I-3 (source grade) alone takes over their job.**
> That makes V2 (the citation verifier) more important than in the original.

If you are not sure, do not raise a finding; write it under `unverified concern`. **`unverified concern` stays in `runs/` only and is never posted.**

---

## 2. Counting and verification rules

- Count numbers in a way that **does not truncate**, such as `grep -c`. Do not count the lines of output cut by `head`.
- **When confirming that something is absent, sweep with a broad pattern first, then narrow down.** A false "it exists" gets filtered at the next step,
  but a false "it does not exist" goes straight through as a wrong call.
- Check line anchors by **actually opening that line** with `Read`'s `offset`/`limit`. Do not guess.
- **Compute** numeric claims yourself and write the formula. Distinguish "theoretical maximum" from "actual".
  **Negative counts and universal phrases such as "0 cases", "no mismatch", "all" are numbers too.** If you checked a sample, say it was a sample. To write a universal claim, count everything.
- **The aggregator does not take judge reports on trust.** For any evidence to be posted, the aggregator opens the anchor again and re-checks it.
  A sentence that summarizes a judge report, a sentence that carries an author reply into a reply, and an example the aggregator added while re-checking are all **newly written sentences** and need the same re-check.
  Re-checking is not only anchors. **For numbers in the post text, the aggregator re-runs the command and counts again, whoever reported them — judge, challenger, or verifier** —
  `grep -c` counts matching lines, not logical units such as methods or calls. **Path statements such as "X turns into Y"** are written by following
  the call chain (handler → called method → return line) with `Read`, not from grep match lines. When the same name appears in two methods, the match lines are not an execution path.

---

## 3. Grades and labels — no scores

| Grade | Meaning | GitHub label |
|---|---|---|
| **`critical`** | Requirement not met · data is wrong · spreads into an outage | `issue (blocking)` |
| **`major`** | Forces rework, or breaks under the stated traffic | `issue (blocking)` / `issue (non-blocking)` |
| `minor` | An alternative is better, but the current code is valid — non-blocking | `suggestion` |
| `nit` | Taste · naming · formatting — non-blocking | `nitpick (non-blocking)` |
| — | Praise | `praise` (at least 1 required in a Stage 1 post) |

**Do not use points, deductions, totals, or pass marks.** The evaluation target does not change, so a score would be a constant every round,
and a constant is not a check. Only the four grades remain in the verdict.
The order `J1`–`J4` is used only as **dedup priority**, not as a score.

The question is not *"is this the ideal design?"* but *"does this make code health worse?"*

**`minor` and `nit` are posted, but they do not go into the summary's blocking order table.**

### F9 grade adjustment — limits the target states itself

A defect that comes from a **limit stated in advance** in the PR description, a `TODO` comment, or a design doc is **downgraded one step** (`critical` → `major`).
This is not an exemption; it reflects the cost of undoing it.

### Bundled findings

If one finding holds two or more strands, **have each strand challenged separately, and re-grade by the number of strands that survive.**
Only lower the grade — since we use no deduction numbers, the original's "bottom of the downgraded grade" rule does not carry over.

### Split comments or bundle them

**Defects resolved by the same fix plan go in one comment.** One comment holding several defects is normal.
"The files to change are different" is not enough reason to split; split only when the author **may fix one side alone**.

---

## 4. Source grades — how far you can claim

| Grade | What | How far you can claim |
|---|---|---|
| **A** | Repository norm documents — `CLAUDE.md` · `README.md` · `settings.gradle`·`build.gradle` · tracked `docs/reference/design/` | Use as evidence as-is |
| **B** | Official docs — Spring Boot / Next.js / Redis / Kafka docs looked up through the context7 MCP | **Only where the quoted text alone supports the conclusion.** No quoting from memory |
| **C** | Code fact — `file:line` | Up to a statement of fact. The size of the impact is a separate claim |
| **D** | Measurement — a command written together with its output | Strongest evidence |

**When using grade B, copy the quote verbatim, and check separately whether that quote alone supports your conclusion.**
Having the exact words is necessary, not sufficient. V2 checks this point.
**The same holds for praise and for the per-axis verdict sentences in the summary.** They have no evidence column, so the quote is easy to drop. A sentence that says
"AWS or a library does X", not "the code does X", either carries the quote with it or is narrowed to a code fact (C).

Write `not measured` for anything you did not measure. Do not dress up a guess as a measurement.

---

## 5. Adjustments by file type — do not mark down a file for what it never set out to contain

| File kind | Axes you can raise | What you cannot raise |
|---|---|---|
| Production code | All axes | — |
| Tests | Mainly R-G; R-H · R-I possible | R-C·R-E·R-D inside test files |
| Design docs (`docs/`·`README.md`) | Mainly R-A; R-B if it disagrees with the code | R-G·R-E·R-C |
| Config (`build.gradle`·`docker-compose.yml`·`package.json`) | R-F · R-H · R-I | R-A·R-B·R-C |

This table is also used as-is for the "applicable axis" call in Stage 1 exit condition S1 —
if the PR only touched config files, R-A·R-B·R-C were never applicable axes.

---

## 6. Comment body format

### Write two lines before writing the paragraph

1. **What action will the author take after reading this?**
2. **If the author pushes back on me here, with what?**

**If you cannot write line 1, do not write the paragraph.** Adding true sentences and making the review better are different things.
Writing line 2 down lets you address that pushback inside the paragraph first.

### Four-part body

1. **What the code does** — "This code does X". Aim it at the code, not the person ("why did you do this").
2. **What happens as a result** — the impact. Tie it to the spec or traffic conditions where possible.
3. **Evidence** — one of A–D from §4. State the grade with it.
4. **Direction** — an alternative, or at least a direction. Do not leave only the problem.

### Posting format

The first line of an inline comment body has this format.

```
**C-01** `issue (blocking)` · R-B (Data correctness)
```

**Write the axis name along with the code, not the code alone.** With only `R-B`, the author has to open the profile document to learn which axis it is.
A comment is read and judged by the author on the spot, so the meaning of the axis must be in the body.

Use the axis name **exactly as written in the profile's §1 axis definition table**. The same code has different names in different profiles
(e.g. `R-C` is `Concurrency & atomicity` in backend and `State races` in frontend).

If one comment covers two axes, join them with `·`.

```
**C-10** `issue (blocking)` · R-D (Interface contract) · R-B (Data correctness)
```

If any of code, label, axis code, or axis name is missing, PG5 catches it.

### Put an axis legend in the summary body once

Even though each comment carries the name, the summary's blocking order table has narrow cells and fits only the code.
So place a **code ↔ name table once** somewhere in the summary. Take it as-is from the profile's §1 axis definition table.

| Code | Axis | Code | Axis |
|---|---|---|---|
| `R-A` | Design–implementation consistency | `R-E` | Load fitness |
| `R-B` | Data correctness | `R-F` | Failure isolation |
| `R-C` | Concurrency & atomicity | `R-G` | Tests |
| `R-D` | Interface contract | `R-H` | Maintainability |
| `R-I` | Security | — | — |

(The above follows the backend profile. In frontend, `R-C`·`R-E` have different names and there is no `R-I`.
`R-I` is a conditional axis, so include it in the legend **only in rounds where it fired**.)

**Write all GitHub text in the language of the PR title and description. If unclear, use English.**

### Pre-post edit — cut once right before posting

The body only grows as evidence is added. Cut it once right before posting.
**Apply this equally to comment bodies, the summary, thread replies, and correction bodies for existing comments** — every piece of text going to GitHub.
When it runs and how it is compared is in `01-stages.md` §3-4 · PG6.

Remove

- Repetition. If two of the four parts say the same fact in different words, merge them into one.
- Re-quoting code that is plainly visible in the diff. The anchor already points at that line. Keep it **only when you must show a flow across several lines**.
- Hedges — words that soften a claim ("might", "seems to", "there is a possibility that"; e.g. in Korean: `~일 수 있습니다` · `~로 보입니다` · `~할 가능성이 있습니다`).
  State what you checked as fact; what you could not check is not posted in the first place (§1).
- Background. The author knows their own code. Remove openers like *"Since this project uses CQRS…"*.
- Harness-internal terms — round · judge · challenger · verifier · confirmed defect · budget. They mean nothing to the author.
- Over-emphasis. At most two `**` spots per comment.

Must keep — if any of these changes, it is a rewrite, not an edit

- The whole first line — keep the code, label, axis code, and axis name from "Posting format" above exactly as they are
- Anchor (`path`·`line`·`side`) · grade · axis
- The evidence's `file:line`, grade B quotes **verbatim**, numbers and formulas
- Part **② What happens as a result** and part **④ Direction** — shorten them but do not remove them. Without the two, the author has nothing to do.
- Praise comments

Length targets — these are targets, not caps. If there is reason to exceed them, exceed them and write the reason in the round log.

| What | Target |
|---|---|
| Comment body | 10 lines or fewer excluding the first line. 1–2 sentences per part |
| Summary overview | 5 lines or fewer |
| Summary blocking order table | One row is one line — no line breaks inside cells |
| Thread reply · correction body | 5 lines or fewer. One verdict line + one or two evidence lines + one line on what remains |

**If the meaning is at stake, keep it long.** If shortening blurs the impact or the fix, the edit has failed.

---

## 7. Fix safety — even a correct finding can carry a fix that creates a new bug

- Challenger question ⑥ (**"what happens if this fix is applied?"**) runs only on findings raised by judges.
  **For fixes in comments the aggregator wrote itself, the aggregator applies ⑥ itself.**
- **Compare the fixes in the same pass against each other** — look for places where following both comments would be wasted work or create a new defect (PG3).
- **Cross-check outputs** — read the posted comment and the reply you are about to write side by side. The author sees both side by side in the thread.
- **Whole-pass check — "do the premises behind the grades I gave in this pass agree with each other?"** Grades are set one comment at a time, but
  premises span the whole pass. Look for the same property given different grades, or a comment that builds a blocking finding
  on a premise another comment called unreachable. **Run it once right before posting** — if you don't, V3 catches it instead.
