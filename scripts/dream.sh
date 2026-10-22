#!/usr/bin/env bash
# dream.sh — 여러 PR run 의 학습 후보와 기록을 모아 learnings 정리안을 낸다. 지시문은 04-dream.md.
# 세션에는 Read·Grep·Glob 만 준다. 정리안은 세션의 마지막 응답을 이 스크립트가 파일로 쓴다 —
# PR 을 읽은 세션이 쓴 글을 입력으로 받는 세션이라, 어떤 파일도 직접 고치지 못하게 한다.
# 반영은 사람이 정리안 항목마다 판정을 적고 하니스 PR 로 한다.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
RUNS="$HARNESS_DIR/runs"

usage() { echo "usage: dream.sh [<run 이름>...]   예: dream.sh tech-n-ai-backend-pr33 tech-n-ai-backend-pr34 (생략하면 runs/ 아래 PR run 전부)" >&2; exit 1; }
case "${1:-}" in -h|--help) usage ;; esac

if [ $# -eq 0 ]; then
  for d in "$RUNS"/*-pr*/; do [ -d "$d" ] && set -- "$@" "$(basename "$d")"; done
  [ $# -gt 0 ] || { echo "runs/ 아래에 PR run 이 없다" >&2; exit 1; }
fi
for r in "$@"; do
  [[ "$r" =~ ^[a-z0-9-]+-pr[1-9][0-9]*$ ]] && [ -d "$RUNS/$r" ] || { echo "run 이 아니다: $r" >&2; usage; }
done

# 지난 정리안 — 완료된 것만 입력으로 준다. 사람이 적은 판정을 보고 거절된 항목을 다시 내지 않게 한다
past=()
for p in "$RUNS"/_dream/*/proposal.md; do
  [ -f "$p" ] && grep -q '^- 상태: 완료$' "$p" && past+=("${p#"$REPO_ROOT"/}")
done

out_dir="$RUNS/_dream/$(date +%Y%m%d%H%M%S)"
[ ! -e "$out_dir" ] || { echo "이미 있다: $out_dir" >&2; exit 1; }
mkdir -p "$out_dir"
out="$out_dir/proposal.md"

runs_list="$*"
started="$(date '+%Y-%m-%d %H:%M:%S %z')"
header() {  # header <상태>
  printf '# learnings 정리안\n\n- 상태: %s\n- 시각: %s\n- 하니스 commit: %s\n- 검토한 run: %s\n- 지난 정리안: %s\n' \
    "$1" "$started" "$(git -C "$REPO_ROOT" rev-parse --short HEAD)" "$runs_list" "${past[*]:-없음}"
}
header "작성 중" > "$out"

prompt="tools/pr-eval/04-dream.md 를 읽고 그대로 따른다.
이번에 볼 run: $(printf 'tools/pr-eval/runs/%s ' "$@")
지난 정리안: ${past[*]:-없음}"

rc=0
res="$( cd "$REPO_ROOT" && claude -p --output-format json --permission-mode dontAsk \
    --setting-sources project --settings tools/pr-eval/dream-settings.json \
    --tools Read,Grep,Glob --strict-mcp-config \
    -- "$prompt" < /dev/null )" || rc=$?

body="$(jq -r 'select(.is_error == false) | .result // empty' <<<"$res" 2>/dev/null || true)"
if [ "$rc" != 0 ] || [ -z "$body" ]; then
  echo "dream 세션이 정리안을 내지 못했다(종료 $rc). $out 은 '작성 중' 으로 남긴다 — 완료 이력으로 쓰이지 않는다" >&2
  exit 4
fi
{ header "완료"
  jq -r '"- 세션: \(.session_id) · \(.num_turns) 턴 · \((.duration_ms // 0) / 1000 | floor) 초 · $\(.total_cost_usd) · 도구 거부 \(.permission_denials | if type == "array" then "\(length) 건" else "미기록" end)\n"' <<<"$res"
  printf '%s\n' "$body"
} > "$out.tmp" && mv "$out.tmp" "$out"
echo "$out"
