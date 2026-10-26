# Review guidance

- Skip `src/generated/` and `vendor/`: generated or vendored, never edited by hand.
- At most 2 `minor`·`nit` comments per review.
- Treat as `major`: a public API response field renamed or removed without a version bump.
- Every finding cites `file:line`.
