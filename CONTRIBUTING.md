# Contributing

AppLocalVoice is intentionally small. The maintainer does not accept outside
contributions directly. Bug reports and focused proposals are welcome once the
project is hosted; an external pull request may illustrate a proposed fix, but
it is not merged as submitted. This document describes the standards used when
the maintainer evaluates a proposal or makes a corresponding change.

See [SUPPORT.md](SUPPORT.md) for issue routing and [README.md](README.md#contributing)
for the complete contribution policy.

## Before opening a pull request

- Read the relevant public files in `Documentation/`, especially the
  compatibility contract, state machine, and release guidance.
- Keep production changes focused and add a deterministic test for each behavior change.
- Do not add networking, analytics, credentials, persistence, or provider SDKs to the core package.
- Do not log microphone audio, transcript text, or speech text.
- Run package tests and format Swift consistently with surrounding code.
- For audio changes, include physical-device observations and the route/interruption matrix used.
- For public API changes, build the DocC catalog and include the symbol-graph
  diff or explain why the change is intentionally additive.
- For lifecycle changes, include resource-balance evidence and a deterministic
  fault or regression test whenever the behavior can be simulated.

## Proposed changes and pull requests

Describe the user-visible behavior, failure mode addressed, test coverage, and any device-only limitations. Breaking API changes require a migration note, maintainer review, and an explicit changelog entry. Do not treat a proposed pull request as accepted for merge. Do not merge a public behavior change based only on a green simulator run when the behavior depends on microphone hardware, routes, Apple model installation, or system interruptions.

## Release checklist

The release owner verifies package tests, strict-warning builds, DocC, API
compatibility, benchmark artifacts, and the physical-device matrix. Unknown
device/OS cells must be listed in the release notes rather than implied to pass.

Before proposing the first open-source release, run the offline repository
scaffolding audit:

```sh
python3 Scripts/audit-release-scaffolding.py
```

It can run without network access. Treat every `OPEN` line as a handoff to the
release owner; Git-host protection, required checks, and tag-signing policy
must be verified in the hosted repository.
