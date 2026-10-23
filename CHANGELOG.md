# Changelog

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
