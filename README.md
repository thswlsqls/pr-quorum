<p align="right">
  <strong>English</strong> | <a href="./README.ko.md">한국어</a> | <a href="./README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo-light.svg" alt="pr-quorum" width="240">
  </picture>
</p>

A Claude Code plugin that reviews your GitHub PRs with several Claude sessions, has an author session apply the review, checks the fixes, re-runs the build and tests, and uses a risk score to decide whether to merge.

Request a review from your bot account on a PR and the rest runs unattended. The review is posted like a human reviewer's: one summary plus inline comments on lines of code.

## How it works

| Stage | What it does |
|---|---|
| Stage 1 · review | Four judges review the PR on separate axes without seeing each other's results. A challenger re-checks every `critical`/`major` finding against the code, and three verifiers re-read the review. Up to 5 rounds |
| Author | A separate session (`/pr-quorum:author`) fixes the code and pushes to the PR branch with your gh account. It never force-pushes, merges, or approves |
| Stage 2 · followup | Replies in each thread with `addressed`, `partial`, `not-addressed`, or `regressed` (the fix introduced a new defect) |
| Stage 3 · measured | Re-runs the build and tests on the fixed commit and looks for defects the review missed (`P`) |

```mermaid
flowchart LR
  C["Stage 1 → author fixes → Stage 2 → Stage 3<br/>→ (author fixes → Stage 2)*"] --> MG{"Merge gate<br/>blocking 0 · regressed 0 · no test failures<br/>did the bot review the current head?"}
  MG -- no --> B[blocked]
  MG -- "critical/major in Stage 3 P" --> H
  MG -- yes --> RG{"Risk gate<br/>0–100 points"}
  RG -- "low (0–14)" --> A{"auto_merge"}
  A -- true --> M[gh pr merge]
  A -- "false (default)" --> R["ready<br/>a human merges"]
  RG -- "medium or higher" --> H["needs-human<br/>a human reviews and merges"]
```

The risk gate scores only which files changed and by how much, not code quality. PRs that touch authentication, secrets, CI, build scripts, or the harness itself score higher and are never merged automatically. Rules: [`rules/03-risk.md`](rules/03-risk.md).

### Example

A review the bot left on a real PR. The review follows the PR's language.

![Review summary the bot left on PR #67](assets/review-summary-en.png)

![Inline comment and follow-up verdict on PR #67](assets/inline-comment-en.png)

Stage 1 left 2 nits and 1 praise. Stage 2 judged both nits `addressed`, Stage 3 found nothing missed, the risk score was 0 (`low`), and the chain merged it.

## Design choices

- **Evidence is graded.** A finding must cite a repository norm document, an official doc quotation, a `file:line`, or a result of running something. A claim beyond what its evidence supports is dropped ([`rules/00-criteria.md`](rules/00-criteria.md) §4).
- **No scores in the review.** Only four grades (`critical`, `major`, `minor`, `nit`), and at least one praise.
- **Confirmed facts are pinned** in `frozen.md`, so rounds don't re-argue them without new evidence.
- **Everything is inspectable.** Rules in [`rules/`](rules/), judge instructions in [`rules/02-judges.md`](rules/02-judges.md), gates in [`scripts/`](scripts/), and per-round logs in `~/.pr-quorum/runs/`.

### Where the criteria come from

The review axes and how far each goes are taken from published guidelines, and each rule stays within what its quotation says.

<details>
<summary>Sources and quotations</summary>

| Harness rule | Source | Sentence it rests on |
|---|---|---|
| Design is checked first — why `R-A` is the first axis and J1 wins in deduplication | Google, [What to look for in a code review](https://google.github.io/eng-practices/review/reviewer/looking-for.html) | "The most important thing to cover in a review is the overall design of the CL." |
| Concurrency is split out as its own axis (`R-C`) | Same document, Functionality section | "…if there is some sort of **parallel programming** going on in the CL that could theoretically cause deadlocks or race conditions." |
| Wording of the test axis verdict — not "are there tests" but "do they fail when it breaks" | Same document, Tests section | "Will the tests actually fail when the code is broken?" |
| At least one praise must always be written | Same document, Good Things section · [Conventional Comments](https://conventionalcomments.org/) | "If you see something nice in the CL, tell the developer…" · "Try to leave at least one of these comments per review." |
| Verdict wording is not "is this the ideal design" but "does it worsen code health" | Google, [The Standard of Code Review](https://google.github.io/eng-practices/review/reviewer/standard.html) | "reviewers should favor approving a CL once it is in a state where it definitely improves the overall code health of the system being worked on, even if the CL isn't perfect." |
| Taste without evidence goes no higher than `nitpick` | Same document | "On matters of style, the style guide is the absolute authority. Any purely style point (whitespace, etc.) that is not in the style guide is a matter of personal preference." |
| Comment labels — `issue (blocking)` · `suggestion` · `nitpick (non-blocking)` · `praise` | [Conventional Comments](https://conventionalcomments.org/) | Follows the label + parenthesized decoration (blocking / non-blocking) format as is |
| Why the first item of the security axis (`R-I`) is missing authorization | OWASP, [ASVS 5.0.0](https://github.com/OWASP/ASVS/blob/v5.0.0/5.0/en/0x17-V8-Authorization.md) V8 Authorization, 8.2.2 (Level 1) | "Verify that the application ensures that data-specific access is restricted to consumers with explicit permissions to specific data items to mitigate insecure direct object reference (IDOR) and broken object level authorization (BOLA)." |
| Basis for treating tokens or credentials left in logs as a defect | [Same standard](https://github.com/OWASP/ASVS/blob/v5.0.0/5.0/en/0x25-V16-Security-Logging-and-Error-Handling.md) V16 Security Logging and Error Handling, 16.2.5 (Level 2) | "Verify that when logging sensitive data, the application enforces logging based on the data's protection level. For example, it may not be allowed to log certain data, such as credentials or payment details. Other data, such as session tokens, may only be logged by being hashed or masked, either in full or partially." |

The test axis does not push hard because its source, *"Ask for unit, integration, or end-to-end tests **as appropriate** for the change."*, offers a choice, so "these tests are missing, so blocking" would go beyond it.

The Google eng-practices repository is archived (last push 2024-09-19); the quotations are from that date. ASVS is not run as a checklist: most of its requirements need configuration and runtime context that a PR diff does not show.

</details>

Axis definitions are in [`examples/profiles/`](examples/profiles/).

## Requirements

- macOS, or Linux including WSL2 on Windows. The scripts are bash and call no macOS-only commands; only the launchd watcher example is macOS-specific. Native Windows (PowerShell, cmd) is not supported
- [Claude Code](https://code.claude.com/docs), `gh` logged in with your own account, `jq`, `git`
- A separate GitHub bot account (see [Setup](#1-bot-account))
- Repositories on github.com. GitHub Enterprise Server and ghe.com are not supported
- By default only PRs opened by the repository owner run; others are skipped. To run teammates' PRs, list them in `trust.authors` or `trust.associations`, and for an organization's repository set `repos.<name>.owner` ([Setup §3](#3-pr-quorumconfigjson)). A trusted author's PR description and diff reach sessions that push and merge under your gh account, so trust only people you would let do that

## Installation

To call the skills from a normal Claude Code session, install from the marketplace:

```
/plugin marketplace add thswlsqls/pr-quorum
/plugin install pr-quorum@pr-quorum
```

The unattended chain does **not** use that install. It runs with `--setting-sources ""` (so user-enabled plugins are not loaded) and needs a fixed path, so it loads a clone with `--plugin-dir`. In this document `<plugin-dir>` is the absolute path of that clone.

```bash
git clone https://github.com/thswlsqls/pr-quorum.git <plugin-dir>
```

Keep this clone on main and make harness changes in a different clone or worktree, so a half-edited harness never runs a real review.

## Setup

### 1. Bot account

Create your own GitHub bot account; there is no shared bot.

- Invite it to each repository as a **collaborator with read**, then accept the invitation (sign in as the bot). That is enough to receive review requests.
- Create a PAT for it: a classic token with scope `public_repo` for public repositories. For a private repository the bot is a collaborator on, use scope `repo`; outside collaborators can only use classic tokens.
- Keep it at read. Both scopes can write to repositories the bot has write access to, so raising the bot to write lets this token push.

The bot only posts reviews and comments. It never approves or requests changes.

### 2. Token file

```bash
mkdir -p ~/.config/pr-quorum
cat > ~/.config/pr-quorum/bot.env <<'ENV'
PR_QUORUM_BOT_TOKEN=<bot-PAT>
ENV
chmod 600 ~/.config/pr-quorum/bot.env
```

`GH_TOKEN` also works as the key name. Only `scripts/pr-quorum.sh` reads this file; review sessions are denied access. Never commit it.

### 3. `~/.pr-quorum/config.json`

```bash
mkdir -p ~/.pr-quorum/profiles
cp <plugin-dir>/templates/config.json ~/.pr-quorum/config.json
touch ~/.pr-quorum/learnings.md ~/.pr-quorum/human-labels.md
```

| Key | Meaning |
|---|---|
| `owner` | Your GitHub login. The owner of every repository under `repos` that does not set its own; the watcher looks for review requests in each owner's repositories |
| `bot` | The bot login from step 1. Must match the token's account |
| `auto_merge` | Whether the chain merges a PR that passed both gates. Default `false`: the chain stops at `ready` |
| `trust` | Whose PRs run the chain: `authors` (logins) or `associations` (GitHub `author_association` values). Missing: `associations` is `["OWNER"]`. A value GitHub does not use stops the watcher and chain with exit 2; values beyond `OWNER`, `MEMBER`, `COLLABORATOR` log a warning. For an organization, prefer logins: `MEMBER` is everyone in it |
| `repos` | Per repository name: the absolute path of its local clone (`path`) and the profile to use (`profile`) |
| `repos.<name>.owner` | The repository's GitHub owner, a user or an organization. Missing: the top-level `owner` |
| `repos.<name>.commands` | The `build`, `test`, and `lint` commands sessions run in a PR worktree; `<target>` in a command is filled in per run. Missing: `./gradlew [<target>:]build` and `test` in a Gradle worktree, otherwise `npm run build`, `npm run lint`, and `npx --no -- tsc --noEmit` as the test. A kind with no command is recorded as `not measured` |
| `limits` | Per step (`stage1`, `stage2`, `stage3`, `author`): `budget_usd` and `timeout_min` (wall time). `stage1.max_rounds` caps Stage 1 rounds (5 when missing). A missing key means no cap. A session cut by a cap is not retried; the chain stops at `blocked` |
| `models` | `session`: the model of each chain session; `subagent`: the model of the judges and other subagents. `null` or missing: Claude Code's default |

All keys and sample values are in [`templates/config.json`](templates/config.json). The keys added in 0.3.0 are optional; without them the chain behaves as before. The template sets sample `limits` (Stage 1 at 3 rounds); delete a key to drop that cap.

`learnings.md` collects lessons across PRs and is read by review sessions. `human-labels.md` is where you grade the bot's comments. Each PR gets a worktree under `<repo-name>-worktrees/` next to the repository clone.

### 4. Profile

A profile defines the review axes and what each judge does and does not look at. Copy a sample and adapt it to your repository; the file name is the `profile` value.

```bash
cp <plugin-dir>/examples/profiles/backend.md ~/.pr-quorum/profiles/backend.md
```

The samples ([`backend.md`](examples/profiles/backend.md), [`frontend.md`](examples/profiles/frontend.md)) were written for a Spring Boot backend and a Next.js frontend.

Then check the setup with `<plugin-dir>/scripts/doctor.sh`. It prints one line per check (commands, `config.json`, each repository's path and profile, the gh login, the token file's mode and account, the bot's invitation) and exits 2 if any line is `FAIL`. It reads only and posts nothing.

### 5. Watcher (optional)

The watcher polls every 60 seconds for review requests to the bot. Without it, requesting a review does nothing and you run the chain by hand ([Usage](#usage)). On macOS, save the following as `~/Library/LaunchAgents/io.github.thswlsqls.pr-quorum.plist` and run `launchctl load` on it. `caffeinate -i` keeps the machine awake.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.github.thswlsqls.pr-quorum</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-i</string>
    <string><plugin-dir>/scripts/watch.sh</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>WorkingDirectory</key><string><plugin-dir></string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string><dirs-containing-claude-gh-jq-git></string>
  </dict>
  <key>StandardOutPath</key><string><home-dir>/Library/Logs/pr-quorum-watch.log</string>
  <key>StandardErrorPath</key><string><home-dir>/Library/Logs/pr-quorum-watch.log</string>
</dict>
</plist>
```

To test it once without launchd, run `<plugin-dir>/scripts/watch.sh --once`. The watcher takes one PR at a time and picks up requests that arrived while the machine was off.

On Linux (a cloud VM, or WSL2 on Windows), run `watch.sh` every minute from cron or a systemd timer, without the macOS-only `caffeinate`.

- **Login**: on a machine without a browser, log in to `gh` with the device code it offers or with `gh auth login --with-token`, and to Claude Code by running `claude` once. Claude Code stores the login in `~/.claude/.credentials.json`, so cron and systemd jobs can use it.
- **cron**: unlike launchd, cron starts the watcher again while a chain is still running, so wrap it in `flock -n`. Otherwise a second chain can start on the same PR and stop it at `held-failed` after one real try. cron does not expand variables such as `$HOME`, so write `PATH` out in full.

  ```
  # crontab -e
  PATH=<dirs-containing-claude-gh-jq-git>:/usr/bin:/bin
  * * * * * cd <plugin-dir> && flock -n <home-dir>/.pr-quorum/watch.lock scripts/watch.sh >> <home-dir>/.pr-quorum/watch.log 2>&1
  ```

- **systemd**: start a `Type=oneshot` service from a timer with both `OnBootSec=1min` and `OnUnitActiveSec=1min`; `OnUnitActiveSec=` alone never fires. The timer does not start the service while it is still running, so `flock` is not needed. Set `PATH` with `Environment=` in the service, and for a user timer run `loginctl enable-linger` so it keeps running after you log out.
- **WSL2**: set `systemd=true` under `[boot]` in `/etc/wsl.conf` and run `wsl --shutdown`. WSL stops a distro after 15 seconds idle and does not start it when you log in to Windows, so set `instanceIdleTimeout=-1` under `[general]` in `%UserProfile%\.wslconfig` and run `wsl.exe -d <distro>` from Task Scheduler at logon. Keep Windows from sleeping as well.

## Usage

`<repo>` below is a repository name under `repos` in `config.json`, and `<pr>` is the PR number.

### Review a PR

Open the PR (not as a draft) and add the bot account as a reviewer. Within a minute the watcher starts the chain, which runs Stage 1 through the merge decision.

Follow progress in the watcher log, or in the PR's state file:

```bash
tail -f ~/Library/Logs/pr-quorum-watch.log
jq '{status, chain}' ~/.pr-quorum/runs/<repo>-pr<pr>/meta.json
```

The chain ends in one of these states (`chain.state`):

| State | Meaning | What to do |
|---|---|---|
| `merged` | Passed both gates with `auto_merge: true` | Nothing |
| `ready` | Passed both gates; `auto_merge` is off | Merge it yourself |
| `needs-human` | Risk is `medium` or higher, or Stage 3 found missed `critical`/`major` defects | Review and decide yourself. The risk scorecard is on the PR |
| `blocked` | Merge gate failed, a merge conflict, a session left no record, a session hit its `limits` budget or time cap, or the head moved | Read `chain.reason`, fix the cause, then run the chain again. The bot also posts the reason and the command to resume once as a comment on the PR |

### Run the chain by hand

Without the watcher, or to resume a `blocked` chain, run it directly. It resumes where it stopped.

```bash
<plugin-dir>/scripts/chain.sh <repo> <pr>
```

### Run one stage

To run a single stage interactively, start Claude Code with the same permissions the chain uses. A plain session does not have them. `~/.pr-quorum/settings.json` exists after `chain.sh` has run once.

```bash
claude --settings ~/.pr-quorum/settings.json --setting-sources "" --plugin-dir <plugin-dir> \
  --permission-mode dontAsk --mcp-config <plugin-dir>/mcp.json --strict-mcp-config
```

Then, inside the session:

```
/pr-quorum:review stage1 <repo> <pr>
/pr-quorum:review stage2 <repo> <pr>
/pr-quorum:review stage3 <repo> <pr>
/pr-quorum:author <repo> <pr>
```

PRs over 50 changed files or 3,000 changed lines are held as `held-large`. To review one anyway, add `--approve` to Stage 1.

### Maintenance

| Command | When |
|---|---|
| `git -C <plugin-dir> pull --ff-only` | To get a new version into the chain. The clone does not update itself |
| `<plugin-dir>/scripts/dream.sh [<repo>-pr<N>...]` | Summarizes learning candidates from past runs into `~/.pr-quorum/runs/_dream/<time>/proposal.md`. You decide what goes into `learnings.md` |
| `<plugin-dir>/scripts/risk-audit.sh <repo> [N]` | Lists the risk score of the last N merged PRs (default 30) next to any fix or revert within 14 days, to tune the auto-merge threshold |
| `<plugin-dir>/scripts/selftest.sh` | After changing a gate script. Re-runs the gates on past outputs without an LLM |
| `<plugin-dir>/scripts/doctor.sh` | After setup or a `config.json` change, or when the watcher stops picking up requests. Read-only; exits 2 on any `FAIL` |

For the marketplace install, `claude plugin update pr-quorum@pr-quorum` picks up a release when `version` goes up. Changes are in [`CHANGELOG.md`](CHANGELOG.md).

## Troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| Watcher log: `error — search failed (<owner>): …` | The search with the bot token failed: an expired or revoked token, a rate limit, or the network. The watcher exits 2 rather than read it as no requests | Run `doctor.sh`. Replace the token in `bot.env`, or wait out the rate limit |
| Watcher log: `warning — search for <owner> hit --limit 100` | More than 100 open review requests to the bot under one owner | Requests past 100 may be missed. Remove the bot from stale PRs |
| `doctor.sh` prints `FAIL — …` | A prerequisite is missing. Each line names what to fix | Fix it and run `doctor.sh` again until it prints `doctor — all checks passed` |
| `blocked` with `budget cap $… reached` or `wall-clock cap of … min reached` | A session hit `limits.<step>.budget_usd` or `timeout_min`. It is not retried | Raise the limit and run `chain.sh <repo> <pr>` again. A Stage 1 lock left by the stopped session clears once its process is gone or after 3 hours; to release it now, run `<plugin-dir>/scripts/pr-quorum.sh unlock <repo> <pr>` |
| Stage 3 reports the build or tests as `not measured` | No command for that kind: `repos.<name>.commands` lacks it, or there is no `commands` and the worktree has neither `gradlew` nor `package.json` (Gradle has no default lint) | Set `repos.<name>.commands.build`, `test`, `lint` |
| Watcher log: `skip <repo>#<pr> — author is not trusted (<login>, <association>)`, or `chain.sh` exits 3 with the same reason | The PR's author is in neither `trust.authors` nor `trust.associations` | Add the login to `trust.authors` if you trust that person |
| A script exits 2 with `GH_HOST=… — pr-quorum supports only github.com` | `GH_HOST` is set to a host other than github.com | Unset `GH_HOST` in the environment the watcher and chain run in |

## Security

Each chain session runs with `claude -p --settings <rendered-settings-file> --permission-mode dontAsk`, which refuses any tool not on the allow list ([`templates/`](templates/)). Review sessions can write only under `~/.pr-quorum/runs/`, post to GitHub only through `scripts/pr-quorum.sh`, and cannot read the token file. The author session pushes only through `scripts/author-push.sh`, which refuses force pushes and other branches.

Other safeguards:

- Only PRs from trusted authors run: the repository owner by default, plus anyone in `trust.authors` or `trust.associations`. Trust comes only from `config.json` and the GitHub API. The watcher filters PRs and `chain.sh` checks again. A trusted author's PR text reaches sessions that push and merge under your account, so the trust list is the boundary.
- Sessions cannot call build tools directly. Builds and tests run only through `pr-quorum.sh build` (review: a clean worktree at a SHA the PR pinned) and `pr-quorum.sh author-build` (the author's worktree), which run the command from `repos.<name>.commands` or the Gradle/npm default.
- Every post and push is scanned for tokens first. `pr-quorum.sh`, `author-reply.sh`, and `author-push.sh` refuse a body or commit that holds a GitHub token pattern or the value of the bot, `GH_TOKEN`, `GITHUB_TOKEN`, or your gh token; `author-push.sh` scans each commit being pushed, not only the net diff.
- Sessions cannot edit `meta.json`, which the merge gate reads. They write Stage 2 and Stage 3 records through `pr-quorum.sh` subcommands.
- PR descriptions, comments, and diffs are treated as data, not instructions. The author session takes tasks only from the bot's comments.

## Contributing

Issues and PRs are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

[MIT](LICENSE)
