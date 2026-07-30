# Performance review

## Baseline and profile boundary

The deterministic proxy benchmark completed on the iPhone 17 Pro iOS 26.5
simulator. It excludes microphone capture, SpeechAnalyzer, audible synthesis,
routes, and physical-device behavior.

| Proxy | Median | p95 | Iterations per sample |
| --- | ---: | ---: | ---: |
| startup and teardown | 953,417 ns | 997,375 ns | 16 |
| repeated recognition turn | 1,139,666 ns | 1,261,458 ns | 16 |
| Unicode-safe chunk transitions | 150,067,208 ns | 151,332,917 ns | 500 |
| slow consumer | 3,090,708 ns | 3,434,458 ns | 8 |
| resource counts | 917,084 ns | 930,208 ns | 12 |

The chunking proxy is the largest total sample, about 0.30 ms per iteration.
It is still small, stable, and not a demonstrated user-facing bottleneck. The
result bundle and sanitized artifact are retained outside the repository at
`/tmp/iosvoice-perf-20260730`.

## Opportunity matrix

| Candidate | Impact | Confidence | Effort | Score | Decision |
| --- | ---: | ---: | ---: | ---: | --- |
| Change recognition or audio buffering | 5 | 1 | 5 | 1.0 | Reject: hardware-sensitive behavior has no physical profile. |
| Change queue scheduling | 3 | 1 | 4 | 0.75 | Reject: no demonstrated hotspot. |
| Change text chunking | 2 | 3 | 3 | 2.0 | Reject: it is measured, but stable and below a meaningful latency threshold; no behavior-preserving lever is justified. |

No performance change is justified. The next pass should collect a physical
profile only after a real app exposes a latency or memory problem, then make
one measured change with a behavior proof.
