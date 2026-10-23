#!/usr/bin/env bash
# watch.sh — finds PRs with a review request for the bot and starts the chain (scripts/chain.sh).
# The chain runs from Stage 1 to merge with no human involved. To run stages one at a time, a person calls /pr-quorum:review.
# Runs continuously via launchd StartInterval 60. --once is the debugging path.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
require_dotcom
trust_check || exit 2
# The bot login is read only from config.json's bot — if this value and the token file's account disagree,
# the watcher polls as the wrong account and the trigger silently never fires. (The token is not read here)
BOT="$(cfg '.bot // empty')"
[ -n "$BOT" ] || { echo "bot login not found: set bot in $PR_QUORUM_HOME/config.json" >&2; exit 2; }
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR_QUORUM="$HARNESS_DIR/scripts/pr-quorum.sh"
MAX_ATTEMPTS=2
SEARCH_LIMIT=100
SEARCH_ERR="$(mktemp)"
GC_CACHE=""   # "<repo> <N> <state>" lines — PR states already asked in this cleanup (bash 3.2 has no associative arrays)
trap 'rm -f "$SEARCH_ERR" ${GC_CACHE:+"$GC_CACHE"}' EXIT

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

known_profile() { [ -n "$(cfg --arg r "$1" '.repos[$r].profile // empty')" ]; }

# Distinct owners of the repositories in config.json — the search runs once per owner
owners() {
  local r s
  for r in $(cfg '.repos | keys[]'); do s="$(repo_slug "$r")" || return 2; echo "${s%/*}"; done | sort -u
}

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

# pr_closed_state <repo> <slug> <N> — prints MERGED or CLOSED when GitHub says so; prints nothing for OPEN or a failed lookup.
# Each PR is asked once per cleanup
pr_closed_state() {
  local s; s="$(awk -v r="$1" -v n="$3" '$1 == r && $2 == n {print $3; exit}' "$GC_CACHE")"
  if [ -z "$s" ]; then
    s="$(gh pr view "$3" --repo "$2" --json state --jq .state 2>/dev/null || echo ERROR)"
    echo "$1 $3 ${s:-ERROR}" >> "$GC_CACHE"
  fi
  case "$s" in MERGED|CLOSED) echo "$s" ;; esac
}

# chain_running <repo> <N> — a chain holds runs/<repo>-pr<N>/.chain.lock and its pid is alive
chain_running() { local p; p="$(cat "$PR_QUORUM_HOME/runs/$1-pr$2/.chain.lock/pid" 2>/dev/null)" && kill -0 "$p" 2>/dev/null; }

# Removes the review and author worktrees (pr-quorum-<N>[-<sha7>] · pr-author-<N>) of merged or closed PRs.
# Session permissions only include worktree add, and the chain cannot see merges done by a person, so the poller does it.
# Each worktree's PR state is asked directly, so old PRs are never missed; only a confirmed MERGED or CLOSED removes it, and a failed
# lookup keeps it. A PR whose chain is running is skipped. Runs at most every 30 minutes ($PR_QUORUM_HOME/.gc-stamp).
# No --force — if there are uncommitted changes, git refuses and only a log line is left. Branches are not touched
gc_worktrees() {
  local repo slug path dir wt name n st
  [ -z "$(find "$PR_QUORUM_HOME/.gc-stamp" -mmin -30 2>/dev/null)" ] || return 0
  touch "$PR_QUORUM_HOME/.gc-stamp"
  [ -n "$GC_CACHE" ] || GC_CACHE="$(mktemp)"
  : > "$GC_CACHE"
  for repo in $(cfg '.repos | keys[]'); do
    path="$(cfg --arg r "$repo" '.repos[$r].path')"
    dir="$(dirname "$path")/$repo-worktrees"
    [ -d "$dir" ] || continue
    slug="$(repo_slug "$repo")" || continue
    for wt in "$dir"/pr-quorum-* "$dir"/pr-author-*; do
      [ -d "$wt" ] || continue
      name="$(basename "$wt")"
      [[ "$name" =~ ^pr-(quorum|author)-([1-9][0-9]*)(-[0-9a-f]{7})?$ ]] || continue
      n="${BASH_REMATCH[2]}"
      st="$(pr_closed_state "$repo" "$slug" "$n")"; [ -n "$st" ] || continue
      chain_running "$repo" "$n" && { log "worktree kept — $repo $name (chain running)"; continue; }
      if git -C "$path" worktree remove "$wt"; then
        log "worktree removed — $repo $name ($st PR)"
      else
        log "worktree removal failed — $repo $name"
      fi
    done
    git -C "$path" worktree prune
  done
}

run_once() {
  local prs="[]" found n own o
  gc_worktrees || log "worktree cleanup step failed — polling continues"
  own="$(owners)" || return 2
  # This is the only query that looks for review requests (apart from the PR-state lookups in the cleanup step above), once per owner. PR comments are not polled.
  # A failed search (expired token, rate limit, network) exits 2 — it must not read as "no review requests"
  for o in $own; do
    if ! found="$(gh search prs --owner "$o" --review-requested="$BOT" --state=open --limit "$SEARCH_LIMIT" \
            --json number,repository,isDraft,authorAssociation,author 2>"$SEARCH_ERR")"; then
      log "error — search failed ($o): $(head -3 "$SEARCH_ERR" | paste -sd ' ' -)" >&2
      return 2
    fi
    [ "$(jq 'length' <<<"$found")" -lt "$SEARCH_LIMIT" ] \
      || log "warning — search for $o hit --limit $SEARCH_LIMIT; some review requests may be missed" >&2
    prs="$(jq -c --argjson f "$found" '. + $f' <<<"$prs")"
  done
  n="$(jq 'length' <<<"$prs")"
  [ "$n" -gt 0 ] || { log "no review requests"; return 0; }

  local i
  for (( i=0; i<n; i++ )); do
    local pr repo nwo draft assoc login rc m
    pr="$(jq -r ".[$i].number" <<<"$prs")"
    repo="$(jq -r ".[$i].repository.name" <<<"$prs")"
    nwo="$(jq -r ".[$i].repository.nameWithOwner" <<<"$prs")"
    draft="$(jq -r ".[$i].isDraft" <<<"$prs")"
    assoc="$(jq -r ".[$i].authorAssociation" <<<"$prs")"
    login="$(jq -r ".[$i].author.login // empty" <<<"$prs")"

    # 1) Repository with no known profile — the query is per --owner, so PRs from other repositories come back too.
    #    Matched by owner and name: with several owners, a same-named repository under another owner must not pass
    { known_profile "$repo" && [ "$nwo" = "$(repo_slug "$repo")" ]; } || { log "skip $nwo#$pr — no profile"; continue; }
    # 2) draft
    [ "$draft" = "false" ] || { log "skip $repo#$pr — draft"; continue; }
    # 2-1) Only PRs from trusted authors (config.sh is_trusted) — someone else's PR would feed its description and diff straight into a session that pushes and merges under the user's account
    rc=0; is_trusted "$login" "$assoc" || rc=$?
    [ "$rc" != 2 ] || return 2
    [ "$rc" = 0 ] || { log "skip $repo#$pr — author is not trusted ($login, $assoc)"; continue; }

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
  # Cleanup only, now — for a manual sweep and for selftest. Clears the stamp so the 30-minute wait does not apply
  --gc-only) rm -f "$PR_QUORUM_HOME/.gc-stamp"; gc_worktrees ;;
  *) echo "usage: watch.sh [--once | --gc-only]" >&2; exit 1 ;;
esac
