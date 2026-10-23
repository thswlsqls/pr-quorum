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
# Build and dependency files of other stacks (rules/03-risk.md) — build script 15 + dependencies 10 + scope 10, or dependencies 10 + scope 10
check "risk Maven pom.xml"           risk_score "pom.xml" 35
check "risk Python pyproject.toml"   risk_score "pyproject.toml" 35
check "risk Python requirements"     risk_score "requirements-dev.txt" 20
check "risk Go go.mod"               risk_score "go.mod" 20
check "risk Rust Cargo.lock"         risk_score "Cargo.lock" 20
# Test files of other stacks count as tests — no production signal and no scope points
check "risk Go test file"            risk_score "pkg/auth/token_test.go" 0
check "risk Python test file"        risk_score "tests/test_api.py" 0
check "risk Go code without tests"   risk_score "pkg/store/store.go" 25

# Translated READMEs record the README.md commit they follow. Warn only — a lagging translation does not change review behavior
for t in "$HARNESS_DIR"/README.*.md; do
  [ -f "$t" ] || continue
  base="$(grep -oE '@ `[0-9a-f]{7,40}`' "$t" | head -1 | tr -d '@` ')"
  n="$(git -C "$HARNESS_DIR" rev-list --count "$base..HEAD" -- README.md 2>/dev/null)" && [ -n "$base" ] || n="?"
  [ "$n" = 0 ] || echo "warning — $(basename "$t") is $n commit(s) behind README.md (base ${base:-missing})"
done

# Build sandbox (scripts/build-sandbox.sh) — under a fake HOME, the build shell must not read a fake ~/.config/pr-quorum file or ~/.npmrc, write into
# ~/.pr-quorum, the git dir or the user's ~/.gradle, or see a token from the environment, while the worktree and its own cache root
# stay writable, and on macOS must not run osascript. No network, no gh.
# Skipped on a host without a sandbox (doctor.sh reports that as FAIL)
source "$HARNESS_DIR/scripts/build-sandbox.sh"
SB_KIND="$(sandbox_kind)"
sandbox_probe() {
  local h rc=0
  h="$(cd "$(mktemp -d)" && pwd -P)" || return 1
  mkdir -p "$h/.config/pr-quorum" "$h/.pr-quorum" "$h/.gradle/wrapper" && echo canary > "$h/.config/pr-quorum/x" && echo canary > "$h/.npmrc" && git init -q "$h/wt" || return 1
  HOME="$h" GH_TOKEN=selftest-not-a-token sandbox_run "$SB_KIND" "$h/wt" "$h/wt" '
    cat "$HOME/.config/pr-quorum/x" && exit 11
    : > "$HOME/.pr-quorum/x" && exit 12
    : > .git/hooks/x && exit 13
    [ -z "${GH_TOKEN:-}" ] || exit 14
    : > "$HOME/.gradle/wrapper/x" && exit 15
    : > "$GRADLE_USER_HOME/x" || exit 16
    cat "$HOME/.npmrc" && exit 17
    [ "$(uname -s)" = Darwin ] && /usr/bin/osascript -e 1 && exit 18
    : > ok' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && [ -f "$h/wt/ok" ] || rc="${rc/#0/no-write}"
  rm -rf "$h"
  [ "$rc" = 0 ] || { echo "build shell got through (11 read secret · 12 wrote ~/.pr-quorum · 13 wrote .git · 14 saw GH_TOKEN · 15 wrote ~/.gradle · 16 cache root not writable · 17 read ~/.npmrc · 18 ran osascript): $rc"; return 1; }
}
# The shared cache root's Gradle init files — a file planted there by one build is cleared before the next run, and a link is refused
sandbox_gradle_reset() {
  local h c rc=0
  h="$(cd "$(mktemp -d)" && pwd -P)" || return 1; c="$h/.cache/pr-quorum-build/gradle"
  mkdir -p "$c/init.d" "$h/wt" "$h/.config/pr-quorum" && echo planted > "$c/init.d/x.gradle" && echo planted > "$c/init.gradle" && git init -q "$h/wt" || return 1
  HOME="$h" sandbox_run "$SB_KIND" "$h/wt" "$h/wt" '[ -z "$(ls "$GRADLE_USER_HOME/init.d")" ] && [ ! -s "$GRADLE_USER_HOME/init.gradle" ]' \
    >/dev/null 2>&1 || rc=1
  [ "$rc" = 0 ] && [ ! -e "$c/init.d/x.gradle" ] && [ ! -e "$c/init.gradle" ] || { echo "planted init files survived"; rc=1; }
  ln -sf "$h/elsewhere" "$c/gradle.properties"
  HOME="$h" sandbox_run "$SB_KIND" "$h/wt" "$h/wt" true >/dev/null 2>&1 && { echo "linked gradle.properties was not refused"; rc=1; }
  rm -rf "$h"
  return "$rc"
}
if [ -n "$SB_KIND" ]; then check "build sandbox ($SB_KIND) resets the shared Gradle init files" sandbox_gradle_reset; fi
# A secret entry that is a link (a dotfile manager's ~/.npmrc -> ~/dotfiles/npmrc) — its target outside HOME must stay unreadable too
sandbox_linked_secret() {
  local h rc=0
  h="$(cd "$(mktemp -d)" && pwd -P)" || return 1
  mkdir -p "$h/home/.config/pr-quorum" "$h/dotfiles" "$h/home/wt" && echo canary > "$h/dotfiles/npmrc" && ln -s "$h/dotfiles/npmrc" "$h/home/.npmrc" \
    && git init -q "$h/home/wt" || return 1
  HOME="$h/home" sandbox_run "$SB_KIND" "$h/home/wt" "$h/home/wt" "cat '$h/dotfiles/npmrc' || cat \"\$HOME/.npmrc\"" >/dev/null 2>&1 \
    && { echo "the target of a linked ~/.npmrc was readable"; rc=1; }
  rm -rf "$h"
  return "$rc"
}
if [ -n "$SB_KIND" ]; then check "build sandbox ($SB_KIND) refuses the target of a linked secret" sandbox_linked_secret; fi
if [ -n "$SB_KIND" ]; then check "build sandbox ($SB_KIND) blocks secrets, harness state, .git, user caches and env tokens" sandbox_probe
else echo "warning — no build sandbox on this host (sandbox-exec / bwrap) — skipping its check"; fi

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
