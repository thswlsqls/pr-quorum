#!/usr/bin/env bash
# selftest.sh — pr-eval.sh 의 기계 게이트(PG5·PG6)를 지난 실제 산출물에 다시 돌린다. LLM 을 쓰지 않는다.
# 게이트 스크립트를 고친 뒤 한 번 돌린다. 이미 게시된 산출물이 새 규칙에 막히면 규칙이 틀렸을 가능성이 크다
# (PR #38 은 축 정규식 R-[A-H] 하나 때문에 게시가 막혔다 — L0-31).
# runs/ 는 gitignore 라 이 머신에만 있다. 없으면 건너뛴다.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR_EVAL="$HARNESS_DIR/scripts/pr-eval.sh"
RUNS="$HARNESS_DIR/runs"

[ -d "$RUNS" ] || { echo "runs/ 가 없다 — 건너뛴다"; exit 0; }

pass=0; fail=0
check() {  # check <이름> <명령...>
  local name="$1" out; shift
  if out="$("$@" 2>&1)"; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "실패 — $name"; sed 's/^/    /' <<<"$out"
  fi
}

# PG5 — 요약과 코멘트가 함께 있는 폴더. 스테이지는 경로로 정한다(초기 run 은 outputs/ 바로 아래가 Stage 1 이다).
while IFS= read -r d; do
  case "$d" in */stage2*) st=stage2 ;; */stage3*) st=stage3 ;; *) st=stage1 ;; esac
  [ -f "$d/comments.json" ] && check "pg5 ${d#"$RUNS"/} ($st)" "$PR_EVAL" pg5 "$d/summary.md" "$d/comments.json" "$st"
done < <(find "$RUNS"/*/outputs -name summary.md -not -path '*/pre-polish/*' -exec dirname {} \; | sort)

# PG6 — 윤문 전 사본이 있는 폴더
while IFS= read -r p; do
  d="$(dirname "$p")"
  # outputs/ 바로 아래 사본은 스테이지별 폴더(L0-15) 이전 구조다. 원본이 stage1/ 로 옮겨져 대조할 짝이 없다
  [ "$(basename "$d")" = outputs ] && { echo "건너뜀 — ${d#"$RUNS"/}/pre-polish (스테이지별 폴더 이전 구조)"; continue; }
  check "pg6 ${d#"$RUNS"/}" "$PR_EVAL" pg6 "$d"
done < <(find "$RUNS"/*/outputs -type d -name pre-polish | sort)

echo "selftest — 통과 $pass · 실패 $fail"
[ "$fail" = 0 ] || exit 3
