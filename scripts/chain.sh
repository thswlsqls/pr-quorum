#!/usr/bin/env bash
# chain.sh — runs one PR through Stage 1 → author fixes → Stage 2 → Stage 3 → (author fixes → Stage 2)* → merge with no human involved.
# Merging requires passing both the merge gate and the risk gate (rules/03-risk.md, only low passes). Otherwise it stops at needs-human.
# Progress is read from meta.json and outputs/author/round-NN.json, so if it dies midway, calling it again resumes where it left off.
# Where a person would normally be asked, the session picks the recommended option (--auto). Only the merge decision is made here, not by the session.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
need_cmds claude gh jq git || exit 2
require_dotcom
# The bot login is read from config.json's bot, the same way watch.sh does. The merge gate uses it to find the bot's reviews
BOT="$(cfg '.bot // empty')"
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR_QUORUM="$HARNESS_DIR/scripts/pr-quorum.sh"
MAX_AUTHOR_ROUNDS=2   # Cap on author passes — one for Stage 1, one for Stage 3
MAX_STEP_TRIES=2      # If a step ends without leaving a record, run it once more
CI_POLL_MAX=20        # The merge gate reads CI checks still running up to this many times (10 minutes at the default interval)
CI_POLL_SECS="${PR_QUORUM_CI_POLL_SECS:-30}"   # selftest sets 0

log() { echo "[$(date -u +%H:%M:%S)] chain $REPO#$PR — $*"; }
die() { log "$1"; exit "${2:-1}"; }

[ $# -eq 2 ] || { echo "usage: chain.sh <repo> <pr>" >&2; exit 1; }
REPO="$1"; PR="$2"
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || { echo "PR number must be a positive integer: $PR" >&2; exit 1; }
[ -n "$BOT" ] || { echo "bot login not found: set bot in $PR_QUORUM_HOME/config.json" >&2; exit 2; }
REPO_ROOT="$(cfg --arg r "$REPO" '.repos[$r].path // empty')"
[ -n "$REPO_ROOT" ] || { echo "repository is not in config.json repos: $REPO" >&2; exit 1; }
SLUG="$(repo_slug "$REPO")" || exit 2
export PR_QUORUM_SLUG="$SLUG"   # gh-get.sh reads only this repository in this chain's sessions
trust_check || exit 2
# Session permissions are rendered from templates on every run — the absolute script paths point at this plugin folder
render_settings "$HARNESS_DIR" settings.json
render_settings "$HARNESS_DIR" author-settings.json
# Hooks under a relative core.hooksPath (husky) live in the worktree, which PRs and builds write — no git call below runs them (harness.md §3-1)
[ "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=pq.probe GIT_CONFIG_VALUE_0=1 git config --get pq.probe 2>/dev/null)" = 1 ] \
  || { echo "git 2.31+ is needed (GIT_CONFIG_COUNT) to turn off repository hooks in sessions" >&2; exit 2; }
n="${GIT_CONFIG_COUNT:-0}"
[[ "$n" =~ ^[0-9]+$ ]] || { echo "GIT_CONFIG_COUNT in the environment is not a number ($n) — unset it or fix it" >&2; exit 2; }
export "GIT_CONFIG_KEY_$n=core.hooksPath" "GIT_CONFIG_VALUE_$n=/dev/null" GIT_CONFIG_COUNT=$((n+1))
RUN="$PR_QUORUM_HOME/runs/$REPO-pr$PR"
M="$RUN/meta.json"
AUTHOR_DIR="$RUN/outputs/author"

meta_set() {  # meta_set <jq program> [jq args...] — temp file → mv, same as pr-quorum.sh
  local prog="$1"; shift
  jq "$@" "$prog" "$M" > "$M.tmp.$$" && mv "$M.tmp.$$" "$M"
}
chain_state() { meta_set '.chain = ((.chain // {}) + {state:$s, reason:$r, at:$at})' \
                  --arg s "$1" --arg r "${2:-}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; log "state=$1 ${2:-}"; }

head_sha() { "$PR_QUORUM" sha "$REPO" "$PR"; }
stage1_done() { [ "$(jq '[.stage1[]?.review_id | select(. != null)] | length' "$M")" -gt 0 ]; }
stage2_count() { jq '[.stage2[]? | select(.verdicts != null)] | length' "$M"; }
stage3_done() { [ "$(jq '.stage3 != null' "$M")" = "true" ]; }
# ls fails when there are no files, which ends the script via pipefail/set -e. find succeeds with empty output
author_count() { find "$AUTHOR_DIR" -name 'round-*.json' | wc -l | tr -d ' '; }
last_author() { find "$AUTHOR_DIR" -name 'round-*.json' | sort | tail -1; }

# Starts one headless session. Why tool permissions and MCP are isolated from this machine's settings is explained in the comments before the claude -p call below.
run_session() {  # run_session <settings.json> <prompt> <step name> <try number>
  local settings="$1" prompt="$2" name="$3" try="$4" add_dirs=() caps=() r p d out rc=0 started
  local budget timeout_min model sub_model secs pid wd="" outf="$RUN/session-$name-$try.json" timed_out=false
  SESSION_CAP=""   # Set when the session was cut by a cap — step() then stops instead of retrying
  # Besides the working folder (this PR's repository), open the other repositories in config.json and the <name>-worktrees next to each
  for r in $(cfg '.repos | keys[]'); do
    p="$(cfg --arg r "$r" '.repos[$r].path')"
    # Created up front: a session reads only folders opened at start, and its git worktree add lands here
    mkdir -p "$(dirname "$p")/$r-worktrees" 2>/dev/null || true
    for d in "$p" "$(dirname "$p")/$r-worktrees"; do
      [ "$d" != "$REPO_ROOT" ] && [ -d "$d" ] && add_dirs+=("$d")
    done
  done
  # Also open this PR's run folder — the state folder is outside the working folder, so Bash ls/wc were denied (PR #61)
  [ -d "$RUN" ] && add_dirs+=("$RUN")
  # The templates block reads outside the working folders (blockReadsOutsideWorkingDirectories), so open profiles/ and the plugin folder
  # (--plugin-dir alone did not make rules/ readable — measured). Not $PR_QUORUM_HOME itself — that would expose every other PR's runs/.
  # config.json and learnings.md come from pr-quorum.sh config|learnings instead
  [ -d "$PR_QUORUM_HOME/profiles" ] && add_dirs+=("$PR_QUORUM_HOME/profiles")
  add_dirs+=("$HARNESS_DIR")
  # Caps from config.json limits.<step> and models. A missing limits key adds nothing, so the session runs as before
  budget="$(cfg --arg s "$name" '.limits[$s].budget_usd // empty')"
  timeout_min="$(cfg --arg s "$name" '.limits[$s].timeout_min // empty')"
  [ -n "$budget" ] && caps+=(--max-budget-usd "$budget")
  # A null or missing model is Sonnet (a 3-PR benchmark found the same defects at about 1/8 the cost); "" leaves Claude Code's default
  model="$(cfg '.models.session // "claude-sonnet-5-5"')"
  [ -n "$model" ] && caps+=(--model "$model")
  sub_model="$(cfg '.models.subagent // "claude-sonnet-5-5"')"
  # --setting-sources "": do not read the target repository's .claude/settings*.json or ~/.claude/settings.json. --settings is read regardless of this value.
  # Skills and agents are loaded via --plugin-dir and run regardless of this value (measured). The repository CLAUDE.md is not loaded either, so the skill reads it directly
  # dontAsk: anything not in allow is denied without asking. acceptEdits approved edits inside the working folder and mkdir/rm/mv etc. regardless of allow (measured)
  started="$(date +%s)"
  # Runs in the background so the watchdog below can stop it — macOS has no timeout command. exec makes $! the claude process itself,
  # and set -m gives it its own process group, so a kill on -$pid also reaches the processes it started (MCP servers, tool commands)
  set -m
  ( cd "$REPO_ROOT"
    [ -z "$sub_model" ] || export CLAUDE_CODE_SUBAGENT_MODEL="$sub_model"
    exec claude -p --output-format json --permission-mode dontAsk \
      --settings "$settings" --setting-sources "" --plugin-dir "$HARNESS_DIR" \
      --mcp-config "$HARNESS_DIR/mcp.json" --strict-mcp-config \
      --disallowedTools AskUserQuestion \
      --append-system-prompt "This is chain mode. No human will respond. Do not ask a person or wait for confirmation; choose the option the rule documents recommend and continue. Append each decision to $RUN/decisions.md as one line, 'time · step · situation · choice · reason', using the Edit or Write tool (mv and cp are denied by permissions, so do not use the '> tmp && mv' pattern)." \
      ${caps[0]+"${caps[@]}"} ${add_dirs[0]+--add-dir "${add_dirs[@]}"} \
      -- "$prompt" ) < /dev/null > "$outf" &
  pid=$!; SESSION_PID=$pid
  set +m
  # Watchdog: TERM after timeout_min (fractions allowed), KILL 30 seconds later if still alive. The flag file tells this shell it fired
  if [ -n "$timeout_min" ]; then
    secs="$(awk -v m="$timeout_min" 'BEGIN { printf "%d", m * 60 }')"
    ( trap 'kill "$s" 2>/dev/null; exit 0' TERM
      sleep "$secs" & s=$!; wait "$s"
      kill -TERM -- "-$pid" 2>/dev/null || exit 0
      : > "$outf.timeout"
      sleep 30 & s=$!; wait "$s"
      kill -KILL -- "-$pid" 2>/dev/null || true ) > /dev/null 2>&1 &
    wd=$!
  fi
  wait "$pid" 2>/dev/null || { rc=$?; log "session exited with $rc — success is judged from the records"; }
  SESSION_PID=""
  [ -z "$wd" ] || kill "$wd" 2>/dev/null || true
  [ ! -f "$outf.timeout" ] || { timed_out=true; SESSION_CAP="wall-clock cap of $timeout_min min reached"; }
  out="$(cat "$outf" 2>/dev/null || true)"
  rm -f "$outf" "$outf.timeout"
  # Send the result text to the log as before. If it is not JSON, print it as received
  jq -r '.result // empty' <<<"$out" 2>/dev/null || printf '%s\n' "$out"
  # Record per-step time, cost, and tool denials — evidence for whether small PRs can skip steps and which denials keep recurring.
  # If the denial field is missing, leave null (distinct from 0). Do not record the denied tools' arguments
  local at wall_ms; at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # duration_ms only measures the span after the last subagent completion notice (measured on PR #52 — a real 23-minute Stage 1 was recorded as 133 seconds).
  # Measure the whole session time here instead
  wall_ms=$(( ($(date +%s) - started) * 1000 ))
  if jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    # subtype is why the session ended (success, error_max_budget_usd, error_max_turns, …)
    [ "$(jq -r '.subtype // empty' <<<"$out")" != "error_max_budget_usd" ] || SESSION_CAP="budget cap \$$budget reached"
    meta_set '.chain.sessions = ((.chain.sessions // []) + [{step:$s, try:$t, at:$at, exit_code:$rc, wall_ms:$w,
      session_id:$r.session_id, subtype:$r.subtype, duration_ms:$r.duration_ms, cost_usd:$r.total_cost_usd, num_turns:$r.num_turns, is_error:$r.is_error,
      permission_denials:($r.permission_denials | if type == "array" then length else null end),
      denied_tools:($r.permission_denials | if type == "array" then [.[].tool_name] | unique else null end)}
      + (if $to then {timed_out:true} else {} end)])' \
      --arg s "$name" --argjson t "$try" --arg at "$at" --argjson rc "$rc" --argjson w "$wall_ms" --argjson r "$out" --argjson to "$timed_out" \
      || log "could not write the session record to meta.json"
  else
    # Leave at least one line so failed tries are not missing from the record
    meta_set '.chain.sessions = ((.chain.sessions // []) + [{step:$s, try:$t, at:$at, exit_code:$rc, wall_ms:$w, json:false}
      + (if $to then {timed_out:true} else {} end)])' \
      --arg s "$name" --argjson t "$try" --arg at "$at" --argjson rc "$rc" --argjson w "$wall_ms" --argjson to "$timed_out" \
      || log "could not write the session record to meta.json"
    log "could not parse the session result as JSON; recorded the try without time or cost"
  fi
}

# Runs one step and judges success by whether the expected record was left. If both tries fail, the chain stops.
# A session cut by a budget or wall-clock cap is not retried — a second try would only double the cost.
step() {  # step <name> <completion check function> <settings> <prompt>
  local name="$1" check="$2" settings="$3" prompt="$4" t reason
  reason="$name left no record $MAX_STEP_TRIES times in a row"
  for (( t=1; t<=MAX_STEP_TRIES; t++ )); do
    chain_state "$name" "try $t"
    run_session "$settings" "$prompt" "$name" "$t"
    "$check" && return 0
    [ -z "$SESSION_CAP" ] || { CAP_STEP="$name"; reason="$name: $SESSION_CAP — not retried"; break; }
    log "$name left no record (try $t)"
  done
  # A stopped Stage 1 has no review, so watch.sh would run it again with the same budget — held-failed keeps it for a person
  [ "$name" != stage1 ] || "$PR_QUORUM" status "$REPO" "$PR" held-failed >/dev/null || log "could not set status=held-failed"
  chain_state "blocked" "$reason"
  exit 4
}

EVAL_SETTINGS="$PR_QUORUM_HOME/settings.json"
AUTHOR_SETTINGS="$PR_QUORUM_HOME/author-settings.json"

# The Stage 1 round cap goes to the session as an argument, like --auto. Without limits.stage1.max_rounds the skill's own cap applies
run_stage1() {
  local rounds; rounds="$(cfg '.limits.stage1.max_rounds // empty')"
  step stage1 stage1_done "$EVAL_SETTINGS" "/pr-quorum:review stage1 $REPO $PR --auto${rounds:+ --max-rounds $rounds}"
}
run_stage3() { step stage3 stage3_done "$EVAL_SETTINGS" "/pr-quorum:review stage3 $REPO $PR --auto"; }

run_stage2() {
  local before; before="$(stage2_count)"
  stage2_grew() { [ "$(stage2_count)" -gt "$before" ]; }
  step stage2 stage2_grew "$EVAL_SETTINGS" "/pr-quorum:review stage2 $REPO $PR --auto"
}

run_author() {  # Success if one more record file appeared
  local before; before="$(author_count)"
  author_grew() { [ "$(author_count)" -gt "$before" ]; }
  step author author_grew "$AUTHOR_SETTINGS" "/pr-quorum:author $REPO $PR"
}

author_pushed() { [ "$(jq -r '.pushed' "$(last_author)")" = "true" ]; }

# mergeable is UNKNOWN until GitHub finishes computing it. Older PRs return it more often on the first query
pr_state() {
  local i out
  for i in 1 2 3 4 5 6; do
    out="$(gh pr view "$PR" --repo "$SLUG" --json state,isDraft,mergeable)" || return 1
    [ "$(jq -r '.mergeable' <<<"$out")" != "UNKNOWN" ] && break
    sleep 10
  done
  printf '%s\n' "$out"
}

# ---------- Merge gate — judged from records and GitHub state, not from the session's self-report ----------
merge_gate() {
  local a head pr_json reasons=()
  a="$(last_author)"
  head="$(head_sha)" \
    || { chain_state "blocked" "merge gate: could not read the PR head from GitHub — run the chain again"; exit 4; }
  GATE_SHA="$head"   # The risk gate and the merge are bound to this commit
  pr_json="$(pr_state)" \
    || { chain_state "blocked" "merge gate: could not read the PR state from GitHub — run the chain again"; exit 4; }

  [ "$(jq -r '.state' <<<"$pr_json")" = "OPEN" ] || reasons+=("PR is not open")
  [ "$(jq -r '.isDraft' <<<"$pr_json")" = "false" ] || reasons+=("PR is a draft")
  [ "$(jq -r '.mergeable' <<<"$pr_json")" = "MERGEABLE" ] || reasons+=("mergeable=$(jq -r '.mergeable' <<<"$pr_json")")
  [ "$(jq -r '.tests.result' "$a")" != "fail" ] || reasons+=("tests failed in the last author pass")
  [ "$(jq -r '.blocking_open' "$a")" = "0" ] || reasons+=("$(jq -r '.blocking_open' "$a") blocking findings remain unaddressed")
  [ "$(jq '[.stage2[-1].verdicts // {} | .[] | select(. == "regressed" or . == "역행")] | length' "$M")" = "0" ] \
    || reasons+=("the last Stage 2 verdicts include regressed")
  # The current head must be a commit someone judged — the one the last Stage 2 saw, or one where the author said nothing more needed fixing
  if [ "$head" != "$(jq -r '.stage2[-1].stage_sha // empty' "$M")" ] \
     && ! { [ "$(jq -r '.pushed' "$a")" = "false" ] && [ "$head" = "$(jq -r '.to_sha' "$a")" ]; }; then
    reasons+=("no step has judged head $head")
  fi
  # The records above are files the session wrote, so they can be rewritten. Check on GitHub that the bot actually left a review or reply on this head
  local bot_reviews
  bot_reviews="$(gh api --paginate "repos/$SLUG/pulls/$PR/reviews" \
    | jq -s --arg b "$BOT" --arg s "$head" '[add // [] | .[] | select(.user.login == $b and .commit_id == $s)] | length')" || bot_reviews=""
  [ "${bot_reviews:-0}" -gt 0 ] || reasons+=("no review by the bot ($BOT) on head $head found on GitHub")

  # Every blocking comment needs Stage 2's latest verdict to be addressed — the author saying it fixed one is not enough.
  # A later pass judges only the codes it covered, so the passes are merged in order. Old runs recorded Korean verdicts and no blocking field:
  # there, only critical counts as blocking. A blocking code with no verdict also stops (a skipped Stage 2 has none)
  local open late
  open="$(jq -r --argjson pushed "$(jq '.pushed == true' "$a")" '
    (reduce .stage2[]?.verdicts as $v ({}; . + ($v // {}))
     | map_values({"반영":"addressed", "부분":"partial", "미반영":"not-addressed", "역행":"regressed"}[.] // .)) as $latest
    | [.stage2[-1].new_comments[]?.code] as $last
    | [(.stage1[-1].comments // []) + (.stage1[-1].summary_items // []) + [.stage2[]?.new_comments[]?]
       | .[] | select(.pre_existing != true and (.blocking == true or (.grade | IN("critical", "치명"))))
       | select($latest[.code] != "addressed") | .code] | unique
    | map(. as $c | if $latest[$c] == null and $pushed and any($last[]; . == $c) then "late:\($c)"
                    else "\($c)(\($latest[$c] // "no verdict"))" end)
    | (map(select(startswith("late:") | not)) | join(", ")), (map(select(startswith("late:")) | ltrimstr("late:")) | join(", "))' "$M")"
  late="$(sed -n 2p <<<"$open")"; open="$(sed -n 1p <<<"$open")"
  [ -z "$open" ] || reasons+=("Stage 2 has not confirmed blocking comments: $open — a person can check them against the code and merge by hand")
  [ -z "$late" ] || reasons+=("blocking comments raised after the last author pass: $late — a person can check them against the code and merge by hand")

  # CI checks on the head (statusCheckRollup). Read here, not in pr_state(), which the conflict check before the author pass also calls.
  # Checks still running are read again every CI_POLL_SECS, up to CI_POLL_MAX reads, while nothing else blocks
  local ci i
  for (( i=1; ; i++ )); do
    ci="$(gh pr view "$PR" --repo "$SLUG" --json headRefOid,statusCheckRollup | jq -c '
      .headRefOid as $sha
      | [.statusCheckRollup[]? | {name:(.name // .context),
        result:(if .__typename == "StatusContext" or .context != null
                then (if .state | IN("PENDING", "EXPECTED") then "pending" elif .state | IN("FAILURE", "ERROR") then .state else "ok" end)
                else (if .status != "COMPLETED" then "pending" elif .conclusion | IN("SUCCESS", "NEUTRAL", "SKIPPED") then "ok" else .conclusion end) end)}]
      | {sha:$sha, checks:length, failing:[.[] | select(.result | IN("ok", "pending") | not) | "\(.name) is \(.result)"],
         pending:[.[] | select(.result == "pending") | .name]}')" \
      || { chain_state "blocked" "merge gate: could not read the CI checks from GitHub — run the chain again"; exit 4; }
    [ "$(jq '.pending | length' <<<"$ci")" -gt 0 ] && [ "$(jq -r '.sha' <<<"$ci")" = "$head" ] \
      && [ ${#reasons[@]} -eq 0 ] && [ "$i" -lt "$CI_POLL_MAX" ] || break
    sleep "$CI_POLL_SECS"
  done
  meta_set '.chain.ci = $c' --argjson c "$ci" || log "could not write the CI checks to meta.json"
  if [ "$(jq -r '.sha' <<<"$ci")" != "$head" ]; then
    reasons+=("CI checks are for $(jq -r '.sha' <<<"$ci"), not head $head — the head moved; run the chain again")
  else
    while IFS= read -r i; do reasons+=("CI check $i on $head"); done < <(jq -r '.failing[]' <<<"$ci")
    [ "$(jq '.pending | length' <<<"$ci")" = 0 ] || reasons+=("CI checks still running on $head — run the chain again")
  fi

  if [ ${#reasons[@]} -gt 0 ]; then
    chain_state "blocked" "merge gate: $(IFS='; '; echo "${reasons[*]}")"
    exit 3
  fi

  # If Stage 3 found a critical or major defect the review missed (P), a person decides whether to rerun Stage 1 (rules/01-stages.md §5).
  # Judged from the P comment grades pr-quorum.sh recorded, not from the verdict text the session writes. A P with no grade also stops
  local missed
  missed="$(jq -r '[.stage3.comments[]? | select(.grade | IN("minor","nit","경미","사소") | not) | "\(.code)(\(.grade))"] | join(", ")' "$M")"
  if [ -n "$missed" ]; then
    chain_state "needs-human" "Stage 3 found defects the review missed: $missed — a person decides whether to rerun Stage 1"
    exit 3
  fi
}

# Risk gate (rules/03-risk.md) — only PRs that passed every other gate are scored. The scorecard is posted on the PR regardless of level.
risk_gate() {
  local rc=0
  "$PR_QUORUM" risk "$REPO" "$PR" >/dev/null || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || { chain_state "blocked" "risk scoring failed (exit $rc)"; exit 4; }
  # If a push landed after the merge gate ran, the score belongs to a commit the gate did not see
  [ "$(jq -r '.risk.sha' "$M")" = "$GATE_SHA" ] \
    || { chain_state "blocked" "head changed after the merge gate (${GATE_SHA:0:7}) — run the chain again"; exit 3; }
  if [ "$(jq -r '.risk.commented_sha // empty' "$M")" != "$(jq -r '.risk.sha' "$M")" ]; then
    # The key keeps a rerun from posting the same scorecard again when the post went up but commented_sha was not recorded
    # Without it, a needs-human or ready stop would leave nothing on the PR
    "$PR_QUORUM" comment "$REPO" "$PR" "$RUN/outputs/risk.md" "risk-$(jq -r '.risk.sha' "$M" | cut -c1-7)" >/dev/null \
      || { chain_state "blocked" "risk scorecard was not posted — run the chain again"; exit 4; }
    meta_set '.risk.commented_sha = .risk.sha' || log "posted the risk comment but could not record it in meta.json"
  fi
  if [ "$rc" = 3 ]; then
    chain_state "needs-human" "risk $(jq -r '.risk.level' "$M") $(jq -r '.risk.score' "$M") points — merges only with human approval"
    exit 3
  fi
}

# Posts one comment when the chain stops at blocked, so a stopped PR is not left for someone to find in meta.json. It does not resume the chain.
# needs-human gets none: the risk gate posts its scorecard, and Stage 3 posted the missed defects as its review.
# The state|reason key in chain.notified keeps a rerun that stops for the same reason from posting again. A failed post is only logged
CAP_STEP=""; NO_NOTICE=""
notify_stop() {
  local state reason key body="$RUN/outputs/chain-stopped.md"
  [ -z "$NO_NOTICE" ] || return 0
  state="$(jq -r '.chain.state // empty' "$M")"
  [ "$state" = "blocked" ] || return 0
  reason="$(jq -r '.chain.reason // ""' "$M")"; key="$state|$reason"
  [ "$key" != "$(jq -r '.chain.notified.key // empty' "$M")" ] || return 0
  # Skipped only when GitHub says the PR is gone — a failed read posts anyway, since the stop may be that very read failing
  case "$(gh pr view "$PR" --repo "$SLUG" --json state --jq '.state' 2>/dev/null)" in
    MERGED|CLOSED) log "stop notice not posted — the PR is not open"; return 0 ;;
  esac
  mkdir -p "$RUN/outputs"
  { printf 'The automated review chain stopped at `%s`: %s\n\n' "$state" "$reason"
    printf 'It does not resume on its own. Once the cause is dealt with, run `<plugin-dir>/scripts/chain.sh %s %s` to continue from where it stopped.\n' "$REPO" "$PR"
    case "$CAP_STEP" in stage1|stage2|stage3)
      printf '\nThe %s session was cut off and may have left its review lock in place. The next run takes that lock over because its process has exited (a lock also expires after 3 hours); if it still reports `lock held`, release it with `<plugin-dir>/scripts/pr-quorum.sh unlock %s %s`.\n' "$CAP_STEP" "$REPO" "$PR" ;;
    esac
    [ "$(jq -r '.status' "$M")" != held-failed ] \
      || printf '\nStage 1 is held at `held-failed`: run `<plugin-dir>/scripts/pr-quorum.sh status %s %s pending` first, then the chain.\n' "$REPO" "$PR"; } > "$body"
  # Keyed by state|reason and the count of recorded notices, so a notice that went up without being recorded is not posted again,
  # while the same stop coming back after a different one gets a new key
  if "$PR_QUORUM" comment "$REPO" "$PR" "$body" "stop-$(printf '%s' "$key" | cksum | cut -d' ' -f1)-$(jq -r '.chain.notified.n // 0' "$M")" >/dev/null; then
    meta_set '.chain.notified = {key:$k, at:$at, n:((.chain.notified.n // 0) + 1)}' --arg k "$key" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      || log "posted the stop notice but could not record it in meta.json"
  else
    log "failed to post the stop notice — chain.state is recorded in meta.json"
  fi
}

do_merge() {
  # --match-head-commit: pass the commit the gate saw. Re-reading head would merge whatever was pushed in between
  gh pr merge "$PR" --repo "$SLUG" --merge --match-head-commit "$GATE_SHA" \
    || { chain_state "blocked" "gh pr merge failed"; exit 4; }
  meta_set '.chain.merged_sha = $s' --arg s "$GATE_SHA"
  chain_state "merged" "head=$GATE_SHA"
}

# ---------- Main ----------
# Same check as watch.sh, read again from the API — even if a person calls chain.sh directly, a PR from an untrusted author never reaches a session
pj="$(gh api "repos/$SLUG/pulls/$PR")" || die "could not check the PR author" 4
author="$(jq -r '"\(.user.login) \(.author_association)"' <<<"$pj")"
# A fork keeps the head branch outside this repository, so the author pass could not push to it. A null head.repo is a deleted fork
fork="$(jq -r 'if .head.repo == null then "a deleted fork" elif (.head.repo.full_name|ascii_downcase) != (.base.repo.full_name|ascii_downcase) then .head.repo.full_name else empty end' <<<"$pj")"
trust_rc=0; is_trusted "${author% *}" "${author#* }" || trust_rc=$?
[ "$trust_rc" != 2 ] || die "trust in config.json is invalid" 2
[ "$trust_rc" = 0 ] || die "author is not trusted (${author% *}, ${author#* }) — not running the chain" 3

[ -f "$M" ] || "$PR_QUORUM" init "$REPO" "$PR" >/dev/null
mkdir -p "$AUTHOR_DIR"

# Prevent double runs — so a watcher resume and a manual call do not overlap. mkdir is atomic (macOS has no flock), so only one caller gets the folder.
# A folder whose pid is dead is stale; the .reap folder lets only one caller remove and retake it
CHAIN_LOCK="$RUN/.chain.lock"
if ! mkdir "$CHAIN_LOCK" 2>/dev/null; then
  other="$(cat "$CHAIN_LOCK/pid" 2>/dev/null || true)"
  [ -n "$other" ] || die "chain lock has no pid yet — another chain is starting (if none is, remove $CHAIN_LOCK)" 5
  ! kill -0 "$other" 2>/dev/null || die "another chain (pid=$other) is running" 5
  mkdir "$CHAIN_LOCK.reap" 2>/dev/null || die "lost the chain lock race (if this repeats, remove $CHAIN_LOCK.reap)" 5
  [ "$(cat "$CHAIN_LOCK/pid" 2>/dev/null || true)" != "$other" ] || { rm -rf "$CHAIN_LOCK"; log "cleared a stale chain lock (pid=$other)"; }
  mkdir "$CHAIN_LOCK" 2>/dev/null || { rmdir "$CHAIN_LOCK.reap"; die "lost the chain lock race" 5; }
  rmdir "$CHAIN_LOCK.reap"
fi
echo "$$" > "$CHAIN_LOCK/pid"
# The pid is also kept in meta.json so the chain can be seen running
meta_set '.chain = ((.chain // {}) + {pid:$p})' --argjson p "$$"
# A background job ignores Ctrl-C, so a session still running when the chain exits is stopped here. The stop notice goes out before the lock is released
SESSION_PID=""
trap '[ -z "$SESSION_PID" ] || kill -TERM -- "-$SESSION_PID" 2>/dev/null; notify_stop || true
      meta_set ".chain.pid = null" 2>/dev/null || true; rm -rf "$CHAIN_LOCK"' EXIT

case "$(jq -r '.chain.state // empty' "$M")" in
  merged) log "already merged"; exit 0 ;;
esac
# Posts outputs/<fork|large>-pr.md under its key. Called again on a rerun: the key adopts a notice already on the PR, or posts one that failed
hold_notice() {
  local key="$1"
  # A fixed key when the head cannot be read, so a rerun still adopts the notice instead of posting it again
  [ "$1" = fork ] || { key="$(head_sha)" && key="large-${key:0:7}" || key=large; }
  [ ! -f "$RUN/outputs/$1-pr.md" ] || "$PR_QUORUM" comment "$REPO" "$PR" "$RUN/outputs/$1-pr.md" ${key:+"$key"} >/dev/null \
    || log "failed to post the $1 notice comment"
}
st="$(jq -r '.status' "$M")"
case "$st" in
  # held-large and held-fork already have their notice — the large-PR or fork comment, or the one posted when Stage 1 held it
  held-large|held-fork|"보류(대형PR)") NO_NOTICE=1; [ "${st#held-}" = "$st" ] || hold_notice "${st#held-}"
     chain_state "blocked" "status=$st — a stage ended on hold"; exit 3 ;;
  held-*|보류*) chain_state "blocked" "status=$st — a stage ended on hold"; exit 3 ;;
esac

# A fork PR stops before any session runs. The notice comment is posted once — a later call stops at the hold check above first
if [ -n "$fork" ]; then
  "$PR_QUORUM" status "$REPO" "$PR" "held-fork" >/dev/null
  mkdir -p "$RUN/outputs"
  printf 'This PR comes from %s. The automated chain does not run on fork PRs because its author pass pushes fixes to the PR branch, which is outside this repository. Push the branch to this repository and open a new PR, or ask for a human review.\n' \
    "$fork" > "$RUN/outputs/fork-pr.md"
  hold_notice fork
  NO_NOTICE=1   # The fork comment is this stop's notice
  chain_state "blocked" "PR comes from a fork ($fork) — the author pass cannot push to it"; exit 3
fi

# The large-PR cutoff is checked here, not left to the session. The notice comment is posted once — a later call stops at the hold check above first
pre_rc=0
pre_out="$("$PR_QUORUM" precheck "$REPO" "$PR")" || pre_rc=$?
case "$pre_rc" in
  0) ;;
  3) "$PR_QUORUM" status "$REPO" "$PR" "held-large" >/dev/null
     mkdir -p "$RUN/outputs"
     printf 'This change is too large for automated review (%s; cutoff: more than 50 files or 3,000 lines). Please split the PR or have a person review it.\n' \
       "$(head -1 <<<"$pre_out" | sed 's/ (cut.*//')" > "$RUN/outputs/large-pr.md"
     hold_notice large
     NO_NOTICE=1   # The large-PR comment is this stop's notice
     chain_state "blocked" "hit the large-PR cutoff"; exit 3 ;;
  *) chain_state "blocked" "large-PR check failed (exit $pre_rc)"; exit 4 ;;
esac

stage1_done || run_stage1
case "$(jq -r '.status' "$M")" in
  held-large|"보류(대형PR)") chain_state "blocked" "Stage 1 was held as a large PR"; exit 3 ;;
esac

# Check for conflicts with main before the author pass. Resolving a conflict changes head, so the later steps would have to run again.
# Stopping before Stage 1 would make watch.sh see a PR with no review, restart it every minute, and end up at held-failed
PR_JSON="$(pr_state)" || { chain_state "blocked" "could not read the PR state from GitHub before the author pass — run the chain again"; exit 4; }
[ "$(jq -r '.mergeable' <<<"$PR_JSON")" != "CONFLICTING" ] \
  || { chain_state "blocked" "conflicts with main — a person resolves the conflict, then runs the chain again"; exit 3; }

[ "$(author_count)" -ge 1 ] || run_author
# Stage 2 judges what the author pushed. A first pass that pushed nothing onto the head Stage 1 judged leaves it nothing to judge, so the
# chain records an empty pass instead of a session — Stage 3's order check and the merge gate read that record (rules/01-stages.md §1)
if [ "$(stage2_count)" -lt 1 ]; then
  HEAD_NOW="$(head_sha)" || { chain_state "blocked" "could not read the PR head from GitHub after the author pass — run the chain again"; exit 4; }
  if ! author_pushed && [ "$HEAD_NOW" = "$(jq -r '.eval_sha // empty' "$M")" ]; then
    meta_set '.stage2 += [{round:((.stage2 | length) + 1), stage_sha:$h, last_judged_sha:$h, at:$at, verdicts:{}, skipped:"no author push"}]' \
      --arg h "$HEAD_NOW" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log "Stage 2 skipped — the author pass pushed nothing onto ${HEAD_NOW:0:7}"
  else
    run_stage2
  fi
fi
stage3_done || run_stage3

# After Stage 3: loop (author → Stage 2) until the author says nothing more needs fixing
while :; do
  # If Stage 2 has not run since the last author pass, run it first (the case where it died midway)
  if author_pushed; then
    HEAD_NOW="$(head_sha)" || { chain_state "blocked" "could not read the PR head from GitHub after the author pass — run the chain again"; exit 4; }
    [ "$HEAD_NOW" = "$(jq -r '.stage2[-1].stage_sha // empty' "$M")" ] || run_stage2
  fi
  # The first pass addresses Stage 1. If there is no pass after Stage 3 yet, run one
  if [ "$(author_count)" -ge "$MAX_AUTHOR_ROUNDS" ]; then
    log "reached the author pass cap ($MAX_AUTHOR_ROUNDS)"; break
  fi
  if [ "$(author_count)" -ge 2 ] && ! author_pushed; then break; fi
  run_author
  author_pushed || break
  run_stage2
done

chain_state "merge-gate"
merge_gate
risk_gate
# Merge only when auto_merge is true. If the key is missing or false, leave just the risk scorecard and let a person merge
if [ "$(cfg '.auto_merge == true')" = "true" ]; then
  do_merge
else
  chain_state "ready" "auto_merge is off — a person merges"
fi
