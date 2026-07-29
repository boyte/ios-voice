# Release evidence status

Status: **public 0.1.0 released; corrective 0.1.1 work in progress**.

AppLocalVoice is published at `https://github.com/boyte/ios-voice` with an
immutable `v0.1.0` tag. That initial release is not device-qualified and its
hosted CI and release metadata require corrective follow-up. This document is
the current release-status record; it intentionally does not publish native
XCTest, benchmark, or device-pass claims without retained matching evidence.

Older audit narratives and local result-bundle paths were removed from this
current-status document because they are not reproducible release evidence for
the present source tree. Historical verification is retained in
[VerificationLog.md](VerificationLog.md) as historical context only.

## Proven in the worktree

The following checks were run for the current release-documentation update:

- repository-relative Markdown validation passed;
- the Python release/evidence tooling suite passed; and
- the release-scaffolding audit checks the tracked public scaffolding; and
- the repository has a canonical Git remote and public Swift Package URL.

These checks prove documentation and tool behavior only. They do not establish
the current package build, native XCTest execution, API compatibility, or
physical-device behavior. Those claims require their own current, retained
evidence.

## Explicitly unproven or impossible in this worktree

- Hosted CI must pass for the corrective release commit, including clean-tree
  documentation, API baseline, simulator, benchmark, and memory gates.
- Physical iPhone/iPad routes, interruptions, backgrounding, Apple model and
  voice availability, endurance, energy/thermal behavior, and crash/relaunch
  recovery remain unproven without physical reports.
- API compatibility against a previous release is impossible until a prior
  semantic tag exists.
- Branch protection, required checks, and any tag-signing policy remain GitHub
  repository settings that must be reviewed by the release owner.
- The tag workflow needs an explicit first-tag bootstrap policy before the
  corrective release can be considered fully release-validated.

## Link and gate review

The local Markdown validator checks repository-relative links. The remaining
release gates are described in [ReleaseChecklist.md](ReleaseChecklist.md) and
[FirstOpenSourceRelease.md](FirstOpenSourceRelease.md). A passing link check or
simulator/provider seam check never substitutes for physical-device evidence.

## Open-task acceptance matrix

| Gate | Required evidence | Current disposition |
| --- | --- | --- |
| Test and API evidence reconciliation | Generated inventory, native results, both API baselines, and reviewed validator results agree | Corrective 0.1.1 work; do not publish unverified counts |
| Physical-device matrix | Complete, privacy-reviewed reports for the required devices, routes, models, voices, interruptions, endurance, and crash/relaunch | Open external evidence |
| Hosted project | Canonical remote, real CODEOWNERS, protected branch, required checks, private security/conduct routes, and clean reviewed commit | Remote and ownership configured; branch protection/review settings remain release-owner work |
| First-tag bootstrap | Reviewed workflow policy that validates the first semantic tag without inventing a previous release | Open distribution work |
| Publication | Tagged release, matching archive/checksum/evidence manifest, hosted release notes, and clean external package resolution | 0.1.0 published; 0.1.1 awaits corrective CI and evidence |

Follow the exact commands and handoff order in
[FirstOpenSourceRelease.md](FirstOpenSourceRelease.md). Keep a gate open when
its evidence is unavailable; do not waive it in prose.
