#!/usr/bin/env bash
# pr-quorum.sh — pr-quorum's only path for posting to GitHub.
# Sessions never hold the bot token. This script reads it internally.
# The contract (subcommands, exit codes) is in docs/harness.md §3.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/token-scan.sh"
require_dotcom
SLUG=""   # <owner>/<repo> of the repository argument, set at the entry point (config.sh repo_slug)
BOT_ENV="${PR_QUORUM_BOT_ENV:-$HOME/.config/pr-quorum/bot.env}"
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS_DIR="$PR_QUORUM_HOME/runs"
LOCK_TTL_SEC=10800   # 3 hours
BIG_PR_FILES=50
BIG_PR_LINES=3000

# Exit codes: 0 success · 1 usage/arguments · 2 environment (no token or meta) · 3 gate violation · 4 API failure · 5 lock held
E_USAGE=1; E_ENV=2; E_GATE=3; E_API=4; E_LOCK=5

die() { echo "pr-quorum: $2" >&2; exit "$1"; }

TMP=""
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT
mktmp() { cleanup; TMP="$(mktemp -d)"; }

usage() {
  cat >&2 <<'USAGE'
usage: pr-quorum.sh <subcommand> <repo> <pr> [args]

  Read (no bot token needed)
    sha        <repo> <pr>                   print the current head SHA
    meta       <repo> <pr>                   print meta.json
    precheck   <repo> <pr>                   check the large-PR cutoff (50 files / 3000 lines)
    ranges     <repo> <pr> <sha>            print the line ranges that accept inline anchors (for judge prompts)
    gate1      <repo> <pr> <sha> <comments.json>   PG1 — check that anchors are inside the diff
    risk       <repo> <pr>                   auto-merge risk score (rules/03-risk.md). 3 if not low
    pg5        <summary.md> <comments.json> [stage1|stage2|stage3]   PG5 mechanical check (the same one post-review runs right before posting)
    pg6        <outputs/stage dir>           PG6 — compare against the pre-edit copy (pre-polish/)
    snapshot   <outputs/stage dir>           save the pre-edit copy to pre-polish/ (under runs/ only)

  State
    init       <repo> <pr> [--reset-eval]    create runs/<repo>-pr<N>/ and meta.json
                                             (--reset-eval: move eval_sha to head, only when rerunning Stage 1)
    lock       <repo> <pr> <stage>           acquire the lock (5 if held)
    unlock     <repo> <pr>
    status     <repo> <pr> <value>
    attempt    <repo> <pr> inc|reset
    stage2-begin <repo> <pr> <stage_sha> <last_judged_sha>   open this Stage 2 pass's record (merges into an unfinished one)
    verdicts   <repo> <pr> <stage_sha> <verdicts.json>   write {code: verdict} into that record (addressed|partial|not-addressed|regressed)
    stage3-replies <repo> <pr>               move stage3_replies into stage3.replies (when finishing without post-review)

  Build (no bot token needed)
    build      <repo> <pr> <worktree> build|test|lint [target]
    author-build <repo> <pr> <worktree> build|test|lint [target]   same, for the author session
                                             run repos.<repo>.commands.<kind> from config.json in the worktree, <target> filled in
                                             (build: clean tree at a pinned SHA · author-build: <repo>-worktrees/pr-author-<pr>)

  Post (bot token needed)
    post-review <repo> <pr> <sha> <summary.md> <comments.json> [stage1|stage2|stage3]
    reply       <repo> <pr> <comment_id> <body.md>
    patch       <repo> <pr> <comment_id> <body.md>
    patch-review <repo> <pr> <review_id> <body.md>   edit the summary body of a posted review
    comment     <repo> <pr> <body.md>        one general comment on the PR
                                             every post refuses a body that holds a token (scripts/token-scan.sh), before any API call

  Check (bot token needed, no repo or pr)
    whoami                                   print the bot token's login (doctor.sh compares it with config.json bot)
USAGE
  exit "$E_USAGE"
}

profile_of() {
  local p; p="$(cfg --arg r "$1" '.repos[$r].profile // empty')"
  [ -n "$p" ] || die "$E_USAGE" "repository has no known profile: $1 (not in config.json repos)"
  echo "$p"
}

run_dir() { echo "$RUNS_DIR/$1-pr$2"; }
meta_path() { echo "$(run_dir "$1" "$2")/meta.json"; }

need_meta() {
  [ -f "$(meta_path "$1" "$2")" ] || die "$E_ENV" "meta.json is missing. Run init first: $(meta_path "$1" "$2")"
}

# Update meta.json with a jq program (temp file → mv, avoids partial writes)
meta_update() {
  local repo="$1" pr="$2" prog="$3"; shift 3
  local m; m="$(meta_path "$repo" "$pr")"
  local tmp="$m.tmp.$$"
  jq "$@" "$prog" "$m" > "$tmp" && mv "$tmp" "$m"
}

load_bot_token() {
  [ -f "$BOT_ENV" ] || die "$E_ENV" "bot token file is missing: $BOT_ENV (see docs/harness.md §5-2)"
  # Environment variables are ignored. A GH_TOKEN from outside is the user's token, so posts would appear under the user instead of the bot
  local tok; tok="$(bot_token_value)"
  [ -n "$tok" ] || die "$E_ENV" "$BOT_ENV has no PR_QUORUM_BOT_TOKEN or GH_TOKEN"
  export GH_TOKEN="$tok"
  unset GITHUB_TOKEN || true
}

# Reads retry on 5xx, 429, a secondary rate limit, or a dropped connection: at most 3 tries, waiting 2 s then 5 s
# (PR_QUORUM_API_BACKOFF overrides the waits; selftest sets "0 0"). 4xx such as 401, 404, 422 fail at once.
# Anything that writes — a method, --input, or a field flag (gh api -f/-F turns the call into a POST) — is never retried:
# a retried POST is a second review. post-review's adoption check covers that side instead.
# Output is held in a file and printed only on success, so a --paginate that fails midway does not print its first pages twice
api() {
  local a d e w
  for a in "$@"; do
    case "$a" in -X*|--method*|--input*|-f*|-F*|--field*|--raw-field*) gh api "$@" || die "$E_API" "gh api failed: $*"; return 0 ;; esac
  done
  d="$(mktemp)"; e="$(mktemp)"
  for w in ${PR_QUORUM_API_BACKOFF:-2 5} end; do
    if gh api "$@" > "$d" 2> "$e"; then cat "$d"; rm -f "$d" "$e"; return 0; fi
    [ "$w" != end ] && grep -qiE 'HTTP (5[0-9]{2}|429)|secondary rate limit|timeout|timed out|connection reset' "$e" || break
    sleep "$w"
  done
  cat "$e" >&2; rm -f "$d" "$e"; die "$E_API" "gh api failed: $*"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# The pid to write into the lock — this script exits immediately, so writing its own pid would make the lock dead at the next check.
# Find a claude session process among the ancestors and use its pid. If there is none (= called by the watcher), use the direct parent.
owner_pid() {
  if [ -n "${PR_QUORUM_LOCK_PID:-}" ]; then echo "$PR_QUORUM_LOCK_PID"; return; fi
  local p="$PPID" name
  while [ "${p:-0}" -gt 1 ]; do
    name="$(ps -o comm= -p "$p" 2>/dev/null | sed 's|.*/||' || true)"
    [ "$name" = "claude" ] && { echo "$p"; return; }
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  echo "$PPID"
}

# ---------- Read ----------

cmd_sha() { api "repos/$SLUG/pulls/$2" --jq '.head.sha'; }

cmd_meta() { need_meta "$1" "$2"; cat "$(meta_path "$1" "$2")"; }

cmd_precheck() {
  local repo="$1" pr="$2" j
  j="$(api "repos/$SLUG/pulls/$pr")"
  local files add del
  files="$(jq -r '.changed_files' <<<"$j")"
  add="$(jq -r '.additions' <<<"$j")"
  del="$(jq -r '.deletions' <<<"$j")"
  local lines=$(( add + del ))
  echo "changed_files=$files diff_lines=$lines (cut: files>$BIG_PR_FILES or lines>$BIG_PR_LINES)"
  if [ "$files" -gt "$BIG_PR_FILES" ] || [ "$lines" -gt "$BIG_PR_LINES" ]; then
    echo "hits the large-PR cutoff. Set status to held-large and do not post."
    return "$E_GATE"
  fi
  echo "passed"
}

# Extract the RIGHT-side hunk ranges from the diff at the pinned SHA and print them as "file<TAB>start<TAB>count".
# gate1 (the after-the-fact check) and ranges (advance info for judge prompts) look at the same data.
emit_ranges() {
  local repo="$1" sha="$2" out="$3" base
  base="$(jq -r '.base_sha' "$(meta_path "$repo" "$4")")"
  [ -n "$base" ] && [ "$base" != "null" ] || die "$E_ENV" "meta.json has no base_sha"
  # No --paginate — compare's files[] is a single response, and with it empty arrays come back from page 2 on.
  api "repos/$SLUG/compare/$base...$sha" > "$out/compare.json"
  jq -r '
    .files[] | select(.patch != null) | . as $f
    | ($f.patch | split("\n")[] | select(startswith("@@"))
       | capture("@@ -[0-9]+(,[0-9]+)? \\+(?<s>[0-9]+)(,(?<c>[0-9]+))?"))
    | "\($f.filename)\t\(.s)\t\(.c // "1")"
  ' "$out/compare.json" > "$out/ranges.tsv"
}

# The list of "lines that accept inline comments" for judge prompts.
# One anchor outside the diff makes the whole review fail with 422, so giving this up front is cheaper than checking afterwards.
cmd_ranges() {
  local repo="$1" pr="$2" sha="$3"
  need_meta "$repo" "$pr"
  mktmp; local tmp="$TMP"
  emit_ranges "$repo" "$sha" "$tmp" "$pr"
  echo "# allowed inline anchor ranges (pinned SHA $sha) — file / start line / end line (inclusive)"
  awk -F'\t' '{printf "%s\t%d-%d\n", $1, $2, $2+$3-1}' "$tmp/ranges.tsv"
  # Given only ranges, judges miscount from the hunk start. Show the same patch with line numbers.
  echo "# numbered diff — '+' and ' ' lines carry new-file numbers (anchorable), '(N) -' lines carry deleted old-file numbers (not anchorable)"
  jq -r '.files[] | select(.patch != null) | "F\t\(.filename)", (.patch | split("\n")[] | "P\t\(.)")' \
    "$tmp/compare.json" | awk '
    /^F\t/ { print "## " substr($0, 3); next }
    { l = substr($0, 3); c = substr(l, 1, 1) }
    c == "@" { match(l, /-[0-9]+/); o = substr(l, RSTART + 1, RLENGTH - 1) + 0
               match(l, /\+[0-9]+(,[0-9]+)?/); h = substr(l, RSTART + 1, RLENGTH - 1)
               n = h + 0; k = (h ~ /,/) ? substr(h, index(h, ",") + 1) + 0 : 1
               printf "  %d-%d  %s\n", n, n + k - 1, l; next }
    c == "+" { printf "%7d + %s\n", n++, substr(l, 2); next }
    c == "-" { printf "%7s - %s\n", "(" o++ ")", substr(l, 2); next }
    c == " " { printf "%7d   %s\n", n++, substr(l, 2); o++; next }
    l != "" { print "          " l }'
  local n; n="$(jq -r '[.files[] | select(.patch == null)] | length' "$tmp/compare.json")"
  [ "$n" = "0" ] || { echo "# $n files with no patch, so no anchors possible:"; \
    jq -r '.files[] | select(.patch == null) | "#   " + .filename' "$tmp/compare.json"; }
}

# PG1 — are the anchors inside the diff at the pinned SHA
cmd_gate1() {
  local repo="$1" pr="$2" sha="$3" cfile="$4"
  [ -f "$cfile" ] || die "$E_USAGE" "comments file is missing: $cfile"
  jq -e 'type == "array"' "$cfile" >/dev/null || die "$E_USAGE" "$cfile must be a JSON array"
  need_meta "$repo" "$pr"
  local base; base="$(jq -r '.base_sha' "$(meta_path "$repo" "$pr")")"
  [ -n "$base" ] && [ "$base" != "null" ] || die "$E_ENV" "meta.json has no base_sha"

  mktmp; local tmp="$TMP"
  emit_ranges "$repo" "$sha" "$tmp" "$pr"

  # Files with no patch (large files) are excluded as anchor targets.
  jq -r '.files[] | select(.patch == null) | .filename' "$tmp/compare.json" > "$tmp/nopatch.txt"
  if [ -s "$tmp/nopatch.txt" ]; then
    echo "warning — files excluded as anchor targets because they have no patch:" >&2
    sed 's/^/  /' "$tmp/nopatch.txt" >&2
  fi
  local nfiles; nfiles="$(jq -r '.files | length' "$tmp/compare.json")"
  [ "$nfiles" -lt 300 ] || echo "warning — compare returned $nfiles files. It may have been truncated at 300." >&2

  local bad=0 total=0
  while IFS=$'\t' read -r p l side; do
    total=$((total+1))
    if [ "$side" != "RIGHT" ]; then
      echo "PG1 violation — side is not RIGHT: $p:$l (side=$side)"; bad=$((bad+1)); continue
    fi
    if ! awk -F'\t' -v P="$p" -v L="$l" '
        $1==P && L+0 >= $2+0 && L+0 < $2+$3 { found=1 }
        END { exit !found }' "$tmp/ranges.tsv"; then
      echo "PG1 violation — anchor outside the diff: $p:$l"; bad=$((bad+1))
    fi
  done < <(jq -r '.[] | [.path, (.line|tostring), (.side // "RIGHT")] | @tsv' "$cfile")

  if [ "$bad" -gt 0 ]; then
    echo "PG1 failed — $bad of $total are outside the diff. Move them into the summary body."
    return "$E_GATE"
  fi
  echo "PG1 passed — all $total anchors are inside the diff (pinned SHA $sha)"
}

# Auto-merge risk score (rules/03-risk.md). Scores the PR diff at the current head and records it in meta.risk and outputs/risk.md.
# 0 if low, otherwise 3 — meaning it merges only with human approval.
cmd_risk() {
  local repo="$1" pr="$2" d m sha
  need_meta "$repo" "$pr"
  d="$(run_dir "$repo" "$pr")"; m="$(meta_path "$repo" "$pr")"
  sha="$(cmd_sha "$repo" "$pr")"
  mktmp; local tmp="$TMP"
  api --paginate "repos/$SLUG/pulls/$pr/files" | jq -s 'add // []' > "$tmp/files.json"
  # A jq syntax error exits with 3, which would be confused with a gate violation (E_GATE). Exit separately as a scoring failure
  jq --arg sha "$sha" --arg at "$(now_iso)" -f "$HARNESS_DIR/scripts/risk.jq" "$tmp/files.json" > "$tmp/risk.json" \
    || die "$E_API" "risk.jq calculation failed"

  # If a comment was already posted for the same head and score, carry that record over (chain.sh uses it to avoid duplicate posts).
  # If a rule change altered the score, do not carry it over — so the scorecard on the PR does not go stale
  meta_update "$repo" "$pr" '.risk = ($r[0] + {commented_sha: (if .risk.sha == $r[0].sha and .risk.score == $r[0].score and .risk.level == $r[0].level
                                                               then .risk.commented_sha else null end)})' \
    --slurpfile r "$tmp/risk.json"

  # The scorecard wording follows the auto_merge setting. When it is off, the chain does not merge even a low PR
  jq -r --arg am "$(cfg '.auto_merge == true')" '
    def action: {low: (if $am == "true" then "Merges automatically once every other merge gate passes."
                       else "Auto-merge is off. A person merges once every other merge gate passes." end),
                 medium: "Not auto-merging. One person checks it and merges manually.",
                 high: "Not auto-merging. Someone who knows the flagged areas reviews it, then merges.",
                 critical: "Not auto-merging. A person first decides whether to split the PR."}[.level];
    def files: if length == 0 then "" elif length <= 2 then " — " + (map("`\(.)`") | join(", "))
               else " — `\(.[0])` and \(length - 1) more" end;
    "**Auto-merge risk \(.score) / 100 — `\(.level)`** · scored commit `\(.sha[0:7])`\n",
    (if .override then "**\(.override).** Not auto-merging. Remove the secret, rotate any value already pushed, then a person reviews again.\n" else "\(action)\n" end),
    "| Category | Points | Signals hit |", "|---|---|---|",
    (.categories[] | "| \(.title) | \(.points) / \(.max) | \([.signals[] | select(.points > 0) | "\(.name) \(.points)\(.hits | files)"] | join("<br>") | if . == "" then "-" else . end) |"),
    "| **Total** | **\(.score)** / 100 | |\n",
    (if $am == "true"
     then "low 0–14 auto-merge · medium 15–39 one person approves · high 40–69 review by someone in that area · critical 70+ or a plaintext secret. If it is not low, the chain does not merge and hands it to a person."
     else "low 0–14 · medium 15–39 one person approves · high 40–69 review by someone in that area · critical 70+ or a plaintext secret. Auto-merge is off, so regardless of level the chain does not merge and hands it to a person." end),
    "This score is computed mechanically from file paths and changed line counts only. It does not judge code quality; it measures how much it would hurt if the change were wrong. The rules are in [rules/03-risk.md](https://github.com/thswlsqls/pr-quorum/blob/main/rules/03-risk.md)."
  ' "$tmp/risk.json" > "$d/outputs/risk.md"
  cat "$d/outputs/risk.md"

  [ "$(jq -r '.level' "$tmp/risk.json")" = "low" ] || return "$E_GATE"
}

# ---------- State ----------

cmd_init() {
  local repo="$1" pr="$2" reset_eval=0 prof d
  case "${3:-}" in
    "")            ;;
    --reset-eval)  reset_eval=1 ;;
    *) die "$E_USAGE" "the only flag init knows is --reset-eval: $3" ;;
  esac
  prof="$(profile_of "$repo")"
  d="$(run_dir "$repo" "$pr")"
  mkdir -p "$d/rounds" "$d/prompts" "$d/outputs/stage1" "$d/outputs/stage2" "$d/outputs/stage3"
  [ -f "$d/frozen.md" ] || printf '# Frozen — facts settled in this PR\n\nTo overturn one, bring *new evidence that the settled fact is wrong*.\n\n| # | Settled fact | Evidence | Round frozen |\n|---|---|---|---|\n' > "$d/frozen.md"

  local j base head
  j="$(api "repos/$SLUG/pulls/$pr")"
  base="$(jq -r '.base.sha' <<<"$j")"
  head="$(jq -r '.head.sha' <<<"$j")"

  if [ -f "$d/meta.json" ]; then
    # Rerun. If Stage 1 has already posted, these are the pinned SHAs that review hangs on, so leave them alone —
    # Stage 2 uses the value as last_judged_sha, and overwriting it would lose track of what the review judged.
    # Update it with --reset-eval only when rerunning Stage 1 on a new head.
    local posted; posted="$(jq -r '[.stage1[]?.review_id | select(. != null)] | length' "$d/meta.json")"
    if [ "$posted" -gt 0 ] && [ "$reset_eval" = 0 ]; then
      echo "meta.json kept — $posted Stage 1 post records exist, so base_sha and eval_sha are preserved."
      echo "  eval_sha=$(jq -r '.eval_sha' "$d/meta.json")  (current head=$head)"
      echo "  to rerun Stage 1 on the current head: init $repo $pr --reset-eval"
    else
      meta_update "$repo" "$pr" '.base_sha=$b | .eval_sha=$h' --arg b "$base" --arg h "$head"
      echo "meta.json updated (existing records kept): $d/meta.json"
    fi
  else
    jq -n --arg o "${SLUG%/*}" --arg r "$repo" --argjson p "$pr" \
          --arg b "$base" --arg h "$head" --arg prof "$prof" '
      {owner:$o, repo:$r, pr:$p, base_sha:$b, eval_sha:$h, profile:$prof,
       lock:null, attempts:0, stage1:[], stage2:[], stage3:null, status:"pending"}
    ' > "$d/meta.json"
    echo "created: $d/meta.json"
  fi
}

# Stage order gate — Stage N runs only if Stage N-1 has a completion record.
# Every stage goes through lock, so blocking here once is enough (enforces the documented rule in the script).
check_stage_order() {
  local m="$1" stage="$2" n1 n2
  n1="$(jq -r '[.stage1[]?.review_id | select(. != null)] | length' "$m")"
  n2="$(jq -r '[.stage2[]?] | length' "$m")"
  case "$stage" in
    2) [ "$n1" -gt 0 ] || die "$E_GATE" "no Stage 1 completion record. Stage 2 will not run" ;;
    3) [ "$n1" -gt 0 ] || die "$E_GATE" "no Stage 1 completion record. Stage 3 will not run"
       [ "$n2" -gt 0 ] || die "$E_GATE" "no Stage 2 verdict record. Stage 3 will not run" ;;
  esac
}

cmd_lock() {
  local repo="$1" pr="$2" stage="$3"; need_meta "$repo" "$pr"
  local m; m="$(meta_path "$repo" "$pr")"
  check_stage_order "$m" "$stage"
  local pid started
  pid="$(jq -r '.lock.pid // empty' "$m")"
  started="$(jq -r '.lock.started_at // empty' "$m")"
  if [ -n "$pid" ]; then
    local alive=0 fresh=0
    kill -0 "$pid" 2>/dev/null && alive=1
    # Is started_at within the TTL
    local s_epoch now_epoch
    s_epoch="$(jq -rn --arg s "$started" '$s | fromdateiso8601' 2>/dev/null || echo 0)"
    now_epoch="$(date -u +%s)"
    [ "$s_epoch" -gt 0 ] && [ $((now_epoch - s_epoch)) -lt "$LOCK_TTL_SEC" ] && fresh=1
    if [ "$alive" = 1 ] && [ "$fresh" = 1 ]; then
      echo "lock held — pid=$pid stage=$(jq -r '.lock.stage' "$m") started=$started"
      return "$E_LOCK"
    fi
    echo "clearing stale lock (pid alive=$alive, ttl fresh=$fresh)" >&2
  fi
  local owner; owner="$(owner_pid)"
  meta_update "$repo" "$pr" '.lock={pid:$pid, started_at:$at, stage:$st}' \
    --argjson pid "$owner" --arg at "$(now_iso)" --argjson st "$stage"
  echo "lock acquired — pid=$owner stage=$stage"
}

cmd_unlock() { need_meta "$1" "$2"; meta_update "$1" "$2" '.lock=null'; echo "lock released"; }

cmd_status() {
  need_meta "$1" "$2"
  case "$3" in
    pending|running|done|held-large|held-failed) ;;
    대기|진행|완료|"보류(대형PR)"|"보류(실패)") ;;   # old Korean values, still accepted
    *) die "$E_USAGE" "status value is not on the scale: $3" ;;
  esac
  meta_update "$1" "$2" '.status=$s' --arg s "$3"; echo "status=$3"
}

cmd_attempt() {
  need_meta "$1" "$2"
  case "$3" in
    inc)   meta_update "$1" "$2" '.attempts = (.attempts // 0) + 1' ;;
    reset) meta_update "$1" "$2" '.attempts = 0' ;;
    *) die "$E_USAGE" "attempt takes inc or reset" ;;
  esac
  jq -r '.attempts' "$(meta_path "$1" "$2")"
}

# Part of PG5 (what can be counted mechanically). post-review calls it right before posting, and selftest.sh reruns it on past outputs.
cmd_pg5() {
  local sfile="$1" cfile="$2" stage="${3:-stage1}"
  [ -f "$sfile" ] || die "$E_USAGE" "summary file is missing: $sfile"
  [ -f "$cfile" ] || die "$E_USAGE" "comments file is missing: $cfile"
  if [ "$stage" = "stage1" ]; then
    grep -q 'praise' "$sfile" || jq -e '[.[] | select(.body | test("praise"))] | length > 0' "$cfile" >/dev/null \
      || die "$E_GATE" "PG5 violation — no praise comment"
  fi
  jq -e '[.[] | select((.code|not) or (.axis|not) or (.body|not))] | length == 0' "$cfile" >/dev/null \
    || die "$E_GATE" "PG5 violation — a comment is missing code/axis/body"
  # The axis needs its name in the body, not just its code — the author must be able to read it without opening the profile.
  local noname; noname="$(jq -r '[.[] | select((.body | test("R-[A-I] \\(")) | not) | .code] | join(", ")' "$cfile")"
  [ -z "$noname" ] || die "$E_GATE" "PG5 violation — axis name missing (must be in \`R-x (Name)\` form): $noname"
  # The summary carries the axis legend once — because the blocking order table cells hold only codes.
  if [ "$stage" = "stage1" ]; then
    grep -qE '`R-[A-I]`' "$sfile" || die "$E_GATE" "PG5 violation — summary has no axis legend (rules/00-criteria.md §6)"
  fi
  echo "PG5 passed — $cfile"
}

# PG6 — did the pre-post edit cut meaning (rules/01-stages.md §7). <dir> is the outputs/<stage>[/round-NN] that contains pre-polish/.
# When sessions ran the document's two lines themselves, permissions blocked them and they fell back to comparing by eye (L0-42, L0-51). This moves it to a one-line call.
# Whether impact (②) and direction (④) survived cannot be counted, so it is not checked here.
cmd_pg6() {
  local dir="${1%/}" pre bad=0
  pre="$dir/pre-polish"
  [ -d "$pre" ] || die "$E_USAGE" "copy folder is missing: $pre"

  # JSON — do the count, fields, and first body line match the copy
  if [ -f "$pre/comments.json" ] || [ -f "$dir/comments.json" ]; then
    [ -f "$pre/comments.json" ] && [ -f "$dir/comments.json" ] \
      || die "$E_GATE" "PG6 violation — comments.json exists in only one of the copy and the current folder"
    if ! jq -e -s 'map(map({code, path, line, side:(.side//"RIGHT"), axis, grade,
                           head:(.body | split("\n")[0])})) | .[0] == .[1]' \
         "$pre/comments.json" "$dir/comments.json" >/dev/null; then
      echo "PG6 violation — comments.json count, fields, or first lines differ from the copy"; bad=1
    fi
  fi

  # Markdown — are there anchor or number tokens only in the copy (summary.md · replies/ · patches/)
  # The copy should mirror the original's relative paths, but when cp -R is blocked by permissions, the session copies flat without replies/.
  # If the same path is missing, look it up by file name.
  local rel cur md_pre=() md_cur=() missing
  while IFS= read -r rel; do
    md_pre+=("$pre/$rel")
    cur="$dir/$rel"
    [ -f "$cur" ] || cur="$(find "$dir" -name "$(basename "$rel")" -not -path "$pre/*" | head -1)"
    [ -n "$cur" ] && [ -f "$cur" ] && md_cur+=("$cur")
  done < <(cd "$pre" && find . -name '*.md' | sed 's|^\./||' | sort)
  # An empty copy leaves nothing to compare and looks like a pass — this happens when making the copy was blocked by permissions
  [ -f "$pre/comments.json" ] || [ "${#md_pre[@]}" -gt 0 ] \
    || die "$E_GATE" "PG6 violation — copy folder is empty. Take the copy again, then rerun: $pre"
  if [ "${#md_pre[@]}" -gt 0 ]; then
    tok() { [ $# -eq 0 ] || grep -ohE '[A-Za-z0-9_./-]+\.[a-z]+:[0-9]+|[0-9]+(\.[0-9]+)?' "$@" | sort -u; }
    missing="$(comm -23 <(tok "${md_pre[@]}") <(tok ${md_cur[@]+"${md_cur[@]}"}))"
    if [ -n "$missing" ]; then
      echo "PG6 violation — tokens only in the copy (check each one for a dropped evidence file:line or number):"
      sed 's/^/  /' <<<"$missing"; bad=1
    fi
  fi

  [ "$bad" = 0 ] || return "$E_GATE"
  echo "PG6 passed — $dir (JSON fields and first lines, markdown anchors and numbers)"
}

# Takes the pre-edit copy. Exists so sessions need no cp permission — the only copy target is one output folder under runs/.
cmd_snapshot() {
  local dir="${1%/}" runs real f copied=()
  [ -d "$dir" ] || dir="$PR_QUORUM_HOME/$dir"
  [ -d "$dir" ] || die "$E_USAGE" "output folder is missing: $1"
  runs="$(cd "$RUNS_DIR" && pwd -P)"
  real="$(cd "$dir" && pwd -P)"
  case "$real/" in "$runs"/*/*) ;; *) die "$E_USAGE" "only output folders under runs/ are accepted: $1" ;; esac
  mkdir -p "$real/pre-polish"
  for f in comments.json summary.md replies patches; do
    [ -e "$real/$f" ] || continue
    cp -R "$real/$f" "$real/pre-polish/"
    copied+=("$f")
  done
  echo "copy — $real/pre-polish (${copied[*]:-none})"
}

# Stage 2 records. Sessions cannot edit meta.json (the merge gate reads these), so the writes they need go through here.
# Opens the record for this pass before the first reply or post-review: a new element when stage2 is empty, the last pass already has
# verdicts, or it judged another commit; otherwise (a resumed session) the unfinished last element is reused
cmd_stage2_begin() {
  local repo="$1" pr="$2" sha="$3" last="$4"; need_meta "$repo" "$pr"
  meta_update "$repo" "$pr" '.stage2 = ((.stage2 // []) | if length == 0 or (.[-1].verdicts != null) or ((.[-1].stage_sha // $sha) != $sha)
                                                       then . + [{}] else . end)
                             | .stage2[-1] += {round: (.stage2 | length), stage_sha:$sha, last_judged_sha:$lj, at:(.stage2[-1].at // $at)}' \
    --arg sha "$sha" --arg lj "$last" --arg at "$(now_iso)"
  echo "stage2 pass $(jq -r '.stage2 | length' "$(meta_path "$repo" "$pr")") open — stage_sha=$sha last_judged_sha=$last"
}

# The four verdict words of rules/01-stages.md §2 and nothing else. The chain counts a Stage 2 pass as done once its element has verdicts
cmd_verdicts() {
  local repo="$1" pr="$2" sha="$3" vfile="$4" m bad; need_meta "$repo" "$pr"
  m="$(meta_path "$repo" "$pr")"
  jq -e 'type == "object" and length > 0' "$vfile" >/dev/null 2>&1 \
    || die "$E_USAGE" "$vfile must be a non-empty JSON object of {code: verdict}"
  bad="$(jq -r '[to_entries[] | select((.key | test("^[A-Za-z0-9][A-Za-z0-9_-]*$") | not)
                 or (.value | IN("addressed", "partial", "not-addressed", "regressed") | not)) | "\(.key)=\(.value)"] | join(", ")' "$vfile")"
  [ -z "$bad" ] || die "$E_USAGE" "verdicts must be addressed|partial|not-addressed|regressed, keyed by comment code: $bad"
  [ "$(jq -r --arg sha "$sha" '(.stage2[-1]? // null) as $l | $l != null and (($l.stage_sha // $sha) == $sha)' "$m")" = true ] \
    || die "$E_GATE" "no open Stage 2 record for $sha. Call stage2-begin first"
  meta_update "$repo" "$pr" '.stage2[-1] += {stage_sha:$sha, verdicts:$v[0]}' --arg sha "$sha" --slurpfile v "$vfile"
  echo "verdicts recorded — $(jq 'length' "$vfile") in stage2 pass $(jq -r '.stage2 | length' "$m")"
}

# Replies made under this lock before post-review collect in stage3_replies (see record_reply). A session that ends without posting moves them here
cmd_stage3_replies() {
  local repo="$1" pr="$2"; need_meta "$repo" "$pr"
  [ "$(jq -r '.stage3 != null' "$(meta_path "$repo" "$pr")")" = true ] || die "$E_GATE" "Stage 3 has no post record to move the replies into"
  meta_update "$repo" "$pr" '.stage3.replies = ((.stage3.replies // {}) + (.stage3_replies // {})) | del(.stage3_replies)'
  echo "stage3 replies — $(jq -r '.stage3.replies | length' "$(meta_path "$repo" "$pr")") recorded"
}

# ---------- Build ----------

# The only way sessions run a build, test, or lint. The command comes from repos.<repo>.commands.<kind> in config.json, which sessions cannot edit;
# the session passes only the kind and a target. Allowing ./gradlew or npm run build directly let a session write a package.json under runs/
# and run any shell from it (improvement plan 02 §1-A), so the tree a build runs in is checked here too.
# build (review sessions): a clean worktree whose HEAD is a SHA this PR pinned. author-build: the author worktree pr-author-<pr>, edits allowed.
# author-build is a separate subcommand, not a flag, so the review settings keep it out by simply not allowing it — no deny prefix to get around
BUILD_AUTHOR=0

cmd_build() {
  local repo="$1" pr="$2" wt="$3" kind="$4" target="${5:-}" path parent wtroot real runs top c head m
  case "$kind" in build|test|lint) ;; *) die "$E_USAGE" "kind must be one of build|test|lint: $kind" ;; esac
  # The target lands inside a bash -c string. No spaces or shell metacharacters, no leading - (an option such as --init-script) or /, no ..
  if [ -n "$target" ]; then
    [[ "$target" =~ ^[A-Za-z0-9:_.][A-Za-z0-9:_./-]*$ ]] && [[ "$target" != *..* ]] \
      || die "$E_USAGE" "target may contain only letters, digits, and : _ . / - (no leading - or /, no ..): $target"
  fi

  [ -d "$wt" ] || die "$E_USAGE" "worktree is missing: $wt"
  real="$(cd "$wt" && pwd -P)"
  path="$(cfg --arg r "$repo" '.repos[$r].path' | sed 's|/*$||')"
  parent="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || die "$E_ENV" "parent folder of repos.$repo.path is missing: $path"
  wtroot="$parent/$repo-worktrees"
  runs="$(cd "$RUNS_DIR" 2>/dev/null && pwd -P || echo "$RUNS_DIR")"
  case "$real/" in "$runs"/*) die "$E_GATE" "builds do not run under runs/: $real" ;; esac
  if [ "$BUILD_AUTHOR" = 1 ]; then
    [ "$real" = "$wtroot/pr-author-$pr" ] || die "$E_GATE" "author-build runs only in $wtroot/pr-author-$pr: $real"
  else
    case "$real/" in "$wtroot"/?*/) ;; *) die "$E_GATE" "builds run only in a worktree under $wtroot/: $real" ;; esac
  fi
  top="$(cd "$real" && git rev-parse --show-toplevel 2>/dev/null)" || die "$E_GATE" "not a git worktree: $real"
  [ "$(cd "$top" && pwd -P)" = "$real" ] || die "$E_GATE" "pass the worktree root, not a folder inside it: $real"
  top="$real"

  if [ "$BUILD_AUTHOR" = 0 ]; then
    # Clean means nothing planted only because review sessions cannot write inside <repo>-worktrees (gitignored files do not show here)
    [ -z "$(cd "$real" && git status --porcelain)" ] || die "$E_GATE" "worktree has changes — review builds run only on a clean tree: $real"
    head="$(cd "$real" && git rev-parse HEAD)"
    # The SHAs this PR pinned (§6 of rules/01-stages.md), else the current PR head on GitHub
    m="$(meta_path "$repo" "$pr")"
    if ! { [ -f "$m" ] && jq -e --arg h "$head" '[.eval_sha, .stage1[]?.eval_sha, .stage2[]?.stage_sha, .stage3.stage_sha?,
                                                   .stage3_history[]?.stage_sha] | index($h) != null' "$m" >/dev/null; } \
       && [ "$(cmd_sha "$repo" "$pr")" != "$head" ]; then
      die "$E_GATE" "HEAD ${head:0:7} is neither a SHA pinned in meta.json nor the head of PR #$pr"
    fi
  fi

  if [ "$(cfg --arg r "$repo" '.repos[$r] | has("commands")')" = true ]; then
    c="$(cfg --arg r "$repo" --arg k "$kind" '.repos[$r].commands[$k] // empty')"
    [ -n "$c" ] || die "$E_ENV" "repos.$repo.commands.$kind is not set in config.json — record it as not measured"
    if [[ "$c" == *"<target>"* ]]; then
      [ -n "$target" ] || die "$E_USAGE" "this $kind command needs a target: $c"
      c="${c//"<target>"/$target}"
    elif [ -n "$target" ]; then
      die "$E_USAGE" "this $kind command takes no target: $c"
    fi
  # No commands in config.json — run what the rules ran before the setting existed
  elif [ -f "$real/gradlew" ]; then
    case "$kind" in
      build|test) c="./gradlew ${target:+$target:}$kind" ;;
      *) die "$E_ENV" "no $kind command for a Gradle worktree without repos.$repo.commands — record it as not measured" ;;
    esac
  else
    # npm — the target is the app folder to run in (e.g. app/), as the frontend profile measures per app
    if [ -n "$target" ]; then
      real="$(cd "$real/$target" 2>/dev/null && pwd -P)" || die "$E_USAGE" "target folder is missing: $target"
      case "$real/" in "$top"/*) ;; *) die "$E_GATE" "target folder is outside the worktree: $target" ;; esac
    fi
    [ -f "$real/package.json" ] \
      || die "$E_ENV" "repos.$repo.commands is not set and $real has neither gradlew nor package.json — record it as not measured"
    case "$kind" in
      build) c="npm run build" ;;
      lint)  c="npm run lint" ;;
      test)  c="npx --no -- tsc --noEmit" ;;   # --no: never fetch a package from the registry when typescript is not installed locally
    esac
  fi

  echo "pr-quorum: running in $real: $c" >&2
  # The command's own exit code and output pass through as-is
  local rc=0
  (cd "$real" && exec bash -c "$c") || rc=$?
  return "$rc"
}

# ---------- Post ----------

# Post bodies must be regular files under runs/. Sessions can call this script, so
# passing another path would post that file as a public comment without going through the Read deny rules
need_run_file() {
  local f="$1" runs dir
  [ -f "$f" ] && [ ! -L "$f" ] || die "$E_USAGE" "body file is missing or is a link: $f"
  runs="$(cd "$RUNS_DIR" && pwd -P)"
  dir="$(cd "$(dirname "$f")" && pwd -P)"
  case "$dir/" in "$runs"/*) ;; *) die "$E_USAGE" "body file must be under runs/: $f" ;; esac
}

# Runs before the bot token is loaded and before any API call. Exit 3, and the matched text is never echoed
need_clean_body() { scan_tokens "$@" || die "$E_GATE" "outgoing body holds a token — nothing was posted. Remove it from the file"; }
# comments.json goes out through jq, which decodes escapes such as \u0067hp_…, so scan the decoded strings too, not only the file as written.
# A file jq cannot parse fails closed
need_clean_json() {
  local d; d="$(mktemp)"
  jq -r '.. | strings' "$1" > "$d" 2>/dev/null || { rm -f "$d"; die "$E_GATE" "could not decode $1 for the token scan — nothing was posted"; }
  scan_tokens "$d" || { rm -f "$d"; die "$E_GATE" "outgoing comments hold a token once decoded — nothing was posted. Remove it from $1"; }
  rm -f "$d"
}

cmd_post_review() {
  local repo="$1" pr="$2" sha="$3" sfile="$4" cfile="$5" stage="${6:-stage1}"
  case "$stage" in
    stage1|stage2|stage3) ;;
    *) die "$E_USAGE" "stage must be one of stage1|stage2|stage3: $stage" ;;
  esac
  [ -f "$sfile" ] || die "$E_USAGE" "summary file is missing: $sfile"
  [ -f "$cfile" ] || die "$E_USAGE" "comments file is missing: $cfile"
  need_meta "$repo" "$pr"

  # Run PG1 once more right before posting — even if the session skipped it, it is caught here.
  cmd_gate1 "$repo" "$pr" "$sha" "$cfile" || return "$E_GATE"

  cmd_pg5 "$sfile" "$cfile" "$stage"

  load_bot_token
  mktmp; local tmp="$TMP" known rid posting
  # The draft as posted. When a later call adopts the review, this copy stands in for comments.json — a retrying session may have
  # rewritten that file, and its codes must not land on the earlier review's comments. Removed once the review is recorded
  posting="$(run_dir "$repo" "$pr")/outputs/$stage/posting-${sha:0:7}.json"
  # Sessions can write under runs/, so the copy gets the same distrust as comments.json: no link, nothing but a regular file,
  # and a stage folder that resolves inside runs/
  mkdir -p "$(dirname "$posting")"
  { [ ! -L "$posting" ] && { [ ! -e "$posting" ] || [ -f "$posting" ]; }; } \
    || die "$E_USAGE" "posting copy is a link or not a regular file — nothing was posted. Remove it: $posting"
  case "$(cd "$(dirname "$posting")" && pwd -P)/" in
    "$(cd "$RUNS_DIR" && pwd -P)"/*) ;;
    *) die "$E_USAGE" "outputs/$stage resolves outside runs/ — nothing was posted: $(dirname "$posting")" ;;
  esac

  # Adoption — a bot review on this SHA carrying this stage's marker that meta.json does not know was posted by an earlier call
  # that died before recording it, or whose POST response was lost. Record that one instead of posting a second.
  # Reviews already recorded are left out, so rerunning a stage on purpose still posts. A failed check posts nothing
  known="$(jq -c '[.stage1[]?.review_id, .stage2[]?.review_id, .stage3.review_id?, .stage3_history[]?.review_id] | map(select(. != null))' \
    "$(meta_path "$repo" "$pr")")"
  rid="$(api --paginate "repos/$SLUG/pulls/$pr/reviews" \
    | jq -s -r --arg b "$(cfg '.bot // empty')" --arg s "$sha" --arg mk "<!-- pr-quorum:$stage -->" --argjson k "$known" '
        [add // [] | .[] | select(.user.login == $b and ((.commit_id // "") | startswith($s)) and ((.body // "") | contains($mk))
                                 and ((.id as $i | $k | index($i)) == null))]
        | last | .id // empty')" \
    || die "$E_API" "could not list the PR's reviews to check for an unrecorded earlier post — nothing was posted"
  if [ -n "$rid" ]; then
    [ -f "$posting" ] || posting="$cfile"
    # The file whose codes go into meta.json passes the checks comments.json passed at the entry point
    need_run_file "$posting"; need_clean_body "$posting"; need_clean_json "$posting"
    jq -e 'type == "array"' "$posting" >/dev/null 2>&1 || die "$E_USAGE" "$posting must be a JSON array — nothing was recorded"
    record_review "$repo" "$pr" "$stage" "$rid" "$sha" "$posting" \
      || die "$E_API" "review_id=$rid is on GitHub but recording it in meta.json failed — rerun the same post-review command"
    [ "$posting" = "$cfile" ] || rm -f "$posting"
    echo "adopted — review_id=$rid (already posted, now recorded)"
    return 0
  fi

  # Only path/line/side/body are posted. code/axis/grade are for the meta record.
  # The body ends with a stage marker (an HTML comment, not rendered) — the adoption check above looks for it
  jq -n --arg cid "$sha" --rawfile body "$sfile" --slurpfile c "$cfile" --arg st "$stage" '
    {commit_id:$cid, event:"COMMENT", body:($body + "\n\n<!-- pr-quorum:" + $st + " -->"),
     comments: ($c[0] | map({path, line, side:(.side // "RIGHT"), body}))}
  ' > "$tmp/payload.json"

  # Written to a temp file beside it and renamed over, so the copy is never half-written and never followed through a link
  local t; t="$(mktemp "$(dirname "$posting")/.posting.XXXXXX")" && cp "$cfile" "$t" && mv -f "$t" "$posting" \
    || { rm -f "${t:-}"; die "$E_ENV" "could not write the posting copy — nothing was posted: $posting"; }
  local resp; resp="$(gh api "repos/$SLUG/pulls/$pr/reviews" --input "$tmp/payload.json")" \
    || die "$E_API" "review post failed. On 422, first suspect a line anchor that does not attach at the pinned SHA ($sha) (rules/01-stages.md §7). If the review did go up, rerunning the same post-review command records it without posting again"
  local review_id; review_id="$(jq -r '.id' <<<"$resp")"

  record_review "$repo" "$pr" "$stage" "$review_id" "$sha" "$posting" \
    || die "$E_API" "review posted (review_id=$review_id) but not recorded in meta.json — rerun the same post-review command; it records this review without posting again"
  rm -f "$posting"
  echo "posted — review_id=$review_id, $(jq 'length' "$cfile") inline comments"
}

# record_review <repo> <pr> <stage> <review_id> <sha> <draft comments.json> — writes a posted review into meta.json.
# It runs after the review is public and is called with ||, so errexit is off here: each step returns 1 on failure instead.
record_review() {
  local repo="$1" pr="$2" stage="$3" review_id="$4" sha="$5" cfile="$6" tmp="$TMP" merged

  # Fetch the ids of the posted inline comments and attach code/axis/grade by (path,line).
  api --paginate "repos/$SLUG/pulls/$pr/comments" \
    | jq -s 'add | map(select(.pull_request_review_id == '"$review_id"'))
             | map({id, path, line, body})' > "$tmp/posted.json" || return 1

  # Match by body first — with two comments at the same spot, (path,line) alone cannot tell them apart,
  # the ids get swapped, and Stage 2 replies in the wrong thread.
  merged="$(jq -s '
      .[0] as $draft | .[1] as $posted |
      $draft | map(. as $d
        | (first($posted[] | select(.body == $d.body) | .id)
           // first($posted[] | select(.path==$d.path and .line==$d.line) | .id)) as $id
        | {id: ($id // null), code:$d.code, path:$d.path, line:$d.line,
           axis:$d.axis, grade:($d.grade // null)})
    ' "$cfile" "$tmp/posted.json")" || return 1

  # Each stage records in a different place. Appending stage2 to stage1 would break both the watcher's "already posted" check and
  # the stage1[].comments[].id that Stage 2 uses to find threads.
  case "$stage" in
    stage1)
      meta_update "$repo" "$pr" '.stage1 += [{review_id:$rid, posted_at:$at, eval_sha:$sha, comments:$c}] | .attempts=0 | .status="done"' \
        --argjson rid "$review_id" --arg at "$(now_iso)" --arg sha "$sha" --argjson c "$merged" || return 1 ;;
    stage2)
      # If the last element is a round that judged a different commit, append a new element — merging would overwrite the previous round's post record (L0-25)
      meta_update "$repo" "$pr" '.stage2 = ((.stage2 // []) | if length == 0 or ((.[-1].stage_sha // $sha) != $sha) then . + [{}] else . end)
                                 | .stage2[-1] += {review_id:$rid, posted_at:$at, stage_sha:$sha, new_comments:$c}' \
        --argjson rid "$review_id" --arg at "$(now_iso)" --arg sha "$sha" --argjson c "$merged" || return 1 ;;
    stage3)
      # On a rerun against a different commit, move the previous round to stage3_history — merging would overwrite its review_id and stage_sha (L0-43)
      meta_update "$repo" "$pr" '((.stage3 != null) and ((.stage3.stage_sha // $sha) != $sha)) as $new
                                 | (if $new then .stage3_history = ((.stage3_history // []) + [.stage3]) | .stage3 = null else . end)
                                 | .stage3 = ((.stage3 // {}) + {review_id:$rid, posted_at:$at, stage_sha:$sha, comments:$c})
                                 | .stage3.replies = ((.stage3.replies // {}) + (.stage3_replies // {})) | del(.stage3_replies)' \
        --argjson rid "$review_id" --arg at "$(now_iso)" --arg sha "$sha" --argjson c "$merged" || return 1 ;;
  esac

  jq -r '.[] | select(.id == null) | "warning — comment with no id found: \(.code) \(.path):\(.line)"' <<<"$merged" >&2
}

cmd_reply() {
  local repo="$1" pr="$2" cid="$3" bfile="$4" rid
  [ -f "$bfile" ] || die "$E_USAGE" "body file is missing: $bfile"
  need_meta "$repo" "$pr"
  load_bot_token
  rid="$(jq -n --rawfile b "$bfile" '{body:$b}' \
    | gh api "repos/$SLUG/pulls/$pr/comments/$cid/replies" --input - --jq '.id')" \
    || die "$E_API" "reply failed (comment_id=$cid)"
  echo "$rid"

  # The post already went through, so exit 0 even if recording fails — retrying on a failure code would post the reply twice.
  record_reply "$repo" "$pr" "$cid" "$rid" \
    || echo "warning — the reply was posted (id $rid) but recording it in meta.json failed. Do not post again; record it by hand" >&2
}

# Records the reply id in the stage record of the current lock. Without it, the next stage cannot find the thread and
# a resumed session posts the same reply twice (L0-23). The key is the parent comment's code, or comment_id if not found.
# For Stage 3, it goes into the round post-review already posted under this lock if there is one; otherwise it is collected in .stage3_replies
# and post-review merges it — if a reply created .stage3, chain.sh's stage3_done would turn true before posting,
# and attached to the previous round's object it would be pushed into history along with it on a rerun.
record_reply() {
  local repo="$1" pr="$2" cid="$3" rid="$4" m stage code
  m="$(meta_path "$repo" "$pr")"
  stage="$(jq -r '.lock.stage // empty' "$m")" || return 1
  code="$(jq -r --argjson id "$cid" 'first(([.stage1[]?.comments[]?] + [.stage2[]?.new_comments[]?] + [.stage3.comments[]?])[]
                                           | select(.id == $id) | .code) // empty' "$m")" || return 1
  case "$stage" in
    2) meta_update "$repo" "$pr" '.stage2 = ((.stage2 // []) | if length == 0 then [{}] else . end) | .stage2[-1].replies[$k] = $rid' \
         --arg k "${code:-$cid}" --argjson rid "$rid" ;;
    3) meta_update "$repo" "$pr" 'if .stage3 != null and (.stage3.posted_at // "") >= (.lock.started_at // "~")
                                  then .stage3.replies[$k] = $rid else .stage3_replies[$k] = $rid end' \
         --arg k "${code:-$cid}" --argjson rid "$rid" ;;
    *) echo "warning — the lock has no stage 2 or 3, so reply id ($rid) was not recorded in meta.json" >&2 ;;
  esac
}

cmd_patch() {
  local repo="$1" pr="$2" cid="$3" bfile="$4"
  [ -f "$bfile" ] || die "$E_USAGE" "body file is missing: $bfile"
  load_bot_token
  jq -n --rawfile b "$bfile" '{body:$b}' \
    | gh api -X PATCH "repos/$SLUG/pulls/comments/$cid" --input - --jq '.id' \
    || die "$E_API" "patch failed (comment_id=$cid). The bot can edit only its own comments"
}

# Edits the summary body of a posted review. The bot can edit only its own reviews.
cmd_patch_review() {
  local repo="$1" pr="$2" rid="$3" bfile="$4"
  [ -f "$bfile" ] || die "$E_USAGE" "body file is missing: $bfile"
  load_bot_token
  jq -n --rawfile b "$bfile" '{body:$b}' \
    | gh api -X PUT "repos/$SLUG/pulls/$pr/reviews/$rid" --input - --jq '.id' \
    || die "$E_API" "summary correction failed (review_id=$rid)"
}

cmd_comment() {
  local repo="$1" pr="$2" bfile="$3"
  [ -f "$bfile" ] || die "$E_USAGE" "body file is missing: $bfile"
  load_bot_token
  jq -n --rawfile b "$bfile" '{body:$b}' \
    | gh api "repos/$SLUG/issues/$pr/comments" --input - --jq '.id' \
    || die "$E_API" "comment post failed"
}

# ---------- Check ----------

# doctor.sh calls this instead of reading the token file itself — the token is read only in this script
cmd_whoami() { load_bot_token; api user --jq '.login'; }

# ---------- Entry point ----------

# Comment and review ids go straight into gh api paths. A non-numeric value could call a different API path
need_id() { [[ "$2" =~ ^[0-9]+$ ]] || die "$E_USAGE" "$1 must be numeric: $2"; }
# The pinned SHA also goes into the compare path. Accept only 7–40 hex characters
need_sha() { [[ "$1" =~ ^[0-9a-f]{7,40}$ ]] || die "$E_USAGE" "SHA must be 7–40 hex characters: $1"; }
# Stage 2 records are matched to post-review's stage_sha by string, so a short SHA would split one pass into two elements
need_full_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]] || die "$E_USAGE" "SHA must be the full 40 hex characters: $1"; }

[ $# -ge 1 ] || usage
sub="$1"; shift
# The repository name and PR number become gh api paths and paths under runs/. Only repository names in config.json repos are accepted.
# A non-numeric PR number could make init create a folder and frozen.md outside runs/
case "$sub" in
  pg5|pg6|snapshot|whoami) ;;
  *) profile_of "${1:-}" >/dev/null
     [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "$E_USAGE" "PR number must be a positive integer: ${2:-}"
     SLUG="$(repo_slug "$1")" || exit "$E_ENV" ;;
esac
case "$sub" in
  sha)         [ $# -eq 2 ] || usage; cmd_sha "$@" ;;
  meta)        [ $# -eq 2 ] || usage; cmd_meta "$@" ;;
  precheck)    [ $# -eq 2 ] || usage; cmd_precheck "$@" ;;
  ranges)      [ $# -eq 3 ] || usage; need_sha "$3"; cmd_ranges "$@" ;;
  gate1)       [ $# -eq 4 ] || usage; need_sha "$3"; cmd_gate1 "$@" ;;
  risk)        [ $# -eq 2 ] || usage; cmd_risk "$@" ;;
  pg5)         [ $# -ge 2 ] && [ $# -le 3 ] || usage; cmd_pg5 "$@" ;;
  pg6)         [ $# -eq 1 ] || usage; cmd_pg6 "$@" ;;
  snapshot)    [ $# -eq 1 ] || usage; cmd_snapshot "$@" ;;
  init)        [ $# -ge 2 ] && [ $# -le 3 ] || usage; cmd_init "$@" ;;
  lock)        [ $# -eq 3 ] || usage; cmd_lock "$@" ;;
  unlock)      [ $# -eq 2 ] || usage; cmd_unlock "$@" ;;
  status)      [ $# -eq 3 ] || usage; cmd_status "$@" ;;
  attempt)     [ $# -eq 3 ] || usage; cmd_attempt "$@" ;;
  stage2-begin) [ $# -eq 4 ] || usage; need_full_sha "$3"; need_full_sha "$4"; cmd_stage2_begin "$@" ;;
  verdicts)    [ $# -eq 4 ] || usage; need_full_sha "$3"; need_run_file "$4"; cmd_verdicts "$@" ;;
  stage3-replies) [ $# -eq 2 ] || usage; cmd_stage3_replies "$@" ;;
  build)       [ $# -ge 4 ] && [ $# -le 5 ] || usage; cmd_build "$@" ;;
  author-build) [ $# -ge 4 ] && [ $# -le 5 ] || usage; BUILD_AUTHOR=1; cmd_build "$@" ;;
  post-review) [ $# -ge 5 ] || usage; need_sha "$3"; need_run_file "$4"; need_run_file "$5"; need_clean_body "$4" "$5"; need_clean_json "$5"; cmd_post_review "$@" ;;
  reply)       [ $# -eq 4 ] || usage; need_id comment_id "$3"; need_run_file "$4"; need_clean_body "$4"; cmd_reply "$@" ;;
  patch)       [ $# -eq 4 ] || usage; need_id comment_id "$3"; need_run_file "$4"; need_clean_body "$4"; cmd_patch "$@" ;;
  patch-review) [ $# -eq 4 ] || usage; need_id review_id "$3"; need_run_file "$4"; need_clean_body "$4"; cmd_patch_review "$@" ;;
  comment)     [ $# -eq 3 ] || usage; need_run_file "$3"; need_clean_body "$3"; cmd_comment "$@" ;;
  whoami)      [ $# -eq 0 ] || usage; cmd_whoami ;;
  *) usage ;;
esac
