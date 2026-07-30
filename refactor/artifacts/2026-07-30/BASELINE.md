# Refactor baseline

Captured from `0c3c61e` plus the documentation-only worktree on 2026-07-30.

| Check | Result |
| --- | --- |
| Production source lines | 10,548 |
| Strict Swift package/test build | Passed with iOS 26 simulator SDK and warnings as errors |
| Public API validation | Passed; 500 allowlisted symbols |
| Documentation validation | Passed; 36 Markdown files |
| Python tooling suite | Passed; 98 tests |
| Release scaffolding audit | Passed |

No portable runtime golden output is available in this environment. The package
depends on iOS frameworks, and simulator XCTest execution is intentionally a
manual workflow. The strict build, public symbol graph, focused test inventory,
and deterministic tooling checks are the available behavior baselines.
