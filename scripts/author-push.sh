#!/usr/bin/env bash
# author-push.sh — the path the author session uses to push its fix commits. Call it from inside the PR worktree.
# Reads the PR's head branch from GitHub and pushes the current HEAD to that branch only, without force.
# It takes no refspec or flags, so the session cannot choose a push to main, a force push, or a push to another branch (audit S-4).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/token-scan.sh"

die() { echo "author-push.sh: $1" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: author-push.sh <repo> <pr>"
REPO="$1"; PR="$2"
[ "$(cfg --arg r "$REPO" '.repos | has($r)')" = true ] || die "unknown repository: $REPO"
[[ "$PR" =~ ^[0-9]+$ ]] || die "PR number is not numeric: $PR"
SLUG="$(repo_slug "$REPO")" || exit 2  # The session calls this script, so the owner comes only from config.json, not from environment variables

# A PR from a fork would push to the same-named branch in the base repository, so reject it
cross="$(gh pr view "$PR" --repo "$SLUG" --json isCrossRepository --jq .isCrossRepository)"
[ "$cross" = "false" ] || die "PR comes from a fork"
head="$(gh pr view "$PR" --repo "$SLUG" --json headRefName --jq .headRefName)"
remote_head="$(gh pr view "$PR" --repo "$SLUG" --json headRefOid --jq .headRefOid)"
default="$(gh repo view "$SLUG" --json defaultBranchRef --jq .defaultBranchRef.name)"
current="$(git symbolic-ref --short HEAD 2>/dev/null)" || die "HEAD is not a branch (detached)"

[ -n "$head" ] || die "could not read the head branch of PR #$PR"
[ "$head" != "$default" ] || die "head branch is the default branch ($default)"
[ "$current" = "$head" ] || die "current branch ($current) differs from PR head ($head)"
# The worktree's origin must be this repository — called from another repository's worktree, it would create a branch in the wrong place
# git push sends to every push URL if there are several. There must be exactly one, and it must be this repository
urls="$(git remote get-url --push --all origin)"
[ "$(wc -l <<<"$urls")" -eq 1 ] && [[ "$urls" =~ ^(https://|git@)github\.com[:/]$SLUG(\.git)?$ ]] \
  || die "origin push URL is not exactly $SLUG"

# What is about to go out — every commit's diff (as text, binary files included) and message since the PR head on GitHub.
# A commit holding a token is not pushed (exit 3, as pr-quorum.sh's gate violation). The matched text is never echoed
git cat-file -e "$remote_head^{commit}" 2>/dev/null || die "PR head ${remote_head:0:7} is not in this clone — git fetch origin $head first"
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
{ git diff --text "$remote_head..HEAD"; git log --format=%B "$remote_head..HEAD"; } > "$out"
scan_tokens "$out" || { echo "author-push.sh: the commits to push hold a token — nothing was pushed. Remove it and rewrite the commit" >&2; exit 3; }

# The refspec has no +, so GitHub rejects anything that is not a fast-forward
git push origin "HEAD:refs/heads/$head"
