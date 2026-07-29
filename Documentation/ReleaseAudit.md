# Release evidence status

Status: **pre-release; not ready to publish**.

AppLocalVoice currently has no Git repository/remote, release tag, canonical
Swift Package URL, or completed physical-device matrix. This document is the
current release-status record. It intentionally does not publish XCTest,
pass/skip, benchmark, or public-symbol totals: the native result evidence,
generated test inventory, and public-API baseline paths are being reconciled.

Older audit narratives and local result-bundle paths were removed from this
current-status document because they are not reproducible release evidence for
the present source tree. Historical verification is retained in
[VerificationLog.md](VerificationLog.md) as historical context only.

## Proven in the worktree

The following checks were run for the current release-documentation update:

- repository-relative Markdown validation passed;
- the Python release/evidence tooling suite passed; and
- the release-scaffolding audit passed its local structural checks while
  reporting the missing Git repository and placeholder CODEOWNERS identity.

These checks prove documentation and tool behavior only. They do not establish
the current package build, native XCTest execution, API compatibility, or
physical-device behavior. Those claims require their own current, retained
evidence.

## Explicitly unproven or impossible in this worktree

- The checked-in test inventory, native XCTest result identities, and
  pass/skip evidence are not yet reconciled; no test total is release-ready.
- The checked-in public API baselines require reconciliation before a current
  symbol total or API-validation claim can be published.
- Physical iPhone/iPad routes, interruptions, backgrounding, Apple model and
  voice availability, endurance, energy/thermal behavior, and crash/relaunch
  recovery remain unproven without physical reports.
- API compatibility against a previous release is impossible until a prior
  semantic tag exists.
- Protected branches, reviewed commits, real CODEOWNERS identities, private
  vulnerability reporting, signing policy, tags, and hosted artifacts require
  a real Git host and release-owner authority.
- The tag workflow currently expects a previous semantic tag, so first-tag
  bootstrap behavior must be implemented and tested before `v0.1.0` is pushed.

## Link and gate review

The local Markdown validator checks repository-relative links. The remaining
release gates are described in [ReleaseChecklist.md](ReleaseChecklist.md) and
[FirstOpenSourceRelease.md](FirstOpenSourceRelease.md). A passing link check or
simulator/provider seam check never substitutes for physical-device evidence.

## Open-task acceptance matrix

| Gate | Required evidence | Current disposition |
| --- | --- | --- |
| Test and API evidence reconciliation | Generated inventory, native results, both API baselines, and reviewed validator results agree | Open local work; do not publish counts |
| Physical-device matrix | Complete, privacy-reviewed reports for the required devices, routes, models, voices, interruptions, endurance, and crash/relaunch | Open external evidence |
| Hosted project | Canonical remote, real CODEOWNERS, protected branch, required checks, private security/conduct routes, and clean reviewed commit | Open Git-host work |
| First-tag bootstrap | Reviewed workflow policy that validates the first semantic tag without inventing a previous release | Open distribution work |
| Publication | Tagged release, matching archive/checksum/evidence manifest, hosted release notes, and clean external package resolution | Not started |

Follow the exact commands and handoff order in
[FirstOpenSourceRelease.md](FirstOpenSourceRelease.md). Keep a gate open when
its evidence is unavailable; do not waive it in prose.
