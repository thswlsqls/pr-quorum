# Changelog

## 0.15.2

No new `config.json` keys.

- Fixed two wrong section references the orchestrator followed: the Phase 5 row of `rules/01-stages.md` points to the §10 signal table (was §7, the posting gates), and the A/B note points to `00-criteria.md` §6 (was a bare §6, which in that file is SHA pinning).
- The review skill names the pair PG2 compares (`summary.md` and the comment bodies in `comments.json`), and its paste rule now carries the `CLAUDE.md`/`REVIEW.md` exception from `01-stages.md` §3-1.
- Removed two sentences that were given twice: the "ideal design / code health" line judges received from both `00-criteria.md` §3 and `02-judges.md` §1, and the challenger ⑥ rule repeated in `00-criteria.md` §7 (kept in `02-judges.md` §5).

## 0.15.1

No new `config.json` keys.

- `doctor.sh` warns when a repository has no `commands`, no `gradlew`, and a `package.json` without a `tsconfig.json`: the auto-detected test is `tsc --noEmit`, which fails in a JavaScript repository, so set `repos.<name>.commands.test`.

## 0.15.0

No new `config.json` keys.

- The chain records on each session in `chain.sessions[]` how many subagents it launched (`subagents`), counted from the transcripts Claude Code keeps under `~/.claude/projects/` (`null` when the session's transcript is not found). After the merge gate, a Stage 1 whose sessions launched no subagents stops the chain at `needs-human` ("Stage 1 ran without judges (0 subagents) — a person checks the review"); an unknown count does not block. Stage 1 is not rerun, since it has already posted.
- The merge gate reads the test result from the newest author pass that ran tests, so a later pass with nothing to answer (`tests.result: "skip"`) no longer hides an earlier `fail`.

## 0.14.1

No new `config.json` keys.

- `pr-quorum.sh learnings` stops before the `## Already in the rules` section of `learnings.md` (older files: `## 규칙에 이미 박은 것`); a file without that heading prints whole. Dream sessions still read the whole file.
- Review sessions run `init`, `lock` and `sha` as one Bash call joined with `&&`, then `ranges` on its own; the skill says not to append `echo $?`, `cd` or shell variables, which chain permissions deny, or `;`, so a failing step stops the call.
- `rules/01-stages.md` no longer spells out the commands `pr-quorum.sh pg6` runs, and its `meta.json` schema lists only the fields sessions read or write; `lock` and `attempts` are described in `docs/harness.md`.

## 0.14.0

No new `config.json` keys.

- When a PR's base is the repository's default branch, judges, challengers and V1–V3 get the target repository's root `REVIEW.md`, read from the base commit (`git show <base_sha>:REVIEW.md`), never from the PR. It may name paths to skip, lower the `minor`·`nit` cap, describe failures to grade higher, and add checks per axis; it cannot lower a grade, raise the budget, or change invalidation conditions, gates, the risk score or the merge gate (`rules/00-criteria.md` §0). V1 checks that the review followed it. Subfolder `REVIEW.md` files and `@` includes are not read. Example in `examples/REVIEW.md`.
- Each item in the author's `declined[]` has a `kind`: `wrong`, `intentional` or `out-of-scope` (pre-existing declines are `out-of-scope`).
- `dream.sh` reads the author's `declined[]`, counts declines by kind (`unknown` for items without one), flags an axis declined as `wrong` or `intentional` in two or more PRs, and has a new kind `move to lint/test` for a finding repeated across PRs that a grep or lint rule could express; it drafts the rule or test for a human to move into the target repository.
- `rules/03-risk.md`: a missed-defect row in the observation log ends with a `missed-by:` tag naming the layer that should have caught it.

## 0.13.0

No new `config.json` keys.

- A comment on a defect that is a pattern lists every place in the diff with the same pattern and the command that found them ("0 others" when there are none); places outside the diff go on their own line and the author does not fix them. The author fixes every listed place in the diff.
- Stage 1 can mark a defect the PR did not introduce as pre-existing: the same defect is at the base commit and the PR's change does not reach it. It keeps its grade, is labelled `issue (non-blocking) · pre-existing`, goes in the summary's pre-existing section (at most 3), and stays out of the blocking table and `blocking_open`; the author declines it with a reason starting "pre-existing". A pre-existing `critical`·`major` always gets a challenger. Stage 2 and 3 do not use the mark.
- `post-review` records `pre_existing` (from the comment's first line) and `base_anchor` on Stage 1 comments and summary items; PG6 compares both. After the merge gate, a pre-existing `critical` or `major` stops the chain at `needs-human` ("pre-existing defects near this PR: …").
- PG5 fails a `pre-existing` first line labelled `issue (blocking)`, and no longer asks a pre-existing `critical` for that label.
- `pr-quorum.sh init` copies the PR description into `meta.json` as `eval_body` when it sets `eval_sha` (again on `--reset-eval` or a new `eval_sha`, not on the same one). In Stage 2·3, F9 downgrades only for limits stated by Stage 1 — `eval_body` and the `TODO` comments and design docs at `eval_sha` — so a limit the author writes into the description after the review no longer lowers a grade. Old runs with no `eval_body` do not use the description in Stage 2·3.
- The Stage 1 summary's first line starts with the blocking count; PG2 checks it against the body.

## 0.12.0

New optional `config.json` key `repos.<name>.always_human`. Without it the chain behaves as in 0.11.0.

- `repos.<name>.always_human` lists path prefixes (no globs) that always go to a person. A PR touching one, at its new or old path, is raised from `low` to `medium` and stops at `needs-human`; higher levels and a secret's `critical` are unchanged, and so is the score. The risk `override` names the prefix and a file, joined with `; ` to the secret reason when both apply. `risk-audit.sh` scores without the list, so threshold tuning still reads the score alone.
- The `needs-human` reason ends with the override when there is one, so a 0-point `medium` says why it stopped.
- The risk scorecard gives each override reason its own line: a secret still says to remove and rotate it; an owner-listed path names the prefix and a file and keeps the level's action.
- The scorecard posts again on the same head when its level, score or override changes: `meta.risk.commented_sha` carries over only when the override is also the same, and the chain keys the scorecard `risk-<sha7>-<level>-<score>-<override hash>`. Before this, a rule change on the same head left the old scorecard up, though `rules/03-risk.md` said it posted again.
- `doctor.sh` fails when `always_human` is present and not a list of strings.

## 0.11.0

No new `config.json` keys.

- The merge gate holds every blocking comment until Stage 2 judges it `addressed`. Before this it read only the author session's own count of open blockers, so a blocking comment the author reported as fixed merged even when Stage 2 judged it `partial` or `not-addressed`, or when Stage 2 was skipped because nothing was pushed. Verdicts are merged across all Stage 2 passes, latest first, and a blocking code with no verdict holds too. Blocking means the comment's first line is labelled `issue (blocking)` (now recorded as `blocking` in `stage1[].comments`) or it is `critical`; old records count only `critical`. A blocking `S2-` comment raised after the last author pass stops with its own reason. The stop notice says a person can check the codes and merge by hand.
- Stage 1 writes the findings that went to the summary body to `summary-items.json` next to `summary.md`. `post-review` records them as `stage1[].summary_items` (`[]` without the file), the merge gate counts their blocking codes, Stage 2 judges them by code, and PG6 checks that the pre-post edit kept their count, codes, grades, blocking flags and anchors.
- PG5 fails a `critical` comment whose first line is not labelled `issue (blocking)`.
- The merge gate reads the head's CI checks. A failed check run (anything but success, neutral or skipped) or a failed or errored commit status blocks, naming the check. Checks still running are read again every 30 seconds for up to 10 minutes, then the chain stops at `blocked` with "run the chain again". A repository with no checks merges as before. The last read is kept in `chain.ci`.

## 0.10.1

- `watch.sh --cron` prints the two crontab lines with the plugin folder, `$HOME` and the same `PATH` as `--plist`, quoting the folder, lock and log for cron's `/bin/sh`. README Setup §5 uses it instead of a crontab with placeholders.

## 0.10.0

No new `config.json` keys. `models` changes meaning: a `null` or missing `session` or `subagent` now runs `claude-sonnet-5-5`; set it to `""` to keep Claude Code's default, as before.

- Chain sessions and their subagents run on Sonnet by default. In a 3-PR benchmark Sonnet found the same planted defects for about $2 per PR, against $15.5 on Claude Code's default model.
- `doctor.sh --init` also creates `~/.pr-quorum/profiles/`, `learnings.md` and `human-labels.md`, and copies `examples/profiles/generic.md` to `profiles/generic.md` when it is missing. It replaces nothing. README Setup §3 and §4 drop the `mkdir`, `touch` and `cp` steps.
- `watch.sh --plist` prints the macOS LaunchAgent with the plugin folder, `$HOME` and a `PATH` of the folders `claude`, `gh`, `jq` and `git` are found in. README Setup §5 uses it instead of a plist with placeholders.
- README Setup §1: a repository under a personal account cannot give a collaborator read, so the bot has write there; read applies to an organization's repository. `doctor.sh` no longer says to invite the bot "with read".

## 0.9.0

No new `config.json` keys. `templates/config.json` holds `__OWNER__`, `__BOT__` and `__REPO_PATH__` where it had sample logins and a sample path.

- `doctor.sh --init <repo-path>` writes `~/.pr-quorum/config.json` from the template when there is none: `owner` from the gh login, `bot` from the bot token's account (`pr-quorum.sh whoami`, still the only reader of `bot.env`), and one repository named after the clone's github.com `origin`, with its absolute path and owner. It writes nothing if any of these cannot be read, never overwrites an existing file, and then runs the usual checks. README Setup §3 uses it instead of copying and editing the template.
- `doctor.sh` reports the new template tokens as template values, so a hand-copied template still fails.

## 0.8.0

No new `config.json` keys. `templates/config.json` now starts from the `generic` profile with no `commands`, so build and test commands are detected (`gradlew`, `package.json`).

- Stop notices are no longer lost. A stop notice is skipped only when GitHub says the PR is merged or closed; a failed read of its state posts anyway, since the stop may be that very read failing. A risk scorecard that cannot be posted stops the chain as `blocked` with a notice, instead of ending `ready` or `needs-human` with nothing on the PR. A fork or large-PR notice that failed is posted again on the next run (its key adopts one already posted).
- A Stage 1 session that hits its cost or time cap, or leaves no record twice, sets `held-failed`, so the watcher no longer runs Stage 1 again with the same budget. The stop notice says how to resume.
- Stage 2 does not start a session when the first author pass pushed nothing and the head is the one Stage 1 judged. The chain records an empty Stage 2 pass (`skipped`) that Stage 3 and the merge gate read. This saves one session per such PR.
- The risk score counts `Dockerfile`, `*.Dockerfile`, `Dockerfile.<suffix>`, `Containerfile` and `compose`/`docker-compose` YAML files as files that run at build time, so a PR changing one of them is at least `medium` even with a test file alongside. Before this such a PR could be `low` and auto-merge.
- `doctor.sh` warns when a repository belongs to an organization whose members' PRs would be skipped by `trust`, when `limits` is missing, and when a repository has no `commands` and no `gradlew` or `package.json`. It fails when a `limits.*.budget_usd` is not a number, when the bot token cannot read a repository, when `bot` is the `owner`, and when a repository `path` is not absolute. `pr-quorum.sh whoami <repo>` also checks the bot can read that repository.
- README states the per-PR cost and the always-on machine in its first lines, and Setup copies the `generic` profile.

## 0.7.0

No new `config.json` keys.

- Sessions read GitHub only through `gh-get.sh`, and only the PR's own repository. `gh-get.sh` sends a request only when its first argument is `repos/<owner>/<repo>[/…]` for a repository in `config.json`. Inside the chain it also has to be the run's repository, which the chain passes in `PR_QUORUM_SLUG` (this can only narrow the list). Paths with `..`, `.`, `%`, `:` (an `owner:branch` compare reaches other forks) or a second endpoint are refused, and so is `search/…`. A `?query` is refused with a hint to pass it as `-f key=value`, which `gh api` sends as the query string with GET. The session templates no longer allow `gh pr view`, `gh pr diff`, `gh pr list`, `gh pr checks` or `gh search`, and the author skill reads the PR through `gh-get.sh`. Before this, text in a PR could make a session read another private repository with the user's gh login and post it in a comment.
- The watcher marks a chain that died after Stage 1 (killed, reboot, power loss: its lock pid is gone and its state is not an end state) as `blocked`, and posts one stop notice if the PR is open. Before this, the chain stayed in its in-progress state and the watcher skipped the PR as already reviewed, so nobody was told. The chain still does not resume on its own. The watcher also skips a PR whose chain is running (or still starting), instead of counting a failed attempt that could hold it at `held-failed`.
- `chain.sh` and `watch.sh` stop at start with exit 2 and the missing command's name when `claude`, `gh`, `jq` or `git` is not on `PATH`, instead of trying sessions that exit 127. A missing `jq` is no longer reported as "config.json is not valid JSON". `doctor.sh` prints the folder each command was found in, for the watcher's `PATH`.

## 0.6.0

No new `config.json` keys. `git` 2.31 or later is now required, and fork PRs stop before Stage 1.

- Repository git hooks no longer run in the chain. A repository that points `core.hooksPath` into its own tree (husky does) used to run a PR's hooks, or ones a build wrote into the worktree, on the author session's `git commit` and on `author-push.sh`'s `git push`, outside the build sandbox. The chain now gives every session `core.hooksPath=/dev/null` through `GIT_CONFIG_*`, which a session cannot override under its permissions. `author-push.sh` and the build's `git status` pass it with `-c`. This also turns off git-lfs's pre-push upload, so a PR that adds LFS objects needs a person to push them. The chain exits 2 before any session if `git` is older than 2.31, the first version that reads `GIT_CONFIG_*`, and `doctor.sh` checks the version.
- The scripts keep their temp files under `~/.pr-quorum/tmp/` instead of `$TMPDIR`. A process a sandboxed build left running could write `$TMPDIR` and rewrite the risk score file before the gate read it. The build sandbox cannot read or write `~/.pr-quorum`. The watcher's cleanup removes entries there older than a day, which a killed script leaves behind. A build's leftover processes are still not stopped on macOS ([`docs/harness.md`](docs/harness.md#3-1-build-sandbox) §3-1).
- `reply` and `comment` no longer post twice when a rerun follows a post whose response was lost or whose recording failed. A reply ends with a hidden marker (comment id, stage, head SHA), and an unrecorded bot reply with the same marker is recorded instead of posted again. `reply` exits 4 when it posts but cannot record. `comment` takes an optional key (`comment <repo> <pr> <file> [<key>]`) and skips posting when a bot comment with that key exists. The chain keys the risk scorecard, the stop notice, the large-PR notice, and the fork notice. A stop notice's key includes how many notices were recorded before it, so a stop that comes back after a different one is announced again.
- A PR whose head is in a fork (or a deleted fork) stops at `held-fork` before Stage 1 with one comment, instead of spending Stage 1 and then failing at the author's push. The watcher skips it like the other `held-*` states.
- CI: `.github/workflows/selftest.yml` runs `bash -n` and `selftest.sh` on macOS (`/bin/bash` 3.2) and Ubuntu for each PR. The Ubuntu job runs without `bwrap`: its build sandbox checks do not pass yet.

## 0.5.0

No new `config.json` keys. The risk score counts more files, so some PRs that were `low` now are not.

- The risk score counts more files that run in CI, at build or test time, or as agent configuration: composite actions (`.github/actions/`, and `action.yml` at the top level or under `.github/`), git hooks (`.husky/`, `.pre-commit-config.yaml`), `tox.ini`, `noxfile.py`, `build.rs`, `.mcp.json`, `CLAUDE.local.md`, and `CODEOWNERS` (removal included) each add 15 points, so a PR changing only one of them is `medium`. The plugin's own top-level `mcp.json`, which every chain session loads, counts toward the harness signal. A secret added to a `.toml`, `.ini`, or `.cfg` file counts like one in `.yml` (30, `critical`). Re-scoring the last 30 merged PRs gave no change.
- When the chain cannot read the PR head or state from GitHub after Stage 1 (the conflict check, the head check after an author pass, the merge gate), it stops at `blocked` (exit 4) and posts the stop notice, instead of exiting with the PR left unmerged and no comment, or running the next step on an empty value.
- New sample profile [`examples/profiles/generic.md`](examples/profiles/generic.md): stack-neutral judge sections with `<fill in>` lines only for project context and measurement baselines.
- `doctor.sh` reports template values left in `config.json` (`your-github-login`, `your-repo`, `/absolute/path/to/...`) as one `FAIL`, tells a missing or invisible repository (404) apart from a bot that is not a collaborator, prints the error when GitHub cannot be reached, warns when a profile is an unmodified copy of a sample or still has `<fill in` lines, and checks that each `repos.<name>.commands` entry can start (`./gradlew` with no `gradlew` in the repository is a `FAIL`; an npm-family command with no `package.json` is a warning).

## 0.4.0

New `config.json` keys are optional. Builds now run in a sandbox by default (first item), and session permissions are narrower; both can change what an existing setup is allowed to do.

- `pr-quorum.sh build` and `author-build` run the build command with an emptied environment inside an OS sandbox: `sandbox-exec` (Seatbelt) on macOS, `bwrap` (bubblewrap) on Linux. The build shell cannot read credential files (`~/.config`, `~/.ssh`, `~/.aws`, `~/.npmrc`, `~/.m2/settings.xml`, the bot token file, the macOS keychain, and others), cannot write outside the worktree, the temp folder, and its own cache root `~/.cache/pr-quorum-build/`, and cannot write the git dir. Network stays open. `build.sandbox` is `"require"` (default) or `"off"`; with `"require"` and no working sandbox the build exits 2 as not measured. `build.env_passthrough` lists extra variable names to keep; names that look like credentials are refused. A build that needs private-registry credentials from `~/.npmrc` or `~/.m2/settings.xml` needs `"off"`. The first sandboxed build downloads its Gradle distribution and dependencies into the new cache root. `doctor.sh` checks that the sandbox starts. Remaining risks are listed in `docs/harness.md` §3-1.
- Review and author sessions block reads outside their working folders (`permissions.blockReadsOutsideWorkingDirectories`; Claude Code 2.1.257 or later, which `doctor.sh` checks). `profiles/` and the plugin folder are opened with `--add-dir`; skills read `config.json` and `learnings.md` through the new `pr-quorum.sh config` and `pr-quorum.sh learnings`. The three session templates share one credential deny list, and sessions can no longer read local secret env files (`.env`, `.env.local`, `.env.*.local`, `.env.development`/`production`/`staging`/`test`, `.envrc`); `.env.example` and similar stay readable. `git diff`/`log`/`show --output` and `git diff --no-index` are denied, and `git worktree add` is allowed only into each repository's `<repo>-worktrees/` folder.
- The risk score counts dependency changes at 15 points, so a PR that changes only a manifest or lock file is `medium`. `buildSrc/`, `Makefile`, `.npmrc`, `.yarnrc(.yml)`, `conftest.py`, and `*.config.{js,ts,mjs,cjs,...}` count as build scripts, a plaintext token in `.npmrc` counts as a secret, and a renamed or copied file also counts at its old path. Past PRs #38 and #43 rescore from 50 to 55 (still `high`).
- `post-review` no longer posts a review twice when a rerun follows a post whose recording failed or whose response was lost. The review body ends with a hidden stage marker, and a bot review on the same SHA with that marker that `meta.json` does not know is recorded instead of posted again. GitHub reads retry up to 3 times on 5xx, 429, and secondary rate limits; writes are never retried.
- The watcher removes worktrees of PRs that GitHub reports as merged or closed, asking each PR's state directly (no 200-PR limit), skipping PRs whose chain is running, at most every 30 minutes. `watch.sh --gc-only` runs the cleanup at once.

## 0.3.0

New `config.json` keys are optional. With none of them set, the chain runs as in 0.2.1, except for how builds run (last item).

- PRs from trusted authors run the chain: `trust.authors` (logins) and `trust.associations` (GitHub `author_association` values, default `["OWNER"]`). Unknown association values stop the watcher and chain with exit 2; values beyond `OWNER`, `MEMBER`, `COLLABORATOR` log a warning. Skipped PRs log `author is not trusted (<login>, <association>)`.
- `repos.<name>.owner` sets a repository's GitHub owner, so one `config.json` can hold personal and organization repositories. Missing, it is the top-level `owner`. The watcher searches once per owner.
- Only github.com is supported. With `GH_HOST` set to another host, `watch.sh`, `chain.sh`, `pr-quorum.sh`, and `doctor.sh` exit 2 before reading or posting anything.
- `limits.<step>.budget_usd` and `limits.<step>.timeout_min` cap each chain session (`stage1`, `stage2`, `stage3`, `author`), and `limits.stage1.max_rounds` caps Stage 1 rounds (5 when missing). A session cut by a cap is not retried; the chain stops at `blocked` with the cap in the reason. `models.session` and `models.subagent` pick the session and subagent models. The template sets sample limits.
- A failed watcher search (expired token, rate limit, network) logs `error — search failed` and exits 2 instead of reporting no review requests. The search asks for up to 100 PRs per owner and warns when it hits that.
- `scripts/doctor.sh` checks the first-run setup, one line per check, and exits 2 on any `FAIL`. `pr-quorum.sh whoami` prints the bot token's login.
- Every post and push is scanned for tokens first. `pr-quorum.sh`, `author-reply.sh`, and `author-push.sh` refuse (exit 3) a body or commit holding a GitHub token pattern or a known token value; `author-push.sh` scans each pushed commit.
- Sessions can no longer edit `meta.json`. Stage 2 and Stage 3 records go through new `pr-quorum.sh` subcommands: `stage2-begin`, `verdicts`, `stage3-replies`.
- The risk score counts code under nested `docs/` and `contents/` folders (only top-level ones are documents), `doctor.sh` and `token-scan.sh` as harness scripts, and build, dependency, and test files of Maven, Python, Go, and Rust.
- Builds and tests run only through `pr-quorum.sh build` (review sessions) and `pr-quorum.sh author-build` (the author session), which run `repos.<name>.commands.{build,test,lint}`. Without `commands` they fall back to `./gradlew` or `npm run build`/`npm run lint`/`npx --no -- tsc --noEmit`, as before. The session settings no longer allow `./gradlew`, `npm`, or `npx` directly, so a profile or local setup that called them must use the wrapper.

## 0.2.1

- Axis names in posted comments and the summary legend (names and headers) follow the PR's language, like the rest of the review. When the profile is in another language, the session translates the names and keeps one translation per axis for the whole PR. Before, they were copied from the profile, so a Korean PR got English axis names with an English profile.

## 0.2.0

- Docs, prompts, and script messages are in English.
- Stored values (verdicts, grades, status) and the posted Stage 2 verdict line now use English IDs: `addressed`·`partial`·`not-addressed`·`regressed`, `critical`·`major`·`minor`·`nit`, `pending`·`running`·`done`·`held-large`·`held-failed`. Readers still accept the old Korean values, so existing runs in `~/.pr-quorum/runs/` keep working.
- Review text follows the language of the PR.
- `README.ko.md` and `README.zh-CN.md` translate the README. Each records the `README.md` commit it follows, and `scripts/selftest.sh` warns when a translation falls behind.

## 0.1.1

- `pr-quorum.sh` rejects, with exit 1 before calling GitHub, a repository name not in `repos` of `config.json` and a SHA that is not 7–40 hex characters.

## 0.1.0

First public release. Moved a review harness that ran inside a personal repository into a Claude Code plugin.

Two things were fixed before release.

- `reply`, `patch`, and `patch-review` in `pr-quorum.sh` exit 1 before calling GitHub when given a non-numeric comment or review id.
- The risk scorecard comment the bot leaves points to either "auto-merge" or "a human merges" depending on the `auto_merge` setting, and links to the rule document in this repository.
