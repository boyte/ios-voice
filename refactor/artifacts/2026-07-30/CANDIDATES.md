# Simplification map

| Candidate | Evidence | Score | Decision |
| --- | --- | --- | --- |
| Remove internal legacy facade wrappers | The wrappers are used by deterministic facade/session tests and forward to the same coordinator seams. Removing them requires a broad test migration across lifecycle, ordering, and cleanup behavior. | 0.8 | Rejected: high concurrency and test-coverage risk. |
| Merge input and output cleanup paths | The paths have different Apple ownership, cancellation, and late-callback rules. | 0.6 | Rejected: semantic resemblance is not equivalence. |
| Extract shared elapsed-time helper | Only two call sites; extraction would add a shared abstraction with no meaningful line reduction. | 1.0 | Rejected: fails the rule of three. |
| Remove stale source references to deleted budget planning | One comment referenced removed planning material. | 3.0 | Accepted: replace the stale comment with the current session-contract wording. |

## Isomorphism card: stale source comment

- Inputs covered: none; comment-only source edit.
- Ordering and tie-breaking: unchanged.
- Errors, laziness, cancellation, and side effects: unchanged.
- Floating point and random behavior: not applicable.
- Verification: strict build, API validation, documentation validation, and
  Python tooling baseline passed.

No production-code refactor qualified for implementation. The remaining
complexity represents actor ownership, cancellation, stale-callback rejection,
and bounded cleanup behavior that the test suite exercises.
