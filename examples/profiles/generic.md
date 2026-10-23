# Profile: generic (any stack)

Axis definitions for Stages 1 and 3. The orchestrator copies **the full section for each judge** into the prompt body.

> **Start here for a stack the other samples do not cover.** Replace every `<fill in: …>` line in §0 and §6; §1–§5 work as written.

## 0. Project context every judge must know (loaded for all judges)

**Stack** — <fill in: language and version · framework · build tool · datastores>

**Layout** — <fill in: top-level modules or apps, which depend on which, and which ones are deployable>

**Not available locally** — <fill in: infrastructure the repository cannot start on a laptop, e.g. a managed database or queue>

**Commands** — sessions run them only through `pr-quorum.sh build <repo> <PR-number> <worktree> build|test|lint [target]`.
<fill in: a target example and what it runs, e.g. target `core` → `make -C core test`>

## 1. The eight review axes — generic

| Axis | Name | Meaning in this profile |
|---|---|---|
| **R-A** | Design–implementation consistency | Does the code keep what the PR description and design documents declare? If not, which is wrong, the document or the code? |
| **R-B** | Data correctness | Are values computed, converted, stored, and deleted correctly? Off-by-one, rounding, time zones, lost or duplicated writes |
| **R-C** | Concurrency | Races, missing locks or transactions, retries and duplicate requests that break an invariant |
| **R-D** | Interface contract | Public APIs, CLI flags, file and wire formats, error responses. **Also authentication, authorization, and input trust** |
| **R-E** | Performance | Work that grows with input size without need · repeated I/O in loops · missing limits or pagination |
| **R-F** | Failure isolation | When a dependency fails or times out, does the failure stay contained and visible? |
| **R-G** | Tests | Does the test actually fail when the code breaks? Does it avoid false positives? |
| **R-H** | Maintainability | Dead code · duplicated logic · hardcoded values · misleading names · missing logs for new failure paths |

**Axis notation for comment bodies** — in a PR written in this profile's language, use the names in the table above exactly as written. In other PRs, translate them (`rules/00-criteria.md` §6).

```
R-A (Design–implementation consistency)   R-B (Data correctness)    R-C (Concurrency)   R-D (Interface contract)
R-E (Performance)                         R-F (Failure isolation)   R-G (Tests)         R-H (Maintainability)
```

> **Security is checked inside R-D.** No separate axis is created.

## 2. Judge J1 — design and data correctness (review axes R-A · R-B)

### What to look at
- **R-A** Does the change do what its description says, and nothing it does not mention? Does it contradict a design document?
- **R-B** Boundary values, empty input, overflow, rounding, encoding, and time zone conversion.
- **R-B** Does every write path keep related records consistent, including deletes and partial failures?

### What not to look at
- Races → J2 · API shape, performance → J3 · tests, style → J4

### Grade examples
- **`critical`**: A conversion silently changes stored values for some inputs.
- **`major`**: The PR description promises a validation the code never performs.
- **`minor`**: An edge case (empty list) returns a wrong but harmless default.

## 3. Judge J2 — concurrency and failure isolation (review axes R-C · R-F)

### What to look at
- **R-C** Read-modify-write without a lock or transaction · shared mutable state · a retried request applied twice.
- **R-F** Are timeouts set on calls to other services? Does one dependency's failure take down unrelated work?
- **R-F** Are errors swallowed, or surfaced to the caller and the logs?

### What not to look at
- The value being wrong, in itself → J1 · API spec, performance → J3 · tests → J4

### Grade examples
- **`critical`**: Two concurrent requests can both pass a balance check and overdraw.
- **`major`**: A call to an external service has no timeout, so a slow dependency blocks every worker.
- **`minor`**: A caught exception is logged without the identifier needed to trace it.

## 4. Judge J3 — interface contract and performance (review axes R-D · R-E)

### What to look at
- **R-D** Does a change break existing callers (renamed fields, changed defaults, new required arguments)? Are error codes consistent?
- **R-D** Is caller input validated before use? Does a new path skip authentication or authorization?
- **R-E** Queries or calls inside loops · unbounded reads · work repeated on every request that could be done once.

### What not to look at
- Races, error handling → J2 · data conversion → J1 · tests, style → J4

### Grade examples
- **`critical`**: A new endpoint returns another user's data without an ownership check.
- **`major`**: A response field is renamed with no compatibility path for existing clients.
- **`major`**: A list endpoint loads every row with no limit.

## 5. Judge J4 — tests and maintainability (review axes R-G · R-H)

### What to look at
- **R-G** Would the new tests fail if the change were reverted? Do they assert outcomes, not just that no exception was thrown?
- **R-G** Is the changed behavior covered at all? Name the case that is missing.
- **R-H** Dead code, duplicated logic, hardcoded URLs or secrets. **Existing problems unrelated to the change are only mentioned.**

### What not to look at
- Correctness of the code under test → J1·J2·J3

### Grade examples
- **`major`**: The only new test mocks the function it claims to test.
- **`minor`**: The same parsing logic is copied into a third place.
- **`nit`**: Unused import.

## 6. Measurement baseline

| What | Value | Command | Measured on | What this command can miss |
|---|---|---|---|---|
| <fill in: what> | <fill in: value> | <fill in: command> | <fill in: YYYY-MM-DD> | <fill in: blind spot> |

**When you update the baseline, update the measurement date with it.**
