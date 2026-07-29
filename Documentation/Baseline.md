# Baseline snapshot

This is the documentation/release audit baseline captured on 2026-07-11. It
describes the current worktree; it is not a claim that physical-device gates
have passed.

## Scope and footprint

- Product promise: microphone speech to on-device text and text to on-device
  speech.
- Deployment target: iOS 26 and later (`Package.swift`).
- Runtime package dependencies: none outside Apple frameworks; the Objective-C
  audio safety bridge is an in-repository target.
- Production implementation footprint: 4,798 physical lines across 13 Swift,
  Objective-C, and safety-bridge header files in the current worktree.
- Test methods: 146 XCTest methods across 22 test-bearing Swift files (24 Swift
  test files including support-only files) in the current worktree.
- Public declaration inventory: 51 source lines beginning with `public` in
  `Sources/AppLocalVoice`. This is a review aid, not an API count; the
  generated production-only symbol graph in CI is authoritative for API review.

## Existing evidence

- State and lifecycle contract: [StateMachine.md](StateMachine.md).
- Public API and compatibility contract: [PublicAPI.md](PublicAPI.md) and
  [Compatibility.md](Compatibility.md).
- Deterministic tests: `Tests/AppLocalVoiceTests/` (the test target is run by
  the CI workflow in [`.github/workflows/test.yml`](../.github/workflows/test.yml)).
- Documentation and symbol-graph gates: [`.github/workflows/test.yml`](../.github/workflows/test.yml).
- Device-only procedure: [DeviceMatrix.md](DeviceMatrix.md),
  [DeviceValidationReport.md](DeviceValidationReport.md), and
  `Scripts/run-device-validation.sh`.

## Known evidence limits

This repository has a public remote and `v0.1.0`; the hosted `v0.1.1` release
workflow must emit the compared symbol graphs and retained release evidence.
Protected-branch policy, required checks, and tag-signing policy remain GitHub
settings for the release owner to verify. Physical iPhone/iPad routes,
interruptions, model installation, enhanced voices, endurance, energy, and
process-level recovery remain unproven until privacy-reviewed device reports
exist. These are release blockers, not documentation defects.
