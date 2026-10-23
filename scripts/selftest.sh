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

pass=0; fail=0
check() {  # check <name> <command...>
  local name="$1" out; shift
  if out="$("$@" 2>&1)"; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL — $name"; sed 's/^/    /' <<<"$out"
  fi
}

# risk.jq — document classification (rules/03-risk.md). One file, 400 added lines. Needs no network and no runs/
risk_score() {  # risk_score <filename> <expected score>
  local got
  got="$(jq -nc --arg f "$1" '[{filename:$f, additions:400, deletions:0, patch:"+x"}]' \
        | jq --arg sha t --arg at t -f "$HARNESS_DIR/scripts/risk.jq" | jq -r .score)" || return 1
  [ "$got" = "$2" ] || { echo "$1: expected $2, got $got"; return 1; }
}
check "risk doc top-level docs/"     risk_score "docs/guide.md" 0
check "risk doc contents/ image"     risk_score "contents/api-auth/flow.png" 0
check "risk doc contents/ .mmd"      risk_score "contents/api-auth/flow.mmd" 0
check "risk doc nested .md"          risk_score "api/auth/docs/design.md" 0
check "risk code under nested docs/" risk_score "src/main/java/com/acme/docs/auth/JwtAuthFilter.java" 40
check "risk code under contents/"    risk_score "src/main/java/com/acme/contents/auth/JwtAuthFilter.java" 40
check "risk harness rule .md"        risk_score "rules/03-risk.md" 15
# Every plugin script must hit the harness signal — risk.jq lists them by name, so a new script left off that list would auto-merge at 0 points
harness_hit() {  # harness_hit <filename>
  jq -nc --arg f "$1" '[{filename:$f, additions:1, deletions:0, patch:"+x"}]' \
    | jq --arg sha t --arg at t -f "$HARNESS_DIR/scripts/risk.jq" \
    | jq -e '[.categories[].signals[] | select(.name == "Auto-merge gate/harness") | .points] | add == 15' >/dev/null \
    || { echo "$1 is not in the harness name list of scripts/risk.jq and rules/03-risk.md"; return 1; }
}
for s in "$HARNESS_DIR"/scripts/*; do
  check "risk harness list has $(basename "$s")" harness_hit "scripts/$(basename "$s")"
done
# Build and dependency files of other stacks (rules/03-risk.md) — build script 15 + dependencies 15 + scope 10, or dependencies 15 + scope 10
check "risk Maven pom.xml"           risk_score "pom.xml" 40
check "risk Python pyproject.toml"   risk_score "pyproject.toml" 40
check "risk Python requirements"     risk_score "requirements-dev.txt" 25
check "risk Go go.mod"               risk_score "go.mod" 25
check "risk Rust Cargo.lock"         risk_score "Cargo.lock" 25
# Test files of other stacks count as tests — no production signal and no scope points
check "risk Go test file"            risk_score "pkg/auth/token_test.go" 0
check "risk Python test file"        risk_score "tests/test_api.py" 0
check "risk Go code without tests"   risk_score "pkg/store/store.go" 25
# Dependency-only PRs, files run at build or test time, and renames out of a sensitive path (rules/03-risk.md)
risk_json() {  # risk_json <files JSON> <expected score> — for multi-file and rename cases
  local got; got="$(jq --arg sha t --arg at t -f "$HARNESS_DIR/scripts/risk.jq" <<<"$1" | jq -r .score)" || return 1
  [ "$got" = "$2" ] || { echo "expected $2, got $got"; return 1; }
}
check "risk lock file only"          risk_score "package-lock.json" 15
check "risk small manifest bump"     risk_json '[{"filename":"go.mod","additions":1,"deletions":1,"patch":"+x"}]' 15
check "risk .npmrc"                  risk_score ".npmrc" 25
check "risk Makefile"                risk_score "Makefile" 25
check "risk build config with tests" risk_json '[{"filename":"vite.config.ts","additions":30,"deletions":0,"patch":"+x"},{"filename":"src/__tests__/a.test.ts","additions":1,"deletions":0}]' 15
check "risk buildSrc with tests"     risk_json '[{"filename":"buildSrc/src/main/kotlin/Conv.kt","additions":30,"deletions":0,"patch":"+x"},{"filename":"src/test/x/ATest.java","additions":1,"deletions":0}]' 15
check "risk .npmrc token"            risk_json '[{"filename":".npmrc","additions":1,"deletions":0,"patch":"+//registry.npmjs.org/:_authToken=npm_abcdefgh1234"}]' 30
check "risk rename out of auth"      risk_json '[{"filename":"src/main/java/a/Moved.java","previous_filename":"src/main/java/a/JwtAuthFilter.java","status":"renamed","additions":0,"deletions":0}]' 15
check "risk rename out of harness"   risk_json '[{"filename":"lib/risk.jq","previous_filename":"scripts/risk.jq","status":"renamed","additions":0,"deletions":0}]' 15
check "risk doc rename stays 0"      risk_json '[{"filename":"docs/a.md","previous_filename":"docs/b.md","status":"renamed","additions":0,"deletions":0}]' 0

# Translated READMEs record the README.md commit they follow. Warn only — a lagging translation does not change review behavior
for t in "$HARNESS_DIR"/README.*.md; do
  [ -f "$t" ] || continue
  base="$(grep -oE '@ `[0-9a-f]{7,40}`' "$t" | head -1 | tr -d '@` ')"
  n="$(git -C "$HARNESS_DIR" rev-list --count "$base..HEAD" -- README.md 2>/dev/null)" && [ -n "$base" ] || n="?"
  [ "$n" = 0 ] || echo "warning — $(basename "$t") is $n commit(s) behind README.md (base ${base:-missing})"
done

[ -d "$RUNS" ] || { echo "no runs/ — skipping PG5/PG6"; echo "selftest — passed $pass · failed $fail"; [ "$fail" = 0 ] || exit 3; exit 0; }

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
