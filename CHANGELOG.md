# 변경 기록

## 0.1.1

- `pr-quorum.sh` 가 `config.json` 의 `repos` 에 없는 저장소 이름과 16진수 7~40자가 아닌 SHA 를 GitHub 를 부르기 전에 종료 1 로 거절한다.

## 0.1.0

첫 공개판이다. tech-n-ai-backend 의 `tools/pr-eval/` 에서 돌던 리뷰 하니스를 Claude Code 플러그인으로 옮겼다.

공개 전에 두 가지를 고쳤다.

- `pr-quorum.sh` 의 `reply`·`patch`·`patch-review` 가 숫자가 아닌 코멘트·리뷰 id 를 받으면 GitHub 를 부르기 전에 종료 1 로 끝낸다.
- 봇이 남기는 리스크 점수표 코멘트가 `auto_merge` 설정에 맞춰 "자동 머지"와 "사람이 머지" 중 하나로 안내하고, 규칙 문서는 이 저장소 링크로 가리킨다.
