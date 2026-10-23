# risk.jq — auto-merge risk score. Rules and rationale are in rules/03-risk.md.
# Input: the array from gh api repos/{o}/{r}/pulls/{N}/files. Arguments: $sha · $at
# Looks only at file paths and changed lines. No session judgment goes in — the same diff always gets the same score.

def doc:        test("\\.(md|png|jpe?g|gif|svg|drawio)$|(^|/)(docs|contents)/"; "i");
def test_file:  test("(^|/)src/test/|(^|/)__tests__/|Tests?\\.(java|kt)$|\\.(test|spec)\\.[jt]sx?$");
# Code that can have tests. .tf, .sql, and .sh have no test tooling in this repository, and their risk is already counted by "Hard-to-reverse changes"
def testable:   test("\\.(java|kt|ts|tsx|js|jsx|mjs|py)$");
def conf_file:  test("\\.(ya?ml|properties|json|env|tfvars|conf|xml)$|(^|/)\\.env[^/]*$");
# Lock files are counted by the dependency signal. They are generated, so they are left out of the scope line count
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
| ([$nd[] | select((.filename | test_file | not) and (.filename | lock_file | not)) | lines] | add // 0) as $size   # Test lines are not counted — otherwise writing more tests would raise the score
| [
    category("Security"; 30; [
      sig("Authentication/authorization code"; 15; $nd | hits((.filename | test_file | not) and (.filename | test(
        "(^|/)common/security/|(Security|Auth|Jwt|OAuth|Cors|Password|Permission|Role|Bcrypt|Principal|Credential|(Refresh|Access|Secure)Token|ApiKey)[A-Za-z0-9]*\\.(java|kt|ts|tsx)$|(^|/)api/gateway/.*/filter/"
        + "|(^|/)(middleware|proxy)\\.[jt]s$|(^|/)lib/(auth[^/]*|cookie-config)\\.ts$|(^|/)contexts/auth-context\\.tsx$|/api/bff/auth/")))),
      sig("credentials-secrets"; 30; $all | hits(.status != "removed" and (
        ((.filename | test("(^|/)\\.env(\\.[a-z]+)?$|\\.(pem|key|p12|jks)$")) and (.filename | test("example|template|sample") | not))
        or ((.filename | conf_file) and (added | test(
          "(?i)(password|passwd|secret([_-]?key)?|api[_-]?key|access[_-]?key|private[_-]?key|token)[\"']?\\s*[:=]\\s*[\"']?[^\\s\"'$<{]{8,}")))))),
      # This gate and the review harness itself. Rule documents (.md) are run-time rules the session follows, so the document exclusion does not apply. At 15 points this signal alone moves a PR out of low
      sig("Auto-merge gate/harness"; 15; $all | hits(.filename | test("^(skills|agents|rules|templates|\\.claude-plugin)/|^scripts/(pr-quorum|chain|watch|dream|selftest|risk-audit|gh-get|author-push|author-reply|config)\\.sh$|^scripts/risk\\.jq$"))),
      # Instructions and settings agent sessions follow, files CI runs, and build scripts ./gradlew runs. .md files count too, for the same reason as the harness
      sig("Agent instructions/CI/build scripts"; 15; $all | hits(.filename | test(
        "(^|/)(CLAUDE|AGENTS)\\.md$|(^|/)\\.claude/|(^|/)\\.github/workflows/|(^|/)Jenkinsfile[^/]*$|\\.gradle(\\.kts)?$|(^|/)gradle\\.properties$|(^|/)gradle/wrapper/|(^|/)gradlew(\\.bat)?$"))),
      sig("Dependencies"; 10; $nd | hits(.filename | test(
        "\\.gradle(\\.kts)?$|libs\\.versions\\.toml$|gradle-wrapper\\.properties$|(^|/)package(-lock)?\\.json$|pnpm-lock\\.yaml$|yarn\\.lock$|\\.terraform\\.lock\\.hcl$"))),
      sig("Infrastructure permissions (IAM)"; 15; $nd | hits((.filename | test("\\.tf$")) and ((.patch // "") | test("aws_iam_|\"Action\"|actions\\s*=|iam:"))))
    ]),
    category("Breaking changes"; 25; [
      sig("API contract"; 15; $nd | hits((.filename | test_file | not) and (.filename | test(
        "(^|/)controller/|Controller\\.(java|kt)$|(^|/)dto/(request|response)/|(Request|Response)\\.(java|kt)$|\\.proto$|openapi")))),
      sig("DB schema (entities/documents)"; 15; $nd | hits((.filename | test_file | not) and (.filename | test(
        "(^|/)entity/|Entity\\.(java|kt)$|(^|/)document/")))),   # A *Document suffix would catch non-DB classes such as the web search result record (WebSearchDocument)
      sig("Configuration/environment variables"; 10; $nd | hits(.filename | test(
        "(^|/)application[^/]*\\.(ya?ml|properties)$|\\.env\\.(example|template|sample)$|docker-compose[^/]*\\.ya?ml$|(^|/)Dockerfile|(^|/)Jenkinsfile[^/]*$|(^|/)\\.github/workflows/|next\\.config\\.[mc]?[jt]s$"))),
      sig("Event contract"; 10; $nd | hits(.filename | test("(^|/)common/kafka/|Event\\.(java|kt)$")))
    ]),
    category("Hard-to-reverse changes"; 15; [
      sig("DB migration"; 15; $nd | hits(.filename | test("(^|/)(db/)?migrations?/|\\.sql$|changelog[^/]*\\.(xml|ya?ml)$"))),
      sig("Infrastructure (Terraform)"; 15; $nd | hits(.filename | test("\\.(tf|tfvars)$")))
    ]),
    category("Tests"; 15; [
      sig("Production code changed with no test changes"; 15;
        if $prod > 0 and $tests == 0 then [$nd[] | select((.filename | test_file | not) and (.filename | testable)) | .filename] else [] end)
    ]),
    category("Scope"; 15; [
      {name: "\($size) changed lines excluding tests and docs",
       points: (if $size <= 100 then 0 elif $size <= 300 then 5 elif $size <= 800 then 10 else 15 end),
       hits: []}
    ])
  ] as $cats
| ([$cats[].points] | add) as $score
# A plaintext secret is not a risk to add up and compare — it is a change that must not be merged. Raise it to critical regardless of score
| ([$cats[].signals[] | select(.name == "credentials-secrets") | .hits[]] | length > 0) as $secret
| {sha: $sha, at: $at, score: $score,
   level: (if $secret then "critical"
           elif $score < 15 then "low" elif $score < 40 then "medium" elif $score < 70 then "high" else "critical" end),
   override: (if $secret then "Plaintext secret found, so critical regardless of score" else null end),
   size: $size, categories: $cats}
