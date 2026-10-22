# config.sh — ~/.pr-quorum/config.json 을 읽는다. 값을 쓰는 스크립트가 source 한다.
# PR_QUORUM_HOME 은 환경 변수로 바꾸지 못하게 고정한다. 세션이 부르는 스크립트(author-push.sh 등)에
# 다른 config.json 을 물려 owner 를 바꾸지 못하게 하려는 것이다.
PR_QUORUM_HOME="$HOME/.pr-quorum"
cfg() { jq -r "$@" "$PR_QUORUM_HOME/config.json"; }   # cfg [jq 옵션...] <jq 필터>

# render_settings <플러그인 루트> <템플릿 이름> — templates/<이름> 의 자리표시자를 채워 $PR_QUORUM_HOME/<이름> 에 쓴다.
# 권한 규칙에는 변수 치환이 없어 실행할 때마다 만든다. /runs/** 같은 규칙은 이 파일이 놓인 ~/.pr-quorum/ 기준이 된다.
# __AUTHOR_WORKTREES__ 는 config.json 의 저장소마다 <path 의 부모>/<이름>-worktrees/pr-author-* 편집 허용 규칙으로 바꾼다
render_settings() {
  local wt
  wt="$(cfg -c '[.repos | to_entries[] | "Edit(/\(.value.path | sub("/+$"; "") | sub("/[^/]*$"; ""))/\(.key)-worktrees/pr-author-*/**)"]')"
  sed "s|__PLUGIN_ROOT__|$1|g" "$1/templates/$2" \
    | jq --argjson wt "$wt" '.permissions.allow |= [.[] | if . == "__AUTHOR_WORKTREES__" then $wt[] else . end]' \
    > "$PR_QUORUM_HOME/$2"
}
