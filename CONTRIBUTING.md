# Contributing

Issues and PRs are welcome. Outside PRs are reviewed by a human, not by the chain: the chain runs only on PRs from authors the maintainer trusts.

## Before you change the harness

Read [`docs/harness.md`](docs/harness.md). It covers script contracts, output specs, and facts confirmed by measurement.

Develop in a separate clone or worktree, not in the clone your watcher runs from. A plugin loaded with `--plugin-dir` reads the files in that folder each time a session starts, so a half-edited harness would run a real review.

## Checks

- After changing a gate script (`scripts/pr-quorum.sh`, `scripts/risk.jq`), run `scripts/selftest.sh`. It re-runs the gates on past outputs without an LLM. If an output that was already posted fails the new rule, the rule is most likely wrong.
- CI runs `bash -n` and `selftest.sh` on macOS and Ubuntu for every PR, plus `shellcheck -S error` on Ubuntu.
- Add a line to [`CHANGELOG.md`](CHANGELOG.md) for user-visible changes. A marketplace install only picks up a release when `version` in `.claude-plugin/plugin.json` goes up. Raise it and add its `## <version>` section to the top of `CHANGELOG.md` in the same PR; `selftest.sh` checks they match. After the merge, `.github/workflows/release.yml` creates the `pr-quorum--v<version>` tag and a GitHub release with that section, so do not tag by hand.

## Sharing learnings

`learnings.md` builds up per user in `~/.pr-quorum/`. If a `scripts/dream.sh` proposal contains lessons that would help other repositories too, please open an issue or PR with them.

## Translations

`README.md` is the source. `README.ko.md` and `README.zh-CN.md` record the `README.md` commit they follow, and `selftest.sh` warns when they fall behind. When you change `README.md`, update the translations in the same PR or write "translations not updated" in the PR description. Other docs are English only.
