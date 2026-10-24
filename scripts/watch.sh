#!/usr/bin/env bash
# watch.sh — finds PRs with a review request for the bot and starts the chain (scripts/chain.sh).
# The chain runs from Stage 1 to merge with no human involved. To run stages one at a time, a person calls /pr-quorum:review.
# Runs continuously via launchd StartInterval 60. --once is the debugging path.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
need_cmds claude gh jq git || exit 2
# --plist prints the macOS LaunchAgent (README Setup §5) for this plugin folder and $HOME. Its PATH is the folders of claude, gh, jq and git
# found now, then /usr/bin and /bin — launchd starts with a short PATH. Needs no config.json
if [ "${1:-}" = --plist ]; then
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" path=""
  for c in claude gh jq git; do d="$(dirname "$(command -v "$c")")"; case ":$path:" in *":$d:"*) ;; *) path="${path:+$path:}$d" ;; esac; done
  for d in /usr/bin /bin; do case ":$path:" in *":$d:"*) ;; *) path="$path:$d" ;; esac; done
  xml() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }   # a folder name with & or < breaks the plist; sed, as bash 5.2 reads & in ${//}
  dir="$(xml "$dir")" path="$(xml "$path")" home="$(xml "$HOME")"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.github.thswlsqls.pr-quorum</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-i</string>
    <string>$dir/scripts/watch.sh</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>WorkingDirectory</key><string>$dir</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$path</string>
  </dict>
  <key>StandardOutPath</key><string>$home/Library/Logs/pr-quorum-watch.log</string>
  <key>StandardErrorPath</key><string>$home/Library/Logs/pr-quorum-watch.log</string>
</dict>
</plist>
PLIST
  exit 0
fi
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
SEARCH_ERR="$(pq_mktemp)"
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

# chain_running <repo> <N> — a chain holds runs/<repo>-pr<N>/.chain.lock and its pid is alive.
# A lock folder with no pid yet is a chain between its mkdir and its pid write (chain.sh), so it counts as running
chain_running() {
  local l="$PR_QUORUM_HOME/runs/$1-pr$2/.chain.lock" p
  [ -d "$l" ] || return 1
  p="$(cat "$l/pid" 2>/dev/null || true)"
  [ -z "$p" ] || kill -0 "$p" 2>/dev/null
}

# A chain killed after Stage 1 (SIGKILL, machine restart) never runs its EXIT trap, and one ended by a signal runs it without
# recording a stop — either way chain.state keeps an in-progress value, and the posted review removed the review request, so
# the search below never finds the PR again. Such a chain is marked blocked with the one notice the chain itself would post
# (only on an OPEN PR, as notify_stop does). It is not resumed: a person reruns chain.sh, as the notice says
mark_dead_chains() {
  local m dir repo pr state at st reason body
  for m in "$PR_QUORUM_HOME"/runs/*-pr*/meta.json; do
    [ -f "$m" ] || continue
    # Held statuses, no Stage 1 review, and any state not on this in-progress list are left alone
    state="$(jq -r 'select((.status // "" | test("^(held-|보류)")) | not)
                    | select([.stage1[]?.review_id | select(. != null)] | length > 0)
                    | .chain.state // empty | select(test("^(stage[123]|author|merge-gate)$"))' "$m" 2>/dev/null)" || continue
    [ -n "$state" ] || continue
    dir="$(basename "$(dirname "$m")")"; repo="${dir%-pr*}"; pr="${dir##*-pr}"
    [[ "$pr" =~ ^[1-9][0-9]*$ ]] && known_profile "$repo" || continue
    chain_running "$repo" "$pr" && continue
    lock_valid "$m" && continue
    st="$(gh pr view "$pr" --repo "$(repo_slug "$repo")" --json state --jq .state 2>/dev/null)" \
      || { log "dead chain check skipped — could not read the state of $repo#$pr"; continue; }
    # gh took a moment: a person may have rerun chain.sh in the meantime
    chain_running "$repo" "$pr" && continue
    reason="the chain process ended during $state without recording a stop (killed, or the machine restarted)"
    at="$(jq -r '.chain.at // ""' "$m")"
    if [ "$st" = OPEN ]; then
      body="$(dirname "$m")/outputs/chain-died.md"; mkdir -p "$(dirname "$body")"
      { printf 'The automated review chain stopped at `blocked`: %s\n\n' "$reason"
        printf 'It does not resume on its own. Once the cause is dealt with, run `<plugin-dir>/scripts/chain.sh %s %s` to continue from where it stopped.\n' "$repo" "$pr"; } > "$body"
      # Keyed by the dead state's time, so a meta write that fails below does not post a second notice for the same death
      "$PR_QUORUM" comment "$repo" "$pr" "$body" "died-$(printf '%s' "$at" | cksum | cut -d' ' -f1)" >/dev/null \
        || log "failed to post the stop notice — $repo#$pr"
    fi
    # Only if the state is still the dead one, so a chain that started since is not overwritten
    jq 'if .chain.state == $s then .chain += {state:"blocked", reason:$r, at:$at, pid:null} else . end' \
      --arg s "$state" --arg r "$reason" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$m" > "$m.tmp.$$" && mv "$m.tmp.$$" "$m" || { log "could not mark $repo#$pr blocked in meta.json"; continue; }
    log "chain.state=blocked — $repo#$pr ($reason; PR $st)"
  done
}

# Removes the review and author worktrees (pr-quorum-<N>[-<sha7>] · pr-author-<N>) of merged or closed PRs.
# Session permissions only include worktree add, and the chain cannot see merges done by a person, so the poller does it.
# Each worktree's PR state is asked directly, so old PRs are never missed; only a confirmed MERGED or CLOSED removes it, and a failed
# lookup keeps it. A PR whose chain is running is skipped. Runs at most every 30 minutes ($PR_QUORUM_HOME/.gc-stamp).
# No --force — if there are uncommitted changes, git refuses and only a log line is left. Branches are not touched
gc_worktrees() {
  local repo slug path dir wt name n st
  [ -z "$(find "$PR_QUORUM_HOME/.gc-stamp" -mmin -30 2>/dev/null)" ] || return 0
  touch "$PR_QUORUM_HOME/.gc-stamp"
  # Temp files a killed script left behind (scripts keep them under ~/.pr-quorum/tmp, which the OS does not clean)
  [ ! -d "$PR_QUORUM_HOME/tmp" ] || find "$PR_QUORUM_HOME/tmp" -mindepth 1 -maxdepth 1 -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
  [ -n "$GC_CACHE" ] || GC_CACHE="$(pq_mktemp)"
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
  mark_dead_chains || log "dead chain check failed — polling continues"
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

    # 2-2) A chain is running or starting (a person ran chain.sh before Stage 1 took the review lock)
    chain_running "$repo" "$pr" && { log "skip $repo#$pr — chain running"; continue; }
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
  *) echo "usage: watch.sh [--once | --gc-only | --plist]" >&2; exit 1 ;;
esac
