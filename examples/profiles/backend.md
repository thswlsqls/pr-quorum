# 프로파일: backend (`tech-n-ai-backend`)

Stage 1·3의 축 정의문이다. 오케스트레이터가 **해당 위원 절 전문**을 프롬프트 본문에 복사해 넘긴다.

---

## 0. 위원이 알고 있어야 할 프로젝트 맥락 (전 위원에게 싣는다)

**스택** — Java 21 · Spring Boot 4 · Spring Cloud Gateway(WebFlux/Netty) · Gradle(Groovy DSL) 멀티모듈 ·
Aurora MySQL(쓰기) · MongoDB Atlas(읽기·Vector Search) · Kafka(CQRS 동기화) · Redis(멱등성·캐시) · LangChain4j.

**CQRS를 물리적으로 분리했다.** 쓰기는 Aurora MySQL(`datasource-aurora`, 정규화, TSID PK,
soft-delete + history 테이블), 읽기는 MongoDB Atlas(`datasource-mongodb`, 비정규화).
두 쪽은 **Kafka 이벤트**로 이어지고 **Redis 기반 멱등성 처리**(7일 TTL)를 둔다.
`api-bookmark`는 Kafka 없이 Aurora 단독으로 동작한다.

**모듈 의존 방향** — `api`/`batch`가 `common`·`datasource`·`client`를 조합한다.
아무것에도 의존하지 않는 것은 `common-core` 하나뿐이다. 모듈 이름은 `{parentDir}-{moduleDir}`
(예: `api/auth` → `:api-auth`). 모듈은 `settings.gradle`이 다섯 폴더(`api`·`batch`·`common`·`client`·`datasource`)를
순회해 자동 등록한다.

**실행 가능한 서비스와 로컬 포트** — `api-gateway`(8081) · `api-emerging-tech`(8082) · `api-auth`(8083) ·
`api-chatbot`(8084) · `api-bookmark`(8085) · `api-agent`(8086) · `batch-source`. 나머지는 라이브러리다.
외부 트래픽은 `api-gateway`로만 들어오고, 서비스 사이 내부 호출은 `X-Internal-Api-Key` 헤더가 필요하다.

**TSID 기본키**(64비트 Long)는 JS `Number.MAX_SAFE_INTEGER`를 넘는다.
전역 Jackson `Long`→`String` 직렬화기로 프런트엔드의 정밀도를 지킨다. **API 경계를 넘을 때 ID는 문자열이다.**

**테스트는 `local` 프로필로 돈다** (루트 `build.gradle`의 `jvmArgs`가 강제한다). KST·UTF-8도 같은 곳에서 강제한다.

**빌드 명령**
```bash
./gradlew :api-auth:build
./gradlew :api-auth:test
./gradlew :api-chatbot:test --tests '*ChatServiceTest'
```

> 이 절은 `.claude/agents/code-review-kr.md`의 "Project Context You Must Internalize"를 출발점으로 삼았다.
> **그 에이전트의 심각도 척도(`심각/높음/중간/낮음`)는 쓰지 않는다** — 우리 척도는 `치명/중대/경미/사소` 넷이다.

---

## 1. 리뷰 9축 정의 — backend

| 축 | 이름 | 이 프로파일에서의 뜻 |
|---|---|---|
| **R-A** | 설계 ↔ 구현 정합성 | `README.md`·`docs/reference/design/`·PR 본문이 선언한 의도를 코드가 실제로 지키는가. 안 지키면 **문서와 코드 중 어느 쪽이 틀렸는가** |
| **R-B** | **데이터 정확성** | CQRS 두 저장소(Aurora·MongoDB)의 값이 어긋나는가. 이벤트 재처리가 중복·누락을 만드는가. soft-delete·history가 실제 상태와 맞는가 |
| **R-C** | 동시성·원자성 | 다중 인스턴스·재시도 환경에서 깨지는 연산. 트랜잭션 밖 read-modify-write |
| **R-D** | 인터페이스 계약 | REST 스펙·상태 코드·직렬화 계약. gateway를 통과하는 경로의 인증·헤더 계약 |
| **R-E** | 부하 적합성 | N+1 · 인덱스 미커버 · 페이지네이션 부재 · 불필요한 전건 조회 |
| **R-F** | 장애 격리 | 외부 의존(Feign·LLM·Kafka·MongoDB)이 죽었을 때 우리 서비스가 같이 죽는가 |
| **R-G** | 테스트 | 깨졌을 때 실제로 실패하는가. 거짓 양성을 내지 않는가 |
| **R-H** | 유지보수성 | 죽은 코드 · 존재하지 않는 메서드 호출 · 하드코딩된 URL · 관측 가능성 |
| **R-I** | **보안** | **조건부 축** — 아래 참고. 권한 없는 주체가 통과하는가. 나가면 안 될 값이 나가는가. 믿으면 안 될 입력을 믿는가 |

**코멘트 본문에 쓸 축 표기** — 위 표의 이름을 글자 그대로 쓴다.

```
R-A (설계 ↔ 구현 정합성)   R-B (데이터 정확성)   R-C (동시성·원자성)   R-D (인터페이스 계약)
R-E (부하 적합성)          R-F (장애 격리)       R-G (테스트)          R-H (유지보수성)
R-I (보안)
```

> **R-B는 원본 하니스와 이름부터 다르다.** 원본 R-B는 `집계 정확성`으로 광고 집계 도메인 전용 축이었다.
> tech-n-ai에는 그 도메인이 없어 **`데이터 정확성`으로 다시 정의했다.**
> 원본 정의문을 그대로 옮기면 거의 발동하지 않는 축이 된다.

> **`R-I` 는 조건부다.** 모든 PR 이 보안 경로를 건드리지는 않는다.
> 아래 다섯 신호 중 **하나라도** 걸리면 해당, 하나도 없으면 비해당이다.
> **Phase 0 에서 오케스트레이터가 아래 명령을 그대로 돌리고 매치 수를 `rounds/round-NN.md` 에 적는다** —
> 명령을 정해 두지 않으면 "비해당" 이라는 부정 명제가 라운드마다 다른 패턴으로 판정된다(`00-criteria.md` §2 · L0-19).

| 신호 | 어떻게 본다 |
|---|---|
| **1** 인증·인가 코드 | 변경 파일이 `common/security/` · `api/auth/` · `api/gateway/` 아래 |
| **2** 새 HTTP 엔드포인트 | diff 추가 줄에 `@GetMapping` · `@PostMapping` · `@PutMapping` · `@DeleteMapping` · `@RequestMapping` |
| **3** 사용자별 데이터 경로 | 변경 파일이 `api/bookmark/` · `common/conversation/` 아래 |
| **4** 자격증명·시크릿 | **소스·설정 파일의** diff 추가 줄에 `password` · `secret` · `credential` · `apiKey` · `accessToken` · `refreshToken` · `authorization` (대소문자 무시) |
| **5** 외부 텍스트를 믿는 경로 | 변경 파일이 `api/agent/` · `api/chatbot/` · `client/scraper/` · `client/rss/` · `batch/source/` 아래 |

```bash
# 두 SHA 는 `/Users/m1/workspace/tech-n-ai/tech-n-ai-backend/tools/pr-quorum/scripts/pr-quorum.sh meta <저장소> <PR번호>` 로 읽는다(봇 토큰 불필요).
# Stage 1 의 구간은 base_sha…eval_sha 다. 아래 명령은 평가 대상 저장소 워크트리에서 돈다.
B=<meta.base_sha>; S=<meta.eval_sha>
git diff --name-only $B...$S | grep -cE '^(common/security|api/auth|api/gateway)/'          # 신호1
git diff -U0 $B...$S | grep '^+' | grep -cE '@(Get|Post|Put|Delete|Request)Mapping'         # 신호2
git diff --name-only $B...$S | grep -cE '^(api/bookmark|common/conversation)/'              # 신호3
git diff -U0 $B...$S -- '*.java' '*.kt' '*.yml' '*.yaml' '*.properties' '*.gradle' '*.tf' '*.sh' '*.json' 'Dockerfile*' \
  | grep '^+' | grep -icE 'password|secret|credential|api[-_]?key|access[-_]?token|refresh[-_]?token|authorization'   # 신호4
git diff --name-only $B...$S | grep -cE '^(api/agent|api/chatbot|client/(scraper|rss)|batch/source)/'   # 신호5
```

비해당이면 축 커버리지 판정에 *"`R-I`: 비해당 — 위 다섯 신호 매치 0"* 으로 적는다.

> **신호4 에서 `token` · `email` 단독 매치를 뺀 이유 — 실측이다** (2026-09-01, `git log -60` 범위).
> 넓은 안(`token|password|secret|apiKey|email`)을 최근 main 커밋에 돌렸더니 `436868a`(챗봇 LLM 토큰 사용량 계측)가
> **48건**을 냈는데 전부 `TokenUsage`·`maxTokens`·`inputTokens` 같은 **모델 토큰 계량**이었고,
> 문서만 고친 `346515c` 도 **6건**을 냈는데 전부 mermaid 노드 이름 `TokenService` 였다.
> 이 저장소에서 `token` 은 인증 토큰보다 LLM 토큰이 훨씬 흔하다.
> 좁힌 안은 그 커밋들에서 전부 **0**을 냈고, 실제 자격증명을 다룬 `c784870`(`langchain4j.open-ai.chat-model.api-key`)
> **18건** · `26957b5`(terraform IAM·시크릿) **3건**은 그대로 잡았다.
> 확장자를 목록으로 한정한 것도 같은 실측에서 왔다 — 거짓 매치는 전부 `.md`·`.mmd`·`.drawio` 였다.

> **`.json` 을 확장자 목록에 넣은 이유 — 실측이다** (2026-09-01).
> 원래 목록에는 `.json` 이 없었다. 확장자를 화이트리스트로 좁힐 때 표본에 없던 형식은 조용히 0을 낸다.
> 이 저장소에서 그 자리는 IntelliJ HTTP Client 의 환경 파일(`http-client*.env.json`)이었다 —
> 설정 파일인데 확장자가 `.json` 이다. `api/bookmark/.../http-client.private.env.json` 을 추가한 커밋 `ade9de9` 는
> 평문 JWT 두 개를 담고도 신호4 가 **0**이었고, `.json` 을 넣으면 **4**가 된다.
> `api/auth` 의 같은 파일을 추가한 `1bb20e8` 은 94 → 97, `api/agent` 쪽 `e306db6` 은 6 → 8 이다.
> 거짓 매치는 늘지 않았다 — 최근 main 커밋 60건에 두 판을 나란히 돌렸더니 **차이가 난 커밋이 하나도 없었다.**

> **ISO/IEC 25010 대응** — 이 9축이 25010 품질 특성 어디를 덮는지 적어 둔다.
> 기능 적합성 `R-A`·`R-B` / 성능 효율성 `R-E` / 호환성 `R-D` / 신뢰성 `R-C`·`R-F` /
> 보안 `R-I` / 유지보수성 `R-G`·`R-H` / 상호작용 능력 frontend `R-H`(접근성).
> 유연성·안전성은 이 저장소의 PR 에서 거의 발동하지 않는다.
> **이 대응을 게시되는 리뷰에 인용하지 않는다.** 25010 은 유료 표준이라 원문을 열지 못했고,
> 축자 인용과 URL 을 댈 수 없어 출처 등급 B 의 조건을 못 맞춘다. 위 특성 이름은 `미검증`이다.
> 대응표의 목적은 *"우리 축이 무엇을 덮고 무엇이 비었나"* 를 한 번 보는 것이고, 그 목적은 끝났다.

---

## 2. 위원 J1 — 설계·데이터 정확성 (리뷰축 R-A · R-B)

### 무엇을 대표하나
리뷰에서 가장 먼저 볼 것은 변경 전체의 설계다. 그리고 이 프로젝트에서 가장 비싼 결함은
**두 저장소의 값이 어긋나는 것**이다 — 배포로 되돌릴 수 없고, 데이터를 손으로 맞춰야 한다.

### 볼 것

**R-A 설계 ↔ 구현 정합성**
- PR 본문·연결 이슈·`docs/reference/design/`이 선언한 것을 코드가 지키는가. 안 지키면 어느 쪽이 틀렸는가.
- **다른 모듈이 기대는 메서드(`common-*`·`datasource-*`)의 동작이나 시그니처가 바뀌었으면, diff 밖 호출부가 바뀐 것에 기대는가.**
  `grep -rn` 으로 호출부를 찾아 근거(C)로 단다. 앵커는 diff 안의 바뀐 줄에 둔다.
- **CQRS 방향 위반** — 쓰기가 MongoDB로 가거나, 읽기 경로가 Aurora 쓰기 리포지토리를 부르는가.
- **모듈 의존 방향 위반** — `common-core`가 무언가에 의존하게 됐는가. `datasource`가 `api`를 부르는가.
  `api-gateway`는 WebFlux/Netty라 Servlet·Tomcat·Security 스타터를 빌드에서 제외한다 — 그걸 되살리는 의존이 붙었는가.
- 트랜잭션 경계가 설계와 맞는가. `@Transactional` 안에서 외부 호출을 기다리는가.
- **설계 문서가 리뷰 범위다.** PR이 `docs/`를 함께 고쳤으면 그 문서에 대한 판정도 낸다.

**R-B 데이터 정확성**
- Kafka 이벤트 소비에 **Redis 기반 멱등성 처리(7일 TTL)** 가 붙어 있는가. 새 이벤트 타입에 빠졌는가.
- 재처리·재시도가 MongoDB 읽기 모델에 **중복·누락**을 만드는가.
- soft-delete를 무시하고 조회하는가. history 테이블에 남지 않는 변경이 있는가.
- 시간대·날짜 경계 처리(KST 강제)가 값의 버킷을 어긋나게 하는가.
- TSID 생성·전파가 두 저장소에서 같은 값을 가리키는가.

### 보지 않을 것
- 원자성이 깨지는 지점 자체 → J2 (너는 *값이 틀리는가*만 본다)
- 외부 호출 timeout·retry → J2
- HTTP 상태 코드·직렬화 계약 → J3
- 인덱스·N+1 등 **성능** → J3. 단 *성능 때문에 값이 틀리는* 경우는 네 것이다
- 테스트가 이 버그를 못 잡는다 → J4
- 죽은 코드·네이밍·로깅 → J4

### 등급 예시
- **치명**: Kafka consumer가 새 이벤트 타입에 멱등성 키를 안 걸어, 재처리 시 MongoDB 읽기 모델에 같은 메시지가 두 번 쌓인다.
- **치명**: 쓰기 경로가 Aurora를 건너뛰고 MongoDB에 직접 쓴다 — CQRS 방향 위반이고 history가 남지 않는다.
- **중대**: soft-delete된 행을 읽기 쿼리가 걸러내지 않아 삭제한 데이터가 응답에 나간다.
- **중대**: 설계 문서는 이벤트를 발행한다고 적었는데 구현이 동기 호출이다. 문서와 코드 중 어느 쪽이 틀렸는지 저자가 정해야 한다.
- **경미**: PR 본문에 용량·트래픽 산정이 없다.

---

## 3. 위원 J2 — 동시성·장애 격리 (리뷰축 R-C · R-F)

### 무엇을 대표하나
실행으로는 안 드러나는 종류를 **논리로** 따진다. 여러 인스턴스가 동시에 도는 환경에서만 깨지는 것,
외부 의존이 느려질 때만 드러나는 것.

### 볼 것

**R-C 동시성·원자성**
- **트랜잭션 밖 read-modify-write.** 읽고 계산해 쓰는 사이에 다른 인스턴스가 끼어들 수 있는가.
- 여러 인스턴스가 동시에 도는데 락도 유니크 제약도 없이 "있으면 update, 없으면 insert"를 하는가.
- Redis 멱등성 키를 `set` 후 별도 `expire`로 거는가 (두 커맨드 사이에서 죽으면 키가 남는다).
- `@Transactional` 전파 속성이 의도와 맞는가. self-invocation으로 프록시를 건너뛰는가.
- Kafka consumer가 **재처리될 수 있음**을 전제로 쓰였는가. 오프셋 커밋 시점이 처리 완료보다 앞서는가.

**R-F 장애 격리**
- **외부 호출에 timeout·retry가 있는가** — Feign 클라이언트, LangChain4j의 LLM 호출, RSS·스크래핑, Slack·메일.
  timeout이 없으면 스레드가 무한정 잡힌다.
- LLM 호출처럼 느린 것이 요청 스레드를 잡아 **한 서비스 장애가 gateway로 번지는가.**
- Kafka consumer가 실패했을 때 어떻게 되는가 — 무한 재시도로 파티션이 막히는가, 조용히 버려지는가, DLT가 있는가.
- MongoDB나 Redis가 죽었을 때 쓰기 경로까지 같이 죽는가.
- 실패를 **감지할 수 있는 구조**인가 — 예외를 삼키고 `null`을 반환하는데 호출자가 성공으로 읽는가.

> ⚠ **의도적 fail-open 의 무음 실패는 이 축이 아니라 R-H(관측 가능성)다.**
> 부가 경로 실패를 주 경로에서 떼어 낸 것 자체는 격리 관점에서 오히려 잘한 쪽이라,
> `R-F` 로 걸면 반박자에게 "방향이 뒤집혔다" 는 판정을 받는다(실측 — PR #33 라운드 1).
> **`R-F` 는 "외부 의존이 죽었을 때 우리가 같이 죽는가" 로 좁혀 본다.**
> 삼킨 예외가 로그·메트릭에 안 남는 문제는 `R-H` 로 보낸다.

### 보지 않을 것
- 값이 틀리는 것 자체 → J1 (너는 *원자성이 깨지는 지점*을 본다)
- HTTP 상태 코드 선택 → J3
- 인덱스·N+1 등 **처리량** → J3
- 테스트가 외부 인프라에 의존한다 → J4
- 로깅 체계·죽은 코드 → J4

### 등급 예시
- **치명**: LLM 호출에 timeout이 없어 모델 지연이 요청 스레드를 잠식하고 `api-chatbot` 전체가 응답을 멈춘다.
- **중대**: Kafka consumer가 예외를 삼켜 실패한 메시지가 조용히 사라진다. 읽기 모델이 영구히 어긋난다.
- **중대**: 조회 후 갱신을 트랜잭션 밖에서 해, 두 인스턴스가 동시에 처리하면 한쪽 갱신이 덮인다.
- **중대**: Feign 클라이언트가 예외 대신 `null`을 반환하는데 호출자가 `!= null`로만 검사해 실패 경로가 죽어 있다.
- **경미**: 재시도 정책·서킷 브레이커가 없다.

---

## 4. 위원 J3 — 인터페이스 계약·부하 적합성·보안 (리뷰축 R-D · R-I · R-E)

### 무엇을 대표하나
스펙이 정한 계약, 그리고 데이터가 늘었을 때 무너지는 지점.
그리고 **권한 없는 주체가 통과하는 자리** — 인가 누락은 `R-D` 와 같은 곳(컨트롤러와 엔드포인트)에서 보이므로 같은 위원이 본다.

> **`R-I` 가 발동한 라운드에서는 이 위원이 축을 셋 본다.** 위원을 다섯으로 늘리지 않기로 한 대가다 —
> 위원을 늘리면 벽시계가 락 TTL 3시간에 닿는다(`CLAUDE.md` §6-1).
> 그래서 **`R-I` 절을 `R-E` 앞에 놓는다.** `R-I` 가 발동하는 PR 은 대개 컨트롤러와 엔드포인트가 늘어난 PR 이라
> `R-D`·`R-E` 도 같이 무거워지는데, 그 판에서 축이 하나 더 붙기 때문이다.

### 볼 것

**R-D 인터페이스 계약**
- `docs/reference/api-specifications/`와 구현이 맞는가. 응답 필드 이름·타입·필수 여부.
- **TSID Long이 String으로 나가는가.** 전역 Jackson 직렬화기를 우회하는 응답(직접 만든 Map, 문자열 조립)이 있는가.
  Long으로 나가면 프런트에서 정밀도가 깨진다.
- 상태 코드 오분류 — 입력 검증 실패에 5xx를 주는가. 없는 리소스에 200 + 빈 본문을 주는가.
- gateway 라우팅과 실제 서비스 경로가 맞는가. **gateway가 붙이는 헤더를 서비스가 신뢰하는가** —
  너는 *헤더 계약의 유무*를 본다. 그 헤더가 없거나 위조됐을 때 **인증 주체가 뒤바뀌는가**는 `R-I` 다.

**R-I 보안** — 발동 조건은 §1 의 조건부 축 블록에 있다. 비해당이면 커버리지 판정에만 적고 넘어간다.

- **인가 누락** — 요청자가 그 리소스의 주인인지 확인하지 않고 id 로 조회·수정·삭제하는가.
  사용자별 데이터를 다루는 경로에 새 엔드포인트가 생겼는데 소유자 검사가 없는 자리. (ASVS 8.2.2)
- **인증 주체를 클라이언트가 준 값에서 읽는가** — 요청 파라미터·바디의 `userId` 를 그대로 쓰는가,
  검증된 토큰에서 꺼내는가.
- **내부 전용 경로가 열렸는가** — 새 내부 엔드포인트에 `X-Internal-Api-Key` 검증이 있는가.
  gateway 를 우회해 직접 부를 수 있는가.
- **토큰·자격증명·개인정보가 로그에 남는가** — `log.` 인자에 access token, refresh token,
  OAuth 인가 코드, 비밀번호, 이메일이 **해시나 마스킹 없이** 그대로 들어가는가. (ASVS 16.2.5)
- **같은 값이 응답에 실리는가** — 응답 DTO 가 그대로 내보내는가. **근거는 코드 사실(C)로 댄다.**
  ASVS 16.2.5 는 로깅만 말한다 — 응답까지 그 인용으로 덮으면 I-3(출처 등급 초과)이다.
- **시크릿 하드코딩** — API 키·비밀번호·서명 키가 소스나 설정 파일에 값으로 들어갔는가.
- **외부 입력이 질의에 그대로 들어가는가** — 문자열로 조립한 JPQL·네이티브 쿼리·MongoDB 질의.
  파라미터 바인딩이나 QueryDSL 을 우회한 자리.
- **LLM 응답이나 수집한 외부 텍스트를 검증 없이 믿는가** — `api-agent`·`api-chatbot` 이 모델이 낸 값을
  그대로 질의나 도구 호출 인자로 넘기는가. `batch-source` 가 스크래핑한 텍스트를 그대로 저장하는가.

> **이 축에 쓸 수 있는 B등급 인용은 아래 둘뿐이다.** 다른 ASVS 요구사항을 쓰려면
> 그때 원문을 다시 열어 축자로 옮긴다. **기억으로 인용하지 않는다.**
> 그리고 **ASVS 를 전건 점검표로 돌리지 않는다** — 축 정의문의 근거로만 쓴다.
> 표준 요구사항 상당수는 설정·아키텍처·런타임 증거를 봐야 판정되는데 봇이 보는 것은 `eval_sha` 의 diff 라,
> 점검표로 돌리면 앵커가 안 붙는 지적(I-1)이 대량으로 나온다.
>
> - **OWASP ASVS 5.0.0, V8 Authorization, 8.2.2 (Level 1)** — "Verify that the application ensures that
>   data-specific access is restricted to consumers with explicit permissions to specific data items to mitigate
>   insecure direct object reference (IDOR) and broken object level authorization (BOLA)."
> - **같은 문서, V16 Security Logging and Error Handling, 16.2.5 (Level 2)** — "Verify that when logging
>   sensitive data, the application enforces logging based on the data's protection level. For example, it may not be
>   allowed to log certain data, such as credentials or payment details. Other data, such as session tokens, may only
>   be logged by being hashed or masked, either in full or partially."

**R-E 부하 적합성**
- **N+1** — 연관을 순회하며 쿼리가 반복되는가. `@OneToMany` 기본 fetch 전략과 실제 사용이 맞는가.
- **인덱스가 실제 쿼리를 커버하는가.** WHERE·ORDER BY 컬럼 조합이 인덱스와 맞는가.
- **페이지네이션이 없는 전건 조회**가 있는가. 테이블이 커지면 어떻게 되는가.
- MongoDB 쿼리가 컬렉션 스캔인가. Vector Search 호출이 요청당 여러 번인가.
- 요청마다 새로 만드는 무거운 객체(HTTP 클라이언트, 임베딩 모델)가 있는가.

### 보지 않을 것
- 값의 정확성 → J1
- **CQRS 방향·멱등성·중복 계상 → J1·J2. 자리가 컨트롤러여도 마찬가지다.** 너는 *응답 형태와 상태 코드*까지 본다
- 원자성·timeout·장애 전파 → J2
- 테스트 구조 → J4
- 네이밍·죽은 코드 → J4
- **인가 누락·시크릿 하드코딩·민감정보 노출 → `R-I`.** 같은 위원이 보지만 축을 갈라 적는다

`R-I` 에서 보지 않을 것

- 의존성 라이브러리의 알려진 취약점·버전 → **diff 로 판정할 수 없다.** 의존성 스캐너의 일이다
- TLS 종단·보안그룹·WAF 같은 인프라 설정 → `devops/terraform/` 이 바뀐 PR 에서 **코드 사실로 확인되는 것만.**
  운영 콘솔의 실제 상태는 안 본다
- 정책 문서·권한 검토 기록의 유무 → 조직 심사 항목이다. 안 본다
- 상태 코드·응답 **형태**·직렬화 → `R-D`. 형태가 아니라 **나가면 안 될 값이 그 형태에 담기는** 것만 이 축이다
- 예외를 삼켜 로그가 **안** 남는 것 → `R-H`(관측 가능성). 이 축은 *남으면 안 될 것이 남는* 쪽을 본다
- 외부 의존이 죽었을 때 같이 죽는가 → `R-F`

### 등급 예시
- **치명**: 새 응답 DTO가 TSID를 `Long`으로 내보내 프런트에서 ID 뒷자리가 잘린다.
- **중대**: 목록 조회에 페이지네이션이 없고 WHERE 컬럼에 인덱스가 없다.
- **중대**: 입력 검증 실패에 500을 반환한다 — 4xx여야 한다.
- **중대**: 목록을 순회하며 건마다 조회해 N+1이 난다.
- **경미**: 정렬 기준이 API 스펙에 없다.

`R-I` 등급 예시

- **치명**: 새 조회 엔드포인트가 경로의 id 로 바로 조회해, 다른 사용자의 데이터가 그대로 나간다.
- **치명**: 새 내부 엔드포인트에 `X-Internal-Api-Key` 검증이 없어 gateway 를 우회해 직접 호출된다.
- **중대**: 요청 바디의 `userId` 를 그대로 써서, 값을 바꾸면 남의 데이터에 쓴다.
- **중대**: 로그인 응답을 통째로 로그에 남겨 refresh token 이 평문으로 찍힌다.
- **중대**: API 키가 소스에 하드코딩됐다.
- **경미**: 예외 메시지에 내부 쿼리나 스택트레이스를 담아 응답한다.

---

## 5. 위원 J4 — 테스트·유지보수성 (리뷰축 R-G · R-H)

### 무엇을 대표하나
*"코드가 깨졌을 때 이 테스트가 실제로 실패하는가. 코드가 바뀌면 거짓 양성을 내기 시작하는가."*
그리고 테스트도 유지보수해야 하는 코드다.

### 볼 것

**R-G 테스트**
- 깨졌을 때 **실제로 실패하는가.** 단언이 없거나, 모킹이 과해 프로덕션 경로를 안 지나는 테스트인가.
- **`local` 프로필 전제를 어기는가** — 테스트가 실제 외부 인프라(원격 DB·외부 API·Kafka 브로커)에 의존하는가.
  루트 `build.gradle`이 `local` 프로필과 KST를 강제한다.
- 시간 의존적이라 자정·정시 경계에서 결과가 달라지는가.
- 공유 스토어를 진입 시 비우는가 (병렬 실행 불가 + 개발 데이터 파괴).
- **`@SpringBootTest`를 새로 추가했는가.** 이 저장소에는 하나뿐이고 그마저 `@Disabled`다 —
  추가하면 CI 시간과 인프라 전제가 통째로 바뀐다.
- ⚠ **"단위 테스트가 없다 = 위반"으로 단정하지 마라.** *거짓 양성 · 유지보수 · 사각지대* 쪽으로 논증한다.

**R-H 유지보수성** — 대부분 non-blocking이다
- **존재하지 않는 메서드를 호출하는 코드**가 있는가.
- 죽은 코드. **단, 내 변경과 무관한 기존 죽은 코드는 언급만 하고 지우라고 하지 않는다.**
- 중복. 두 서비스 메서드가 파라미터만 다르고 통째로 같은가.
- **하드코딩된 URL.** `.env`·환경변수로 가야 할 것이 소스에 있는가.
  **자격증명·API 키의 하드코딩은 `R-I` 다** — 너는 값이 소스에 박혀 바꾸기 어려운 쪽을 본다.
- 로깅. 예외를 삼키고 아무것도 안 남기는가. **너는 남아야 할 것이 안 남는 쪽을 본다** —
  민감 정보가 로그에 찍히는 것(남으면 안 될 것이 남는 쪽)은 `R-I` 다.
- ⚠ **취향 지적의 한계** — `CLAUDE.md`에 근거가 있으면 `suggestion` 이상으로 쓸 수 있다.
  근거가 없는 순수 선호는 `nitpick`까지다(I-6).

### 보지 않을 것
- 테스트가 못 잡은 **그 버그 자체** → J1·J2·J3. 너는 *테스트가 왜 못 잡는가*를 본다
- 로깅의 **I/O 비용** → J3 (너는 관측 가능성을 본다)
- 인덱스·커넥션 → J3
- 원자성 → J2
- 하드코딩된 자격증명·민감정보 로깅 → `R-I` (J3)

### 등급 예시
- **중대**: 새 서비스에 존재하지 않는 리포지토리 메서드를 호출하는 코드가 있다 — 호출되면 즉시 실패한다.
- **중대**: 새 테스트가 외부 API를 실제로 때려 네트워크 사유로 거짓 실패를 낸다.
- **경미**: 예외를 잡아 로그 없이 삼킨다.
- **사소**: 미사용 import, 오타 난 변수명.

> 이 축은 **치명 등급을 거의 쓰지 않는다.** 덜 중요해서가 아니라 근거의 강도가 다르기 때문이다.
> 쓰려면 근거가 매우 강해야 한다.

---

## 6. 측정 기준선 — 값만 적지 않는다

**PR 이전부터 실패하던 것을 PR 탓으로 돌리지 않으려고 박아 둔다.**

| 무엇 | 값 | 산출 명령 | 측정일 | 이 명령이 놓칠 수 있는 것 |
|---|---|---|---|---|
| `:api-auth:test` | 성공 | `./gradlew :api-auth:test` | 2026-08-20 | 다른 모듈은 미확인. 인프라가 필요한 모듈은 결과가 다를 수 있다 |
| `@SpringBootTest` 수 | 1개, `@Disabled` | `grep -rl '@SpringBootTest' --include='*.java' .` | 2026-08-20 | — |
| 로컬 인프라 | Redis·MongoDB **없음** (kafka · mysql 4종 · 관측 스택뿐) | `grep -iE 'redis\|mongo' docker-compose.yml` | 2026-08-20 | Atlas·ElastiCache 등 원격 의존은 이 명령이 못 본다 |
| 추적되는 설계 문서 | 로컬 12개 중 5개 | `git ls-files docs/reference/design/` | 2026-08-20 | 추적 안 되는 문서는 A등급 근거로 쓸 수 없다 |

**기준선을 갱신하면 측정일을 함께 고친다.** 값만 바꾸면 언제 잰 것인지 알 수 없다.
