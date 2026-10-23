# Profile: frontend (`tech-n-ai-frontend`)

Axis definitions for Stages 1 and 3. The orchestrator copies **the full section for each judge** into the prompt body.

> **This profile is adjusted after running backend Stage 1 once** (design doc D-7).
> For now it is a draft; axis boundaries get revisited the first time a frontend PR is run.

---

## 0. Project context every judge must know (loaded for all judges)

**Stack** — Next.js 16 (App Router) · React 19 · TypeScript strict · Tailwind 4 · Radix UI + CVA ·
Neo-Brutalism design system.

**There are two apps.** `app/` (public user app, port 3000) and `admin/` (internal admin app, port 3001).
Each has its own `CLAUDE.md`. **They are separate projects** — do not apply `app/` rules to `admin/`.

**Backend IDs arrive as strings.** TSIDs (64-bit Long) exceed `Number.MAX_SAFE_INTEGER`,
so the backend applies `Long`→`String` serialization globally. **Parsing them with `Number()` or `parseInt` on the frontend breaks precision.**

**Commands** — `npm run dev | build | lint` in each app directory.

---

## 1. The eight review axes — frontend

The axis **codes are the same as backend, but three axes mean something different.** Do not apply the backend definition just from the code.

| Axis | Name | Meaning in this profile |
|---|---|---|
| **R-A** | Design–implementation consistency | Misuse of App Router boundaries (server/client). Do `revalidate` and cache tags match when data actually updates? |
| **R-B** | Data correctness | **Does parsing an ID as a number break precision?** Does date/time zone conversion change the value? Does an optimistic update stay out of sync with server state? |
| **R-C** | **State races** | Async races and duplicate requests · `useEffect` dependency arrays · setState after unmount |
| **R-D** | Interface contract | Does the API client match the backend spec? Error response handling |
| **R-E** | **Client performance** | Bundle size · unnecessary re-renders · image and font loading |
| **R-F** | Failure isolation | Error boundaries · failure fallbacks · auth expiry handling |
| **R-G** | Tests | **Conditional axis** — see below |
| **R-H** | Maintainability (incl. accessibility) | Design system consistency · **accessibility** · dead code |

**Axis notation for comment bodies** — in a PR written in this profile's language, use the names in the table above exactly as written. In other PRs, translate them (`rules/00-criteria.md` §6). **Three axis names differ from backend.**

```
R-A (Design–implementation consistency)   R-B (Data correctness)   R-C (State races)      R-D (Interface contract)
R-E (Client performance)                  R-F (Failure isolation)  R-G (Tests)            R-H (Maintainability)
```

> **Accessibility is checked inside R-H.** No separate axis is created.
>
> **R-G is conditional.** This repository has zero test files and zero runners.
> **The fact that "there are no tests" is not in itself a deduction.** Look at R-G only when the PR adds tests.
> Otherwise, record it as `not applicable` in the axis coverage verdict.

---

## 2. Judge J1 — design and data correctness (review axes R-A · R-B)

### What to look at

**R-A**
- **The server/client boundary.** Is `'use client'` attached where it is not needed, pushing the whole tree down to the client?
  Conversely, does a server component use browser APIs or event handlers?
- Do server-only values (tokens, internal URLs) leak into the client bundle? Was the `NEXT_PUBLIC_` prefix attached by mistake?
- **Do `revalidate` and cache tags match when data actually updates?** Is invalidation missing after a write, so the screen keeps showing the old value?
- Does the code keep what the PR description and design documents declare?

**R-B**
- **Is an ID parsed with `Number()`, `parseInt`, or `+id`?** Backend TSIDs arrive as strings, and converting them to numbers cuts off the last digits.
- Is a date string parsed with `new Date()` without a time zone, shifting it by a day?
- Does an optimistic update roll back when it fails? If not, the screen and the server diverge permanently.

### What not to look at
- The race itself → J2 · error handling → J2 · API spec mismatch → J3 · bundle size → J3 · accessibility, dead code → J4

### Grade examples
- **`critical`**: `Number(id)` is used for list item keys and detail query parameters, so a particular ID points to a different resource.
- **`major`**: There is no `revalidateTag` after a write, so the list does not update.
- **`major`**: A server-only API key is referenced from a client component.
- **`minor`**: `'use client'` is placed at the top of the page, pushing parts that do not need it down to the client.

---

## 3. Judge J2 — state and failure isolation (review axes R-C · R-F)

### What to look at

**R-C State races**
- Does the same request go out twice? (Is there no guard against rapid clicks or duplicate submits?)
- **If responses arrive out of order, does an old response overwrite new state?** (Is there no cancellation or sequence check?)
- Does the `useEffect` dependency array match what is actually referenced? Is something missing so it holds an old value, or is too much included so it loops forever?
- Does code update state after unmount? Does cleanup cancel the request?

**R-F Failure isolation**
- Is there **a fallback the user sees** when a request fails? Does the screen silently go blank?
- Do error boundaries, `error.tsx`, and `not-found.tsx` cover this path?
- On **auth expiry**, does it fall into an infinite redirect or infinite retry?
- Does one widget's failure bring down the whole page?

### What not to look at
- The value being wrong, in itself → J1 · API spec, performance → J3 · accessibility, dead code → J4

### Grade examples
- **`major`**: A request is sent on every search keystroke without cancellation, so a slow response arriving later overwrites the results.
- **`major`**: The submit button has no duplicate guard, so rapid clicks create the same resource twice.
- **`major`**: A 401 redirects to login, but the login page makes the same request, causing a redirect loop.
- **`minor`**: A function is put in `useEffect` dependencies, but it is recreated on every render, so the effect reruns needlessly.

---

## 4. Judge J3 — interface contract and performance (review axes R-D · R-E)

### What to look at

**R-D**
- Do the API client's paths, methods, and parameters match the backend spec (`docs/reference/api-specifications/`)?
- Do response type declarations match the actual response? Was the contract erased by covering it with `any`?
- **Error response handling** — does code check `res.ok`? Does it read 4xx/5xx as success?

**R-E Client performance**
- **Bundle size** — is a heavy library statically imported at the top level? Is an icon or chart library pulled in whole?
- **Unnecessary re-renders** — are new objects, arrays, or functions passed to child props on every render? Is a context value recreated on every render?
- Do images use `next/image` with a size set? Do fonts cause layout shift?

### What not to look at
- Races, error boundaries → J2 · precision, cache invalidation → J1 · accessibility → J4

### Grade examples
- **`critical`**: `res.ok` is not checked, so an error body is rendered as normal data.
- **`major`**: The response type is received as `any`, so a backend field rename is caught nowhere.
- **`major`**: A chart library is statically imported at the top level and lands in the first-page bundle.
- **`minor`**: The context `value` is built as an inline object, so consumers redraw on every render.

---

## 5. Judge J4 — accessibility and maintainability (review axis R-H primarily, R-G conditional)

### What to look at

**R-H (incl. accessibility)**
- **Radix/CVA design system consistency** — was something built anew when an existing component or variant would do?
  Were colors or spacing hardcoded instead of using Neo-Brutalism tokens?
- **Accessibility** — is a click handler attached to a `div` (unusable by keyboard)? Does an icon button lack a name?
  Are form inputs linked to labels? Has focus order or the focus indicator disappeared?
- Dead code. **Existing dead code unrelated to my change is only mentioned, not asked to be removed.**
- Hardcoded URLs and keys.
- ⚠ **Limits on taste** — `app/` has `eslint.config.mjs`; `admin/` does not.
  **Style findings on `admin/` cannot cite eslint as grounds.** Each app's `CLAUDE.md` is grounds for both (I-6).

**R-G (conditional)**
- **Look only when the PR adds tests.** Otherwise, the verdict is `not applicable`.
- If tests were added, did runner configuration come with them? Do they actually fail when the code breaks?

### What not to look at
- Re-render cost → J3 · races → J2 · precision → J1

### Grade examples
- **`major`**: Closing a modal is implemented only as a `div` `onClick`, so keyboard users cannot get out.
- **`major`**: The API base URL is hardcoded in a component.
- **`minor`**: A new component was built for something an existing `Button` variant already handles.
- **`nit`**: Unused import.

> This axis **almost never uses the `critical` grade.** Using it requires very strong evidence.

---

## 6. Measurement baseline

| What | Value | Command | Measured on | What this command can miss |
|---|---|---|---|---|
| `app` lint | **3 errors — already failing before the PR** | `cd app && npm run lint` | 2026-08-20 | Pinned first so existing failures are not blamed on the PR. If the value is not 3, measure again and update this table |
| `admin` lint | **Cannot run** — no eslint config file | `cd admin && npm run lint` | 2026-08-20 | Findings that cite lint as grounds cannot be written for `admin/` |
| `app` types | clean | `cd app && npx tsc --noEmit` | 2026-08-20 | Cannot see runtime type mismatches |
| `admin` types | clean | `cd admin && npx tsc --noEmit` | 2026-08-20 | Same |
| Tests | **0** (no files, no runner) | `find app admin -name '*.test.*' -o -name '*.spec.*'` | 2026-08-20 | — |

**When you update the baseline, update the measurement date with it.**
