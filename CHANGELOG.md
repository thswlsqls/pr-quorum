# Changelog

## 0.1.1

- `pr-quorum.sh` rejects, with exit 1 before calling GitHub, a repository name not in `repos` of `config.json` and a SHA that is not 7–40 hex characters.

## 0.1.0

First public release. Moved the review harness that ran in tech-n-ai-backend's `tools/pr-eval/` into a Claude Code plugin.

Two things were fixed before release.

- `reply`, `patch`, and `patch-review` in `pr-quorum.sh` exit 1 before calling GitHub when given a non-numeric comment or review id.
- The risk scorecard comment the bot leaves points to either "auto-merge" or "a human merges" depending on the `auto_merge` setting, and links to the rule document in this repository.
