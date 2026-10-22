# config.sh — ~/.pr-quorum/config.json 을 읽는다. 값을 쓰는 스크립트가 source 한다.
# PR_QUORUM_HOME 은 환경 변수로 바꾸지 못하게 고정한다. 세션이 부르는 스크립트(author-push.sh 등)에
# 다른 config.json 을 물려 owner 를 바꾸지 못하게 하려는 것이다.
PR_QUORUM_HOME="$HOME/.pr-quorum"
cfg() { jq -r "$@" "$PR_QUORUM_HOME/config.json"; }   # cfg [jq 옵션...] <jq 필터>
