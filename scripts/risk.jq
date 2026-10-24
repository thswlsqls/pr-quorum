# risk.jq — auto-merge risk score. Rules and rationale are in rules/03-risk.md.
# Input: the array from gh api repos/{o}/{r}/pulls/{N}/files. Arguments: $sha · $at
# Looks only at file paths and changed lines. No session judgment goes in — the same diff always gets the same score.

def doc:        test("\\.(md|png|jpe?g|gif|svg|drawio)$|^(docs|contents)/"; "i");   # Only top-level doc folders. A code path such as .../contents/auth/ is not a document
def test_file:  test("(^|/)src/test/|(^|/)__tests__/|Tests?\\.(java|kt)$|\\.(test|spec)\\.[jt]sx?$|(^|/)test_[^/]*\\.py$|_test\\.(py|go)$");
# Code that can have tests. .tf, .sql, and .sh have no test tooling in this repository, and their risk is already counted by "Hard-to-reverse changes".
# .rs is left out — Rust unit tests sit in the same file, so a path cannot tell whether tests changed
def testable:   test("\\.(java|kt|ts|tsx|js|jsx|mjs|py|go)$");
def conf_file:  test("\\.(ya?ml|properties|json|env|tfvars|conf|xml|toml|ini|cfg)$|(^|/)\\.env[^/]*$|(^|/)\\.npmrc$");
# Lock files are counted by the dependency signal. They are generated, so they are left out of the scope line count.
# poetry.lock, uv.lock, Cargo.lock, and go.sum are not added here — that would lower the scope points of PRs already scored
def lock_file:  test("(^|/)package-lock\\.json$|pnpm-lock\\.yaml$|yarn\\.lock$|\\.terraform\\.lock\\.hcl$");
def lines:      .additions + .deletions;
def added:      (.patch // "") | split("\n") | map(select(startswith("+") and (startswith("+++") | not))) | join("\n");

def hits(f):    [ .[] | select(f) | .filename ];
def sig($name; $pts; $hits): {name: $name, points: (if ($hits | length) > 0 then $pts else 0 end), hits: $hits};
def category($title; $max; $sigs): {title: $title, max: $max, signals: $sigs,
                                    points: ([([$sigs[].points] | add), $max] | min)};

# A rename or copy also counts at its old path, so moving a file out of a sensitive path does not drop the signal.
# The old path gets 0 lines (scope and test lines stay unchanged) and status "removed" (no secret check on content that is not there)
map(., (select(.previous_filename != null and .previous_filename != .filename)
        | {filename: .previous_filename, status: "removed", additions: 0, deletions: 0})) as $all
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
      sig("Auto-merge gate/harness"; 15; $all | hits(.filename | test("^(skills|agents|rules|templates|\\.claude-plugin)/|^scripts/(pr-quorum|chain|watch|dream|selftest|risk-audit|gh-get|author-push|author-reply|config|doctor|token-scan|build-sandbox)\\.sh$|^scripts/risk\\.jq$|^mcp\\.json$"))),
      # Instructions and settings agent sessions follow (including MCP config), files CI runs (including composite actions), container build and compose files (RUN runs on the next image build), git hooks, CODEOWNERS, and build scripts and config files the build or test tool runs (Gradle, Maven, Python packaging, Make, Node). .md files count too, for the same reason as the harness
      sig("Agent instructions/CI/build scripts"; 15; $all | hits(.filename | test(
        "(^|/)(CLAUDE(\\.local)?|AGENTS)\\.md$|(^|/)\\.claude/|(^|/)\\.github/workflows/|(^|/)Jenkinsfile[^/]*$|\\.gradle(\\.kts)?$|(^|/)gradle\\.properties$|(^|/)gradle/wrapper/|(^|/)gradlew(\\.bat)?$"
        + "|(^|/)pom\\.xml$|(^|/)mvnw(\\.cmd)?$|(^|/)\\.mvn/wrapper/|(^|/)pyproject\\.toml$|(^|/)setup\\.py$"
        + "|(^|/)buildSrc/|(^|/)Makefile$|(^|/)\\.npmrc$|(^|/)\\.yarnrc(\\.yml)?$|(^|/)conftest\\.py$|(^|/)[^/]+\\.config\\.[mc]?[jt]s$"
        + "|(^|/)\\.github/actions/|^action\\.ya?ml$|(^|/)\\.github/(.*/)?action\\.ya?ml$|(^|/)\\.husky/|(^|/)\\.pre-commit-config\\.ya?ml$|(^|/)tox\\.ini$|(^|/)noxfile\\.py$|(^|/)build\\.rs$|(^|/)\\.mcp\\.json$|(^|/)CODEOWNERS$"
        + "|(^|/)([^/]*\\.)?([Dd]ockerfile|[Cc]ontainerfile)(\\.[^/]*)?$|(^|/)(docker-)?compose[^/]*\\.ya?ml$"))),
      sig("Dependencies"; 15; $nd | hits(.filename | test(
        "\\.gradle(\\.kts)?$|libs\\.versions\\.toml$|gradle-wrapper\\.properties$|(^|/)package(-lock)?\\.json$|pnpm-lock\\.yaml$|yarn\\.lock$|\\.terraform\\.lock\\.hcl$"
        + "|(^|/)pom\\.xml$|(^|/)pyproject\\.toml$|(^|/)setup\\.py$|(^|/)requirements[^/]*\\.txt$|(^|/)(poetry|uv|Cargo)\\.lock$|(^|/)go\\.(mod|sum)$|(^|/)Cargo\\.toml$"))),
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
