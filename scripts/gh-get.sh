#!/usr/bin/env bash
# gh-get.sh — 헤드리스 세션이 GitHub API 를 읽는 경로. `gh api` 와 같은 인자를 받지만 GET 만 보낸다.
# 세션 권한에서 `gh api` 를 통째로 막고 이것만 허용한다. 인자 자리를 보는 deny 규칙은 순서·붙여 쓰기로 빠져나간다(감사 S-1).
# 메서드·본문·요청 대상을 바꾸는 인자는 거절하고, 나머지는 `gh api --method GET` 에 넘긴다. GET 에서 -f 는 쿼리 문자열이 된다.
set -euo pipefail

reject() { echo "gh-get.sh: 읽기 전용이라 '$1' 을 받지 않는다" >&2; exit 1; }

for a in "$@"; do
  case "$a" in
    # -X/--method 는 마지막 값이 이기므로 앞에 붙인 --method GET 을 덮는다. -F 는 @파일 로 로컬 파일을 읽어 보낸다
    -X*|--method|--method=*|--input|--input=*|-F*|--field|--field=*) reject "$a" ;;
    # 다른 호스트나 전체 URL 로 보내지 않는다. graphql 은 POST 로만 돈다
    --hostname|--hostname=*|*://*|graphql) reject "$a" ;;
    *[Mm]ethod-[Oo]verride*) reject "$a" ;;
    # 값 없는 짧은 옵션 -i 뒤에 붙인 -iXPOST · -iFbody=@x
    -i*) [[ "$a" =~ ^-i+[XF] ]] && reject "$a" ;;
  esac
done

exec gh api --method GET "$@"
