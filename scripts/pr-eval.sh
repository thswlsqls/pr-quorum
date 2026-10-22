#!/usr/bin/env bash
# pr-eval.sh — PR eval harness 의 유일한 GitHub 게시 경로.
# 세션은 봇 토큰을 갖지 않는다. 이 스크립트가 자기 안에서 읽는다.
# 계약(서브커맨드·종료 코드)은 tools/pr-eval/CLAUDE.md §3 에 있다.
set -euo pipefail

OWNER="${PR_EVAL_OWNER:-thswlsqls}"
BOT_ENV="${PR_EVAL_BOT_ENV:-$HOME/.config/pr-eval/bot.env}"
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS_DIR="$HARNESS_DIR/runs"
LOCK_TTL_SEC=10800   # 3시간
BIG_PR_FILES=50
BIG_PR_LINES=3000

# 종료 코드: 0 성공 · 1 사용법/인자 · 2 환경(토큰·meta 없음) · 3 게이트 위반 · 4 API 실패 · 5 락 점유
E_USAGE=1; E_ENV=2; E_GATE=3; E_API=4; E_LOCK=5

die() { echo "pr-eval: $2" >&2; exit "$1"; }

TMP=""
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT
mktmp() { cleanup; TMP="$(mktemp -d)"; }

usage() {
  cat >&2 <<'USAGE'
usage: pr-eval.sh <subcommand> <repo> <pr> [args]

  조회 (봇 토큰 불필요)
    sha        <repo> <pr>                   현재 head SHA 를 출력한다
    meta       <repo> <pr>                   meta.json 을 출력한다
    precheck   <repo> <pr>                   대형 PR 컷(파일 50 / 줄 3000) 을 판정한다
    ranges     <repo> <pr> <sha>            inline 앵커를 달 수 있는 줄 범위를 낸다 (위원 프롬프트용)
    gate1      <repo> <pr> <sha> <comments.json>   PG1 — 앵커가 diff 안인지 검사한다
    risk       <repo> <pr>                   자동 머지 리스크 점수 (03-risk.md). low 가 아니면 3
    pg5        <summary.md> <comments.json> [stage1|stage2|stage3]   PG5 기계 검사 (post-review 가 게시 직전에 도는 것과 같다)
    pg6        <outputs/stage 디렉터리>      PG6 — 윤문 전 사본(pre-polish/)과 대조한다
    snapshot   <outputs/stage 디렉터리>      윤문 전 사본을 pre-polish/ 에 뜬다 (runs/ 아래만)

  상태
    init       <repo> <pr> [--reset-eval]    runs/<repo>-pr<N>/ 와 meta.json 을 만든다
                                             (--reset-eval: Stage 1 재실행 시에만 eval_sha 를 head 로 올린다)
    lock       <repo> <pr> <stage>           락을 획득한다 (점유 중이면 5)
    unlock     <repo> <pr>
    status     <repo> <pr> <값>
    attempt    <repo> <pr> inc|reset

  게시 (봇 토큰 필요)
    post-review <repo> <pr> <sha> <summary.md> <comments.json> [stage1|stage2|stage3]
    reply       <repo> <pr> <comment_id> <body.md>
    patch       <repo> <pr> <comment_id> <body.md>
    patch-review <repo> <pr> <review_id> <body.md>   게시한 리뷰 요약 본문을 고친다
    comment     <repo> <pr> <body.md>        PR 본문에 일반 코멘트 1건
USAGE
  exit "$E_USAGE"
}

profile_of() {
  case "$1" in
    tech-n-ai-backend)  echo backend ;;
    tech-n-ai-frontend) echo frontend ;;
    *) die "$E_USAGE" "프로파일을 모르는 저장소다: $1 (profiles/ 에 정의가 없다)" ;;
  esac
}

run_dir() { echo "$RUNS_DIR/$1-pr$2"; }
meta_path() { echo "$(run_dir "$1" "$2")/meta.json"; }

need_meta() {
  [ -f "$(meta_path "$1" "$2")" ] || die "$E_ENV" "meta.json 이 없다. 먼저 init 을 돌려라: $(meta_path "$1" "$2")"
}

# meta.json 을 jq 프로그램으로 갱신한다 (임시파일 → mv, 부분 기록 방지)
meta_update() {
  local repo="$1" pr="$2" prog="$3"; shift 3
  local m; m="$(meta_path "$repo" "$pr")"
  local tmp="$m.tmp.$$"
  jq "$@" "$prog" "$m" > "$tmp" && mv "$tmp" "$m"
}

load_bot_token() {
  [ -f "$BOT_ENV" ] || die "$E_ENV" "봇 토큰 파일이 없다: $BOT_ENV (CLAUDE.md §5-2 참고)"
  # source 하지 않고 watch.sh 처럼 값만 꺼낸다 — 파일에 셸 코드가 들어가도 실행되지 않는다.
  # 환경 변수도 보지 않는다. 밖에서 받은 GH_TOKEN 은 사용자 토큰이라 봇 대신 사용자 이름으로 게시된다
  local tok
  tok="$(sed -n 's/^PR_EVAL_BOT_TOKEN=//p' "$BOT_ENV" | tr -d "\"'" | head -1)"
  [ -n "$tok" ] || tok="$(sed -n 's/^GH_TOKEN=//p' "$BOT_ENV" | tr -d "\"'" | head -1)"
  [ -n "$tok" ] || die "$E_ENV" "$BOT_ENV 에 PR_EVAL_BOT_TOKEN 또는 GH_TOKEN 이 없다"
  export GH_TOKEN="$tok"
  unset GITHUB_TOKEN || true
}

api() { gh api "$@" || die "$E_API" "gh api 실패: $*"; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# 락에 적을 pid — 이 스크립트는 즉시 끝나므로 자기 pid 를 적으면 다음 확인에서 바로 죽은 락이 된다.
# 조상 중 claude 세션 프로세스를 찾아 그 pid 를 쓴다. 없으면(=watcher 가 부른 경우) 직속 부모를 쓴다.
owner_pid() {
  if [ -n "${PR_EVAL_LOCK_PID:-}" ]; then echo "$PR_EVAL_LOCK_PID"; return; fi
  local p="$PPID" name
  while [ "${p:-0}" -gt 1 ]; do
    name="$(ps -o comm= -p "$p" 2>/dev/null | sed 's|.*/||' || true)"
    [ "$name" = "claude" ] && { echo "$p"; return; }
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  echo "$PPID"
}

# ---------- 조회 ----------

cmd_sha() { api "repos/$OWNER/$1/pulls/$2" --jq '.head.sha'; }

cmd_meta() { need_meta "$1" "$2"; cat "$(meta_path "$1" "$2")"; }

cmd_precheck() {
  local repo="$1" pr="$2" j
  j="$(api "repos/$OWNER/$repo/pulls/$pr")"
  local files add del
  files="$(jq -r '.changed_files' <<<"$j")"
  add="$(jq -r '.additions' <<<"$j")"
  del="$(jq -r '.deletions' <<<"$j")"
  local lines=$(( add + del ))
  echo "changed_files=$files diff_lines=$lines (cut: files>$BIG_PR_FILES or lines>$BIG_PR_LINES)"
  if [ "$files" -gt "$BIG_PR_FILES" ] || [ "$lines" -gt "$BIG_PR_LINES" ]; then
    echo "대형 PR 컷에 걸린다. status 를 보류(대형PR) 로 두고 게시하지 않는다."
    return "$E_GATE"
  fi
  echo "통과"
}

# 게시 기준 SHA 의 diff 에서 RIGHT 측 hunk 범위를 뽑아 "파일<TAB>시작<TAB>줄수" 로 낸다.
# gate1(사후 검사)과 ranges(위원 프롬프트에 실을 사전 정보)가 같은 것을 본다.
emit_ranges() {
  local repo="$1" sha="$2" out="$3" base
  base="$(jq -r '.base_sha' "$(meta_path "$repo" "$4")")"
  [ -n "$base" ] && [ "$base" != "null" ] || die "$E_ENV" "meta.json 에 base_sha 가 없다"
  # --paginate 를 붙이지 않는다 — compare 의 files[] 는 단일 응답이고, 붙이면 2페이지부터 빈 배열이 딸려 나온다.
  api "repos/$OWNER/$repo/compare/$base...$sha" > "$out/compare.json"
  jq -r '
    .files[] | select(.patch != null) | . as $f
    | ($f.patch | split("\n")[] | select(startswith("@@"))
       | capture("@@ -[0-9]+(,[0-9]+)? \\+(?<s>[0-9]+)(,(?<c>[0-9]+))?"))
    | "\($f.filename)\t\(.s)\t\(.c // "1")"
  ' "$out/compare.json" > "$out/ranges.tsv"
}

# 위원 프롬프트에 실을 "inline 코멘트를 달 수 있는 줄" 목록.
# 앵커 하나가 diff 밖이면 리뷰가 통째로 422 라 사전에 주는 편이 사후 검사보다 싸다.
cmd_ranges() {
  local repo="$1" pr="$2" sha="$3"
  need_meta "$repo" "$pr"
  mktmp; local tmp="$TMP"
  emit_ranges "$repo" "$sha" "$tmp" "$pr"
  echo "# inline 앵커 허용 범위 (기준 SHA $sha) — 파일 / 시작줄 / 끝줄(포함)"
  awk -F'\t' '{printf "%s\t%d-%d\n", $1, $2, $2+$3-1}' "$tmp/ranges.tsv"
  # 범위만 주면 위원이 hunk 시작줄부터 세다 틀린다. 같은 patch 에 줄 번호를 붙여 보여 준다.
  echo "# 줄 번호를 붙인 diff — '+'·' ' 줄은 새 파일 번호(앵커 가능), '(N) -' 줄은 삭제된 옛 파일 번호(앵커 불가)"
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
  [ "$n" = "0" ] || { echo "# patch 가 없어 앵커를 달 수 없는 파일 $n 건:"; \
    jq -r '.files[] | select(.patch == null) | "#   " + .filename' "$tmp/compare.json"; }
}

# PG1 — 앵커가 게시 기준 SHA 의 diff 안인가
cmd_gate1() {
  local repo="$1" pr="$2" sha="$3" cfile="$4"
  [ -f "$cfile" ] || die "$E_USAGE" "코멘트 파일이 없다: $cfile"
  jq -e 'type == "array"' "$cfile" >/dev/null || die "$E_USAGE" "$cfile 은 JSON 배열이어야 한다"
  need_meta "$repo" "$pr"
  local base; base="$(jq -r '.base_sha' "$(meta_path "$repo" "$pr")")"
  [ -n "$base" ] && [ "$base" != "null" ] || die "$E_ENV" "meta.json 에 base_sha 가 없다"

  mktmp; local tmp="$TMP"
  emit_ranges "$repo" "$sha" "$tmp" "$pr"

  # patch 가 없는 파일(대용량)은 앵커 대상에서 제외한다.
  jq -r '.files[] | select(.patch == null) | .filename' "$tmp/compare.json" > "$tmp/nopatch.txt"
  if [ -s "$tmp/nopatch.txt" ]; then
    echo "주의 — patch 가 없어 앵커 대상에서 제외한 파일:" >&2
    sed 's/^/  /' "$tmp/nopatch.txt" >&2
  fi
  local nfiles; nfiles="$(jq -r '.files | length' "$tmp/compare.json")"
  [ "$nfiles" -lt 300 ] || echo "주의 — compare files 가 $nfiles 건이다. 300 에서 절단됐을 수 있다." >&2

  local bad=0 total=0
  while IFS=$'\t' read -r p l side; do
    total=$((total+1))
    if [ "$side" != "RIGHT" ]; then
      echo "PG1 위반 — side 가 RIGHT 가 아니다: $p:$l (side=$side)"; bad=$((bad+1)); continue
    fi
    if ! awk -F'\t' -v P="$p" -v L="$l" '
        $1==P && L+0 >= $2+0 && L+0 < $2+$3 { found=1 }
        END { exit !found }' "$tmp/ranges.tsv"; then
      echo "PG1 위반 — diff 밖 앵커: $p:$l"; bad=$((bad+1))
    fi
  done < <(jq -r '.[] | [.path, (.line|tostring), (.side // "RIGHT")] | @tsv' "$cfile")

  if [ "$bad" -gt 0 ]; then
    echo "PG1 실패 — $total 건 중 $bad 건이 diff 밖이다. 요약 본문으로 옮겨라."
    return "$E_GATE"
  fi
  echo "PG1 통과 — 앵커 $total 건 전부 diff 안이다 (기준 SHA $sha)"
}

# 자동 머지 리스크 점수 (03-risk.md). 현재 head 의 PR diff 로 매기고 meta.risk 와 outputs/risk.md 에 남긴다.
# low 면 0, 그 밖이면 3 — 사람이 승인해야 머지된다는 뜻이다.
cmd_risk() {
  local repo="$1" pr="$2" d m sha
  need_meta "$repo" "$pr"
  d="$(run_dir "$repo" "$pr")"; m="$(meta_path "$repo" "$pr")"
  sha="$(cmd_sha "$repo" "$pr")"
  mktmp; local tmp="$TMP"
  api --paginate "repos/$OWNER/$repo/pulls/$pr/files" | jq -s 'add // []' > "$tmp/files.json"
  # jq 문법 오류는 종료 3 이라 게이트 위반(E_GATE)과 섞인다. 판정 실패로 따로 끝낸다
  jq --arg sha "$sha" --arg at "$(now_iso)" -f "$HARNESS_DIR/scripts/risk.jq" "$tmp/files.json" > "$tmp/risk.json" \
    || die "$E_API" "risk.jq 계산 실패"

  # 같은 head·같은 점수로 이미 코멘트를 달았으면 그 기록을 이어 받는다 (chain.sh 가 중복 게시를 막는 데 쓴다).
  # 규칙이 바뀌어 점수가 달라지면 이어 받지 않는다 — PR 에 남은 점수표가 낡은 채로 남지 않게
  meta_update "$repo" "$pr" '.risk = ($r[0] + {commented_sha: (if .risk.sha == $r[0].sha and .risk.score == $r[0].score and .risk.level == $r[0].level
                                                               then .risk.commented_sha else null end)})' \
    --slurpfile r "$tmp/risk.json"

  jq -r '
    def action: {low: "다른 머지 게이트를 모두 통과하면 자동으로 머지합니다.",
                 medium: "자동 머지하지 않습니다. 사람 1명이 확인한 뒤 직접 머지합니다.",
                 high: "자동 머지하지 않습니다. 걸린 항목을 아는 사람이 리뷰한 뒤 머지합니다.",
                 critical: "자동 머지하지 않습니다. 사람이 PR 을 쪼갤지부터 판단합니다."}[.level];
    def files: if length == 0 then "" elif length <= 2 then " — " + (map("`\(.)`") | join(", "))
               else " — `\(.[0])` 외 \(length - 1)건" end;
    "**자동 머지 리스크 \(.score) / 100 — `\(.level)`** · 기준 커밋 `\(.sha[0:7])`\n",
    (if .override then "**\(.override)**입니다. 자동 머지하지 않습니다. 비밀값을 빼고, 이미 올라간 값은 교체한 뒤 사람이 다시 봅니다.\n" else "\(action)\n" end),
    "| 항목 | 점수 | 걸린 신호 |", "|---|---|---|",
    (.categories[] | "| \(.title) | \(.points) / \(.max) | \([.signals[] | select(.points > 0) | "\(.name) \(.points)\(.hits | files)"] | join("<br>") | if . == "" then "-" else . end) |"),
    "| **합계** | **\(.score)** / 100 | |\n",
    "low 0–14 자동 머지 · medium 15–39 사람 1명 승인 · high 40–69 해당 분야 리뷰 · critical 70+ 또는 평문 비밀값. low 가 아니면 체인은 머지하지 않고 사람에게 넘깁니다.",
    "파일 경로와 변경 줄 수만 보고 기계로 매긴 점수입니다. 코드 품질 판정이 아니라, 잘못됐을 때 얼마나 아픈 변경인지를 잽니다. 규칙은 `tools/pr-eval/03-risk.md` 에 있습니다."
  ' "$tmp/risk.json" > "$d/outputs/risk.md"
  cat "$d/outputs/risk.md"

  [ "$(jq -r '.level' "$tmp/risk.json")" = "low" ] || return "$E_GATE"
}

# ---------- 상태 ----------

cmd_init() {
  local repo="$1" pr="$2" reset_eval=0 prof d
  case "${3:-}" in
    "")            ;;
    --reset-eval)  reset_eval=1 ;;
    *) die "$E_USAGE" "init 이 아는 플래그는 --reset-eval 뿐이다: $3" ;;
  esac
  prof="$(profile_of "$repo")"
  d="$(run_dir "$repo" "$pr")"
  mkdir -p "$d/rounds" "$d/prompts" "$d/outputs/stage1" "$d/outputs/stage2" "$d/outputs/stage3"
  [ -f "$d/frozen.md" ] || printf '# 동결 — 이 PR 에서 확정된 사실\n\n뒤집으려면 *그 확정이 틀렸다는 새 근거*를 대야 한다.\n\n| # | 확정된 사실 | 근거 | 동결한 라운드 |\n|---|---|---|---|\n' > "$d/frozen.md"

  local j base head
  j="$(api "repos/$OWNER/$repo/pulls/$pr")"
  base="$(jq -r '.base.sha' <<<"$j")"
  head="$(jq -r '.head.sha' <<<"$j")"

  if [ -f "$d/meta.json" ]; then
    # 재실행. Stage 1 이 이미 게시했으면 그 리뷰가 매달린 기준 SHA 이므로 건드리지 않는다 —
    # Stage 2 가 last_judged_sha 로 쓰는 값이고, 덮으면 무엇을 판정한 리뷰인지 알 수 없게 된다.
    # Stage 1 을 새 head 로 다시 돌릴 때만 --reset-eval 로 갱신한다.
    local posted; posted="$(jq -r '[.stage1[]?.review_id | select(. != null)] | length' "$d/meta.json")"
    if [ "$posted" -gt 0 ] && [ "$reset_eval" = 0 ]; then
      echo "meta.json 유지 — Stage 1 게시 기록 $posted 건이 있어 base_sha·eval_sha 를 보존한다."
      echo "  eval_sha=$(jq -r '.eval_sha' "$d/meta.json")  (현재 head=$head)"
      echo "  Stage 1 을 현재 head 로 다시 돌리려면: init $repo $pr --reset-eval"
    else
      meta_update "$repo" "$pr" '.base_sha=$b | .eval_sha=$h' --arg b "$base" --arg h "$head"
      echo "meta.json 갱신 (기존 기록 보존): $d/meta.json"
    fi
  else
    jq -n --arg o "$OWNER" --arg r "$repo" --argjson p "$pr" \
          --arg b "$base" --arg h "$head" --arg prof "$prof" '
      {owner:$o, repo:$r, pr:$p, base_sha:$b, eval_sha:$h, profile:$prof,
       lock:null, attempts:0, stage1:[], stage2:[], stage3:null, status:"대기"}
    ' > "$d/meta.json"
    echo "생성: $d/meta.json"
  fi
}

# 스테이지 순서 게이트 — Stage N 은 Stage N-1 완료 기록이 있어야 돈다.
# 모든 스테이지가 lock 을 지나므로 여기서 한 번만 막으면 된다(문서 규칙을 스크립트로 강제).
check_stage_order() {
  local m="$1" stage="$2" n1 n2
  n1="$(jq -r '[.stage1[]?.review_id | select(. != null)] | length' "$m")"
  n2="$(jq -r '[.stage2[]?] | length' "$m")"
  case "$stage" in
    2) [ "$n1" -gt 0 ] || die "$E_GATE" "Stage 1 완료 기록이 없다. Stage 2 는 돌지 않는다" ;;
    3) [ "$n1" -gt 0 ] || die "$E_GATE" "Stage 1 완료 기록이 없다. Stage 3 은 돌지 않는다"
       [ "$n2" -gt 0 ] || die "$E_GATE" "Stage 2 판정 기록이 없다. Stage 3 은 돌지 않는다" ;;
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
    # started_at 이 TTL 안인가
    local s_epoch now_epoch
    s_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$started" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date -u +%s)"
    [ "$s_epoch" -gt 0 ] && [ $((now_epoch - s_epoch)) -lt "$LOCK_TTL_SEC" ] && fresh=1
    if [ "$alive" = 1 ] && [ "$fresh" = 1 ]; then
      echo "락 점유 중 — pid=$pid stage=$(jq -r '.lock.stage' "$m") started=$started"
      return "$E_LOCK"
    fi
    echo "낡은 락을 지운다 (pid alive=$alive, ttl fresh=$fresh)" >&2
  fi
  local owner; owner="$(owner_pid)"
  meta_update "$repo" "$pr" '.lock={pid:$pid, started_at:$at, stage:$st}' \
    --argjson pid "$owner" --arg at "$(now_iso)" --argjson st "$stage"
  echo "락 획득 — pid=$owner stage=$stage"
}

cmd_unlock() { need_meta "$1" "$2"; meta_update "$1" "$2" '.lock=null'; echo "락 해제"; }

cmd_status() {
  need_meta "$1" "$2"
  case "$3" in
    대기|진행|완료|"보류(대형PR)"|"보류(실패)") ;;
    *) die "$E_USAGE" "status 값이 척도 밖이다: $3" ;;
  esac
  meta_update "$1" "$2" '.status=$s' --arg s "$3"; echo "status=$3"
}

cmd_attempt() {
  need_meta "$1" "$2"
  case "$3" in
    inc)   meta_update "$1" "$2" '.attempts = (.attempts // 0) + 1' ;;
    reset) meta_update "$1" "$2" '.attempts = 0' ;;
    *) die "$E_USAGE" "attempt 는 inc 또는 reset 이다" ;;
  esac
  jq -r '.attempts' "$(meta_path "$1" "$2")"
}

# PG5 일부(기계로 셀 수 있는 것). post-review 가 게시 직전에 부르고, selftest.sh 가 지난 산출물에 다시 돌린다.
cmd_pg5() {
  local sfile="$1" cfile="$2" stage="${3:-stage1}"
  [ -f "$sfile" ] || die "$E_USAGE" "요약 파일이 없다: $sfile"
  [ -f "$cfile" ] || die "$E_USAGE" "코멘트 파일이 없다: $cfile"
  if [ "$stage" = "stage1" ]; then
    grep -q 'praise' "$sfile" || jq -e '[.[] | select(.body | test("praise"))] | length > 0' "$cfile" >/dev/null \
      || die "$E_GATE" "PG5 위반 — praise 코멘트가 없다"
  fi
  jq -e '[.[] | select((.code|not) or (.axis|not) or (.body|not))] | length == 0' "$cfile" >/dev/null \
    || die "$E_GATE" "PG5 위반 — code/axis/body 가 빠진 코멘트가 있다"
  # 축은 코드만이 아니라 이름까지 본문에 있어야 한다 — 저자가 프로파일을 열지 않고 읽을 수 있어야 한다.
  local noname; noname="$(jq -r '[.[] | select((.body | test("R-[A-I] \\(")) | not) | .code] | join(", ")' "$cfile")"
  [ -z "$noname" ] || die "$E_GATE" "PG5 위반 — 축 이름이 없다(\`R-x (이름)\` 형식이어야 한다): $noname"
  # 요약에는 축 범례표를 한 번 싣는다 — blocking 순서표 칸에는 코드만 들어가기 때문이다.
  if [ "$stage" = "stage1" ]; then
    grep -qE '`R-[A-I]`' "$sfile" || die "$E_GATE" "PG5 위반 — 요약에 축 범례표가 없다 (00-criteria.md §6)"
  fi
  echo "PG5 통과 — $cfile"
}

# PG6 — 윤문이 뜻을 깎지 않았나 (01-stages.md §7). <dir> 은 pre-polish/ 를 품은 outputs/<stage>[/round-NN] 이다.
# 세션이 문서의 두 줄을 직접 돌리면 권한에 막혀 눈 대조로 우회했다(L0-42·L0-51). 한 줄 호출로 옮긴다.
# 영향(②)과 방향(④)이 남았는지는 셀 수 없으므로 여기서 보지 않는다.
cmd_pg6() {
  local dir="${1%/}" pre bad=0
  pre="$dir/pre-polish"
  [ -d "$pre" ] || die "$E_USAGE" "사본 폴더가 없다: $pre"

  # JSON — 건수·필드·본문 첫 줄이 사본과 같은가
  if [ -f "$pre/comments.json" ] || [ -f "$dir/comments.json" ]; then
    [ -f "$pre/comments.json" ] && [ -f "$dir/comments.json" ] \
      || die "$E_GATE" "PG6 위반 — comments.json 이 사본과 현재 중 한쪽에만 있다"
    if ! jq -e -s 'map(map({code, path, line, side:(.side//"RIGHT"), axis, grade,
                           head:(.body | split("\n")[0])})) | .[0] == .[1]' \
         "$pre/comments.json" "$dir/comments.json" >/dev/null; then
      echo "PG6 위반 — comments.json 의 건수·필드·첫 줄이 사본과 다르다"; bad=1
    fi
  fi

  # 마크다운 — 사본에만 있는 앵커·수치 토큰이 있는가 (summary.md · replies/ · patches/)
  # 사본은 원본과 같은 상대 경로가 원칙이지만, cp -R 가 권한에 막히면 세션이 replies/ 없이 평평하게 복사한다.
  # 같은 경로가 없으면 같은 파일 이름으로 찾는다.
  local rel cur md_pre=() md_cur=() missing
  while IFS= read -r rel; do
    md_pre+=("$pre/$rel")
    cur="$dir/$rel"
    [ -f "$cur" ] || cur="$(find "$dir" -name "$(basename "$rel")" -not -path "$pre/*" | head -1)"
    [ -n "$cur" ] && [ -f "$cur" ] && md_cur+=("$cur")
  done < <(cd "$pre" && find . -name '*.md' | sed 's|^\./||' | sort)
  # 사본이 비어 있으면 대조할 것이 없어 통과처럼 보인다 — 사본 만들기가 권한에 막힌 경우다
  [ -f "$pre/comments.json" ] || [ "${#md_pre[@]}" -gt 0 ] \
    || die "$E_GATE" "PG6 위반 — 사본 폴더가 비어 있다. 사본을 다시 뜬 뒤 돌린다: $pre"
  if [ "${#md_pre[@]}" -gt 0 ]; then
    tok() { [ $# -eq 0 ] || grep -ohE '[A-Za-z0-9_./-]+\.[a-z]+:[0-9]+|[0-9]+(\.[0-9]+)?' "$@" | sort -u; }
    missing="$(comm -23 <(tok "${md_pre[@]}") <(tok ${md_cur[@]+"${md_cur[@]}"}))"
    if [ -n "$missing" ]; then
      echo "PG6 위반 — 사본에만 있는 토큰(근거의 파일:줄이나 수치가 빠졌는지 하나씩 확인한다):"
      sed 's/^/  /' <<<"$missing"; bad=1
    fi
  fi

  [ "$bad" = 0 ] || return "$E_GATE"
  echo "PG6 통과 — $dir (JSON 필드·첫 줄, 마크다운 앵커·수치)"
}

# 윤문 전 사본을 뜬다. 세션에 cp 를 열지 않으려고 둔다 — 복사 대상은 runs/ 아래 산출물 폴더 하나뿐이다.
cmd_snapshot() {
  local dir="${1%/}" runs real f copied=()
  [ -d "$dir" ] || dir="$HARNESS_DIR/$dir"
  [ -d "$dir" ] || die "$E_USAGE" "산출물 폴더가 없다: $1"
  runs="$(cd "$RUNS_DIR" && pwd -P)"
  real="$(cd "$dir" && pwd -P)"
  case "$real/" in "$runs"/*/*) ;; *) die "$E_USAGE" "runs/ 아래 산출물 폴더만 받는다: $1" ;; esac
  mkdir -p "$real/pre-polish"
  for f in comments.json summary.md replies patches; do
    [ -e "$real/$f" ] || continue
    cp -R "$real/$f" "$real/pre-polish/"
    copied+=("$f")
  done
  echo "사본 — $real/pre-polish (${copied[*]:-없음})"
}

# ---------- 게시 ----------

# 게시 본문은 runs/ 아래 일반 파일만 받는다. 세션이 이 스크립트를 부를 수 있으므로,
# 다른 경로를 넘기면 Read deny 를 거치지 않고 그 파일이 공개 코멘트로 올라간다
need_run_file() {
  local f="$1" runs dir
  [ -f "$f" ] && [ ! -L "$f" ] || die "$E_USAGE" "본문 파일이 없거나 링크다: $f"
  runs="$(cd "$RUNS_DIR" && pwd -P)"
  dir="$(cd "$(dirname "$f")" && pwd -P)"
  case "$dir/" in "$runs"/*) ;; *) die "$E_USAGE" "본문 파일은 runs/ 아래에 둔다: $f" ;; esac
}

cmd_post_review() {
  local repo="$1" pr="$2" sha="$3" sfile="$4" cfile="$5" stage="${6:-stage1}"
  case "$stage" in
    stage1|stage2|stage3) ;;
    *) die "$E_USAGE" "stage 는 stage1|stage2|stage3 중 하나다: $stage" ;;
  esac
  [ -f "$sfile" ] || die "$E_USAGE" "요약 파일이 없다: $sfile"
  [ -f "$cfile" ] || die "$E_USAGE" "코멘트 파일이 없다: $cfile"
  need_meta "$repo" "$pr"

  # 게시 직전에 PG1 을 한 번 더 돌린다 — 세션이 건너뛰어도 여기서 막힌다.
  cmd_gate1 "$repo" "$pr" "$sha" "$cfile" || return "$E_GATE"

  cmd_pg5 "$sfile" "$cfile" "$stage"

  load_bot_token
  mktmp; local tmp="$TMP"

  # 게시에는 path/line/side/body 만 보낸다. code/axis/grade 는 meta 기록용이다.
  jq -n --arg cid "$sha" --rawfile body "$sfile" --slurpfile c "$cfile" '
    {commit_id:$cid, event:"COMMENT", body:$body,
     comments: ($c[0] | map({path, line, side:(.side // "RIGHT"), body}))}
  ' > "$tmp/payload.json"

  local resp; resp="$(gh api "repos/$OWNER/$repo/pulls/$pr/reviews" --input "$tmp/payload.json")" \
    || die "$E_API" "리뷰 게시 실패. 422 면 기준 SHA($sha)에 line 앵커가 안 붙는 경우를 먼저 의심하라 (01-stages.md §7)"
  local review_id; review_id="$(jq -r '.id' <<<"$resp")"

  # 게시된 inline 코멘트의 id 를 되받아 (path,line) 으로 code/axis/grade 를 붙인다.
  gh api --paginate "repos/$OWNER/$repo/pulls/$pr/comments" \
    | jq -s 'add | map(select(.pull_request_review_id == '"$review_id"'))
             | map({id, path, line, body})' > "$tmp/posted.json"

  # 본문으로 먼저 맞춘다 — 같은 자리에 코멘트가 둘이면 (path,line) 만으로는 갈리지 않고
  # id 가 교차로 붙어 Stage 2 가 엉뚱한 스레드에 답글을 단다.
  local merged; merged="$(jq -s '
      .[0] as $draft | .[1] as $posted |
      $draft | map(. as $d
        | (first($posted[] | select(.body == $d.body) | .id)
           // first($posted[] | select(.path==$d.path and .line==$d.line) | .id)) as $id
        | {id: ($id // null), code:$d.code, path:$d.path, line:$d.line,
           axis:$d.axis, grade:($d.grade // null)})
    ' "$cfile" "$tmp/posted.json")"

  # 스테이지마다 기록 자리가 다르다. stage2 를 stage1 에 붙이면 watcher 의 "이미 게시됨" 판정과
  # Stage 2 가 스레드를 찾는 stage1[].comments[].id 가 함께 어긋난다.
  case "$stage" in
    stage1)
      meta_update "$repo" "$pr" '.stage1 += [{review_id:$rid, posted_at:$at, eval_sha:$sha, comments:$c}] | .attempts=0 | .status="완료"' \
        --argjson rid "$review_id" --arg at "$(now_iso)" --arg sha "$sha" --argjson c "$merged" ;;
    stage2)
      # 마지막 원소가 다른 커밋을 판정한 회차면 새 원소를 붙인다 — 합치면 앞 회차 게시 기록이 덮인다(L0-25)
      meta_update "$repo" "$pr" '.stage2 = ((.stage2 // []) | if length == 0 or ((.[-1].stage_sha // $sha) != $sha) then . + [{}] else . end)
                                 | .stage2[-1] += {review_id:$rid, posted_at:$at, stage_sha:$sha, new_comments:$c}' \
        --argjson rid "$review_id" --arg at "$(now_iso)" --arg sha "$sha" --argjson c "$merged" ;;
    stage3)
      # 다른 커밋으로 다시 돌면 앞 회차를 stage3_history 로 옮긴다 — 합치면 앞 회차 review_id·stage_sha 가 덮인다(L0-43)
      meta_update "$repo" "$pr" '((.stage3 != null) and ((.stage3.stage_sha // $sha) != $sha)) as $new
                                 | (if $new then .stage3_history = ((.stage3_history // []) + [.stage3]) | .stage3 = null else . end)
                                 | .stage3 = ((.stage3 // {}) + {review_id:$rid, posted_at:$at, stage_sha:$sha, comments:$c})
                                 | .stage3.replies = ((.stage3.replies // {}) + (.stage3_replies // {})) | del(.stage3_replies)' \
        --argjson rid "$review_id" --arg at "$(now_iso)" --arg sha "$sha" --argjson c "$merged" ;;
  esac

  echo "게시 완료 — review_id=$review_id, inline 코멘트 $(jq 'length' <<<"$merged") 건"
  jq -r '.[] | select(.id == null) | "주의 — id 를 못 찾은 코멘트: \(.code) \(.path):\(.line)"' <<<"$merged" >&2
}

cmd_reply() {
  local repo="$1" pr="$2" cid="$3" bfile="$4" rid
  [ -f "$bfile" ] || die "$E_USAGE" "본문 파일이 없다: $bfile"
  need_meta "$repo" "$pr"
  load_bot_token
  rid="$(jq -n --rawfile b "$bfile" '{body:$b}' \
    | gh api "repos/$OWNER/$repo/pulls/$pr/comments/$cid/replies" --input - --jq '.id')" \
    || die "$E_API" "reply 실패 (comment_id=$cid)"
  echo "$rid"

  # 게시는 이미 끝났으므로 기록이 실패해도 0 으로 끝낸다 — 실패 코드를 보고 다시 올리면 reply 가 두 번 달린다.
  record_reply "$repo" "$pr" "$cid" "$rid" \
    || echo "주의 — reply 는 게시됐지만(id $rid) meta.json 기록에 실패했다. 다시 올리지 말고 손으로 적는다" >&2
}

# reply id 를 지금 락의 스테이지 기록에 남긴다. 안 남기면 다음 스테이지가 스레드를 못 찾고
# 재개 세션이 같은 reply 를 두 번 올린다(L0-23). 키는 부모 코멘트의 code, 못 찾으면 comment_id 다.
# Stage 3 은 이번 락에서 post-review 가 이미 게시한 회차가 있으면 거기에, 없으면 .stage3_replies 에 모아 두고
# post-review 가 합친다 — reply 가 .stage3 를 만들면 chain.sh 의 stage3_done 이 게시 전에 참이 되고,
# 앞 회차 객체에 붙으면 다시 돌 때 history 로 같이 밀려난다.
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
    *) echo "주의 — 락에 스테이지 2·3 이 없어 reply id($rid) 를 meta.json 에 남기지 않았다" >&2 ;;
  esac
}

cmd_patch() {
  local repo="$1" pr="$2" cid="$3" bfile="$4"
  [ -f "$bfile" ] || die "$E_USAGE" "본문 파일이 없다: $bfile"
  load_bot_token
  jq -n --rawfile b "$bfile" '{body:$b}' \
    | gh api -X PATCH "repos/$OWNER/$repo/pulls/comments/$cid" --input - --jq '.id' \
    || die "$E_API" "patch 실패 (comment_id=$cid). 봇은 자기 코멘트만 수정할 수 있다"
}

# 게시한 리뷰 요약 본문을 고친다. 봇은 자기 리뷰만 고칠 수 있다.
cmd_patch_review() {
  local repo="$1" pr="$2" rid="$3" bfile="$4"
  [ -f "$bfile" ] || die "$E_USAGE" "본문 파일이 없다: $bfile"
  load_bot_token
  jq -n --rawfile b "$bfile" '{body:$b}' \
    | gh api -X PUT "repos/$OWNER/$repo/pulls/$pr/reviews/$rid" --input - --jq '.id' \
    || die "$E_API" "요약 정정 실패 (review_id=$rid)"
}

cmd_comment() {
  local repo="$1" pr="$2" bfile="$3"
  [ -f "$bfile" ] || die "$E_USAGE" "본문 파일이 없다: $bfile"
  load_bot_token
  jq -n --rawfile b "$bfile" '{body:$b}' \
    | gh api "repos/$OWNER/$repo/issues/$pr/comments" --input - --jq '.id' \
    || die "$E_API" "코멘트 게시 실패"
}

# ---------- 진입점 ----------

[ $# -ge 1 ] || usage
sub="$1"; shift
# PR 번호는 runs/ 아래 경로가 된다. 숫자가 아니면 init 이 runs/ 밖에 폴더와 frozen.md 를 만들 수 있다
case "$sub" in
  pg5|pg6|snapshot) ;;
  *) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "$E_USAGE" "PR 번호는 양의 정수여야 한다: ${2:-}" ;;
esac
case "$sub" in
  sha)         [ $# -eq 2 ] || usage; cmd_sha "$@" ;;
  meta)        [ $# -eq 2 ] || usage; cmd_meta "$@" ;;
  precheck)    [ $# -eq 2 ] || usage; cmd_precheck "$@" ;;
  ranges)      [ $# -eq 3 ] || usage; cmd_ranges "$@" ;;
  gate1)       [ $# -eq 4 ] || usage; cmd_gate1 "$@" ;;
  risk)        [ $# -eq 2 ] || usage; cmd_risk "$@" ;;
  pg5)         [ $# -ge 2 ] && [ $# -le 3 ] || usage; cmd_pg5 "$@" ;;
  pg6)         [ $# -eq 1 ] || usage; cmd_pg6 "$@" ;;
  snapshot)    [ $# -eq 1 ] || usage; cmd_snapshot "$@" ;;
  init)        [ $# -ge 2 ] && [ $# -le 3 ] || usage; cmd_init "$@" ;;
  lock)        [ $# -eq 3 ] || usage; cmd_lock "$@" ;;
  unlock)      [ $# -eq 2 ] || usage; cmd_unlock "$@" ;;
  status)      [ $# -eq 3 ] || usage; cmd_status "$@" ;;
  attempt)     [ $# -eq 3 ] || usage; cmd_attempt "$@" ;;
  post-review) [ $# -ge 5 ] || usage; need_run_file "$4"; need_run_file "$5"; cmd_post_review "$@" ;;
  reply)       [ $# -eq 4 ] || usage; need_run_file "$4"; cmd_reply "$@" ;;
  patch)       [ $# -eq 4 ] || usage; need_run_file "$4"; cmd_patch "$@" ;;
  patch-review) [ $# -eq 4 ] || usage; need_run_file "$4"; cmd_patch_review "$@" ;;
  comment)     [ $# -eq 3 ] || usage; need_run_file "$3"; cmd_comment "$@" ;;
  *) usage ;;
esac
