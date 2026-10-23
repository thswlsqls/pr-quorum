#!/usr/bin/env bash
# dream.sh — gathers learning candidates and records from several PR runs and produces a learnings proposal. Instructions are in rules/04-dream.md.
# The session gets only Read, Grep, and Glob. This script writes the session's final response to the proposal file —
# the session takes text written by sessions that read PRs as input, so it must not edit any file directly.
# Applying it is done by a person, who records a verdict for each proposal item and opens a harness PR.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HARNESS_DIR/scripts/config.sh"
RUNS="$PR_QUORUM_HOME/runs"

usage() { echo "usage: dream.sh [<run name>...]   e.g. dream.sh my-repo-pr33 my-repo-pr34 (default: every PR run under runs/)" >&2; exit 1; }
case "${1:-}" in -h|--help) usage ;; esac

if [ $# -eq 0 ]; then
  for d in "$RUNS"/*-pr*/; do [ -d "$d" ] && set -- "$@" "$(basename "$d")"; done
  [ $# -gt 0 ] || { echo "no PR runs under runs/" >&2; exit 1; }
fi
for r in "$@"; do
  [[ "$r" =~ ^[a-z0-9-]+-pr[1-9][0-9]*$ ]] && [ -d "$RUNS/$r" ] || { echo "not a run: $r" >&2; usage; }
done

# Past proposals — pass only finished ones as input. The session reads the verdicts people wrote so it does not re-propose rejected items
past=()
for p in "$RUNS"/_dream/*/proposal.md; do
  # Accept the old Korean header too, so proposals written before the English migration still count
  [ -f "$p" ] && grep -qE '^- (status: done|상태: 완료)$' "$p" && past+=("$p")
done

out_dir="$RUNS/_dream/$(date +%Y%m%d%H%M%S)"
[ ! -e "$out_dir" ] || { echo "already exists: $out_dir" >&2; exit 1; }
mkdir -p "$out_dir"
out="$out_dir/proposal.md"

runs_list="$*"
started="$(date '+%Y-%m-%d %H:%M:%S %z')"
header() {  # header <status>
  printf '# learnings proposal\n\n- status: %s\n- time: %s\n- harness commit: %s\n- runs reviewed: %s\n- past proposals: %s\n' \
    "$1" "$started" "$(git -C "$HARNESS_DIR" rev-parse --short HEAD)" "$runs_list" "${past[*]:-none}"
}
header "writing" > "$out"

prompt="Read $HARNESS_DIR/rules/04-dream.md and follow it exactly.
Runs to review this time: $(for r in "$@"; do printf '%s/%s ' "$RUNS" "$r"; done)
Past proposals: ${past[*]:-none}"

render_settings "$HARNESS_DIR" dream-settings.json
rc=0
res="$( cd "$HARNESS_DIR" && claude -p --output-format json --permission-mode dontAsk \
    --settings "$PR_QUORUM_HOME/dream-settings.json" --setting-sources "" \
    --tools Read,Grep,Glob --strict-mcp-config \
    -- "$prompt" < /dev/null )" || rc=$?

body="$(jq -r 'select(.is_error == false) | .result // empty' <<<"$res" 2>/dev/null || true)"
if [ "$rc" != 0 ] || [ -z "$body" ]; then
  echo "the dream session did not produce a proposal (exit $rc). $out stays at 'writing' — it will not count as a finished proposal" >&2
  exit 4
fi
{ header "done"
  jq -r '"- session: \(.session_id) · \(.num_turns) turns · \((.duration_ms // 0) / 1000 | floor) s · $\(.total_cost_usd) · tool denials \(.permission_denials | if type == "array" then "\(length)" else "not recorded" end)\n"' <<<"$res"
  printf '%s\n' "$body"
} > "$out.tmp" && mv "$out.tmp" "$out"
echo "$out"
