#!/usr/bin/env bash
# watch.sh — 봇에게 리뷰 요청이 걸린 PR 을 찾아 체인(scripts/chain.sh)을 띄운다.
# 체인이 Stage 1 부터 머지까지 사람 없이 돈다. 단계별로 따로 돌릴 때는 사람이 /pr-eval 을 부른다.
# launchd StartInterval 60 으로 상시 실행한다. --once 는 디버깅 경로다.
set -euo pipefail

OWNER="${PR_EVAL_OWNER:-thswlsqls}"
# 봇 로그인은 bot.env 의 BOT_LOGIN 하나에서 읽는다 — 여기와 토큰 파일이 어긋나면
# watcher 가 엉뚱한 계정으로 폴링해 트리거가 조용히 안 돈다. (토큰은 읽지 않는다)
BOT_ENV="${PR_EVAL_BOT_ENV:-$HOME/.config/pr-eval/bot.env}"
BOT="${PR_EVAL_BOT:-$(sed -n 's/^BOT_LOGIN=//p' "$BOT_ENV" 2>/dev/null | tr -d "\"'" | head -1)}"
[ -n "$BOT" ] || { echo "봇 로그인을 못 찾았다: $BOT_ENV 의 BOT_LOGIN 또는 PR_EVAL_BOT 을 설정하라" >&2; exit 2; }
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
WS_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PR_EVAL="$HARNESS_DIR/scripts/pr-eval.sh"
MAX_ATTEMPTS=2

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

known_profile() { case "$1" in tech-n-ai-backend|tech-n-ai-frontend) return 0 ;; *) return 1 ;; esac; }

# meta.lock 이 유효한가 — 시작 후 3시간 이내이고 pid 가 살아 있으면 유효하다.
lock_valid() {
  local m="$1" pid started s_epoch
  pid="$(jq -r '.lock.pid // empty' "$m")"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  started="$(jq -r '.lock.started_at // empty' "$m")"
  s_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$started" +%s 2>/dev/null || echo 0)"
  [ "$s_epoch" -gt 0 ] || return 1
  [ $(( $(date -u +%s) - s_epoch )) -lt 10800 ]
}

# 머지된 PR 의 평가·저자 워크트리(pr-eval-<N>[-<sha7>] · pr-author-<N>)를 지운다.
# 세션 권한에는 worktree add 만 있고, 체인은 사람이 한 머지를 못 보므로 폴링하는 여기서 한다.
# --force 를 쓰지 않는다 — 커밋 안 한 변경이 있으면 git 이 거부하고 로그만 남는다. 브랜치는 건드리지 않는다
gc_worktrees() {
  local repo dir wt name merged
  for repo in tech-n-ai-backend tech-n-ai-frontend; do
    dir="$WS_ROOT/$repo-worktrees"
    [ -d "$dir" ] || continue
    merged="$(gh pr list --repo "$OWNER/$repo" --state merged --limit 200 --json number --jq '.[].number')" || continue
    for wt in "$dir"/pr-eval-* "$dir"/pr-author-*; do
      [ -d "$wt" ] || continue
      name="$(basename "$wt")"
      [[ "$name" =~ ^pr-(eval|author)-([1-9][0-9]*)(-[0-9a-f]{7})?$ ]] || continue
      grep -qx "${BASH_REMATCH[2]}" <<<"$merged" || continue
      if git -C "$WS_ROOT/$repo" worktree remove "$wt"; then
        log "워크트리 정리 — $repo $name (머지된 PR)"
      else
        log "워크트리 정리 실패 — $repo $name"
      fi
    done
    git -C "$WS_ROOT/$repo" worktree prune
  done
}

run_once() {
  local prs n
  gc_worktrees || log "워크트리 정리 단계가 실패했다 — 폴링은 계속한다"
  # 리뷰 요청을 찾는 질의는 이것 하나뿐이다(위 정리 단계의 머지 목록 조회 말고는). PR 코멘트를 폴링하지 않는다.
  prs="$(gh search prs --owner "$OWNER" --review-requested="$BOT" --state=open \
          --json number,repository,isDraft,authorAssociation 2>/dev/null || echo '[]')"
  n="$(jq 'length' <<<"$prs")"
  [ "$n" -gt 0 ] || { log "리뷰 요청 없음"; return 0; }

  local i
  for (( i=0; i<n; i++ )); do
    local pr repo draft assoc m
    pr="$(jq -r ".[$i].number" <<<"$prs")"
    repo="$(jq -r ".[$i].repository.name" <<<"$prs")"
    draft="$(jq -r ".[$i].isDraft" <<<"$prs")"
    assoc="$(jq -r ".[$i].authorAssociation" <<<"$prs")"

    # 1) 프로파일을 모르는 저장소 — 질의가 --owner 단위라 밖의 PR 도 걸려 온다.
    known_profile "$repo" || { log "skip $repo#$pr — 프로파일 없음"; continue; }
    # 2) draft
    [ "$draft" = "false" ] || { log "skip $repo#$pr — draft"; continue; }
    # 2-1) 저장소 소유자가 연 PR 만 — 저장소가 public 이라, 남의 PR 이면 본문·diff 가 사용자 계정으로 push·머지하는 세션에 그대로 들어간다
    [ "$assoc" = "OWNER" ] || { log "skip $repo#$pr — 작성자가 소유자가 아니다($assoc)"; continue; }

    m="$HARNESS_DIR/runs/$repo-pr$pr/meta.json"
    if [ -f "$m" ]; then
      # 3) 유효한 락
      lock_valid "$m" && { log "skip $repo#$pr — 락 점유 중"; continue; }
      # 4) 보류 상태 — 재개는 사람만 한다
      case "$(jq -r '.status' "$m")" in
        보류*) log "skip $repo#$pr — $(jq -r '.status' "$m")"; continue ;;
      esac
      # 5) 이미 Stage 1 리뷰를 게시했다
      [ "$(jq -r '[.stage1[]?.review_id | select(. != null)] | length' "$m")" = "0" ] \
        || { log "skip $repo#$pr — 이미 게시됨"; continue; }
      # 실패 반복 차단
      if [ "$(jq -r '.attempts // 0' "$m")" -ge "$MAX_ATTEMPTS" ]; then
        log "$repo#$pr — 연속 실패 $MAX_ATTEMPTS 회. 보류(실패) 로 멈춘다"
        "$PR_EVAL" status "$repo" "$pr" "보류(실패)" >/dev/null
        continue
      fi
    fi

    log "Stage 1 시작 — $repo#$pr"
    "$PR_EVAL" init "$repo" "$pr" >/dev/null
    "$PR_EVAL" attempt "$repo" "$pr" inc >/dev/null

    # Stage 1 부터 머지까지 체인 하나가 끝까지 돈다(scripts/chain.sh). 끝날 때까지 기다린다 —
    # 그래야 launchd 가 StartInterval 회차를 건너뛰어 이중 실행이 이중으로 막힌다.
    "$HARNESS_DIR/scripts/chain.sh" "$repo" "$pr" || log "체인이 멈췄다 — $repo#$pr (chain.state=$(jq -r '.chain.state // "?"' "$m" 2>/dev/null))"

    log "체인 종료 — $repo#$pr (status=$(jq -r '.status' "$m" 2>/dev/null || echo '?'))"
  done
}

case "${1:-}" in
  --once|"") run_once ;;
  *) echo "usage: watch.sh [--once]" >&2; exit 1 ;;
esac
