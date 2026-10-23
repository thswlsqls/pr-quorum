#!/usr/bin/env bash
# author-reply.sh — the path the author session uses to post one reply to a review thread. It is posted under the user's gh account.
# If the third argument is comment, it posts one PR comment; if body, it replaces the PR description. gh pr comment/edit --body-file also uploads any file, so they go through here too.
# Session permissions block `gh api`, so this is the only write path. Only body files under runs/ are accepted —
# `-F body=@<file>` reads any file and posts it as a public comment, so this keeps a token file from going out as a reply.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/token-scan.sh"
OWNER="$(cfg .owner)"  # The session calls this script, so read only from config.json, not from environment variables
RUNS="$(cd "$PR_QUORUM_HOME/runs" && pwd -P)"

die() { echo "author-reply.sh: $1" >&2; exit 1; }

[ $# -eq 4 ] || die "usage: author-reply.sh <repo> <pr> <comment_id|comment|body> <body_file>"
REPO="$1"; PR="$2"; ID="$3"; BODY="$4"
[ "$(cfg --arg r "$REPO" '.repos | has($r)')" = true ] || die "unknown repository: $REPO"
[[ "$PR" =~ ^[0-9]+$ ]] || die "PR number is not numeric: $PR"
[[ "$ID" =~ ^([0-9]+|comment|body)$ ]] || die "third argument must be a comment id, comment, or body: $ID"
[ -f "$BODY" ] && [ ! -L "$BODY" ] || die "body file is missing or is a link: $BODY"
body_dir="$(cd "$(dirname "$BODY")" && pwd -P)"
case "$body_dir/" in "$RUNS"/*) ;; *) die "body file must be under $RUNS: $BODY" ;; esac

FILE="$body_dir/$(basename "$BODY")"
# A body holding a token is not posted (exit 3, as pr-quorum.sh's gate violation). The matched text is never echoed
scan_tokens "$FILE" || { echo "author-reply.sh: body holds a token — nothing was posted. Remove it from the file" >&2; exit 3; }
case "$ID" in
  comment) gh pr comment "$PR" --repo "$OWNER/$REPO" --body-file "$FILE" ;;
  body)    gh pr edit "$PR" --repo "$OWNER/$REPO" --body-file "$FILE" ;;
  *)       gh api --method POST "repos/$OWNER/$REPO/pulls/$PR/comments/$ID/replies" -F "body=@$FILE" ;;
esac
