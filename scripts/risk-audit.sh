#!/usr/bin/env bash
# risk-audit.sh — 머지된 PR 의 리스크 점수와, 머지 뒤 14일 안에 같은 파일을 고친 fix·revert PR 을 나란히 놓는다.
# 자동 머지 문턱을 감이 아니라 기록으로 조정하려고 둔다(03-risk.md "문턱 조정"). GitHub 에 아무것도 쓰지 않는다.
set -euo pipefail

OWNER="${PR_EVAL_OWNER:-thswlsqls}"
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINDOW_DAYS=14

[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: risk-audit.sh <repo> [최근 머지 PR 수, 기본 30]" >&2; exit 1; }
REPO="$1"; LIMIT="${2:-30}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

gh pr list --repo "$OWNER/$REPO" --state merged --limit "$LIMIT" --json number,title,mergedAt > "$TMP/prs.json"

# PR 마다 점수를 매기고, 겹침 비교에 쓸 문서 아닌 파일 목록을 붙인다
for n in $(jq -r '.[].number' "$TMP/prs.json"); do
  gh api --paginate "repos/$OWNER/$REPO/pulls/$n/files" | jq -s 'add // []' > "$TMP/files.json"
  auto="false"
  m="$HARNESS_DIR/runs/$REPO-pr$n/meta.json"
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
      | $a + {
          followups: [ $prs[] | select(.t > $a.t and .t <= $a.t + $w * 86400
                                       and (.title | test("^\\s*(fix|revert)"; "i"))
                                       and ([.files[] | IN($a.files[])] | any)) | .number ],
          watching: ($now < $a.t + $w * 86400) } ] as $rows
  | "| PR | 등급 | 점수 | 체인 자동 머지 | 14일 안 fix·revert PR |",
    "|---|---|---|---|---|",
    ($rows | sort_by(-.t)[]
      | "| #\(.number) | \(.level) | \(.score) | \(if .auto then "예" else "-" end) | \(if (.followups | length) > 0 then (.followups | map("#\(.)") | join(", ")) elif .watching then "관찰 중" else "없음" end) |"),
    "",
    "| 등급 | 머지 수 | 후속 수정이 붙은 수 | 관찰 중 (앞 두 칸에서 뺐다) |",
    "|---|---|---|---|",
    ($rows | group_by(.level)[]
      | ([.[] | select((.watching | not) or (.followups | length) > 0)]) as $done   # 후속이 이미 붙었으면 결과가 난 것이다
      | "| \(.[0].level) | \($done | length) | \([$done[] | select((.followups | length) > 0)] | length) | \(length - ($done | length)) |")
' "$TMP/prs.json"
