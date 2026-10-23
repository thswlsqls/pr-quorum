# pr-quorum harness

A harness that evaluates incoming PRs axis by axis and posts the review. This is the first document to read when changing or operating the plugin.

## 0. Invariants — before anything else

1. **The subject of evaluation is the PR. Do not change a single character of it.** The only place writes are allowed is under `~/.pr-quorum/runs/<repo>-pr<N>/`. Sessions do not edit `~/.pr-quorum/learnings.md` or `human-labels.md` — what is learned goes into the run's `learning-candidates.md` as candidates, and a human applies the `scripts/dream.sh` proposal through a PR.
2. **Only `scripts/pr-quorum.sh` writes to GitHub.** Sessions do not post directly with `gh api`. The script reads the bot token internally. Posting directly would put the review up under the user's account.
   The author session (`/pr-quorum:author`) pushes only through `scripts/author-push.sh`, and replies, PR comments, and description replacement go only through `scripts/author-reply.sh`. These two post under the user's account.
3. **Judges, challengers, and verifiers write no files.** All they do is return results as text. They use `Bash` only for lookups such as `grep`, `wc`, and `jq`, and do not use redirection, `sed -i`, `mv`, or `rm`.
4. **No scores.** Only the four grades (`critical`, `major`, `minor`, `nit`) are used.
5. Do not post what could not be verified. An `unverified concern` stays only in `~/.pr-quorum/runs/`.
6. Do not commit the bot token to a repository.

> - The only enforcement that keeps the bot from changing code is **the collaborator read role.** The token scope cannot prevent it — `public_repo` includes code write on public repositories. If the repository the bot reviews is public, the moment the bot is raised to write, this token allows push.
> - When the harness lived inside the product repository, harness changes got mixed into a product PR, and the chain stopped on a conflict with main (PR #36 — a session edited `_memory/learnings.md` in the working tree directly).
> - **State lives in `~/.pr-quorum/`, not in the repository.** `config.json`, `profiles/`, `learnings.md`, `human-labels.md`, the three rendered settings files, and `runs/` are here. `runs/` holds per-PR scratch folders that are thrown away. This folder has no backup and does not come along when you clone on another machine. Rule documents, scripts, and settings templates are tracked in the plugin repository.

## 1. File map

| File | What |
|---|---|
| `rules/00-criteria.md` | Common to all three stages — invariants · invalidation conditions I-1–I-8 · grades · source grades · adjustments by file type · comment format · pre-post edit |
| `rules/01-stages.md` | What differs per stage · phase table · SHA pinning · `meta.json` · exit conditions · posting gates PG1–PG6 · metrics · signal table |
| `rules/02-judges.md` | Common judge rules · output format · challenger instructions · document verifiers V1, V2, V3 |
| `rules/03-risk.md` | Auto-merge risk score — scorecard · handling by level · calibration log |
| `rules/04-dream.md` | Instructions for the `scripts/dream.sh` session — gathers learning candidates from multiple runs into a learnings proposal |
| `~/.pr-quorum/profiles/<profile>.md` (samples in `examples/profiles/`) | Review axis definitions and, for the four judges, what to look at / what not to look at / grade examples / measurement baselines |
| `~/.pr-quorum/learnings.md` | Learning accumulated across PRs. Sessions only read it |
| `~/.pr-quorum/human-labels.md` | Table in which a human judges posted bot comments as right, wrong, or overreaching. Sessions do not write it |
| `~/.pr-quorum/runs/<repo>-pr<N>/` | Working folder for one PR. Thrown away per PR. `learning-candidates.md` holds the learning candidates written by evaluation sessions (denied to the author session) |
| `~/.pr-quorum/runs/_dream/<timestamp>/proposal.md` | Learnings proposal produced by `dream.sh`. A human marks each item accept, reject, or hold |
| `scripts/` | `pr-quorum.sh` (the only posting path) · `watch.sh` (automatic trigger · cleans up `pr-quorum-*` and `pr-author-*` worktrees of merged PRs) · `chain.sh` (Stage 1 through merge) · `risk.jq` (risk score) · `risk-audit.sh` (tracks follow-up fixes after merge) · `selftest.sh` (re-runs PG5 and PG6 on past outputs; run once after changing a gate) · `gh-get.sh` (how sessions read GitHub; GET only) · `author-push.sh` (the only way the author session pushes to the PR branch; no force) · `author-reply.sh` (how the author session posts thread replies, PR comments, and PR description replacements; bodies only from files under `runs/`) · `dream.sh` (gathers learning candidates from runs and produces a proposal; called by hand) · `build-sandbox.sh` (runs `build`/`author-build` commands with an emptied environment inside an OS sandbox, §3-1) |
| `templates/settings.json` · `templates/author-settings.json` · `templates/dream-settings.json` · `templates/config.json` · root `mcp.json` · `scripts/config.sh` | Tool allow/deny templates for evaluation, author, and dream sessions · sample `~/.pr-quorum/config.json` · config that restricts chain sessions' MCP to context7 alone (dream sessions run without MCP) · functions that read `config.json` and render the settings. Every time `chain.sh` or `dream.sh` runs, it replaces `__PLUGIN_ROOT__` in the templates with the plugin folder path and writes them to `~/.pr-quorum/` |

## 2. Three stages

| Stage | Question | Trigger |
|---|---|---|
| 1 review | What defects does this PR have? | Called by the chain. On its own: `/pr-quorum:review stage1 <repo> <PR-number>` |
| 2 followup | Did the author do what the review asked? | Called by the chain. On its own: `/pr-quorum:review stage2 …` |
| 3 measured | Does the review hold up when measured, and did it miss anything? | Called by the chain. On its own: `/pr-quorum:review stage3 …` |

**By default it goes all the way to merge.** When the bot is assigned as a reviewer, the watcher starts `scripts/chain.sh <repo> <PR-number>`, and the chain runs
Stage 1 → author fixes (`/pr-quorum:author`) → Stage 2 → Stage 3 → (author fixes → Stage 2)* → merge gate → **risk gate** → `gh pr merge` without a human.
The merge is done by the chain with the user's gh account, not by the bot. The merge gate does not trust only the records sessions wrote; it checks directly on GitHub that the bot's review on the current head commit exists. If the risk score (`03-risk.md`) is not `low`, or Stage 3 found a `critical`/`major` the review missed (`P`), it does not merge and stops with `chain.state=needs-human` —
the bot leaves the scorecard as a PR comment. The chain reads `meta.json` and resumes from where it stopped, so it is safe to call it again by hand.
Only one chain runs per PR: the chain takes `runs/<repo>-pr<N>/.chain.lock` with `mkdir` (atomic, no `flock` needed) and writes its pid there and to `chain.pid`; a second call exits 5, and a lock folder whose pid is dead is cleared and taken over. The folder is removed when the chain exits.
When the chain stops at `chain.state=blocked`, the bot posts one PR comment with the state, `chain.reason`, and the `chain.sh <repo> <pr>` command to resume — the chain never resumes on its own. `chain.notified.key` (`state|reason`) keeps a rerun that stops for the same reason from posting again; a new reason posts again. `needs-human` and the large-PR hold get no extra comment, since the scorecard, the Stage 3 review, or the large-PR notice already says why. A failed post is only logged.
For each headless session the chain starts, time, cost, and turn count are appended as one entry to `chain.sessions[]` in `meta.json` (`session_id`, `subtype`, `duration_ms`, `total_cost_usd`, `num_turns`, `is_error` from `claude -p --output-format json`, plus the count of `permission_denials` and the names of denied tools). For whole-session time, use `wall_ms`, which the chain measures itself — `duration_ms` only covers the span after the last subagent completion notice (measured on PR #52). Attempts whose result could not be read as JSON also leave one entry, with their exit code.
Caps come from `config.json`, and a missing key means no cap: `limits.<step>.budget_usd` becomes `--max-budget-usd`, `limits.<step>.timeout_min` starts a watchdog that sends TERM to the session's process group, then KILL 30 seconds later (the entry gets `timed_out:true`), `models.session` becomes `--model`, and `models.subagent` becomes `CLAUDE_CODE_SUBAGENT_MODEL`. A session that ends with subtype `error_max_budget_usd` or by timeout is not retried; the chain stops at `blocked` with the cap in the reason.
The watcher only feeds the chain PRs from trusted authors — the author's login is in `trust.authors` or the PR's `authorAssociation` is in `trust.associations` of `config.json` (default `["OWNER"]`, so with neither key only the repository owner's PRs run) — and `chain.sh` checks again from the API at start. This keeps other people's PR descriptions and diffs out of sessions that push and merge with the user's account; other PRs are skipped. `trust.associations` accepts only GitHub's `author_association` values (anything else stops with exit 2), and values beyond `OWNER`/`MEMBER`/`COLLABORATOR` log a warning. For an organization, prefer listing logins: `MEMBER` means everyone in the organization.
Each repository's GitHub owner is `repos.<name>.owner`, falling back to the top-level `owner`; the watcher searches once per distinct owner and matches PRs by owner and name. Only github.com is supported: with `GH_HOST` set to anything else, `watch.sh`, `chain.sh`, `pr-quorum.sh`, and `doctor.sh` exit 2 at start (gh would use `GH_ENTERPRISE_TOKEN` there, not the bot token).
Reassigning the reviewer does not rerun Stage 1. **Stage N runs only if `meta.json` has a completion record for Stage N−1** (`lock` blocks it, exit code 3).

## 2-1. Review axes and the four judges — axis assignment

**The authoritative definitions are in §1 of `profiles/<profile>.md`.** Below is a summary of the assignment; the prompt carries the profile text copied verbatim.

| Judge | Axes (backend) | Axes (those that mean something different in frontend) |
|---|---|---|
| J1 | `R-A` Design–implementation consistency · `R-B` Data correctness | `R-B` is whether parsing IDs as number loses precision |
| J2 | `R-C` Concurrency & atomicity · `R-F` Failure isolation | `R-C` is state races |
| J3 | `R-D` Interface contract · **`R-I` Security (conditional)** · `R-E` Load fitness | `R-E` is client performance. `R-I` is backend only |
| J4 | `R-G` Tests · `R-H` Maintainability | `R-H` includes accessibility · `R-G` is a conditional axis |

**Backend has 9 axes, frontend has 8** — `R-I` exists only in the backend profile, and even there it is conditional; its trigger conditions are in §1 of `profiles/backend.md`.

The order `J1`–`J4` is not a score but **deduplication priority** — if the design or data is wrong, that is the premise for everything else. The sources of the axis criteria (Google eng-practices · Conventional Comments) and their quotations are in [the README's "Where the criteria come from"](../README.md#where-the-criteria-come-from).

## 3. `pr-quorum.sh` contract

| Subcommand | Arguments | What it does | Bot token |
|---|---|---|---|
| `sha` | `<repo> <pr>` | Prints the current head SHA | Not needed |
| `meta` | `<repo> <pr>` | Prints `meta.json` | Not needed |
| `precheck` | `<repo> <pr>` | Large-PR cutoff check (50 files / 3000 lines) | Not needed |
| `ranges` | `<repo> <pr> <sha>` | Emits the line ranges that can take inline anchors, plus the diff body with line numbers (deleted lines carry old-file numbers, so they cannot be anchored). **It is loaded into the judge prompt to prevent anchors outside the diff in the first place** | Not needed |
| `gate1` | `<repo> <pr> <sha> <comments.json>` | **PG1** — checks line by line that anchors are inside that SHA's diff | Not needed |
| `init` | `<repo> <pr> [--reset-eval]` | Creates/updates `~/.pr-quorum/runs/<repo>-pr<N>/` and `meta.json`. **Never overwrites existing records.** If Stage 1 has already posted, it also keeps `base_sha` and `eval_sha` — use `--reset-eval` only when rerunning Stage 1 on a new head | Not needed |
| `lock` | `<repo> <pr> <stage>` | Acquires the lock. A lock whose pid is dead or that is older than 3 hours is removed and taken | Not needed |
| `unlock` | `<repo> <pr>` | Releases the lock | Not needed |
| `status` | `<repo> <pr> <value>` | One of `pending`, `running`, `done`, `held-large`, `held-failed` | Not needed |
| `attempt` | `<repo> <pr> inc\|reset` | Count of consecutive Stage 1 failures | Not needed |
| `stage2-begin` | `<repo> <pr> <stage_sha> <last_judged_sha>` | Both SHAs in full (40 hex). Opens this Stage 2 pass's `stage2[]` element (`round`, `stage_sha`, `last_judged_sha`, `at`) before its first `reply` or `post-review`. Appends one if `stage2` is empty, the last element has `verdicts`, or it judged another commit; otherwise reuses the last element | Not needed |
| `verdicts` | `<repo> <pr> <stage_sha> <verdicts.json>` | Writes a `{code: verdict}` object (file under `runs/`) into `stage2[-1].verdicts`. Values other than `addressed`·`partial`·`not-addressed`·`regressed` exit 1; no open element for `stage_sha` exits 3 | Not needed |
| `stage3-replies` | `<repo> <pr>` | Moves `stage3_replies` into `stage3.replies`, for a session that ends without `post-review`. Exits 3 if Stage 3 has no post record | Not needed |
| `post-review` | `<repo> <pr> <sha> <summary.md> <comments.json> [stage1\|stage2\|stage3]` | Posts the summary and inline comments together as one review. **Reruns PG1 and PG5 right before posting** | Needed |
| `reply` | `<repo> <pr> <comment_id> <body.md>` | Thread reply | Needed |
| `patch` | `<repo> <pr> <comment_id> <body.md>` | Corrects the body of the bot's own comment | Needed |
| `patch-review` | `<repo> <pr> <review_id> <body.md>` | Corrects the **summary** body of a posted review. **Returns 404 on a closed PR** (measured) — use only on open PRs | Needed |
| `comment` | `<repo> <pr> <body.md>` | One general comment on the PR (large-PR hold notice · risk scorecard) | Needed |
| `risk` | `<repo> <pr>` | Auto-merge risk score of the current head (`03-risk.md`). Recorded in `meta.risk` and `outputs/risk.md`. **Exits 3 if not `low`** | Not needed |
| `pg5` | `<summary.md> <comments.json> [stage1\|stage2\|stage3]` | **PG5** machine check (praise · code/axis/body · axis names · summary axis legend). The same function `post-review` runs right before posting | Not needed |
| `snapshot` | `<outputs/<stage>[/round-NN]>` | Takes a pre-edit copy into `pre-polish/`. Accepts only folders under `~/.pr-quorum/runs/` | Not needed |
| `pg6` | `<outputs/<stage>[/round-NN]>` | **PG6** — compares against the `pre-polish/` copy to check that the JSON's counts, fields, and first lines, and the markdown's anchors and numbers, are unchanged | Not needed |
| `build` · `author-build` | `<repo> <pr> <worktree> build\|test\|lint [target]` | Runs `repos.<repo>.commands.<kind>` from `config.json` in the worktree with `bash -c` inside the build sandbox (§3-1), `<target>` replaced by the target (letters, digits, `: _ . / -`; no leading `-` or `/`, no `..`). Without `commands`: `gradlew` → `./gradlew <target>:build\|test`; `package.json` → `npm run build`, `npm run lint`, `npx --no -- tsc --noEmit` for `test` (never fetched from the registry) (target = app folder); otherwise it refuses (exit 2) and the measurement is `not measured`. The worktree must be a worktree root under `<parent of repos.<repo>.path>/<repo>-worktrees/` and not under `runs/`; review mode also needs a clean tree whose HEAD is a SHA pinned in `meta.json` or the PR head, and `author-build` allows only `pr-author-<pr>`, edits included. **The command's exit code and output pass through.** It is the only way sessions run build tools — the settings templates allow this subcommand instead of `./gradlew`·`npm`·`npx` (the review template does not allow `author-build`) | Not needed |

Posting subcommands (`post-review`, `reply`, `patch`, `patch-review`, `comment`) accept as body files only regular files under `~/.pr-quorum/runs/`. A link or any other path exits 1.
Before reading the bot token or calling GitHub, they also scan the body (and `comments.json`) with `scripts/token-scan.sh`: a GitHub token pattern (`ghp_`·`gho_`·`ghu_`·`ghs_`·`ghr_` + 36 or more letters and digits, `github_pat_…`), the bot token value, `GH_TOKEN`/`GITHUB_TOKEN`, or the user's `gh auth token` exits 3 without posting, and the match is never printed. `author-reply.sh` scans its body and `author-push.sh` the diff and messages of the commits it would push (since the PR head on GitHub) the same way, exiting 3.

Sessions cannot edit `meta.json` — both session templates deny `Edit(/runs/*/meta.json)`, and the review template no longer allows `cd` (build and `git worktree add` take absolute paths). The Stage 2 and Stage 3 records the review skill used to write by hand go through `stage2-begin`, `verdicts`, and `stage3-replies`.

`<repo>` must be a name in `repos` of `config.json`, `<pr>` a positive integer, `<comment_id>` and `<review_id>` numeric, and `<sha>` 7–40 hex characters. Otherwise it exits 1 before reading the bot token or calling GitHub.

**Exit codes** — 0 success · 1 usage or argument error · 2 environment (no bot token file, no `meta.json` or no `base_sha` in it) · 3 gate violation (PG1 failure, missing PG5 required item, PG6 comparison failure, large-PR cutoff, **stage order violation**, a token in an outgoing body) · 4 GitHub API or risk calculation (`risk.jq`) failure · 5 lock held.

### 3-1. Build sandbox

`build` and `author-build` run code the PR controls — `build.gradle`, `gradlew`, `package.json` scripts — and the author session can write that code itself. The session's Bash allow list and Read/Edit deny rules do not reach into the build shell, so `scripts/build-sandbox.sh` limits it instead:

- **Environment.** `env -i` keeps only `PATH HOME USER LOGNAME SHELL TMPDIR LANG LC_ALL LC_CTYPE TERM JAVA_HOME NVM_DIR` (when set) plus the names in `build.env_passthrough`. Names must match `^[A-Z_][A-Z0-9_]*$`, and `*TOKEN*`, `*SECRET*`, `*KEY*`, `PR_QUORUM_*` are refused (exit 2). Fixed values come last: an empty `GH_CONFIG_DIR`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS`/`SSH_ASKPASS=false`, `GRADLE_OPTS=-Dorg.gradle.daemon=false` — a build otherwise runs in a Gradle daemon already running outside the sandbox (§6-3) — and the cache locations below.
- **Sandbox.** macOS uses `sandbox-exec` (Seatbelt), Linux `bwrap` (bubblewrap). Writes are allowed only in the worktree, the temp folder (`$TMPDIR`, `/tmp`), `/dev`, and the builds' own cache root `~/.cache/pr-quorum-build/` (both platforms): `GRADLE_USER_HOME=<root>/gradle`, `npm_config_cache=<root>/npm`, `MAVEN_OPTS=-Dmaven.repo.local=<root>/m2` (appended to `MAVEN_OPTS` only when it is passed through), `XDG_CACHE_HOME=<root>/xdg`. The user's own `~/.gradle`, `~/.m2`, `~/.npm`, `~/.cache` and `~/Library/Caches` are read-only — a wrapper, JDK, or package a build left there would later run in the user's own builds, outside the sandbox. The root persists across builds, so only the first build downloads the Gradle distribution and dependencies; its `gradle/init.d` and `gradle/gradle.properties` are read-only so one build cannot plant code for the next. The git dir (the worktree's `.git` pointer and the common dir) stays read-only, since hooks planted there would run in the next `git commit` outside the sandbox. Reads and writes are refused for `~/.config`, `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.docker`, `~/.kube`, `~/.claude`, `~/.claude.json`, `~/.pr-quorum`, `~/.git-credentials`, `~/.npmrc`, `~/.yarnrc`, `~/.yarnrc.yml`, `~/.m2/settings.xml`, `~/.m2/settings-security.xml`, `~/.pypirc`, `~/.cargo/credentials`, `~/.cargo/credentials.toml`, `~/.gradle/gradle.properties`, `~/.zsh_history`, `~/.bash_history`, the bot token file, and macOS `~/Library/Keychains`, `~/Library/Application Support`, `~/Library/Cookies` (`SANDBOX_SECRETS`, one list for both platforms). On macOS the keychain service (`com.apple.SecurityServer`) and the launchd SSH agent socket are refused too; on Linux `/run/user/<uid>` (session D-Bus) is hidden.
- **Network stays open** — first builds fetch dependencies. **Tradeoff: private-registry auth is not available.** `~/.npmrc`, `~/.yarnrc*`, `~/.gradle/gradle.properties`, `~/.m2/settings.xml` and the like are refused, and `build.env_passthrough` refuses credential-like names, so a build that needs registry credentials needs `build.sandbox: "off"`. Public registries work (npm ignores an unreadable `~/.npmrc`).
- **`build.sandbox`** in `config.json` — `"require"` (default, also when the key is missing) or `"off"`. With `"require"`, a host without the tool or where it fails to start (`true` is run inside it first) exits 2 "sandbox unavailable — record it as not measured" and nothing is built. `"off"` runs the command as before, with the session's environment and no sandbox — for repositories whose tests need Docker, the keychain, or other places under the home folder. `scripts/doctor.sh` checks the sandbox and the passthrough names; `scripts/selftest.sh` runs an offline check of it.
- The first stderr line, `pr-quorum: running in <dir> (sandbox=seatbelt|bwrap|off): <command>`, records which applied in the session log.
- Left open: a build can poison the sandbox cache root for later sandboxed builds (not for the user's own), reach anything on the network including `localhost`, and read source code anywhere readable. The Linux side has not been measured on a host yet.

## 4. Output spec

Outputs go under `~/.pr-quorum/runs/<repo>-pr<N>/outputs/<stage>/` (`<stage>` = `stage1`, `stage2`, `stage3`). **The three stages share one run directory, so each stage gets its own folder** — writing everything in one place overwrites the Stage 1 outputs that Stage 3 judges read when classifying origin (P/Q/N) (measured — PR #33 Stage 3).

- `summary.md` — review summary body. Becomes `reviews.body` as is.
- `comments.json` — array of inline comments.
- `replies/<code>.md` · `patches/<comment-id>.md` — Stage 2 and 3 thread replies and corrections to existing comments.
- `pre-polish/` — pre-edit copies of all of the above. PG6 compares against these.

```jsonc
[
  { "path": "api/auth/src/main/java/.../AuthService.java",  // file path in the PR
    "line": 42,              // line number in the new file. RIGHT side
    "side": "RIGHT",         // RIGHT if omitted
    "body": "**C-01** `issue (blocking)` · R-B (Data correctness)\n\n…",
    "code": "C-01",          // not sent when posting. For meta.json records
    "axis": "R-B",           // same
    "grade": "critical" }    // same
]
```

**Only four fields go into the post: `path`, `line`, `side`, `body`.** `code`, `axis`, and `grade` are recorded in `meta.json` with the comment id after posting — Stage 1 in `stage1[].comments`, Stage 2 in `stage2[-1].new_comments`, Stage 3 in `stage3.comments`. Stage 2 finds threads by `stage1[].comments[].id`.

Line-range anchors (`path:12-18`) and whole-file anchors (`path:0`) cannot be inline. **Move them into the summary body.** The anchor notation rules for judge output are in §2 of `02-judges.md`.

**Text going to GitHub is trimmed once right before posting** (`01-stages.md` §3-4 pre-post edit). This applies to `reply` and `patch` bodies as well as `post-review`. PG6 compares against the copy to confirm that anchors, grades, axes, first lines, and numbers are unchanged.

## 5. One-time setup

### 5-1. Bot account

| Item | Value |
|---|---|
| Account | A dedicated bot (a regular GitHub account; `bot` in `config.json`) |
| Repository permission | **collaborator read** — read is enough for review requests |
| Token | Bot PAT, scope `public_repo` |
| What it writes | Only reviews and comments. Uses only `event=COMMENT`; never approves or requests changes |

If the bot approved or requested changes, it would hold the merge gate, and people would bend the review to get past the bot.

### 5-2. Token file

```bash
mkdir -p ~/.config/pr-quorum
cat > ~/.config/pr-quorum/bot.env <<'ENV'
PR_QUORUM_BOT_TOKEN=ghp_...
ENV
chmod 600 ~/.config/pr-quorum/bot.env
```

**Do not commit it to a repository.** Sessions do not read this file — `pr-quorum.sh` reads it internally. The bot login name goes not in this file but in `bot` of `~/.pr-quorum/config.json`.

### 5-3. Entry points

Nothing to install. The chain loads the skills (`/pr-quorum:review`, `/pr-quorum:author`) and the judge agent with `claude -p --plugin-dir <plugin-dir>`.
`chain.sh` and `dream.sh` render the absolute script paths in session permissions from the templates every time they run, so wherever you clone the plugin, you never change paths by hand.

### 5-4. Running the watcher continuously (optional)

Put the following in `~/Library/LaunchAgents/io.github.thswlsqls.pr-quorum.plist` and run `launchctl load` (a minimal example; the plist in use wraps it in `/usr/bin/caffeinate -i` and logs to `~/Library/Logs/pr-quorum-watch.log`). For debugging, `scripts/watch.sh --once`.

```xml
<key>ProgramArguments</key>
<array>
  <string><plugin-dir>/scripts/watch.sh</string>
</array>
<key>StartInterval</key><integer>60</integer>
<key>WorkingDirectory</key>
<string><plugin-dir></string>
```

**PRs with risk `low` are merged automatically only when `auto_merge` in `~/.pr-quorum/config.json` is true (default false).**
When it is off, the chain does not merge even after passing the merge gate and the risk gate, and stops with `chain.state=ready`.
To turn off auto-merge (see "When to turn off auto-merge" in `rules/03-risk.md`), set `auto_merge` to false. The chain reads this value right before merging, so there is no need to restart the watcher.

It does not run while the machine is off. Once on, it polls and handles the backlog first. **It processes one PR at a time, in order** — if you assign the reviewer on PR B while PR A is running, B starts only after A finishes.

**Manual calls do not get `--settings`.** Headless sessions enforce tool permissions from the command line, but an interactive session a human opens runs with the usual settings. To get the same guarantees, start manual calls with `claude --settings ~/.pr-quorum/settings.json --setting-sources "" --plugin-dir <plugin-dir> --permission-mode dontAsk --mcp-config <plugin-dir>/mcp.json --strict-mcp-config` as well. `~/.pr-quorum/settings.json` exists after `chain.sh` has run once.

## 6. Confirmed by measurement — do not re-run these experiments

**Confirmed on 2026-08-20 with PR #31 (a temporary PR, discarded after checking) and PR #32.**

| What | Result |
|---|---|
| Assigning the bot as reviewer while it is a **read** collaborator | **Works.** But the GitHub search index takes a few seconds to catch up — right after assignment, `gh search prs --review-requested=` returns an empty array. The watcher's 60-second polling absorbs this |
| `POST /pulls/{N}/reviews` with a `public_repo` PAT | **Works.** Author is the bot account, state `COMMENTED` |
| Review request cleared automatically on review submission | **Cleared.** After posting, `reviewRequests` became an empty array |
| Anchor outside the diff | **Rejected — and the whole review with it.** `422 {"errors":["Line could not be resolved"]}`; a nonexistent file gives `Path could not be resolved`. **PG1 is the cheapest safeguard in this harness** |
| `line` anchor when `eval_sha` is older than head | **Attaches.** Posted with a SHA two commits behind head, and `line` and `original_line` were kept as is. There is no need to move the pinned SHA up to head |
| Using `pulls/{N}/files` as the basis for PG1 | **Breaks.** It lets through lines that are in the head diff but not in the `eval_sha` diff, and the post fails with 422. Use `compare/{base}...{pinned-SHA}` |
| Does `tools/pipeline/` worktree cleanup delete `pr-quorum-*`? | **No.** It deletes only the one `$WORKTREE_PATH` it created (`tools/pipeline/impl-agent/agents/impl-implementer.md:98`) |
| Editing comments on a closed PR | **Inline comments can be edited with `PATCH`. The review summary cannot** — `PUT .../reviews/{id}` returns 404 (a `GET` of the same review returns 200). To edit the summary, the PR must be open |
| `reply` · `patch` · `meta.json` records | All work. `review_id`, comment `id`, and `code`/`axis`/`grade` are all recorded |
| Infinite loop on reviewer reassignment | **Does not happen.** The watcher sees `stage1.review_id` and logs a skip because the review is already posted |
| Lock | Persists across tool calls. A dead pid invalidates it even before the TTL |
| Exit codes · rerunning `init` | 1 argument error · 2 no token · 3 gate · 4 API failure · 5 lock held, all confirmed. Rerunning `init` keeps the existing `stage1` records |

### 6-1. Stage 1 duration — operating assumption

**Running Stage 1 on PR #32 (4 files, 216 lines) took about 50 minutes for round 1 alone, and over 60 minutes through round 2.** The four judges, the challenger, and the three verifiers are all separate sessions, and judges go as far as running `./gradlew compileJava`.

- The watcher handles one PR at a time. A single PR holds the watcher for over an hour.
- The 3-hour `meta.lock` TTL accounts for this length. **Do not shorten it** — normal runs would lose the lock.
- **The round limit is `limits.stage1.max_rounds`** (3 in the template, 5 when the key is missing). Running 5 rounds can reach the 3-hour TTL, so keep `limits.stage1.timeout_min` below it. Record per-round time in `~/.pr-quorum/runs/<…>/rounds/`, and if runs start reaching the TTL, raise the TTL, not the limit.
- The large-PR cutoff (50 files / 3,000 lines) also keeps this time from growing linearly.

### 6-2. Headless session environment

| What | Result | So |
|---|---|---|
| Does `--settings` replace `.claude/settings.local.json`? | **No. They merge.** The local allow list also applied to the headless session (re-measured 2026-10-04) | `chain.sh` uses `--setting-sources ""` so local, project, and user settings and their hooks are not read. Skills and agents are loaded with `--plugin-dir` and are called regardless of this value |
| Can hooks be turned off? | `hooks:{}` does not turn them off. With `disableAllHooks: true` in both settings files, no `rtk` hook records appeared in measurement | Commands in headless sessions are not rewritten to `rtk …` |
| Does deny actually block? | **Yes.** With `Bash(git config:*)` in deny, no value is left in `.git/config` | The safeguard actually works rather than being a documentation promise |
| MCP | Not filtered by `--settings`. playwright, filesystem, and memory all started | `--mcp-config <plugin-dir>/mcp.json --strict-mcp-config` leaves only context7 |

> **Do not measure tool permissions by the session's self-report.** It answers inconsistently, saying the same command ran or was denied. Judge only by **observable side effects** (was a file created, was a setting value left).

### 6-3. Build shell — measured 2026-10-23 on macOS (improvement plan 2-01, step 0)

Probe run through `author-build` and `build` with a fake `HOME`; the real home was only read, with output to `/dev/null`. 0 means the attempt succeeded.

| What | Before | With §3-1 |
|---|---|---|
| `GH_TOKEN`·`GITHUB_TOKEN`·`ANTHROPIC_API_KEY`·`SSH_AUTH_SOCK`·`PR_QUORUM_*` in the environment | present (`SSH_AUTH_SOCK`) | none |
| `gh auth status` (real home) · `git credential fill` for github.com | 0 · 0 (keychain helper from the system git config) | 1 · 128 |
| Read `~/.config/pr-quorum/*`, `~/.config/gh/hosts.yml`, `~/.ssh`, `~/.aws`, `~/.claude`, `~/.claude.json`, `~/.pr-quorum/config.json` | all 0 | all 1 |
| `security find-generic-password -s gh:github.com` (real home) · `ssh-add -l` | 0 · 1 (agent reachable) | 44 · 2 (no agent) |
| Write `~/.pr-quorum/probe-target`, `~/.zshrc-probe`, `~/.gradle/init.d/probe`, `<repo>/.git/hooks/probe` | all 0 | all 1 |
| Write the worktree, `$TMPDIR`, `~/.gradle/caches` · `curl -I registry.npmjs.org` | 0 · 0 | 0 · 0 |
| Gradle daemon started in the user's shell, then a wrapper build | **the build ran in that daemon** ("Starting 2nd build in daemon", same pid) — outside any sandbox | `GRADLE_OPTS=-Dorg.gradle.daemon=false` forks a single-use daemon under the sandbox, even with `org.gradle.daemon=true` in the project's `gradle.properties`; the outer daemon stays idle |
| Java `user.home` with `HOME` changed | stays the passwd home — Gradle keeps using the real `~/.gradle` | — |
| tech-n-ai-backend `:common-security:test` (2 tests) and `build -x test`, twice | pass | pass, same results; second run all `UP-TO-DATE`, no downloads |
| tech-n-ai-frontend `npm run lint` in `app/` | exit 1, 3 errors | exit 1, the same 3 errors |

## 7. Porting order — how far along

| Step | Task | Done when | Status |
|---|---|---|---|
| 1 | Skeleton + the three rule documents | Running one Stage 1 round by hand on one PR produces outputs | Done |
| 2 | `profiles/backend.md` | All four axes have the four parts: what to look at / what not to look at / grade examples / measurement baselines | Done |
| 3 | `scripts/pr-quorum.sh` | One inline comment is attached to a dummy PR with the bot account, and PG1 catches an anchor outside the diff | Done — measured on PR #31 (§6) |
| 4 | Post Stage 1 on a real PR | The posted review has blocking and praise, and all anchors are inside the diff | Done — PR #33, 16 comments |
| 5 | Stage 2 · Stage 3 | Thread replies and new comments are attached and a `P` list is produced | Done — PR #33, 16 verdicts · 1 `P` |
| 6 | `profiles/frontend.md` + one frontend PR | Runs through the same procedure | Draft document only |
