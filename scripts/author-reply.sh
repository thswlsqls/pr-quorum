#!/usr/bin/env bash
# author-reply.sh — 저자 세션이 리뷰 스레드에 답글 1건을 다는 경로. 사용자 gh 계정으로 올라간다.
# 셋째 인자가 comment 면 PR 코멘트 1건, body 면 PR 본문 교체다. gh pr comment/edit --body-file 도 아무 파일이나 올리므로 여기로 모은다.
# 세션 권한에서 `gh api` 를 막았으므로 쓰기는 이 경로 하나로만 연다. 본문 파일은 runs/ 아래 것만 받는다 —
# `-F body=@<파일>` 은 아무 파일이나 읽어 공개 코멘트로 올리므로, 토큰 파일을 답글로 내보내지 못하게 한다.
set -euo pipefail

OWNER=thswlsqls  # 세션이 부르는 스크립트라 환경 변수로 바꾸지 못하게 고정한다
RUNS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../runs" && pwd -P)"

die() { echo "author-reply.sh: $1" >&2; exit 1; }

[ $# -eq 4 ] || die "usage: author-reply.sh <repo> <pr> <comment_id|comment|body> <body_file>"
REPO="$1"; PR="$2"; ID="$3"; BODY="$4"
case "$REPO" in tech-n-ai-backend|tech-n-ai-frontend) ;; *) die "모르는 저장소: $REPO" ;; esac
[[ "$PR" =~ ^[0-9]+$ ]] || die "PR 번호가 숫자가 아니다: $PR"
[[ "$ID" =~ ^([0-9]+|comment|body)$ ]] || die "셋째 인자는 코멘트 id·comment·body 중 하나다: $ID"
[ -f "$BODY" ] && [ ! -L "$BODY" ] || die "본문 파일이 없거나 링크다: $BODY"
body_dir="$(cd "$(dirname "$BODY")" && pwd -P)"
case "$body_dir/" in "$RUNS"/*) ;; *) die "본문 파일은 $RUNS 아래에 둔다: $BODY" ;; esac

FILE="$body_dir/$(basename "$BODY")"
case "$ID" in
  comment) gh pr comment "$PR" --repo "$OWNER/$REPO" --body-file "$FILE" ;;
  body)    gh pr edit "$PR" --repo "$OWNER/$REPO" --body-file "$FILE" ;;
  *)       gh api --method POST "repos/$OWNER/$REPO/pulls/$PR/comments/$ID/replies" -F "body=@$FILE" ;;
esac
