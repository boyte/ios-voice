# First open-source release

This is the handoff guide for AppLocalVoice's first public release. It is
intentionally conservative: the current checkout has no Git repository,
canonical remote, tag, or published package URL. It also has no completed
physical-device release matrix. Do not describe it as published or
device-qualified until every applicable gate below has evidence.

For the recurring release procedure after the first release, see
[RELEASING.md](../RELEASING.md). The authoritative work graph is in Beads; the
release evidence boundary is documented in [Release Checklist](ReleaseChecklist.md)
and [Release Audit](ReleaseAudit.md).

## 1. Reconcile the source evidence

Before selecting a version, close or explicitly defer the current evidence
work. In particular, the checked-in XCTest inventory, native result evidence,
and public-symbol baseline paths must agree. Do not copy historical test,
pass/skip, or symbol totals into release notes while that reconciliation is
open.

From a clean, hosted clone, run the normal local gates:

```sh
python3 Scripts/test-inventory.py --check Documentation/TestInventory.json
python3 Scripts/validate-documentation.py
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
Scripts/validate-evidence-tooling.sh
python3 Scripts/audit-release-scaffolding.py --require-host

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
swift build --build-tests \
  --sdk "$SDK" \
  --triple arm64-apple-ios26.0-simulator \
  -Xcc -isysroot -Xcc "$SDK" \
  -Xswiftc -warnings-as-errors

xcodebuild -project Testing/AppLocalVoice.xcodeproj \
  -scheme AppLocalVoiceTests \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

Generate the public symbol graph and run both checked validation paths. Review
every change; do not regenerate a baseline merely to make validation pass.

```sh
Scripts/emit-public-symbol-graph.sh /tmp/AppLocalVoice-symbols /tmp/AppLocalVoice-derived
python3 Scripts/validate-public-api.py \
  --symbol-graph /tmp/AppLocalVoice-symbols/AppLocalVoice.symbols.json \
  --baseline Documentation/PublicAPIBaseline.json
python3 Scripts/validate-public-docs.py \
  --symbol-graph /tmp/AppLocalVoice-symbols/AppLocalVoice.symbols.json \
  --baseline Documentation/PublicAPIBaseline.json
```

Run the full simulator workflow on the pinned supported destinations. Treat
simulator results as simulator evidence only.

## 2. Complete physical-device release evidence

Use [Device Matrix](DeviceMatrix.md) as a release gate, not a wish list. Run
the report generator on every device/route combination required by the matrix,
complete each manual scenario, and validate the report in release mode:

```sh
Scripts/run-device-validation.sh <physical-device-udid> \
  Documentation/device-reports/<utc-device-report>.md
python3 Scripts/validate-device-report.py \
  Documentation/device-reports/<utc-device-report>.md \
  --require-complete --require-release
```

The first release needs recorded evidence for the supported iPhone and iPad
coverage, built-in/Bluetooth/wired routes where available, permissions,
model-installation behavior, installed voice classes, interruptions,
backgrounding, lock/unlock, endurance, and crash/relaunch. Sanitize any
retained logs and scan portable evidence before publication; never publish
audio, transcript text, speech text, credentials, or private paths.

## 3. Establish the hosted project

These are administrative changes and require the release owner's authority:

1. Initialize and publish the canonical repository; choose the default branch
   and public Swift Package URL.
2. Replace `.github/CODEOWNERS`'s placeholder with real maintainers.
3. Enable private vulnerability reporting and update [SECURITY.md](../SECURITY.md)
   with the actual reporting route.
4. Configure protected `main`, required CI checks, review policy, and any tag
   signing policy.
5. Configure the repository's issue/discussion settings and add the actual
   conduct-reporting contact required by [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md).
6. From a clean external clone, verify URL-based Xcode resolution and a
   versioned `Package.swift` dependency. Then replace the local-only install
   wording in [README.md](../README.md) and [Quickstart](Quickstart.md).

Do not replace placeholders with guessed usernames, URLs, email addresses, or
security contacts.

## 4. Bootstrap the first tag

The current tag workflow requires a previous reachable semantic-version tag
for its API comparison. That is correct for later releases but means it cannot
validate the first tag as written. The `DIST-BOOTSTRAP` work item must define
and test the bootstrap policy before a `v0.1.0` tag is pushed. Acceptable work
must preserve fail-closed comparison for every later tag and must not invent a
previous public API.

After that work is closed, select `v0.1.0` only if the release owner has
reviewed the current public API, device evidence, known limitations, and
release notes. Create the tag from a clean, reviewed commit. The tag workflow,
source archive, checksum, and hosted release must all describe the same commit.

## 5. Publish and verify

1. Confirm the tag workflow completed and retained its artifacts.
2. Build the deterministic source archive and checksum as described in
   [RELEASING.md](../RELEASING.md).
3. Create the hosted release using the matching `CHANGELOG.md` section. State
   the supported platform and any known/unknown device matrix cells plainly.
4. Attach the source archive, checksum, and privacy-reviewed evidence manifest
   according to the hosting policy.
5. Resolve the package by the final URL and exact tag from a new external
   checkout, then build a minimal iOS 26 app that imports `AppLocalVoice`.
6. Update README/Quickstart links only after that external resolution succeeds.

## Release-note minimum

Each published section in [CHANGELOG.md](../CHANGELOG.md) should identify:

- the exact version and release date;
- public API additions, behavior changes, and migrations;
- known device limitations or unknown matrix cells;
- security/privacy-relevant changes without sensitive details; and
- links to the tag/release once a canonical remote exists.

Do not publish opaque test totals or claim AirPods, model installation,
interruption, crash/relaunch, or endurance validation unless the accompanying
device evidence covers that claim.
