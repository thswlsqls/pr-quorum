# 03. Auto-merge risk score

The chain (`scripts/chain.sh`) takes a PR whose review, fixes, and re-review are done all the way to merge when `auto_merge` in `~/.pr-quorum/config.json` is true.
But a PR whose blocking findings are all resolved is not automatically a PR nobody needs to look at.
In a PR that touches authentication code or infrastructure, one thing the review missed can turn into an outage.
So right before merging, the chain scores **how much it would hurt if this PR were wrong** from 0 to 100, and when `auto_merge` is on, it auto-merges only low-scoring PRs.

The calculation is `scripts/risk.jq`, the call is `pr-quorum.sh risk <repo> <PR-number>`, and the follow-up tracking is `scripts/risk-audit.sh <repo>`.

## How this differs from review grades

The review side does not use scores (`00-criteria.md` §0). A total score makes the author argue with the score instead of fixing the code.
The risk score does not measure whether the code is good or bad. It looks only at **where and how much was changed**.
So polishing the code does not lower the score; only splitting the PR or adding tests with it does — there is nothing to argue with.

Review results (remaining blocking findings, `regressed`, test failures) do not go into this score. The chain's merge gate stops those first. The same signal is not counted twice.

## Scorecard

| Category | Cap | Signals (points) | Why |
|---|---|---|---|
| **Security** | 30 | Authentication/authorization code (15) — production code under `common/security/` or whose name contains `Security`, `Auth`, `Jwt`, `OAuth`, `Cors`, `Password`, `Permission`, `Role`, `Bcrypt`, `Principal`, `Credential`, `Refresh/Access/SecureToken`, or `ApiKey`; the Gateway's `filter/`; on the frontend, `middleware`, `proxy`, `lib/auth*`, `cookie-config`, `/api/bff/auth/`<br>credentials-secrets (30) — `.env`, `.pem`, `.key` files, and newly added `password: value` or `secret-key: value` style entries in config files (`.yml`, `.json`, `.properties`, etc.)<br>Auto-merge gate/harness (15) — everything under the top-level `skills/`, `agents/`, `rules/`, `templates/`, `.claude-plugin/` (rule documents included), plus a name list of the plugin scripts under `scripts/` (`pr-quorum.sh`, `chain.sh`, `watch.sh`, `dream.sh`, `selftest.sh`, `risk-audit.sh`, `gh-get.sh`, `author-push.sh`, `author-reply.sh`, `config.sh`, `doctor.sh`, `token-scan.sh`, `risk.jq`). Same-named folders deeper in the tree (`src/main/resources/templates/` etc.) do not count<br>Agent instructions/CI/build scripts (15) — `CLAUDE.md` and `AGENTS.md` (in any folder), everything under `.claude/`, `.github/workflows/`, `Jenkinsfile*`, build definitions and wrappers the build tool runs (`*.gradle`/`*.gradle.kts`, `gradle.properties`, `gradle/wrapper/`, `gradlew`, `pom.xml`, `mvnw`, `.mvn/wrapper/`, `pyproject.toml`, `setup.py`)<br>Dependencies (10) — `*.gradle`, `package.json`, `pom.xml`, `pyproject.toml`, `setup.py`, `requirements*.txt`, `go.mod`, `Cargo.toml`, lock files (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `poetry.lock`, `uv.lock`, `Cargo.lock`, `go.sum`, `.terraform.lock.hcl`)<br>Infrastructure permissions (IAM) (15) — `.tf` files that change IAM | An incident here leaks data or compromises accounts. Weighted heaviest |
| **Breaking changes** | 25 | API contract (15) — controllers, request/response DTOs<br>DB schema (entities/documents) (15) — `*Entity`, `entity/`, `document/`<br>Configuration/environment variables (10) — `application*.yml`, `docker-compose`, `Jenkinsfile*`, workflows<br>Event contract (10) — `common/kafka/`, `*Event` | Other services or deployment environments break without knowing this PR's assumptions |
| **Hard-to-reverse changes** | 15 | DB migration (15) — `.sql`, `migration/`<br>Infrastructure (Terraform) (15) — `.tf`, `.tfvars` | Reverting the merge does not bring back a schema or infrastructure that was already applied |
| **Tests** | 15 | Production code changed with no test changes (15) — production code that can have tests (`.java`, `.ts`, `.py`, `.go`, etc.; `.tf`, `.sql`, `.sh`, and `.rs` — whose unit tests sit in the same file — excluded) changed with no test file changes. Test files are `src/test/`, `__tests__/`, `*Test(s).java/kt`, `*.test/spec.[jt]s(x)`, `test_*.py`, `*_test.py`, `*_test.go` | Nothing catches it if the same thing breaks again |
| **Scope** | 15 | Changed lines excluding tests, docs, and the npm and Terraform lock files — 0 up to 100 · 5 up to 300 · 10 up to 800 · 15 above that | Review cannot keep the same density through a large PR. Pushes toward small PRs |

Within a category, signal points add up but do not exceed the cap. The five caps sum to 100.
Documents (`*.md`, images, `.drawio`, top-level `docs/` and `contents/` (a folder with the same name deeper in a code path, e.g. `src/.../contents/auth/`, is not a document)) count toward no category, with three exceptions. Secrets count even in document paths. Rule documents under harness paths (`rules/`, `skills/`, etc.) are run-time rules the session follows as written, so they count toward the harness signal. Only `scripts/` is counted by the plugin script name list instead of the whole folder — the reviewed repositories have their own `scripts/` (backend `scripts/jenkins/` and `scripts/tmux/`, frontend `scripts/tmux-*`), so matching the folder would give unrelated PRs 15 points. Documents under `CLAUDE.md`, `AGENTS.md`, and `.claude/` count toward the agent instructions signal for the same reason.

The harness signal exists to stop PRs that loosen the gate itself. The author session can push to the PR branch, so without this signal a small PR that edits `risk.jq` would auto-merge at 0 points `low`. At 15 points, this signal alone moves a PR out of `low`.

The agent instructions/CI/build scripts signal is 15 points for the same reason. A change to `CLAUDE.md` or `.claude/` changes the instructions and permissions of every session started afterwards, and CI config and build definitions (Gradle, Maven, Python packaging) run as-is at build time. CI config and Gradle used to be 10 points, so a PR changing only those could auto-merge as `low`, and `CLAUDE.md` counted as a document at 0 points. `*.gradle`, `pom.xml`, `pyproject.toml`, `setup.py`, workflows, and `Jenkinsfile*` also hit the dependency or configuration signal, for 25 points.

## Levels and handling

| Level | Score | What the chain does |
|---|---|---|
| `low` | 0–14 | **Auto-merge** if `auto_merge` is true and every other merge gate passes |
| `medium` | 15–39 | Does not merge; stops at `needs-human`. One person checks it and merges manually |
| `high` | 40–69 | Same. Someone who knows the flagged categories reviews it (e.g. for security, someone who knows the authentication code) |
| `critical` | 70+, **or a plaintext secret regardless of score** | Same. For a secret, remove and rotate it, then review again. Otherwise, first decide whether to split the PR |

The chain only distinguishes `low` from the rest. If `auto_merge` is off (the default), even `low` is not merged; the chain stops at `ready` and a person merges. The distinctions above `medium` are left for people to decide whom to call.
Regardless of level, the bot posts the scorecard as a comment on the PR. It does not post twice for the same head and score, and posts again if a rule change alters the score.
The result is recorded in `meta.json` under `risk`.

## What was taken from the video and what was decided differently

The scorecard's skeleton follows the video in the sources below, but the video itself says the scorecard is not an absolute standard and should be adapted to the repository.
Where copying it as-is turned out wrong against this repository's past PRs, it was changed.

| Video | Here | Reason |
|---|---|---|
| An LLM scores against a rubric | A jq script scores from paths and line counts | It can only serve as a gate if the same diff always gets the same score. It also matches the principle that the chain decides merges from records, not from the session's self-report |
| Review results mix into the risk score | Review results go to the merge gate; this score covers only where and how much changed | The same signal is not counted twice |
| Migration category | Widened to "Hard-to-reverse changes", including Terraform | This repository has no migration files, and the hard-to-reverse changes were actually infrastructure (#43) |
| The speaker's personal threshold of 30 | 15 | Follows the same video's "start conservative" |
| Security when an auth **directory** changes | Only files whose names reveal a security role, plus `common/security/` | Matching by directory would make a 2-line bean registration in `api/auth` (#38 `ServerConfig`) count as authentication code. Matching `Token` alone caught the chatbot's LLM token metering (#30 `TokenService`), so prefixes were added |
| Scope is PR size | Test lines are not counted | Otherwise writing more tests raises the score. In #34, 452 of 722 lines were tests |
| Penalty for no tests | `.tf` and `.sql`, which cannot have tests, are excluded | This repository's infrastructure has no test tooling. Its risk is already counted by "Hard-to-reverse changes" |
| Secrets are one part of the security score | A hit means critical regardless of score | A committed password is not a high-risk change but a change that must not be merged |
| Only label for the first 1–2 weeks | Not adopted. Instead, `risk-audit.sh` counts after the fact | Initially the default behavior was set to merge. In exchange, there is a way to check from records whether auto-merge was wrong. Now the default is off, and it turns on only when `auto_merge` in `config.json` is true |

## Results against past PRs (2026-10-02)

| PR | What | Score | Level | Signals hit |
|---|---|---|---|---|
| #8 | Diagrams and images | 0 | low | - |
| #22 | Intent classifier fix + tests | 0 | low | - |
| #30 | Token metering + tests | 0 | low | - |
| #34 | New-tech bulk save refactor + tests | 5 | low | Scope 270 lines |
| #33 | Bookmark report API · 2 entities | 35 | medium | API contract · DB schema · Scope 654 lines |
| #38 | api-auth Mongo config | 50 | high | Agent instructions/CI/build (`build.gradle`) · Dependencies · Configuration · No tests |
| #43 | ECS blue/green (Terraform) | 50 | high | Dependencies · IAM · Infrastructure · Scope 494 lines (224 lock file lines excluded) |
| #36 | Remove plaintext credentials · CORS | 30 | medium | Authentication code (`SecurityConfig`) · Infrastructure (`services.tf`) |

The scores in the table are re-scored under the current rules. #34 was merged under the rules from before test lines were removed from scope, and the score the bot posted then was 10 points `low` (scope 722 lines, test lines included).
#38 was auto-merged by the chain before this score existed, and #43 was also an auto-merge candidate (a person added commits outside the chain, so it hit the merge gate). Under the current rules, a person reviews both.

## Threshold tuning — counting from records whether auto-merge was wrong

Whether this score predicts real risk is not yet proven. Scoring past PRs and checking that the results look plausible is not the same as confirming the predictions.
So for each merged PR, it counts whether **a `fix` or `revert` PR touching the same files within 14 days after the merge** followed.

```bash
risk-audit.sh <repo> 30   # the 30 most recent merged PRs
```

It reports each PR's level, score, whether the chain auto-merged it, and follow-up PRs, plus per level "Merged / With follow-up fixes / Watching". A PR less than 14 days old with no follow-up yet is `watching` and is excluded from the first two columns — counting PRs with no outcome yet as "0 follow-ups" would tilt toward raising the threshold.
Levels and scores are **re-scored under the current rules**, not the result at merge time. Changing the rules changes past PRs' levels too. The auto-merge column only looks at `~/.pr-quorum/runs/` records, so it shows `-` when there is no record.
A follow-up PR does not mean the original PR was wrong — open it and judge. Tuning works like this.

- When a `low` PR gets a follow-up fix, **first check whether the path patterns caught that file**. If not, it is a pattern defect; fix it right away.
- If the patterns caught it and it was still `low`, note that signal's weight as a candidate for raising. Raise it **when the same type shows up twice** — raising it for one case makes a rule fitted to that PR.
- If `medium` and above keep getting 0 follow-up fixes, that is grounds for raising the threshold. Do not raise it before samples accumulate.
- When a person reviewing a PR stopped at `needs-human` finds a defect the bot review missed, add a line to the table below. If there was none, write "0 missed". This is the only record that measures, by a human standard, what the bot review actually misses.
- **The same goes for PRs the chain auto-merged.** After the merge, a person reads the diff and the bot review once and records it in the same table. Auto-merged PRs are exactly the PRs no person looked at.
- **When to turn off auto-merge** — if a person finds even one critical or major defect the bot missed in an auto-merged PR, turn off `low` auto-merge until the cause is understood (set `auto_merge` in `~/.pr-quorum/config.json` to false). Unlike weight tuning, this criterion moves on a single case — it means a missed defect went straight into main.

### Observation log

| Date | What was seen | What was done |
|---|---|---|
| 2026-10-02 | 20 most recent merges. 1 of 12 `low` PRs (#17 → #20) got a follow-up fix. #20 reverted the `disableConcurrentBuilds()` that #17 added. 0 follow-ups for the 8 `medium`/`high` PRs | The pattern (`Jenkinsfile$`) missed #17's `Jenkinsfile-cicd` → changed to `Jenkinsfile[^/]*$`. Even after the fix it is `low` at 10 configuration points. With a sample of 1, the weight stays and it is only noted as a candidate — **CI/deployment config changes** |
| 2026-10-02 | Rule review (rebuttal-based evaluation per criterion). Defects found against repository files, not records | Added `secret-key` to secrets (the JWT signing key name); excluded `.http` from the secret check (about 30 lines of test request bodies matched, making #36 critical over a secret that did not exist); added the harness signal; added Gateway `filter/`, `ApiKey`, and frontend auth files; dropped the `*Document` suffix (`WebSearchDocument` false positive); excluded `.sh` from the test signal; excluded lock files from scope. #36 became 45 high, #43 became scope 494 lines, and the other rows stayed the same |
| 2026-10-04 | Security review. `CLAUDE.md` was 0 points and CI config/Gradle 10 points, so a PR changing only those could auto-merge as `low` | Added the agent instructions/CI/build scripts signal (15). #38 went from 35 medium to 50 high and #17 from 10 low to 25 medium; the other rows stayed the same. This also resolved the "CI/deployment config changes" candidate from the first row |
| 2026-10-23 | The document check matched `docs/` and `contents/` anywhere in a path, so authentication code under them (e.g. `src/.../contents/auth/JwtAuthFilter.java`) scored 0 points `low` | Limited the check to top-level `docs/` and `contents/`, and added fixed risk cases to `selftest.sh` |
| 2026-10-23 | Build, dependency, and test files of stacks other than Gradle and npm were invisible — a PR changing only `pom.xml`, `pyproject.toml`, `go.mod`, or `Cargo.toml` got 0 build and dependency points | Added Maven, Python, Go, and Rust build and dependency files, `test_*.py`/`*_test.py`/`*_test.go` as test files, and `.go` as testable code. The new lock files were not left out of scope, so scope points of already-scored PRs do not drop |

## What this score cannot see

- **It looks only at paths and line counts.** A PR that removes an authorization check from an ordinarily named service gets 0 security points. Catching that is the review's `R-I` axis's job, and if blocking review findings remain, the merge gate stops it first. Widening the name patterns, on the other hand, catches unrelated code — between the two, false negatives were chosen.
- **Changes only to exception handlers or service validation rules are not scored.** If the author session, while fixing, changes status codes or input validation rules without touching controllers, DTOs, or entities and updates the tests along with it, the PR can merge as `low`. If such follow-up fixes show up twice, add patterns then.
- **It does not distinguish new APIs from changed ones.** Creating a new controller also gets API contract points. Left wrong on the conservative side.
- **Frontend code changes are almost always `medium`.** `app/` and `admin/` have no test tooling yet, so the 15-point "no tests" applies. This is intended — code without tests gets a human look. Revisit once a test runner is added.
- **Some argue against merging without a human reading the code at all.** Dex Horthy of HumanLayer says that removing human review increased incidents, and that because models do not yet know what maintainable code looks like, review bots cannot fill the gap (AI Engineer talk "harness engineering is not enough", Korean-subtitled version https://www.youtube.com/watch?v=-c43cv80FiA). `low` auto-merge knowingly goes against this view. That is why the "When to turn off auto-merge" criterion above exists.
- The weights 30/25/15/15/15 are not grounded values but a starting point fitted to the video's frame. They are adjusted through the "Threshold tuning" records above.

## Sources

실밸개발자, [코드 리뷰가 병목이 되는 이유 | 메타 시니어 엔지니어가 AI 코드 리뷰 하는법](https://youtu.be/Be5b6D1IoLI) ("Why code review becomes the bottleneck | How a Meta senior engineer does AI code review", in Korean) (2026-09-26) —
8:32 risk score rubric, 11:25 action matrix by risk, 14:30 the section on safety guards before adoption.
The video's subtitles are auto-generated, so verifying the quoted numbers (30 points for security, threshold of 30) at those timestamps is recommended.
