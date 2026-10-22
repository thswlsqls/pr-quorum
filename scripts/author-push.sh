#!/usr/bin/env bash
# author-push.sh — 저자 세션이 반영 커밋을 올리는 경로. PR 워크트리 안에서 부른다.
# PR 의 head 브랜치를 GitHub 에서 읽어, 지금 HEAD 를 그 브랜치에만 force 없이 push 한다.
# refspec·플래그를 받지 않으므로 세션이 main push·force push·다른 브랜치 push 를 고를 수 없다(감사 S-4).
set -euo pipefail

OWNER=thswlsqls  # 세션이 부르는 스크립트라 환경 변수로 바꾸지 못하게 고정한다

die() { echo "author-push.sh: $1" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: author-push.sh <repo> <pr>"
REPO="$1"; PR="$2"
case "$REPO" in tech-n-ai-backend|tech-n-ai-frontend) ;; *) die "모르는 저장소: $REPO" ;; esac
[[ "$PR" =~ ^[0-9]+$ ]] || die "PR 번호가 숫자가 아니다: $PR"

# fork 에서 온 PR 이면 같은 이름의 원본 저장소 브랜치로 push 하게 되므로 받지 않는다
cross="$(gh pr view "$PR" --repo "$OWNER/$REPO" --json isCrossRepository --jq .isCrossRepository)"
[ "$cross" = "false" ] || die "fork 에서 온 PR 이다"
head="$(gh pr view "$PR" --repo "$OWNER/$REPO" --json headRefName --jq .headRefName)"
default="$(gh repo view "$OWNER/$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)"
current="$(git symbolic-ref --short HEAD 2>/dev/null)" || die "HEAD 가 브랜치가 아니다(detached)"

[ -n "$head" ] || die "PR #$PR 의 head 브랜치를 못 읽었다"
[ "$head" != "$default" ] || die "head 브랜치가 기본 브랜치($default)다"
[ "$current" = "$head" ] || die "지금 브랜치($current)가 PR head($head)와 다르다"
# 워크트리의 origin 이 이 저장소여야 한다 — 다른 저장소 워크트리에서 부르면 엉뚱한 곳에 브랜치가 생긴다
# git push 는 push URL 이 여럿이면 전부에 보낸다. 하나뿐이고 이 저장소여야 한다
urls="$(git remote get-url --push --all origin)"
[ "$(wc -l <<<"$urls")" -eq 1 ] && [[ "$urls" =~ ^(https://|git@)github\.com[:/]$OWNER/$REPO(\.git)?$ ]] \
  || die "origin push URL 이 $OWNER/$REPO 하나가 아니다"

# + 를 붙이지 않은 refspec 이라 fast-forward 가 아니면 GitHub 이 거절한다
git push origin "HEAD:refs/heads/$head"
