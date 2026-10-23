# Changelog

## 0.2.0

- Docs, prompts, and script messages are in English.
- Stored values (verdicts, grades, status) and the posted Stage 2 verdict line now use English IDs: `addressed`·`partial`·`not-addressed`·`regressed`, `critical`·`major`·`minor`·`nit`, `pending`·`running`·`done`·`held-large`·`held-failed`. Readers still accept the old Korean values, so existing runs in `~/.pr-quorum/runs/` keep working.
- Review text follows the language of the PR.
- `README.ko.md` and `README.zh-CN.md` translate the README. Each records the `README.md` commit it follows, and `scripts/selftest.sh` warns when a translation falls behind.

## 0.1.1

- `pr-quorum.sh` rejects, with exit 1 before calling GitHub, a repository name not in `repos` of `config.json` and a SHA that is not 7–40 hex characters.

## 0.1.0

First public release. Moved the review harness that ran in tech-n-ai-backend's `tools/pr-eval/` into a Claude Code plugin.

Two things were fixed before release.

- `reply`, `patch`, and `patch-review` in `pr-quorum.sh` exit 1 before calling GitHub when given a non-numeric comment or review id.
- The risk scorecard comment the bot leaves points to either "auto-merge" or "a human merges" depending on the `auto_merge` setting, and links to the rule document in this repository.
