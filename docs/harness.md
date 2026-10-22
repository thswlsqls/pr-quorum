# CLAUDE.md — PR eval harness

올라온 PR 을 축별로 평가해 리뷰를 게시하는 하니스다. 이 파일은 **에이전트가 이 디렉터리에서 작업할 때** 먼저 읽는다. 설계 근거는 `docs/plans/20260820075900/tech-n-ai-pr-eval-harness/` 에 있다(추적되지 않는다).

## 0. 불변식 — 다른 무엇보다 먼저

1. **평가 대상은 PR 이다. 한 글자도 고치지 않는다.** 쓰기가 허용된 곳은 `runs/<repo>-pr<N>/` 아래뿐이다. `_memory/` 는 세션이 고치지 않는다 — 배운 것은 run 의 `learning-candidates.md` 에 후보로 적고, `scripts/dream.sh` 정리안을 사람이 PR 로 반영한다.
2. **GitHub 에 쓰는 것은 `scripts/pr-eval.sh` 뿐이다.** 세션은 `gh api` 로 직접 게시하지 않는다. 봇 토큰은 스크립트가 자기 안에서 읽는다. 직접 게시하면 사용자 계정으로 리뷰가 올라간다.
   저자 세션(`/pr-eval-author`)의 push 는 `scripts/author-push.sh`, 답글·PR 코멘트·본문 교체는 `scripts/author-reply.sh` 로만 한다. 이 둘은 사용자 계정으로 올라간다.
3. **위원·반박자·검증자는 아무 파일도 쓰지 않는다.** 결과를 텍스트로 반환하는 것이 전부다. `Bash` 는 `grep`·`wc`·`jq` 같은 조회에만 쓰고 리다이렉션·`sed -i`·`mv`·`rm` 을 쓰지 않는다.
4. **점수를 쓰지 않는다.** 등급 넷(치명·중대·경미·사소)만 쓴다.
5. 확인 못 한 것은 게시하지 않는다. `미확인 우려` 는 `runs/` 에만 남긴다.
6. 봇 토큰을 저장소에 커밋하지 않는다.

> - 봇이 코드를 못 고치게 하는 강제 수단은 **collaborator read 역할 하나뿐이다.** 토큰 스코프는 못 막는다 — `public_repo` 는 public 저장소의 코드 write 를 포함하고 두 저장소는 public 이다. 봇을 write 로 올리면 그 순간 이 토큰이 push 를 허용한다.
> - **`tools/pipeline/` 과 헷갈리지 않는다.** `tools/pipeline/` 의 impl·impl-validate 는 **PR 을 올릴 때**, `tools/pr-eval/` 은 **올라온 PR 을 평가할 때** 쓴다. 서로의 산출물을 읽지 않는다.
> - **제품 PR 에 `tools/pr-eval/` 변경을 섞지 않는다.** 섞으면 체인이 main 과 충돌해 멈춘다(PR #36 — 그때는 세션이 작업 트리의 `_memory/learnings.md` 를 직접 고쳤다). 하니스 변경은 따로 PR 을 낸다.
> - **`runs/` 와 `docs/` 만 gitignore 된다.** `docs/` 는 제출용 임시 초안이다. `runs/` 는 PR 마다 버려지는 작업 폴더라 추적하지 않는다 — 백업이 없고 다른 머신에서 clone 해도 따라오지 않는다. 규칙 문서·스크립트와 누적 자산(`_memory/learnings.md`)은 추적된다.

## 1. 파일 지도

| 파일 | 무엇 |
|---|---|
| `00-criteria.md` | 세 스테이지 공통 — 불변식 · 무효 조건 I-1~I-8 · 등급 · 출처 등급 · 유형별 조정표 · 코멘트 규격 · 게시 전 윤문 |
| `01-stages.md` | 스테이지별로 달라지는 것 · Phase 표 · SHA 고정 · `meta.json` · 종료 조건 · 게시 게이트 PG1~PG6 · 지표 · 신호표 |
| `02-judges.md` | 위원 공통 규칙 · 출력 형식 · 반박자 지시 · 문서 검증자 V1·V2·V3 |
| `03-risk.md` | 자동 머지 리스크 점수 — 점수표 · 등급별 처리 · 보정 기록 |
| `04-dream.md` | `scripts/dream.sh` 세션의 지시문 — 여러 run 의 학습 후보를 learnings 정리안으로 모은다 |
| `profiles/backend.md` · `frontend.md` | 리뷰 축 정의문과 위원 4인의 볼 것 / 보지 않을 것 / 등급 예시 / 측정 기준선 |
| `_memory/learnings.md` | PR 을 넘어 누적되는 학습. 세션은 읽기만 한다 |
| `_memory/human-labels.md` | 게시된 봇 코멘트를 사람이 맞음·틀림·과함으로 판정한 표. 세션은 쓰지 않는다 |
| `runs/<repo>-pr<N>/` | PR 하나의 작업 폴더. PR 마다 버려진다. `learning-candidates.md` 는 평가 세션이 적는 학습 후보다(저자 세션은 deny) |
| `runs/_dream/<시각>/proposal.md` | `dream.sh` 가 낸 learnings 정리안. 사람이 항목마다 `수용`·`거절`·`보류` 를 적는다 |
| `scripts/` | `pr-eval.sh` (유일한 게시 경로) · `watch.sh` (자동 트리거 · 머지된 PR 의 `pr-eval-*`·`pr-author-*` 워크트리 정리) · `chain.sh` (Stage 1 부터 머지까지) · `risk.jq` (리스크 점수) · `risk-audit.sh` (머지 뒤 후속 수정 추적) · `selftest.sh` (지난 산출물에 PG5·PG6 을 다시 돌린다. 게이트를 고친 뒤 한 번) · `install-entrypoints.sh` · `gh-get.sh` (세션이 GitHub 을 읽는 길. GET 만 된다) · `author-push.sh` (저자 세션이 PR 브랜치에 push 하는 유일한 길. force 없음) · `author-reply.sh` (저자 세션이 스레드 답글·PR 코멘트·PR 본문 교체를 하는 길. 본문은 `runs/` 아래 파일만) · `dream.sh` (run 들의 학습 후보를 모아 정리안을 낸다. 사람이 손으로 부른다) |
| `settings.json` · `author-settings.json` · `dream-settings.json` · `mcp.json` | 평가·저자·dream 세션의 도구 allow/deny · 체인 세션의 MCP 를 context7 하나로 묶는 설정(dream 세션은 MCP 없이 돈다) |

## 2. 세 스테이지

| Stage | 질문 | 트리거 |
|---|---|---|
| 1 review | 이 PR 에 무슨 결함이 있나 | 체인이 부른다. 단독으로는 `/pr-eval stage1 <저장소> <PR번호>` |
| 2 followup | 리뷰가 시킨 것을 했나 | 체인이 부른다. 단독으로는 `/pr-eval stage2 …` |
| 3 measured | 실측하면 리뷰가 버티나, 놓친 게 있나 | 체인이 부른다. 단독으로는 `/pr-eval stage3 …` |

**기본 동작은 머지까지다.** 봇을 리뷰어로 지정하면 watcher 가 `scripts/chain.sh <저장소> <PR번호>` 를 띄우고, 체인이
Stage 1 → 저자 반영(`/pr-eval-author`) → Stage 2 → Stage 3 → (저자 반영 → Stage 2)* → 머지 게이트 → **리스크 게이트** → `gh pr merge` 를 사람 없이 돈다.
머지는 봇이 아니라 체인이 사용자 gh 계정으로 한다. 머지 게이트는 세션이 쓴 기록만 믿지 않고, 봇이 지금 head 커밋에 남긴 리뷰가 GitHub 에 있는지 직접 확인한다. 리스크 점수(`03-risk.md`)가 `low` 가 아니거나, Stage 3 이 리뷰가 놓친 치명·중대(`P`)를 찾았으면 머지하지 않고 `chain.state=needs-human` 으로 멈춘다 —
점수표는 봇이 PR 코멘트로 남긴다. 체인은 `meta.json` 을 보고 멈춘 자리부터 이어 가므로 손으로 다시 불러도 된다.
체인이 띄운 헤드리스 세션마다 걸린 시간·비용·턴 수가 `meta.json` 의 `chain.sessions[]` 에 한 줄씩 쌓인다(`claude -p --output-format json` 의 `session_id`·`duration_ms`·`total_cost_usd`·`num_turns`·`is_error`, 그리고 `permission_denials` 건수와 거부된 도구 이름). 세션 전체 시간은 체인이 직접 잰 `wall_ms` 를 본다 — `duration_ms` 는 마지막 하위 에이전트 완료 알림 뒤 구간만 잰다(PR #52 실측). 결과를 JSON 으로 못 읽은 시도도 종료 코드와 함께 한 줄 남는다.
watcher 는 저장소 소유자가 연 PR(`authorAssociation=OWNER`)만 체인에 넣고, `chain.sh` 도 시작할 때 다시 확인한다 — 남의 PR 본문·diff 가 사용자 계정으로 push·머지하는 세션에 들어가지 않게 한다.
리뷰어를 다시 지정해도 Stage 1 을 다시 돌지 않는다. **Stage N 은 `meta.json` 에 Stage N−1 완료 기록이 있어야 돈다**(`lock` 이 막는다, 종료 코드 3).

## 2-1. 리뷰 축과 위원 4인 — 축 배정

**정의문의 권위는 `profiles/<프로파일>.md` §1 에 있다.** 아래는 배정 요약이고, 프롬프트에는 프로파일 원문을 그대로 복사해 싣는다.

| 위원 | 축 (backend) | 축 (frontend 에서 뜻이 다른 것) |
|---|---|---|
| J1 | `R-A` 설계 ↔ 구현 정합성 · `R-B` 데이터 정확성 | `R-B` 는 ID 를 number 로 파싱해 정밀도가 깨지는가 |
| J2 | `R-C` 동시성·원자성 · `R-F` 장애 격리 | `R-C` 는 상태 경합 |
| J3 | `R-D` 인터페이스 계약 · **`R-I` 보안(조건부)** · `R-E` 부하 적합성 | `R-E` 는 클라이언트 성능. `R-I` 는 backend 전용 |
| J4 | `R-G` 테스트 · `R-H` 유지보수성 | `R-H` 에 접근성 포함 · `R-G` 는 조건부 축 |

**backend 는 9축, frontend 는 8축이다** — `R-I` 는 backend 프로파일에만 있고, 그마저 조건부라 발동 조건은 `profiles/backend.md` §1 에 있다.

`J1`~`J4` 의 순서는 점수가 아니라 **중복 제거 우선순위**다 — 설계·데이터가 틀린 쪽이 나머지의 전제다. 축 기준의 출처(Google eng-practices · Conventional Comments)와 인용문은 `README.md` "기준의 출처" 에 있다.

## 3. `pr-eval.sh` 계약

| 서브커맨드 | 인자 | 하는 일 | 봇 토큰 |
|---|---|---|---|
| `sha` | `<repo> <pr>` | 현재 head SHA 를 출력 | 불필요 |
| `meta` | `<repo> <pr>` | `meta.json` 출력 | 불필요 |
| `precheck` | `<repo> <pr>` | 대형 PR 컷 판정 (파일 50 / 줄 3000) | 불필요 |
| `ranges` | `<repo> <pr> <sha>` | inline 앵커를 달 수 있는 줄 범위와, 줄 번호를 붙인 diff 본문(삭제 줄은 옛 파일 번호라 앵커 불가)을 낸다. **위원 프롬프트에 실어 diff 밖 앵커를 애초에 막는다** | 불필요 |
| `gate1` | `<repo> <pr> <sha> <comments.json>` | **PG1** — 앵커가 그 SHA 의 diff 안인지 줄 단위로 검사 | 불필요 |
| `init` | `<repo> <pr> [--reset-eval]` | `runs/<repo>-pr<N>/` 와 `meta.json` 생성·갱신. **기존 기록을 덮어쓰지 않는다.** Stage 1 이 이미 게시했으면 `base_sha`·`eval_sha` 도 보존한다 — Stage 1 을 새 head 로 다시 돌릴 때만 `--reset-eval` | 불필요 |
| `lock` | `<repo> <pr> <stage>` | 락 획득. pid 가 죽었거나 3시간이 지난 락은 지우고 가져온다 | 불필요 |
| `unlock` | `<repo> <pr>` | 락 해제 | 불필요 |
| `status` | `<repo> <pr> <값>` | `대기`·`진행`·`완료`·`보류(대형PR)`·`보류(실패)` 중 하나 | 불필요 |
| `attempt` | `<repo> <pr> inc\|reset` | Stage 1 연속 실패 횟수 | 불필요 |
| `post-review` | `<repo> <pr> <sha> <summary.md> <comments.json> [stage1\|stage2\|stage3]` | 리뷰 1건으로 요약과 inline 코멘트를 함께 게시. **게시 직전에 PG1·PG5 를 다시 돌린다** | 필요 |
| `reply` | `<repo> <pr> <comment_id> <body.md>` | 스레드 reply | 필요 |
| `patch` | `<repo> <pr> <comment_id> <body.md>` | 봇 자기 코멘트 본문 정정 | 필요 |
| `patch-review` | `<repo> <pr> <review_id> <body.md>` | 게시한 리뷰 **요약** 본문 정정. **닫힌 PR 에서는 404 다**(실측) — 열린 PR 에서만 쓴다 | 필요 |
| `comment` | `<repo> <pr> <body.md>` | PR 에 일반 코멘트 1건 (대형 PR 보류 알림 · 리스크 점수표) | 필요 |
| `risk` | `<repo> <pr>` | 현재 head 의 자동 머지 리스크 점수(`03-risk.md`). `meta.risk` 와 `outputs/risk.md` 에 남긴다. **`low` 가 아니면 종료 3** | 불필요 |
| `pg5` | `<summary.md> <comments.json> [stage1\|stage2\|stage3]` | **PG5** 기계 검사(praise · code/axis/body · 축 이름 · 요약 축 범례). `post-review` 가 게시 직전에 도는 것과 같은 함수다 | 불필요 |
| `snapshot` | `<outputs/<stage>[/round-NN]>` | 윤문 전 사본을 `pre-polish/` 에 뜬다. `runs/` 아래 폴더만 받는다 | 불필요 |
| `pg6` | `<outputs/<stage>[/round-NN]>` | **PG6** — `pre-polish/` 사본과 대조해 JSON 의 건수·필드·첫 줄, 마크다운의 앵커·수치가 그대로인지 본다 | 불필요 |

게시 서브커맨드(`post-review`·`reply`·`patch`·`patch-review`·`comment`)는 본문 파일로 `runs/` 아래 일반 파일만 받는다. 링크이거나 다른 경로면 종료 1 이다.

**종료 코드** — 0 성공 · 1 사용법·인자 오류 · 2 환경(봇 토큰 파일 없음, `meta.json` 이나 그 안의 `base_sha` 없음) · 3 게이트 위반(PG1 실패, PG5 필수 항목 누락, PG6 대조 실패, 대형 PR 컷, **스테이지 순서 위반**) · 4 GitHub API 또는 리스크 계산(`risk.jq`) 실패 · 5 락 점유 중.

## 4. 산출물 규격

산출물은 `runs/<repo>-pr<N>/outputs/<stage>/` 아래 둔다 (`<stage>` = `stage1`·`stage2`·`stage3`). **세 스테이지가 한 run 디렉터리를 쓰므로 스테이지별 폴더를 나눈다** — 한자리에 몰아 쓰면 Stage 3 위원이 origin(P/Q/N)을 가를 때 읽는 Stage 1 산출물이 덮여 사라진다(실측 — PR #33 Stage 3).

- `summary.md` — 리뷰 요약 본문. 그대로 `reviews.body` 가 된다.
- `comments.json` — inline 코멘트 배열.
- `replies/<코드>.md` · `patches/<코멘트id>.md` — Stage 2·3 의 스레드 reply 와 기존 코멘트 정정.
- `pre-polish/` — 위 전부의 윤문 전 사본. PG6 이 이것과 대조한다.

```jsonc
[
  { "path": "api/auth/src/main/java/.../AuthService.java",  // PR 기준 파일 경로
    "line": 42,              // 새 파일 기준 줄 번호. RIGHT 측이다
    "side": "RIGHT",         // 생략하면 RIGHT
    "body": "**C-01** `issue (blocking)` · R-B (데이터 정확성)\n\n…",
    "code": "C-01",          // 게시에는 안 보낸다. meta.json 기록용
    "axis": "R-B",           // 같음
    "grade": "치명" }        // 같음
]
```

**게시에 실리는 것은 `path`·`line`·`side`·`body` 넷뿐이다.** `code`·`axis`·`grade` 는 게시 후 `meta.json` 에 코멘트 id 와 함께 기록된다 — Stage 1 은 `stage1[].comments`, Stage 2 는 `stage2[-1].new_comments`, Stage 3 은 `stage3.comments`. Stage 2 는 `stage1[].comments[].id` 로 스레드를 찾는다.

줄 범위 앵커(`path:12-18`)나 파일 전체 앵커(`path:0`)는 inline 으로 못 쓴다. **요약 본문으로 옮긴다.** 위원 출력의 앵커 표기 규칙은 `02-judges.md` §2 에 있다.

**GitHub 에 올릴 텍스트는 게시 직전에 한 번 줄인다**(`01-stages.md` §3-4 윤문). `post-review` 뿐 아니라 `reply`·`patch` 본문도 같다. PG6 이 사본과 대조해 앵커·등급·축·첫 줄·수치가 그대로인지 확인한다.

## 5. 처음 한 번 할 것

### 5-1. 봇 계정

| 항목 | 값 |
|---|---|
| 계정 | `tech-n-ai-eval-bot` (일반 GitHub 계정) |
| 저장소 권한 | **collaborator read** — 리뷰 요청은 read 면 된다 |
| 토큰 | 봇 PAT, scope `public_repo` |
| 쓰는 범위 | 리뷰·코멘트 게시만. `event=COMMENT` 만 쓰고 승인·변경요청은 쓰지 않는다 |

봇이 승인·변경요청을 쓰면 머지 게이트를 쥐게 되고, 사람이 봇을 통과시키려고 리뷰를 왜곡한다.

### 5-2. 토큰 파일

```bash
mkdir -p ~/.config/pr-eval
cat > ~/.config/pr-eval/bot.env <<'ENV'
PR_EVAL_BOT_TOKEN=ghp_...
BOT_LOGIN=tech-n-ai-eval-bot
ENV
chmod 600 ~/.config/pr-eval/bot.env
```

**저장소에 커밋하지 않는다.** 세션은 이 파일을 읽지 않는다 — `pr-eval.sh` 가 자기 안에서 읽는다.

### 5-3. 진입점 설치

`.claude/` 는 gitignore 되므로 clone 한 머신마다 `tools/pr-eval/scripts/install-entrypoints.sh` 를 한 번 돌린다. `.claude/commands/pr-eval.md` · `.claude/commands/pr-eval-author.md` · `.claude/agents/pr-eval-judge.md` 를 재생성한다.
두 settings 파일과 명령 문서는 스크립트를 이 머신의 절대 경로(`/Users/m1/workspace/tech-n-ai/tech-n-ai-backend/...`)로 부른다. 다른 위치에 clone 했으면 아래처럼 하니스 안의 경로를 한 번에 바꾸고 이 스크립트를 다시 돌린다. 경로가 안 맞으면 `chain.sh` 와 이 스크립트가 종료 2 로 멈춘다.

```bash
NEW_WS="$(cd "$(git rev-parse --show-toplevel)/.." && pwd)"   # backend·frontend 저장소와 워크트리 폴더가 있는 곳
grep -rlF /Users/m1/workspace/tech-n-ai/ tools/pr-eval --exclude-dir=runs --exclude-dir=docs \
  | xargs sed -i '' "s|/Users/m1/workspace/tech-n-ai/|$NEW_WS/|g"
```

### 5-4. watcher 상시 실행 (선택)

`~/Library/LaunchAgents/com.tech-n-ai.pr-eval.plist` 에 아래를 두고 `launchctl load` 한다(최소 예시다. 지금 쓰는 plist 는 `/usr/bin/caffeinate -i` 로 감싸고 로그를 `~/Library/Logs/pr-eval-watch.log` 에 남긴다). 디버깅은 `scripts/watch.sh --once`.

```xml
<key>ProgramArguments</key>
<array>
  <string>/Users/m1/workspace/tech-n-ai/tech-n-ai-backend/tools/pr-eval/scripts/watch.sh</string>
</array>
<key>StartInterval</key><integer>60</integer>
<key>WorkingDirectory</key>
<string>/Users/m1/workspace/tech-n-ai/tech-n-ai-backend</string>
```

**지금 쓰는 plist 는 리스크 `low` 인 PR 을 자동으로 머지한다.** `EnvironmentVariables.PATH` 에 `~/.config/pr-eval/no-merge-bin` 을 두지 않는다(2026-10-08 뺐다).
자동 머지를 끄려면(`03-risk.md` "자동 머지를 끄는 기준") 이 경로를 PATH 맨 앞에 넣고 `launchctl bootout` 뒤 다시 `bootstrap` 한다.
그 안의 `gh` 래퍼가 `gh pr merge` 와 `gh api .../pulls/<N>/merge` 만 `exit 1` 로 거절해(나머지 명령은 `/opt/homebrew/bin/gh` 로 넘긴다),
체인은 머지 게이트를 지나도 `chain.state=blocked`("gh pr merge 실패")로 끝나고 로그에 `[no-merge] gh pr merge 차단` 이 찍힌다.

머신이 꺼져 있으면 안 돈다. 켜면 폴링이라 밀린 것부터 처리한다. **한 번에 한 건씩 순서대로 처리한다** — PR A 가 도는 동안 PR B 에 리뷰어를 걸어도 A 가 끝나야 뜬다.

**수동 호출에는 `--settings` 가 안 걸린다.** 헤드리스 세션은 호출줄에서 도구 권한을 강제하지만 사람이 여는 대화형 세션은 평소 설정으로 돈다. 같은 보증을 걸려면 수동 호출도 `claude --settings tools/pr-eval/settings.json --setting-sources project --permission-mode dontAsk --mcp-config tools/pr-eval/mcp.json --strict-mcp-config` 로 띄운다.

## 6. 실측으로 확인된 것 — 다시 실험하지 않는다

**2026-08-20, PR #31(임시 PR, 확인 후 폐기)과 PR #32 로 확인했다.**

| 무엇 | 결과 |
|---|---|
| 봇을 **read** collaborator 로 두고 리뷰어 지정 | **된다.** 단 GitHub 검색 인덱스 반영에 수 초 걸린다 — 지정 직후 `gh search prs --review-requested=` 는 빈 배열을 낸다. watcher 60초 폴링이 흡수한다 |
| `public_repo` PAT 으로 `POST /pulls/{N}/reviews` | **된다.** 작성자 `tech-n-ai-eval-bot`, state `COMMENTED` |
| 리뷰 제출 시 리뷰 요청 자동 해제 | **해제된다.** 게시 후 `reviewRequests` 가 빈 배열이 됐다 |
| diff 밖 앵커 | **거부한다. 그것도 리뷰 통째로.** `422 {"errors":["Line could not be resolved"]}`, 없는 파일은 `Path could not be resolved`. **PG1 이 이 하니스에서 가장 값싼 장치다** |
| `eval_sha` 가 head 보다 과거일 때 `line` 앵커 | **붙는다.** head 보다 두 커밋 앞선 SHA 로 게시했고 `line`·`original_line` 이 그대로 잡혔다. 기준 SHA 를 head 로 끌어올릴 필요가 없다 |
| `pulls/{N}/files` 를 PG1 기준으로 쓰면 | **깨진다.** head diff 에는 있고 `eval_sha` diff 에는 없는 줄을 통과시켜 게시가 422 가 된다. `compare/{base}...{기준SHA}` 를 쓴다 |
| `tools/pipeline/` 의 워크트리 정리가 `pr-eval-*` 를 지우는가 | **안 지운다.** 자기가 만든 `$WORKTREE_PATH` 하나만 지운다 (`tools/pipeline/impl-agent/agents/impl-implementer.md:98`) |
| 닫힌 PR 에서 코멘트 수정 | **인라인은 `PATCH` 로 고쳐진다. 리뷰 요약은 안 된다** — `PUT .../reviews/{id}` 가 404 다(같은 리뷰의 `GET` 은 200). 요약을 고치려면 PR 이 열려 있어야 한다 |
| `reply` · `patch` · `meta.json` 기록 | 전부 동작한다. `review_id`·코멘트 `id`·`code`/`axis`/`grade` 가 다 들어간다 |
| 리뷰어 재지정 시 무한 루프 | **안 빠진다.** watcher 가 `stage1.review_id` 를 보고 `skip — 이미 게시됨` 을 낸다 |
| 락 | 도구 호출을 넘어 유지된다. 죽은 pid 는 TTL 전에도 무효 |
| 종료 코드 · `init` 재실행 | 1 인자오류 · 2 토큰없음 · 3 게이트 · 4 API실패 · 5 락점유 전부 확인. `init` 재실행은 기존 `stage1` 기록을 보존한다 |

### 6-1. Stage 1 소요 시간 — 운영 전제

**PR #32(4파일 216줄)를 Stage 1 로 돌렸을 때 라운드 1 에만 약 50분, 라운드 2 까지 60분 이상 걸렸다.** 위원 4인·반박자·검증자 3인이 전부 별도 세션이고, 위원이 `./gradlew compileJava` 까지 돌리기 때문이다.

- watcher 는 한 번에 한 건씩 처리한다. PR 하나가 watcher 를 한 시간 넘게 잡는다.
- `meta.lock` TTL 3시간은 이 길이를 감안한 값이다. **줄이지 마라** — 정상 실행이 락을 잃는다.
- **라운드 상한은 5 다.** 5라운드를 다 돌면 TTL 3시간에 닿을 수 있다. 라운드당 시간을 `runs/<…>/rounds/` 에 적고, TTL 에 닿기 시작하면 상한이 아니라 TTL 을 올린다.
- 대형 PR 컷(파일 50 / 줄 3,000)은 이 시간이 선형으로 늘지 않게 막는 장치이기도 하다.

### 6-2. 헤드리스 세션 환경

| 무엇 | 결과 | 그래서 |
|---|---|---|
| `--settings` 가 `.claude/settings.local.json` 을 대체하는가 | **대체하지 않는다. 합쳐진다.** local 의 allow 가 헤드리스 세션에도 걸렸다(2026-10-04 재실측) | `chain.sh` 는 `--setting-sources project` 로 local 설정과 그 훅을 읽지 않게 한다. `user` 나 빈 값을 주면 `.claude/commands`·`agents` 도 안 읽혀 체인이 멈춘다 |
| 훅을 끌 수 있는가 | `hooks:{}` 로는 안 꺼진다. 두 settings 에 `disableAllHooks: true` 를 넣자 실측에서 `rtk` 훅 기록이 남지 않았다 | 헤드리스 세션의 명령이 `rtk …` 로 바뀌지 않는다 |
| deny 가 실제로 막는가 | **막는다.** `Bash(git config:*)` 를 deny 에 두면 `.git/config` 에 값이 남지 않는다 | 안전장치가 문서 약속이 아니라 실제로 동작한다 |
| MCP | `--settings` 로는 안 걸러진다. playwright·filesystem·memory 까지 전부 떴다 | `--mcp-config tools/pr-eval/mcp.json --strict-mcp-config` 로 context7 하나만 남긴다 |

> **도구 권한을 세션의 자기보고로 재지 마라.** 같은 명령에 실행/거부를 오락가락 답한다. **관측 가능한 부작용**(파일이 생겼는가, 설정 값이 남았는가)으로만 판정한다.

## 7. 이식 순서 — 어디까지 왔나

| 순서 | 할 일 | 완료 판정 | 상태 |
|---|---|---|---|
| 1 | 골격 + 규칙 문서 3종 | PR 1건에 Stage 1 라운드 1회를 손으로 돌려 산출물이 나온다 | 완료 |
| 2 | `profiles/backend.md` | 축 4개에 볼 것 / 보지 않을 것 / 등급 예시 / 측정 기준선 4칸이 다 있다 | 완료 |
| 3 | `scripts/pr-eval.sh` | 더미 PR 에 봇 계정으로 inline 코멘트 1건이 붙고, PG1 이 diff 밖 앵커를 잡아낸다 | 완료 — PR #31 에 실측 (§6) |
| 4 | Stage 1 을 실제 PR 에 게시 | 게시된 리뷰에 blocking·praise 가 있고 앵커가 전부 diff 안이다 | 완료 — PR #33, 코멘트 16건 |
| 5 | Stage 2 · Stage 3 | 스레드 reply 와 신규 코멘트가 붙고 `P` 목록이 나온다 | 완료 — PR #33, 판정 16건 · `P` 1건 |
| 6 | `profiles/frontend.md` + 프런트 PR 1건 | 같은 절차로 돈다 | 문서 초안만 |
