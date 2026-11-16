#!/usr/bin/env bash
# risk-audit.sh — puts each merged PR's risk score next to any revert or fix PR that touched the same files within 14 days of the merge.
# It exists so the auto-merge threshold is tuned from records, not gut feeling (rules/03-risk.md "Threshold tuning"). Writes nothing to GitHub.
# Reverts and fixes are counted apart: a revert undoes the PR, while a fix shares as little as one file and is only a candidate until a person reads it
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINDOW_DAYS=14

[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: risk-audit.sh <repo> [number of recent merged PRs, default 30]" >&2; exit 1; }
REPO="$1"; LIMIT="${2:-30}"
SLUG="$(repo_slug "$REPO")" || exit 2

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

gh pr list --repo "$SLUG" --state merged --limit "$LIMIT" --json number,title,mergedAt > "$TMP/prs.json"

# Score each PR and attach its list of non-document files for the overlap comparison
for n in $(jq -r '.[].number' "$TMP/prs.json"); do
  gh api --paginate "repos/$SLUG/pulls/$n/files" | jq -s 'add // []' > "$TMP/files.json"
  auto="false"
  m="$PR_QUORUM_HOME/runs/$REPO-pr$n/meta.json"
  [ -f "$m" ] && [ "$(jq -r '.chain.state // empty' "$m")" = "merged" ] && auto="true"
  jq --arg sha - --arg at - -f "$HARNESS_DIR/scripts/risk.jq" "$TMP/files.json" \
    | jq --argjson n "$n" --argjson auto "$auto" --slurpfile f "$TMP/files.json" '
        {number: $n, score, level, auto: $auto,
         files: [$f[0][].filename | select(test("\\.(md|png|jpe?g|gif|svg|drawio)$|(^|/)(docs|contents)/"; "i") | not)]}'
done | jq -s '.' > "$TMP/scored.json"

jq -r --slurpfile s "$TMP/scored.json" --argjson w "$WINDOW_DAYS" '
  (now) as $now
  | ($s[0] | map({(.number | tostring): .}) | add) as $by
  | map(. + $by[.number | tostring] + {t: (.mergedAt | fromdateiso8601)}) as $prs
  | [ $prs[] | . as $a
      | [ $prs[] | select(.t > $a.t and .t <= $a.t + $w * 86400 and ([.files[] | IN($a.files[])] | any)) ] as $near
      | $a + {
          reverts: [ $near[] | select(.title | test("^\\s*revert"; "i")) | .number ],
          fixes: [ $near[] | select(.title | test("^\\s*fix"; "i")) | .number ],
          watching: ($now < $a.t + $w * 86400) } ] as $rows
  | def cell($l): if ($l | length) > 0 then $l | map("#\(.)") | join(", ") elif .watching then "watching" else "none" end;
    "| PR | Level | Score | Chain auto-merged | Revert PRs within 14 days | Fix candidates within 14 days |",
    "|---|---|---|---|---|---|",
    ($rows | sort_by(-.t)[]
      | "| #\(.number) | \(.level) | \(.score) | \(if .auto then "yes" else "-" end) | \(cell(.reverts)) | \(cell(.fixes)) |"),
    "",
    "| Level | Merged | With a revert | With fix candidates | Watching (excluded from the previous three columns) |",
    "|---|---|---|---|---|",
    ($rows | group_by(.level)[]
      | ([.[] | select((.watching | not) or (.reverts + .fixes | length) > 0)]) as $done   # A follow-up already attached means the outcome is known
      | "| \(.[0].level) | \($done | length) | \([$done[] | select((.reverts | length) > 0)] | length) | \([$done[] | select((.fixes | length) > 0)] | length) | \(length - ($done | length)) |"),
    "",
    "A fix candidate shares at least one non-document file with the PR and has a title starting with fix — it is not a defect count until a person reads it."
' "$TMP/prs.json"
