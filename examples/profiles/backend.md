# Profile: backend (`tech-n-ai-backend`)

Axis definitions for Stages 1 and 3. The orchestrator copies **the full section for each judge** into the prompt body.

---

## 0. Project context every judge must know (loaded for all judges)

**Stack** — Java 21 · Spring Boot 4 · Spring Cloud Gateway (WebFlux/Netty) · Gradle (Groovy DSL) multi-module ·
Aurora MySQL (writes) · MongoDB Atlas (reads, Vector Search) · Kafka (CQRS sync) · Redis (idempotency, cache) · LangChain4j.

**CQRS is physically split.** Writes go to Aurora MySQL (`datasource-aurora`, normalized, TSID PK,
soft-delete + history tables); reads come from MongoDB Atlas (`datasource-mongodb`, denormalized).
The two sides are connected by **Kafka events**, with **Redis-based idempotency handling** (7-day TTL).
`api-bookmark` runs on Aurora alone, without Kafka.

**Module dependency direction** — `api`/`batch` combine `common`, `datasource`, and `client`.
The only module that depends on nothing is `common-core`. Module names are `{parentDir}-{moduleDir}`
(e.g. `api/auth` → `:api-auth`). `settings.gradle` registers modules automatically by walking five folders (`api`, `batch`, `common`, `client`, `datasource`).

**Runnable services and local ports** — `api-gateway` (8081) · `api-emerging-tech` (8082) · `api-auth` (8083) ·
`api-chatbot` (8084) · `api-bookmark` (8085) · `api-agent` (8086) · `batch-source`. Everything else is a library.
External traffic enters only through `api-gateway`; internal calls between services require the `X-Internal-Api-Key` header.

**TSID primary keys** (64-bit Long) exceed JS `Number.MAX_SAFE_INTEGER`.
A global Jackson `Long`→`String` serializer protects precision on the frontend. **IDs are strings when they cross the API boundary.**

**Tests run under the `local` profile** (the `jvmArgs` in the root `build.gradle` enforce it). KST and UTF-8 are enforced in the same place.

**Build commands**
```bash
./gradlew :api-auth:build
./gradlew :api-auth:test
./gradlew :api-chatbot:test --tests '*ChatServiceTest'
```

> This section started from "Project Context You Must Internalize" in `.claude/agents/code-review-kr.md`.
> **That agent's severity scale (`심각/높음/중간/낮음`) is not used** — our scale is the four grades `critical`/`major`/`minor`/`nit`.

---

## 1. The nine review axes — backend

| Axis | Name | Meaning in this profile |
|---|---|---|
| **R-A** | Design–implementation consistency | Does the code actually keep the intent declared in `README.md`, `docs/reference/design/`, and the PR description? If not, **which is wrong, the document or the code?** |
| **R-B** | **Data correctness** | Do values diverge between the two CQRS stores (Aurora, MongoDB)? Does event reprocessing create duplicates or gaps? Do soft-delete and history match the actual state? |
| **R-C** | Concurrency & atomicity | Operations that break under multiple instances and retries. Read-modify-write outside a transaction |
| **R-D** | Interface contract | REST spec, status codes, serialization contract. Authentication and header contract on paths through the gateway |
| **R-E** | Load fitness | N+1 · queries not covered by an index · missing pagination · unnecessary full scans |
| **R-F** | Failure isolation | When an external dependency (Feign, LLM, Kafka, MongoDB) goes down, does our service go down with it? |
| **R-G** | Tests | Does it actually fail when the code breaks? Does it avoid false positives? |
| **R-H** | Maintainability | Dead code · calls to methods that do not exist · hardcoded URLs · observability |
| **R-I** | **Security** | **Conditional axis** — see below. Does an unauthorized principal get through? Does a value leave that must not? Does the code trust input it must not trust? |

**Axis notation for comment bodies** — in a PR written in this profile's language, use the names in the table above exactly as written. In other PRs, translate them (`rules/00-criteria.md` §6).

```
R-A (Design–implementation consistency)   R-B (Data correctness)   R-C (Concurrency & atomicity)   R-D (Interface contract)
R-E (Load fitness)                        R-F (Failure isolation)  R-G (Tests)                     R-H (Maintainability)
R-I (Security)
```

> **R-B differs from the original harness, starting with its name.** The original R-B was `aggregation correctness`, an axis specific to the ad-aggregation domain.
> tech-n-ai has no such domain, so it was **redefined as `Data correctness`.**
> Carrying over the original definition as-is would produce an axis that almost never fires.

> **`R-I` is conditional.** Not every PR touches a security path.
> If **any one** of the five signals below matches, it applies; if none match, it does not apply.
> **In Phase 0 the orchestrator runs the commands below as written and records the match counts in `rounds/round-NN.md`** —
> without fixed commands, the negative claim "does not apply" gets judged with a different pattern every round (`rules/00-criteria.md` §2 · L0-19).

| Signal | How it is checked |
|---|---|
| **1** Authentication/authorization code | A changed file is under `common/security/` · `api/auth/` · `api/gateway/` |
| **2** New HTTP endpoint | Added diff lines contain `@GetMapping` · `@PostMapping` · `@PutMapping` · `@DeleteMapping` · `@RequestMapping` |
| **3** Per-user data path | A changed file is under `api/bookmark/` · `common/conversation/` |
| **4** Credentials/secrets | Added diff lines **in source and config files** contain `password` · `secret` · `credential` · `apiKey` · `accessToken` · `refreshToken` · `authorization` (case-insensitive) |
| **5** Path that trusts external text | A changed file is under `api/agent/` · `api/chatbot/` · `client/scraper/` · `client/rss/` · `batch/source/` |

```bash
# Read the two SHAs with `<plugin-dir>/scripts/pr-quorum.sh meta <repo> <PR-number>` (no bot token needed).
# The Stage 1 range is base_sha…eval_sha. The commands below run in a worktree of the repository under review.
B=<meta.base_sha>; S=<meta.eval_sha>
git diff --name-only $B...$S | grep -cE '^(common/security|api/auth|api/gateway)/'          # signal 1
git diff -U0 $B...$S | grep '^+' | grep -cE '@(Get|Post|Put|Delete|Request)Mapping'         # signal 2
git diff --name-only $B...$S | grep -cE '^(api/bookmark|common/conversation)/'              # signal 3
git diff -U0 $B...$S -- '*.java' '*.kt' '*.yml' '*.yaml' '*.properties' '*.gradle' '*.tf' '*.sh' '*.json' 'Dockerfile*' \
  | grep '^+' | grep -icE 'password|secret|credential|api[-_]?key|access[-_]?token|refresh[-_]?token|authorization'   # signal 4
git diff --name-only $B...$S | grep -cE '^(api/agent|api/chatbot|client/(scraper|rss)|batch/source)/'   # signal 5
```

If it does not apply, write in the axis coverage verdict: *"`R-I`: not applicable — 0 matches on the five signals above"*.

> **Why signal 4 drops bare `token` and `email` matches — measurement** (2026-09-01, range `git log -60`).
> Running the broad version (`token|password|secret|apiKey|email`) over recent main commits, `436868a` (chatbot LLM token usage metering)
> produced **48 matches**, all of them **model token metering** such as `TokenUsage`, `maxTokens`, `inputTokens`;
> `346515c`, which only changed docs, also produced **6**, all of them the mermaid node name `TokenService`.
> In this repository `token` means an LLM token far more often than an auth token.
> The narrowed version produced **0** on all of those commits, and still caught `c784870` (`langchain4j.open-ai.chat-model.api-key`),
> which actually handled credentials, with **18**, and `26957b5` (terraform IAM and secrets) with **3**.
> Limiting the extensions to a list came from the same measurement — every false match was in `.md`, `.mmd`, or `.drawio`.

> **Why `.json` is in the extension list — measurement** (2026-09-01).
> The original list had no `.json`. When you narrow extensions to an allowlist, formats missing from the sample quietly return 0.
> In this repository that gap was the IntelliJ HTTP Client environment file (`http-client*.env.json`) —
> a config file with a `.json` extension. Commit `ade9de9`, which added `api/bookmark/.../http-client.private.env.json`,
> held two plaintext JWTs and still scored **0** on signal 4; with `.json` included it scores **4**.
> `1bb20e8`, which added the same file under `api/auth`, goes from 94 → 97, and `e306db6` on the `api/agent` side goes from 6 → 8.
> False matches did not increase — running both versions side by side over the 60 most recent main commits, **not a single commit differed.**

> **ISO/IEC 25010 mapping** — records which 25010 quality characteristics these nine axes cover.
> Functional suitability `R-A`·`R-B` / Performance efficiency `R-E` / Compatibility `R-D` / Reliability `R-C`·`R-F` /
> Security `R-I` / Maintainability `R-G`·`R-H` / Interaction capability frontend `R-H` (accessibility).
> Flexibility and safety almost never come up in this repository's PRs.
> **Do not cite this mapping in a posted review.** 25010 is a paid standard, so the original text was not opened;
> no verbatim quote or URL can be given, so it does not meet the conditions for source grade B. The characteristic names above are `unverified`.
> The purpose of the mapping was to look once at *"what our axes cover and what is missing"*, and that purpose is done.

---

## 2. Judge J1 — design and data correctness (review axes R-A · R-B)

### What it represents
The first thing to look at in a review is the design of the whole change. And the most expensive defect in this project
is **values diverging between the two stores** — it cannot be rolled back by a deploy, and the data has to be fixed by hand.

### What to look at

**R-A Design–implementation consistency**
- Does the code keep what the PR description, linked issues, and `docs/reference/design/` declare? If not, which one is wrong?
- **If the behavior or signature of a method other modules depend on (`common-*`, `datasource-*`) changed, do callers outside the diff depend on what changed?**
  Find callers with `grep -rn` and attach them as evidence (C). Put the anchor on the changed line inside the diff.
- **CQRS direction violation** — does a write go to MongoDB, or does a read path call an Aurora write repository?
- **Module dependency direction violation** — has `common-core` come to depend on something? Does `datasource` call `api`?
  `api-gateway` is WebFlux/Netty and excludes the Servlet, Tomcat, and Security starters from its build — was a dependency added that brings them back?
- Do transaction boundaries match the design? Does code wait on an external call inside `@Transactional`?
- **Design documents are in review scope.** If the PR also changed `docs/`, give a verdict on that document too.

**R-B Data correctness**
- Does Kafka event consumption have **Redis-based idempotency handling (7-day TTL)**? Is it missing for a new event type?
- Do reprocessing and retries create **duplicates or gaps** in the MongoDB read model?
- Does a query ignore soft-delete? Is there a change that leaves no row in the history table?
- Does time zone or date-boundary handling (KST enforced) put values in the wrong bucket?
- Do TSID generation and propagation point to the same value in both stores?

### What not to look at
- The point where atomicity breaks, in itself → J2 (you look only at *whether the value is wrong*)
- External call timeout/retry → J2
- HTTP status codes and serialization contract → J3
- **Performance** such as indexes and N+1 → J3. But the case where *performance makes the value wrong* is yours
- Tests that do not catch this bug → J4
- Dead code, naming, logging → J4

### Grade examples
- **`critical`**: A Kafka consumer does not apply an idempotency key to a new event type, so on reprocessing the same message lands twice in the MongoDB read model.
- **`critical`**: A write path skips Aurora and writes straight to MongoDB — a CQRS direction violation, and no history is kept.
- **`major`**: A read query does not filter out soft-deleted rows, so deleted data goes out in the response.
- **`major`**: The design document says an event is published, but the implementation is a synchronous call. The author has to decide whether the document or the code is wrong.
- **`minor`**: The PR description has no capacity or traffic estimate.

---

## 3. Judge J2 — concurrency and failure isolation (review axes R-C · R-F)

### What it represents
Works out **by reasoning** the kinds of problems that do not show up by running the code: things that break only when many instances run at once,
things that show up only when an external dependency slows down.

### What to look at

**R-C Concurrency & atomicity**
- **Read-modify-write outside a transaction.** Can another instance cut in between reading, computing, and writing?
- With many instances running at once, does code do "update if it exists, insert if not" without a lock or a unique constraint?
- Is a Redis idempotency key set with `set` and then a separate `expire`? (If the process dies between the two commands, the key stays.)
- Does the `@Transactional` propagation setting match the intent? Does self-invocation bypass the proxy?
- Is the Kafka consumer written assuming it **may be reprocessed**? Does the offset commit happen before processing completes?

**R-F Failure isolation**
- **Do external calls have timeouts and retries?** — Feign clients, LangChain4j LLM calls, RSS and scraping, Slack and mail.
  Without a timeout, threads are held indefinitely.
- Does something slow like an LLM call hold request threads so that **one service's failure spreads to the gateway?**
- What happens when a Kafka consumer fails — does infinite retry block the partition, is the message silently dropped, is there a DLT?
- When MongoDB or Redis goes down, does the write path go down too?
- Is the structure one where failure **can be detected**? — does code swallow an exception and return `null` while the caller reads it as success?

> ⚠ **A silent failure from an intentional fail-open is not this axis; it is R-H (observability).**
> Detaching a side-path failure from the main path is, from an isolation standpoint, actually the better choice,
> so filing it as `R-F` gets a "the direction is reversed" ruling from the challenger (measurement — PR #33 round 1).
> **Keep `R-F` narrowed to "when an external dependency goes down, do we go down with it?"**
> Send the problem of a swallowed exception leaving nothing in logs or metrics to `R-H`.

### What not to look at
- The value being wrong, in itself → J1 (you look at *the point where atomicity breaks*)
- Choice of HTTP status code → J3
- **Throughput** such as indexes and N+1 → J3
- Tests that depend on external infrastructure → J4
- Logging setup, dead code → J4

### Grade examples
- **`critical`**: An LLM call has no timeout, so model latency eats up request threads and all of `api-chatbot` stops responding.
- **`major`**: A Kafka consumer swallows exceptions, so failed messages silently disappear. The read model diverges permanently.
- **`major`**: A read followed by an update runs outside a transaction, so when two instances process at once one update overwrites the other.
- **`major`**: A Feign client returns `null` instead of throwing, and the caller only checks `!= null`, so the failure path is dead.
- **`minor`**: No retry policy or circuit breaker.

---

## 4. Judge J3 — interface contract, load fitness, security (review axes R-D · R-I · R-E)

### What it represents
The contract the spec sets, and the points that collapse when data grows.
And **the places where an unauthorized principal gets through** — missing authorization shows up in the same places as `R-D` (controllers and endpoints), so the same judge looks at it.

> **In a round where `R-I` fires, this judge covers three axes.** That is the price of deciding not to grow to five judges —
> adding judges pushes wall-clock time to the 3-hour lock TTL (`docs/harness.md` §6-1).
> So **the `R-I` section is placed before `R-E`.** A PR that fires `R-I` is usually one that adds controllers and endpoints,
> so `R-D` and `R-E` get heavy too, and one more axis is added on top of that.

### What to look at

**R-D Interface contract**
- Does the implementation match `docs/reference/api-specifications/`? Response field names, types, required-ness.
- **Does the TSID Long go out as a String?** Is there a response that bypasses the global Jackson serializer (a hand-built Map, string assembly)?
  If it goes out as a Long, precision breaks on the frontend.
- Status code misclassification — does input validation failure return 5xx? Does a missing resource return 200 + an empty body?
- Do gateway routes match the actual service paths? **Does the service trust headers the gateway adds?** —
  you look at *whether the header contract exists*. Whether **the authenticated principal gets swapped** when that header is missing or forged is `R-I`.

**R-I Security** — the firing conditions are in the conditional-axis block in §1. If it does not apply, record it only in the coverage verdict and move on.

- **Missing authorization** — does code read, update, or delete by id without checking that the requester owns the resource?
  A place where a new endpoint appeared on a path handling per-user data with no owner check. (ASVS 8.2.2)
- **Is the authenticated principal read from a client-supplied value?** — does code use the `userId` from request parameters or body as-is,
  or take it from a verified token?
- **Has an internal-only path been opened?** — does a new internal endpoint check `X-Internal-Api-Key`?
  Can it be called directly, bypassing the gateway?
- **Do tokens, credentials, or personal data end up in logs?** — do `log.` arguments include an access token, refresh token,
  OAuth authorization code, password, or email as-is, **without hashing or masking**? (ASVS 16.2.5)
- **Do the same values go into a response?** — does a response DTO send them out as-is? **Give the evidence as a code fact (C).**
  ASVS 16.2.5 talks only about logging — covering responses with that quote too is I-3 (exceeding the source grade).
- **Hardcoded secrets** — has an API key, password, or signing key gone into a source or config file as a value?
- **Does external input go straight into a query?** — JPQL, native queries, or MongoDB queries built from strings.
  Places that bypass parameter binding or QueryDSL.
- **Does code trust LLM responses or collected external text without validation?** — do `api-agent` and `api-chatbot` pass values the model produced
  straight into queries or tool-call arguments? Does `batch-source` store scraped text as-is?

> **These two are the only B-grade quotes allowed on this axis.** To use another ASVS requirement,
> reopen the original text at that time and copy it verbatim. **Do not quote from memory.**
> And **do not run ASVS as an exhaustive checklist** — use it only as the basis for the axis definition.
> Many of the standard's requirements can only be judged with configuration, architecture, or runtime evidence, while the bot sees the diff at `eval_sha`;
> running it as a checklist produces a flood of findings with no anchor (I-1).
>
> - **OWASP ASVS 5.0.0, V8 Authorization, 8.2.2 (Level 1)** — "Verify that the application ensures that
>   data-specific access is restricted to consumers with explicit permissions to specific data items to mitigate
>   insecure direct object reference (IDOR) and broken object level authorization (BOLA)."
> - **Same document, V16 Security Logging and Error Handling, 16.2.5 (Level 2)** — "Verify that when logging
>   sensitive data, the application enforces logging based on the data's protection level. For example, it may not be
>   allowed to log certain data, such as credentials or payment details. Other data, such as session tokens, may only
>   be logged by being hashed or masked, either in full or partially."

**R-E Load fitness**
- **N+1** — do queries repeat while iterating over an association? Does the default fetch strategy of `@OneToMany` match actual use?
- **Does an index actually cover the real query?** Does the WHERE/ORDER BY column combination match an index?
- Is there **a full scan without pagination**? What happens when the table grows?
- Is a MongoDB query a collection scan? Is Vector Search called multiple times per request?
- Is a heavy object (HTTP client, embedding model) created anew on every request?

### What not to look at
- Correctness of values → J1
- **CQRS direction, idempotency, double counting → J1 and J2. Even when the location is a controller.** You look as far as *response shape and status code*
- Atomicity, timeouts, failure propagation → J2
- Test structure → J4
- Naming, dead code → J4
- **Missing authorization, hardcoded secrets, sensitive data exposure → `R-I`.** The same judge looks at it, but records it under a separate axis

What not to look at under `R-I`

- Known vulnerabilities and versions of dependency libraries → **cannot be judged from the diff.** That is the dependency scanner's job
- Infrastructure settings such as TLS termination, security groups, WAF → in PRs that change `devops/terraform/`, **only what can be confirmed as a code fact.**
  The actual state in the operations console is not checked
- Whether policy documents or permission review records exist → that is an organizational audit item. Not checked
- Status codes, response **shape**, serialization → `R-D`. This axis covers only **a value that must not leave being carried in that shape**, not the shape itself
- An exception being swallowed so that **no** log is left → `R-H` (observability). This axis looks at the side where *something that must not be left is left*
- Whether we go down when an external dependency goes down → `R-F`

### Grade examples
- **`critical`**: A new response DTO sends the TSID out as a `Long`, so the last digits of the ID get cut off on the frontend.
- **`major`**: A list query has no pagination and the WHERE column has no index.
- **`major`**: Input validation failure returns 500 — it should be 4xx.
- **`major`**: Code iterates over a list and queries once per item, causing N+1.
- **`minor`**: The sort order is not in the API spec.

`R-I` grade examples

- **`critical`**: A new read endpoint queries directly by the id in the path, so another user's data goes out as-is.
- **`critical`**: A new internal endpoint has no `X-Internal-Api-Key` check, so it can be called directly, bypassing the gateway.
- **`major`**: Code uses the `userId` from the request body as-is, so changing the value writes to someone else's data.
- **`major`**: The whole login response is logged, so the refresh token is printed in plaintext.
- **`major`**: An API key is hardcoded in source.
- **`minor`**: The response includes an internal query or stack trace in the exception message.

---

## 5. Judge J4 — tests and maintainability (review axes R-G · R-H)

### What it represents
*"When the code breaks, does this test actually fail? When the code changes, does it start producing false positives?"*
And tests are code that has to be maintained too.

### What to look at

**R-G Tests**
- Does it **actually fail** when the code breaks? Is it a test with no assertions, or one so heavily mocked it never goes through the production path?
- **Does it break the `local` profile assumption?** — does the test depend on real external infrastructure (remote DB, external API, Kafka broker)?
  The root `build.gradle` enforces the `local` profile and KST.
- Is it time-dependent, so results change at midnight or on-the-hour boundaries?
- Does it wipe a shared store on entry? (Cannot run in parallel + destroys development data.)
- **Was a new `@SpringBootTest` added?** This repository has only one, and even that is `@Disabled` —
  adding one changes CI time and infrastructure assumptions wholesale.
- ⚠ **Do not conclude "no unit test = violation."** Argue in terms of *false positives · maintenance · blind spots*.

**R-H Maintainability** — mostly non-blocking
- Is there **code that calls a method that does not exist**?
- Dead code. **But existing dead code unrelated to my change is only mentioned, not asked to be removed.**
- Duplication. Are two service methods entirely identical except for their parameters?
- **Hardcoded URLs.** Is something in source that should go through `.env` or environment variables?
  **Hardcoded credentials and API keys are `R-I`** — you look at the side where a value baked into source is hard to change.
- Logging. Does code swallow an exception and leave nothing? **You look at the side where something that should be left is not left** —
  sensitive data printed to logs (something that must not be left is left) is `R-I`.
- ⚠ **Limits on taste findings** — if `CLAUDE.md` gives grounds, it can be written as `suggestion` or higher.
  Pure preference without grounds goes no higher than `nitpick` (I-6).

### What not to look at
- **The bug itself** that the test missed → J1, J2, J3. You look at *why the test does not catch it*
- The **I/O cost** of logging → J3 (you look at observability)
- Indexes, connections → J3
- Atomicity → J2
- Hardcoded credentials, logging of sensitive data → `R-I` (J3)

### Grade examples
- **`major`**: A new service contains code that calls a repository method that does not exist — it fails immediately when called.
- **`major`**: A new test actually hits an external API and produces false failures for network reasons.
- **`minor`**: Code catches an exception and swallows it without logging.
- **`nit`**: Unused import, misspelled variable name.

> This axis **almost never uses the `critical` grade.** Not because it matters less, but because the strength of evidence is different.
> Using it requires very strong evidence.

---

## 6. Measurement baseline — do not record only the value

**Pinned here so that things that were already failing before the PR are not blamed on the PR.**

| What | Value | Command | Measured on | What this command can miss |
|---|---|---|---|---|
| `:api-auth:test` | pass | `./gradlew :api-auth:test` | 2026-08-20 | Other modules not checked. Modules that need infrastructure may give different results |
| Number of `@SpringBootTest` | 1, `@Disabled` | `grep -rl '@SpringBootTest' --include='*.java' .` | 2026-08-20 | — |
| Local infrastructure | **No** Redis or MongoDB (only kafka · 4 mysql · observability stack) | `grep -iE 'redis\|mongo' docker-compose.yml` | 2026-08-20 | This command cannot see remote dependencies such as Atlas or ElastiCache |
| Tracked design documents | 5 of 12 local | `git ls-files docs/reference/design/` | 2026-08-20 | Untracked documents cannot be used as grade-A evidence |

**When you update the baseline, update the measurement date with it.** If only the value changes, no one can tell when it was measured.
