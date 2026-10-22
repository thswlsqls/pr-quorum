# risk.jq — 자동 머지 리스크 점수. 규칙과 근거는 tools/pr-eval/03-risk.md 에 있다.
# 입력: gh api repos/{o}/{r}/pulls/{N}/files 의 배열. 인자: $sha · $at
# 파일 경로와 변경 줄만 본다. 세션의 판단은 들어가지 않는다 — 같은 diff 는 늘 같은 점수다.

def doc:        test("\\.(md|png|jpe?g|gif|svg|drawio)$|(^|/)(docs|contents)/"; "i");
def test_file:  test("(^|/)src/test/|(^|/)__tests__/|Tests?\\.(java|kt)$|\\.(test|spec)\\.[jt]sx?$");
# 테스트를 붙일 수 있는 코드. .tf·.sql·.sh 는 이 저장소에 테스트 수단이 없고, 위험은 "되돌리기 어려운 변경" 이 이미 센다
def testable:   test("\\.(java|kt|ts|tsx|js|jsx|mjs|py)$");
def conf_file:  test("\\.(ya?ml|properties|json|env|tfvars|conf|xml)$|(^|/)\\.env[^/]*$");
# lock 파일은 의존성 신호가 따로 센다. 자동 생성이라 범위 줄 수에는 넣지 않는다
def lock_file:  test("(^|/)package-lock\\.json$|pnpm-lock\\.yaml$|yarn\\.lock$|\\.terraform\\.lock\\.hcl$");
def lines:      .additions + .deletions;
def added:      (.patch // "") | split("\n") | map(select(startswith("+") and (startswith("+++") | not))) | join("\n");

def hits(f):    [ .[] | select(f) | .filename ];
def sig($name; $pts; $hits): {name: $name, points: (if ($hits | length) > 0 then $pts else 0 end), hits: $hits};
def category($title; $max; $sigs): {title: $title, max: $max, signals: $sigs,
                                    points: ([([$sigs[].points] | add), $max] | min)};

. as $all
| ($all | map(select(.filename | doc | not))) as $nd
| ([$nd[] | select((.filename | test_file | not) and (.filename | testable)) | lines] | add // 0) as $prod
| ([$nd[] | select(.filename | test_file) | lines] | add // 0) as $tests
| ([$nd[] | select((.filename | test_file | not) and (.filename | lock_file | not)) | lines] | add // 0) as $size   # 테스트 줄은 세지 않는다 — 세면 테스트를 쓸수록 점수가 오른다
| [
    category("보안"; 30; [
      sig("인증·인가 코드"; 15; $nd | hits((.filename | test_file | not) and (.filename | test(
        "(^|/)common/security/|(Security|Auth|Jwt|OAuth|Cors|Password|Permission|Role|Bcrypt|Principal|Credential|(Refresh|Access|Secure)Token|ApiKey)[A-Za-z0-9]*\\.(java|kt|ts|tsx)$|(^|/)api/gateway/.*/filter/"
        + "|(^|/)(middleware|proxy)\\.[jt]s$|(^|/)lib/(auth[^/]*|cookie-config)\\.ts$|(^|/)contexts/auth-context\\.tsx$|/api/bff/auth/")))),
      sig("자격증명·비밀값"; 30; $all | hits(.status != "removed" and (
        ((.filename | test("(^|/)\\.env(\\.[a-z]+)?$|\\.(pem|key|p12|jks)$")) and (.filename | test("example|template|sample") | not))
        or ((.filename | conf_file) and (added | test(
          "(?i)(password|passwd|secret([_-]?key)?|api[_-]?key|access[_-]?key|private[_-]?key|token)[\"']?\\s*[:=]\\s*[\"']?[^\\s\"'$<{]{8,}")))))),
      # 이 게이트와 리뷰 하니스 자체. 규칙 문서(.md)도 세션이 따르는 실행 규칙이라 문서 제외를 하지 않는다. 15점이면 혼자서도 low 를 벗어난다
      sig("자동 머지 게이트·하니스"; 15; $all | hits(.filename | test("(^|/)tools/pr-eval/"))),
      # 에이전트 세션이 따르는 지시와 설정, CI 가 실행하는 파일, ./gradlew 가 실행하는 빌드 스크립트. 하니스와 같은 이유로 .md 도 센다
      sig("에이전트 지시·CI·빌드 스크립트"; 15; $all | hits(.filename | test(
        "(^|/)(CLAUDE|AGENTS)\\.md$|(^|/)\\.claude/|(^|/)\\.github/workflows/|(^|/)Jenkinsfile[^/]*$|\\.gradle(\\.kts)?$|(^|/)gradle\\.properties$|(^|/)gradle/wrapper/|(^|/)gradlew(\\.bat)?$"))),
      sig("의존성"; 10; $nd | hits(.filename | test(
        "\\.gradle(\\.kts)?$|libs\\.versions\\.toml$|gradle-wrapper\\.properties$|(^|/)package(-lock)?\\.json$|pnpm-lock\\.yaml$|yarn\\.lock$|\\.terraform\\.lock\\.hcl$"))),
      sig("인프라 권한(IAM)"; 15; $nd | hits((.filename | test("\\.tf$")) and ((.patch // "") | test("aws_iam_|\"Action\"|actions\\s*=|iam:"))))
    ]),
    category("호환성 깨짐"; 25; [
      sig("API 계약"; 15; $nd | hits((.filename | test_file | not) and (.filename | test(
        "(^|/)controller/|Controller\\.(java|kt)$|(^|/)dto/(request|response)/|(Request|Response)\\.(java|kt)$|\\.proto$|openapi")))),
      sig("DB 스키마(엔티티·도큐먼트)"; 15; $nd | hits((.filename | test_file | not) and (.filename | test(
        "(^|/)entity/|Entity\\.(java|kt)$|(^|/)document/")))),   # *Document 접미어는 웹 검색 결과 record(WebSearchDocument) 같은 비DB 클래스를 잡는다
      sig("설정·환경 변수"; 10; $nd | hits(.filename | test(
        "(^|/)application[^/]*\\.(ya?ml|properties)$|\\.env\\.(example|template|sample)$|docker-compose[^/]*\\.ya?ml$|(^|/)Dockerfile|(^|/)Jenkinsfile[^/]*$|(^|/)\\.github/workflows/|next\\.config\\.[mc]?[jt]s$"))),
      sig("이벤트 계약"; 10; $nd | hits(.filename | test("(^|/)common/kafka/|Event\\.(java|kt)$")))
    ]),
    category("되돌리기 어려운 변경"; 15; [
      sig("DB 마이그레이션"; 15; $nd | hits(.filename | test("(^|/)(db/)?migrations?/|\\.sql$|changelog[^/]*\\.(xml|ya?ml)$"))),
      sig("인프라(Terraform)"; 15; $nd | hits(.filename | test("\\.(tf|tfvars)$")))
    ]),
    category("테스트"; 15; [
      sig("운영 코드만 바뀌고 테스트 변경 없음"; 15;
        if $prod > 0 and $tests == 0 then [$nd[] | select((.filename | test_file | not) and (.filename | testable)) | .filename] else [] end)
    ]),
    category("범위"; 15; [
      {name: "테스트·문서를 뺀 변경 \($size)줄",
       points: (if $size <= 100 then 0 elif $size <= 300 then 5 elif $size <= 800 then 10 else 15 end),
       hits: []}
    ])
  ] as $cats
| ([$cats[].points] | add) as $score
# 평문 비밀값은 더해서 비교할 위험이 아니라 머지하면 안 되는 변경이다. 점수와 상관없이 critical 로 올린다
| ([$cats[].signals[] | select(.name == "자격증명·비밀값") | .hits[]] | length > 0) as $secret
| {sha: $sha, at: $at, score: $score,
   level: (if $secret then "critical"
           elif $score < 15 then "low" elif $score < 40 then "medium" elif $score < 70 then "high" else "critical" end),
   override: (if $secret then "평문 비밀값이 있어 점수와 상관없이 critical" else null end),
   size: $size, categories: $cats}
