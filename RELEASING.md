# Releasing AppLocalVoice

AppLocalVoice is an iOS Swift Package. A release is a source tag whose
checked-in API baseline, documentation, deterministic tests, and device report
describe the same source state.

For public-release history and the corrective release procedure, start with
[First open-source release](Documentation/FirstOpenSourceRelease.md). The
current checkout has a Git remote and `v0.1.0`; the tag workflow's
previous-version comparison still needs a tested first-tag bootstrap policy
before a corrective tag can be fully validated. This document does not
authorize publication while required CI or device-evidence gates remain open.

Binary result bundles, logs, and benchmark outputs are release artifacts, not
checked-in source. Keep them outside the repository and commit only the
privacy-safe Markdown report and any hashed evidence manifest.

## Versioning

- Use semantic version tags of the form `vMAJOR.MINOR.PATCH`.
- Until `1.0.0`, breaking API reductions are allowed only with an explicit
  migration note in `CHANGELOG.md`; after `1.0.0`, follow the compatibility
  contract strictly.
- Never update `PublicAPISymbols.json` to hide an accidental removal. Compare
  the candidate graph with the previous tag first.

## Candidate checklist

From a clean checkout:

```sh
Scripts/emit-public-symbol-graph.sh /tmp/AppLocalVoice-symbols /tmp/AppLocalVoice-derived
python3 Scripts/validate-public-api.py --symbol-graph /tmp/AppLocalVoice-symbols
xcodebuild build-for-testing \
  -project Testing/AppLocalVoice.xcodeproj \
  -scheme AppLocalVoiceTests \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/AppLocalVoice-test-derived \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
APPLOCALVOICE_SIMULATOR_RUNTIME=iOS-26-0 Scripts/run-benchmarks.sh /tmp/AppLocalVoice-benchmarks
APPLOCALVOICE_SIMULATOR_RUNTIME=iOS-26-0 Scripts/run-memory-sweep.sh /tmp/AppLocalVoice-memory
python3 Scripts/create-artifact-manifest.py \
  --output /tmp/AppLocalVoice-artifact-manifest.json \
  --status passed \
  --destination 'iPhone 17 Pro Simulator, iOS 26.0' \
  --test-inventory Documentation/TestInventory.json \
  --artifact /tmp/AppLocalVoice-symbols \
  --artifact /tmp/AppLocalVoice-benchmarks \
  --artifact /tmp/AppLocalVoice-memory
```

The tag workflow runs the complete simulator suite twice from independent
clean derived-data directories per iPhone/iPad form factor, and runs the
benchmark and memory gates before retaining the release evidence bundles.
Local candidates should do the same and retain both `.xcresult` bundles.
Complete the physical-device
matrix in `Documentation/DeviceMatrix.md`, including route, interruption,
background, model, enhanced-voice, endurance, and crash/relaunch evidence.
The release workflow pins both its iPhone and iPad simulator selections to the
iOS 26.0 runtime; local benchmark and memory commands should set the same
`APPLOCALVOICE_SIMULATOR_RUNTIME=iOS-26-0` value explicitly.

For physical-device release acceptance, run both report checks:

```sh
python3 Scripts/validate-device-report.py \
  Documentation/device-reports/<utc-device-report>.md \
  --require-complete --require-release
```

Release mode requires a successful xcodebuild log and all manual scenarios to
pass. A failed scenario can be accepted only with a complete, explicit waiver
row in the report; waivers must name the issue, owner, and approval/expiry.

Attach the generated artifact manifest to the release evidence; it records the
source revision, Xcode version, destination, test inventory, artifact paths,
sizes, and SHA-256 hashes.

## API and source archive

For a candidate tag, emit the public graph from the previous tag and the
candidate with the same Xcode/SDK, then run the machine-checked comparison:

```sh
python3 Scripts/compare-public-api.py \
  --previous /path/to/previous/AppLocalVoice.symbols.json \
  --candidate /path/to/candidate/AppLocalVoice.symbols.json \
  --output api-compatibility.json
```

The comparison fails on removed symbols or changed declaration/availability
metadata. Review additions, actor isolation, `Sendable`, error cases, event
ordering, and resource ownership before updating the baseline.

Local candidate and pull-request checks do not require a previous release tag;
they validate the candidate against the checked-in baseline so they remain
runnable in a fresh checkout. The tagged release workflow is the fail-closed
gate for the previous-tag comparison: it requires a reachable earlier semantic
version tag, emits both graphs with the release toolchain, and fails if the
comparison cannot be completed or reports an incompatible change.

Create the release notes from `CHANGELOG.md`. Publish the source archive and a
SHA-256 checksum alongside the tag with:

```sh
Scripts/create-source-archive.sh v0.1.0 dist
```

The archive command is deliberately strict. The argument must be an exact
`vMAJOR.MINOR.PATCH` tag, the tag must resolve to the current `HEAD`, and the
worktree must be clean. The tag may be lightweight or annotated; verify an
annotated/signature-protected tag separately when the repository's release
policy requires it. The archive is made from an uncompressed Git tar stream
followed by `gzip -n`, so repeated runs for the same commit produce identical
bytes. The checksum file contains only the archive basename and is therefore
relocatable with the archive:

```sh
shasum -a 256 -c dist/AppLocalVoice-v0.1.0.tar.gz.sha256
tar -tzf dist/AppLocalVoice-v0.1.0.tar.gz | head
```

The archive helper has a temporary-repository test suite. Run it before
publishing when Git is available:

```sh
python3 Scripts/tests/test_source_archive.py
```

Do not publish a release while any
physical-device, process-recovery, API-compatibility, or privacy evidence gate
is open.

## Git-host requirements

The repository has a Git directory and canonical `origin`. Run the release
audit in host mode before promotion:

```sh
python3 Scripts/audit-release-scaffolding.py --require-host
```

It verifies the release-facing file set, executable source-archive helper,
immutable workflow action pins, host remote, and real CODEOWNERS identity.
Branch protection, required checks, private vulnerability reporting, signing,
and a reviewed release commit remain GitHub release-owner responsibilities.

The repository must have protected `main`, CODEOWNERS mapped to real
maintainers, required CI checks, vulnerability reporting enabled, and a clean
reviewed commit before the first tag is published.

Pushing a semantic-version tag runs
`.github/workflows/release-validation.yml`. It fetches the complete tag
history, runs the strict package/test/DocC/clean-client gates and complete
simulator suite, compares the candidate production symbol graph with the
immediately previous reachable semantic-version tag, creates the deterministic
source archive, and uploads the comparison, checksums, and provenance manifest.
The normal test workflow and release workflow pin every third-party action to
an immutable commit; update those SHAs only with a reviewed dependency change.
