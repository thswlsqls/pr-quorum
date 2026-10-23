#!/usr/bin/env bash
# watch.sh — finds PRs with a review request for the bot and starts the chain (scripts/chain.sh).
# The chain runs from Stage 1 to merge with no human involved. To run stages one at a time, a person calls /pr-quorum:review.
# Runs continuously via launchd StartInterval 60. --once is the debugging path.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
OWNER="$(cfg .owner)"
# The bot login is read only from config.json's bot — if this value and the token file's account disagree,
# the watcher polls as the wrong account and the trigger silently never fires. (The token is not read here)
BOT="$(cfg '.bot // empty')"
[ -n "$BOT" ] || { echo "bot login not found: set bot in $PR_QUORUM_HOME/config.json" >&2; exit 2; }
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR_QUORUM="$HARNESS_DIR/scripts/pr-quorum.sh"
MAX_ATTEMPTS=2

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

known_profile() { [ -n "$(cfg --arg r "$1" '.repos[$r].profile // empty')" ]; }

# Is meta.lock valid — it is valid if it started less than 3 hours ago and the pid is alive.
lock_valid() {
  local m="$1" pid started s_epoch
  pid="$(jq -r '.lock.pid // empty' "$m")"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  started="$(jq -r '.lock.started_at // empty' "$m")"
  s_epoch="$(jq -rn --arg s "$started" '$s | fromdateiso8601' 2>/dev/null || echo 0)"
  [ "$s_epoch" -gt 0 ] || return 1
  [ $(( $(date -u +%s) - s_epoch )) -lt 10800 ]
}

# Removes the review and author worktrees (pr-quorum-<N>[-<sha7>] · pr-author-<N>) of merged PRs.
# Session permissions only include worktree add, and the chain cannot see merges done by a person, so the poller does it.
# No --force — if there are uncommitted changes, git refuses and only a log line is left. Branches are not touched
gc_worktrees() {
  local repo path dir wt name merged
  for repo in $(cfg '.repos | keys[]'); do
    path="$(cfg --arg r "$repo" '.repos[$r].path')"
    dir="$(dirname "$path")/$repo-worktrees"
    [ -d "$dir" ] || continue
    merged="$(gh pr list --repo "$OWNER/$repo" --state merged --limit 200 --json number --jq '.[].number')" || continue
    for wt in "$dir"/pr-quorum-* "$dir"/pr-author-*; do
      [ -d "$wt" ] || continue
      name="$(basename "$wt")"
      [[ "$name" =~ ^pr-(quorum|author)-([1-9][0-9]*)(-[0-9a-f]{7})?$ ]] || continue
      grep -qx "${BASH_REMATCH[2]}" <<<"$merged" || continue
      if git -C "$path" worktree remove "$wt"; then
        log "worktree removed — $repo $name (merged PR)"
      else
        log "worktree removal failed — $repo $name"
      fi
    done
    git -C "$path" worktree prune
  done
}

run_once() {
  local prs n
  gc_worktrees || log "worktree cleanup step failed — polling continues"
  # This is the only query that looks for review requests (apart from the merged-list query in the cleanup step above). PR comments are not polled.
  prs="$(gh search prs --owner "$OWNER" --review-requested="$BOT" --state=open \
          --json number,repository,isDraft,authorAssociation 2>/dev/null || echo '[]')"
  n="$(jq 'length' <<<"$prs")"
  [ "$n" -gt 0 ] || { log "no review requests"; return 0; }

  local i
  for (( i=0; i<n; i++ )); do
    local pr repo draft assoc m
    pr="$(jq -r ".[$i].number" <<<"$prs")"
    repo="$(jq -r ".[$i].repository.name" <<<"$prs")"
    draft="$(jq -r ".[$i].isDraft" <<<"$prs")"
    assoc="$(jq -r ".[$i].authorAssociation" <<<"$prs")"

    # 1) Repository with no known profile — the query is per --owner, so PRs from other repositories come back too.
    known_profile "$repo" || { log "skip $repo#$pr — no profile"; continue; }
    # 2) draft
    [ "$draft" = "false" ] || { log "skip $repo#$pr — draft"; continue; }
    # 2-1) Only PRs opened by the repository owner — the repository is public, so someone else's PR would feed its description and diff straight into a session that pushes and merges under the user's account
    [ "$assoc" = "OWNER" ] || { log "skip $repo#$pr — author is not the owner ($assoc)"; continue; }

    m="$PR_QUORUM_HOME/runs/$repo-pr$pr/meta.json"
    if [ -f "$m" ]; then
      # 3) Valid lock
      lock_valid "$m" && { log "skip $repo#$pr — lock held"; continue; }
      # 4) Held status — only a person resumes it
      case "$(jq -r '.status' "$m")" in
        held-*|보류*) log "skip $repo#$pr — $(jq -r '.status' "$m")"; continue ;;
      esac
      # 5) Stage 1 review already posted
      [ "$(jq -r '[.stage1[]?.review_id | select(. != null)] | length' "$m")" = "0" ] \
        || { log "skip $repo#$pr — already posted"; continue; }
      # Stop repeated failures
      if [ "$(jq -r '.attempts // 0' "$m")" -ge "$MAX_ATTEMPTS" ]; then
        log "$repo#$pr — failed $MAX_ATTEMPTS times in a row. Stopping at held-failed"
        "$PR_QUORUM" status "$repo" "$pr" "held-failed" >/dev/null
        continue
      fi
    fi

    log "Stage 1 start — $repo#$pr"
    "$PR_QUORUM" init "$repo" "$pr" >/dev/null
    "$PR_QUORUM" attempt "$repo" "$pr" inc >/dev/null

    # One chain runs from Stage 1 all the way to merge (scripts/chain.sh). Wait until it finishes —
    # that way launchd skips StartInterval ticks, adding a second guard against double runs.
    "$HARNESS_DIR/scripts/chain.sh" "$repo" "$pr" || log "chain stopped — $repo#$pr (chain.state=$(jq -r '.chain.state // "?"' "$m" 2>/dev/null))"

    log "chain finished — $repo#$pr (status=$(jq -r '.status' "$m" 2>/dev/null || echo '?'))"
  done
}

case "${1:-}" in
  --once|"") run_once ;;
  *) echo "usage: watch.sh [--once]" >&2; exit 1 ;;
esac
