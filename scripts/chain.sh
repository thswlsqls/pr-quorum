#!/usr/bin/env bash
# chain.sh — PR 하나를 Stage 1 → 저자 반영 → Stage 2 → Stage 3 → (저자 반영 → Stage 2)* → 머지까지 사람 없이 돌린다.
# 머지는 머지 게이트와 리스크 게이트(03-risk.md, low 만 통과)를 둘 다 넘어야 한다. 아니면 needs-human 으로 멈춘다.
# 어디까지 했는지는 meta.json 과 outputs/author/round-NN.json 으로 판단하므로, 중간에 죽어도 다시 부르면 이어서 간다.
# 사람에게 물을 자리는 세션 쪽에서 권장안으로 정한다(--auto). 머지 여부만은 세션이 아니라 여기서 판정한다.
set -euo pipefail

OWNER="${PR_EVAL_OWNER:-thswlsqls}"
# 봇 로그인은 watch.sh 와 같은 방식으로 bot.env 에서 값만 꺼낸다. 머지 게이트가 봇 리뷰를 찾을 때 쓴다
BOT_ENV="${PR_EVAL_BOT_ENV:-$HOME/.config/pr-eval/bot.env}"
BOT="${PR_EVAL_BOT:-$(sed -n 's/^BOT_LOGIN=//p' "$BOT_ENV" 2>/dev/null | tr -d "\"'" | head -1 || true)}"
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
WS_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PR_EVAL="$HARNESS_DIR/scripts/pr-eval.sh"
MAX_AUTHOR_ROUNDS=2   # 저자 반영 회차 상한 — Stage 1 반영 한 번, Stage 3 반영 한 번
MAX_STEP_TRIES=2      # 한 단계가 기록을 못 남기고 끝나면 한 번 더 돌린다

log() { echo "[$(date -u +%H:%M:%S)] chain $REPO#$PR — $*"; }
die() { log "$1"; exit "${2:-1}"; }

[ $# -eq 2 ] || { echo "usage: chain.sh <repo> <pr>" >&2; exit 1; }
REPO="$1"; PR="$2"
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || { echo "PR 번호는 양의 정수여야 한다: $PR" >&2; exit 1; }
[ -n "$BOT" ] || { echo "봇 로그인을 못 찾았다: $BOT_ENV 의 BOT_LOGIN 또는 PR_EVAL_BOT 을 설정하라" >&2; exit 2; }
# 세션 권한과 명령 문서는 스크립트를 이 저장소의 절대 경로로만 부른다(상대 경로는 PR 워크트리 사본을 가리킨다).
# 다른 위치에 clone 했는데 경로를 안 바꾸면 세션 호출이 모두 권한에서 거부되므로 여기서 먼저 멈춘다
for f in "$HARNESS_DIR/settings.json" "$HARNESS_DIR/author-settings.json" "$HARNESS_DIR/scripts/install-entrypoints.sh"; do
  grep -qF "$REPO_ROOT/tools/pr-eval/scripts/" "$f" \
    || { echo "$f 의 스크립트 절대 경로가 이 저장소($REPO_ROOT)와 다르다 — tools/pr-eval/CLAUDE.md §5-3 대로 바꾼다" >&2; exit 2; }
done
RUN="$HARNESS_DIR/runs/$REPO-pr$PR"
M="$RUN/meta.json"
AUTHOR_DIR="$RUN/outputs/author"

meta_set() {  # meta_set <jq 프로그램> [jq 인자...] — pr-eval.sh 와 같은 임시파일 → mv 방식
  local prog="$1"; shift
  jq "$@" "$prog" "$M" > "$M.tmp.$$" && mv "$M.tmp.$$" "$M"
}
chain_state() { meta_set '.chain = ((.chain // {}) + {state:$s, reason:$r, at:$at})' \
                  --arg s "$1" --arg r "${2:-}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; log "state=$1 ${2:-}"; }

head_sha() { "$PR_EVAL" sha "$REPO" "$PR"; }
stage1_done() { [ "$(jq '[.stage1[]?.review_id | select(. != null)] | length' "$M")" -gt 0 ]; }
stage2_count() { jq '[.stage2[]? | select(.verdicts != null)] | length' "$M"; }
stage3_done() { [ "$(jq '.stage3 != null' "$M")" = "true" ]; }
# ls 는 파일이 없으면 실패해 pipefail·set -e 로 스크립트가 끝난다. find 는 빈 결과로 성공한다
author_count() { find "$AUTHOR_DIR" -name 'round-*.json' | wc -l | tr -d ' '; }
last_author() { find "$AUTHOR_DIR" -name 'round-*.json' | sort | tail -1; }

# 헤드리스 세션 하나를 띄운다. 도구 권한·MCP 를 이 머신 설정과 떼어 놓는 이유는 watch.sh 주석과 같다.
run_session() {  # run_session <settings.json> <프롬프트> <단계 이름> <시도 번호>
  local settings="$1" prompt="$2" name="$3" try="$4" add_dirs=() d out rc=0 started
  for d in "$WS_ROOT/tech-n-ai-backend-worktrees" "$WS_ROOT/tech-n-ai-frontend" \
           "$WS_ROOT/tech-n-ai-frontend-worktrees"; do
    [ -d "$d" ] && add_dirs+=("$d")
  done
  # --setting-sources project: .claude/settings.local.json 의 allow·훅과 ~/.claude/settings.json 을 읽지 않는다.
  # user 만 남기면 .claude/commands·agents 도 안 읽혀 /pr-eval 이 없어진다(실측). --settings 는 이 값과 상관없이 읽힌다
  # dontAsk: allow 에 없는 것은 묻지 않고 거부한다. acceptEdits 는 작업 폴더 안 편집과 mkdir·rm·mv 등을 allow 와 상관없이 승인했다(실측)
  started="$(date +%s)"
  out="$( cd "$REPO_ROOT" && claude -p --output-format json --permission-mode dontAsk \
      --setting-sources project --settings "$settings" \
      --mcp-config tools/pr-eval/mcp.json --strict-mcp-config \
      --disallowedTools AskUserQuestion \
      --append-system-prompt "체인 모드다. 사람은 응답하지 않는다. 사람에게 묻거나 확인을 기다리지 말고, 규칙 문서가 권하는 쪽(권장안)으로 정해 진행한다. 정한 것은 tools/pr-eval/runs/$REPO-pr$PR/decisions.md 에 '시각 · 단계 · 상황 · 고른 쪽 · 이유' 한 줄로 Edit·Write 도구로 덧붙인다(mv·cp 는 권한에서 거부되므로 '> tmp && mv' 방식은 쓰지 않는다)." \
      ${add_dirs[0]+--add-dir "${add_dirs[@]}"} \
      -- "$prompt" < /dev/null )" || { rc=$?; log "세션이 $rc 로 끝났다 — 기록으로 성공 여부를 판단한다"; }
  # 결과 텍스트는 예전처럼 로그로 흘린다. JSON 이 아니면 받은 그대로 찍는다
  jq -r '.result // empty' <<<"$out" 2>/dev/null || printf '%s\n' "$out"
  # 단계별 시간·비용과 도구 거부를 남긴다 — 작은 PR 에서 단계를 줄여도 되는지, 어떤 거부가 반복되는지 판단할 근거.
  # 거부 필드가 없으면 null 로 둔다(0 건과 구분한다). 거부된 도구의 인자는 남기지 않는다
  local at wall_ms; at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # duration_ms 는 마지막 하위 에이전트 완료 알림 뒤 구간만 잰다(PR #52 실측 — Stage 1 실제 23분이 133초로 남았다).
  # 세션 전체 시간은 여기서 직접 잰다
  wall_ms=$(( ($(date +%s) - started) * 1000 ))
  if jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    meta_set '.chain.sessions = ((.chain.sessions // []) + [{step:$s, try:$t, at:$at, exit_code:$rc, wall_ms:$w,
      session_id:$r.session_id, duration_ms:$r.duration_ms, cost_usd:$r.total_cost_usd, num_turns:$r.num_turns, is_error:$r.is_error,
      permission_denials:($r.permission_denials | if type == "array" then length else null end),
      denied_tools:($r.permission_denials | if type == "array" then [.[].tool_name] | unique else null end)}])' \
      --arg s "$name" --argjson t "$try" --arg at "$at" --argjson rc "$rc" --argjson w "$wall_ms" --argjson r "$out" \
      || log "meta.json 에 세션 기록을 남기지 못했다"
  else
    # 실패한 시도도 기록에서 빠지지 않게 한 줄은 남긴다
    meta_set '.chain.sessions = ((.chain.sessions // []) + [{step:$s, try:$t, at:$at, exit_code:$rc, wall_ms:$w, json:false}])' \
      --arg s "$name" --argjson t "$try" --arg at "$at" --argjson rc "$rc" --argjson w "$wall_ms" \
      || log "meta.json 에 세션 기록을 남기지 못했다"
    log "세션 결과를 JSON 으로 못 읽어 시간·비용 없이 시도만 남겼다"
  fi
}

# 단계 하나를 돌리고, 기대한 기록이 남았는지로 성공을 판정한다. 두 번 다 실패하면 체인을 멈춘다.
step() {  # step <이름> <완료 판정 함수> <settings> <프롬프트>
  local name="$1" check="$2" settings="$3" prompt="$4" t
  for (( t=1; t<=MAX_STEP_TRIES; t++ )); do
    chain_state "$name" "시도 $t"
    run_session "$settings" "$prompt" "$name" "$t"
    "$check" && return 0
    log "$name 이 기록을 남기지 못했다 (시도 $t)"
  done
  chain_state "blocked" "$name 이 $MAX_STEP_TRIES 회 연속 기록을 남기지 못했다"
  exit 4
}

EVAL_SETTINGS="tools/pr-eval/settings.json"
AUTHOR_SETTINGS="tools/pr-eval/author-settings.json"

run_stage1() { step stage1 stage1_done "$EVAL_SETTINGS" "/pr-eval stage1 $REPO $PR --auto"; }
run_stage3() { step stage3 stage3_done "$EVAL_SETTINGS" "/pr-eval stage3 $REPO $PR --auto"; }

run_stage2() {
  local before; before="$(stage2_count)"
  stage2_grew() { [ "$(stage2_count)" -gt "$before" ]; }
  step stage2 stage2_grew "$EVAL_SETTINGS" "/pr-eval stage2 $REPO $PR --auto"
}

run_author() {  # 기록 파일이 하나 늘었으면 성공
  local before; before="$(author_count)"
  author_grew() { [ "$(author_count)" -gt "$before" ]; }
  step author author_grew "$AUTHOR_SETTINGS" "/pr-eval-author $REPO $PR"
}

author_pushed() { [ "$(jq -r '.pushed' "$(last_author)")" = "true" ]; }

# mergeable 은 GitHub 가 계산을 마칠 때까지 UNKNOWN 이다. 오래된 PR 일수록 첫 조회에서 자주 나온다
pr_state() {
  local i out
  for i in 1 2 3 4 5 6; do
    out="$(gh pr view "$PR" --repo "$OWNER/$REPO" --json state,isDraft,mergeable)" || return 1
    [ "$(jq -r '.mergeable' <<<"$out")" != "UNKNOWN" ] && break
    sleep 10
  done
  printf '%s\n' "$out"
}

# ---------- 머지 게이트 — 세션의 자기보고가 아니라 기록과 GitHub 상태로 본다 ----------
merge_gate() {
  local a head pr_json reasons=()
  a="$(last_author)"
  head="$(head_sha)"
  GATE_SHA="$head"   # 리스크 게이트와 머지가 이 커밋에 묶인다
  pr_json="$(pr_state)"

  [ "$(jq -r '.state' <<<"$pr_json")" = "OPEN" ] || reasons+=("PR 이 열려 있지 않다")
  [ "$(jq -r '.isDraft' <<<"$pr_json")" = "false" ] || reasons+=("draft 다")
  [ "$(jq -r '.mergeable' <<<"$pr_json")" = "MERGEABLE" ] || reasons+=("mergeable=$(jq -r '.mergeable' <<<"$pr_json")")
  [ "$(jq -r '.tests.result' "$a")" != "fail" ] || reasons+=("마지막 저자 회차 테스트가 실패했다")
  [ "$(jq -r '.blocking_open' "$a")" = "0" ] || reasons+=("반영하지 않은 blocking 지적이 $(jq -r '.blocking_open' "$a") 건 남았다")
  [ "$(jq '[.stage2[-1].verdicts // {} | .[] | select(. == "역행")] | length' "$M")" = "0" ] \
    || reasons+=("마지막 Stage 2 판정에 역행이 있다")
  # 지금 head 가 누군가 판정한 커밋이어야 한다 — 마지막 Stage 2 가 본 커밋이거나, 저자가 더 고칠 게 없다고 한 커밋
  if [ "$head" != "$(jq -r '.stage2[-1].stage_sha // empty' "$M")" ] \
     && ! { [ "$(jq -r '.pushed' "$a")" = "false" ] && [ "$head" = "$(jq -r '.to_sha' "$a")" ]; }; then
    reasons+=("head $head 를 아무 단계도 판정하지 않았다")
  fi
  # 위 기록은 세션이 쓴 파일이라 고쳐 쓸 수 있다. 봇이 이 head 에 리뷰나 reply 를 실제로 남겼는지 GitHub 에서 본다
  local bot_reviews
  bot_reviews="$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/reviews" \
    | jq -s --arg b "$BOT" --arg s "$head" '[add // [] | .[] | select(.user.login == $b and .commit_id == $s)] | length')" || bot_reviews=""
  [ "${bot_reviews:-0}" -gt 0 ] || reasons+=("봇($BOT)이 head $head 에 남긴 리뷰를 GitHub 에서 찾지 못했다")

  if [ ${#reasons[@]} -gt 0 ]; then
    chain_state "blocked" "머지 게이트: $(IFS='; '; echo "${reasons[*]}")"
    exit 3
  fi

  # Stage 3 이 리뷰가 놓친 치명·중대(P)를 찾았으면 Stage 1 재실행 여부는 사람이 정한다 (01-stages.md §5).
  # 세션이 적는 verdict 문구가 아니라 pr-eval.sh 가 기록한 P 코멘트 등급으로 본다. 등급이 빠진 P 도 멈춘다
  local missed
  missed="$(jq -r '[.stage3.comments[]? | select(.grade != "경미" and .grade != "사소") | "\(.code)(\(.grade))"] | join(", ")' "$M")"
  if [ -n "$missed" ]; then
    chain_state "needs-human" "Stage 3 이 리뷰가 놓친 결함을 찾았다: $missed — Stage 1 재실행 여부를 사람이 정한다"
    exit 3
  fi
}

# 리스크 게이트 (03-risk.md) — 다른 게이트를 다 통과한 PR 만 점수를 매긴다. 점수표는 레벨과 상관없이 PR 에 남긴다.
risk_gate() {
  local rc=0
  "$PR_EVAL" risk "$REPO" "$PR" >/dev/null || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || { chain_state "blocked" "리스크 판정 실패(종료 $rc)"; exit 4; }
  # 머지 게이트를 본 뒤 push 가 들어왔으면 점수는 게이트가 보지 않은 커밋의 것이다
  [ "$(jq -r '.risk.sha' "$M")" = "$GATE_SHA" ] \
    || { chain_state "blocked" "머지 게이트(${GATE_SHA:0:7}) 뒤에 head 가 바뀌었다 — 체인을 다시 부른다"; exit 3; }
  if [ "$(jq -r '.risk.commented_sha // empty' "$M")" != "$(jq -r '.risk.sha' "$M")" ]; then
    "$PR_EVAL" comment "$REPO" "$PR" "$RUN/outputs/risk.md" >/dev/null \
      && meta_set '.risk.commented_sha = .risk.sha' \
      || log "리스크 코멘트 게시 실패 — 판정은 meta.json 에 남았다"
  fi
  if [ "$rc" = 3 ]; then
    chain_state "needs-human" "리스크 $(jq -r '.risk.level' "$M") $(jq -r '.risk.score' "$M")점 — 사람이 승인해야 머지한다"
    exit 3
  fi
}

do_merge() {
  # --match-head-commit: 게이트가 본 커밋을 넘긴다. head 를 새로 읽으면 그 사이 push 된 커밋이 그대로 머지된다
  gh pr merge "$PR" --repo "$OWNER/$REPO" --merge --match-head-commit "$GATE_SHA" \
    || { chain_state "blocked" "gh pr merge 실패"; exit 4; }
  meta_set '.chain.merged_sha = $s' --arg s "$GATE_SHA"
  chain_state "merged" "head=$GATE_SHA"
}

# ---------- 본체 ----------
# watch.sh 와 같은 확인을 여기서도 한다 — 사람이 chain.sh 를 직접 불러도 남이 연 PR 은 세션에 들어가지 않는다
assoc="$(gh api "repos/$OWNER/$REPO/pulls/$PR" --jq '.author_association')" || die "PR 작성자를 확인하지 못했다" 4
[ "$assoc" = "OWNER" ] || die "작성자가 저장소 소유자가 아니다($assoc) — 체인을 돌리지 않는다" 3

[ -f "$M" ] || "$PR_EVAL" init "$REPO" "$PR" >/dev/null
mkdir -p "$AUTHOR_DIR"

case "$(jq -r '.chain.state // empty' "$M")" in
  merged) log "이미 머지됐다"; exit 0 ;;
esac
case "$(jq -r '.status' "$M")" in
  보류*) chain_state "blocked" "status=$(jq -r '.status' "$M") — 스테이지가 보류로 끝났다"; exit 3 ;;
esac

# 이중 실행 막기 — watcher 의 이어 돌리기와 수동 호출이 겹치지 않게
other="$(jq -r '.chain.pid // empty' "$M")"
if [ -n "$other" ] && [ "$other" != "$$" ] && kill -0 "$other" 2>/dev/null; then
  die "다른 chain(pid=$other)이 돌고 있다" 5
fi
meta_set '.chain = ((.chain // {}) + {pid:$p})' --argjson p "$$"
trap 'meta_set ".chain.pid = null" 2>/dev/null || true' EXIT

# 대형 PR 컷은 세션에 맡기지 않고 여기서 본다. 알림 코멘트는 한 번만 단다 — 다시 불러도 위의 보류 확인에서 먼저 멈춘다
pre_rc=0
pre_out="$("$PR_EVAL" precheck "$REPO" "$PR")" || pre_rc=$?
case "$pre_rc" in
  0) ;;
  3) "$PR_EVAL" status "$REPO" "$PR" "보류(대형PR)" >/dev/null
     mkdir -p "$RUN/outputs"
     printf '변경이 커서 자동 리뷰를 하지 않습니다(%s, 기준: 파일 50개 또는 3,000줄 초과). PR 을 나누거나 사람이 리뷰해 주세요.\n' \
       "$(head -1 <<<"$pre_out" | sed 's/ (cut.*//')" > "$RUN/outputs/large-pr.md"
     "$PR_EVAL" comment "$REPO" "$PR" "$RUN/outputs/large-pr.md" >/dev/null || log "대형 PR 알림 코멘트 게시 실패"
     chain_state "blocked" "대형 PR 컷에 걸렸다"; exit 3 ;;
  *) chain_state "blocked" "대형 PR 판정 실패(종료 $pre_rc)"; exit 4 ;;
esac

stage1_done || run_stage1
[ "$(jq -r '.status' "$M")" = "보류(대형PR)" ] && { chain_state "blocked" "대형 PR 로 Stage 1 이 보류됐다"; exit 3; }

# 저자 반영 전에 main 과 충돌하는지 본다. 충돌을 풀면 head 가 바뀌어 그 뒤 단계를 다시 돌아야 한다.
# Stage 1 앞에서 멈추면 watch.sh 가 리뷰가 없는 PR 로 보고 매분 다시 띄워 보류(실패) 로 만든다
[ "$(pr_state | jq -r '.mergeable')" != "CONFLICTING" ] \
  || { chain_state "blocked" "main 과 충돌한다 — 사람이 충돌을 푼 뒤 체인을 다시 부른다"; exit 3; }

[ "$(author_count)" -ge 1 ] || run_author
[ "$(stage2_count)" -ge 1 ] || run_stage2
stage3_done || run_stage3

# Stage 3 뒤: 저자가 더 고칠 게 없다고 할 때까지 (저자 → Stage 2) 를 돈다
while :; do
  # 마지막 저자 회차 뒤에 Stage 2 가 아직 안 돌았으면 먼저 돌린다(중간에 죽은 경우)
  if author_pushed && [ "$(head_sha)" != "$(jq -r '.stage2[-1].stage_sha // empty' "$M")" ]; then
    run_stage2
  fi
  # 첫 회차는 Stage 1 반영이다. Stage 3 이후 회차가 아직 없으면 한 번은 돈다
  if [ "$(author_count)" -ge "$MAX_AUTHOR_ROUNDS" ]; then
    log "저자 회차 상한($MAX_AUTHOR_ROUNDS)에 닿았다"; break
  fi
  if [ "$(author_count)" -ge 2 ] && ! author_pushed; then break; fi
  run_author
  author_pushed || break
  run_stage2
done

chain_state "merge-gate"
merge_gate
risk_gate
do_merge
