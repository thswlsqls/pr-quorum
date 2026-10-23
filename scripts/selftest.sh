#!/usr/bin/env bash
# selftest.sh — reruns pr-quorum.sh's mechanical gates (PG5, PG6) on real past outputs. Uses no LLM.
# Run it once after changing a gate script. If an already-posted output fails the new rule, the rule is most likely wrong
# (PR #38 was blocked from posting by the axis regex R-[A-H] alone — L0-31).
# ~/.pr-quorum/runs lives outside the repository, so it exists only on this machine. Skip if it is missing.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR_QUORUM="$HARNESS_DIR/scripts/pr-quorum.sh"
source "$HARNESS_DIR/scripts/config.sh"
RUNS="$PR_QUORUM_HOME/runs"

[ -d "$RUNS" ] || { echo "no runs/ — skipping"; exit 0; }

pass=0; fail=0
check() {  # check <name> <command...>
  local name="$1" out; shift
  if out="$("$@" 2>&1)"; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL — $name"; sed 's/^/    /' <<<"$out"
  fi
}

# PG5 — folders with both a summary and comments. The stage comes from the path (in early runs, outputs/ itself is Stage 1).
while IFS= read -r d; do
  case "$d" in */stage2*) st=stage2 ;; */stage3*) st=stage3 ;; *) st=stage1 ;; esac
  [ -f "$d/comments.json" ] && check "pg5 ${d#"$RUNS"/} ($st)" "$PR_QUORUM" pg5 "$d/summary.md" "$d/comments.json" "$st"
done < <(find "$RUNS"/*/outputs -name summary.md -not -path '*/pre-polish/*' -exec dirname {} \; | sort)

# PG6 — folders with a pre-edit copy
while IFS= read -r p; do
  d="$(dirname "$p")"
  # A copy directly under outputs/ is the layout from before per-stage folders (L0-15). The original moved to stage1/, so there is nothing to compare against
  [ "$(basename "$d")" = outputs ] && { echo "skipped — ${d#"$RUNS"/}/pre-polish (layout from before per-stage folders)"; continue; }
  check "pg6 ${d#"$RUNS"/}" "$PR_QUORUM" pg6 "$d"
done < <(find "$RUNS"/*/outputs -type d -name pre-polish | sort)

echo "selftest — passed $pass · failed $fail"
[ "$fail" = 0 ] || exit 3
