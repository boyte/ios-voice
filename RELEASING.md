# Releasing AppLocalVoice

AppLocalVoice is an iOS Swift Package. A release is a source tag whose
checked-in API baseline, documentation, and deterministic tests describe the
same source state. The current remote already carries `v0.1.0`.

## Versioning

- Use semantic version tags of the form `vMAJOR.MINOR.PATCH`.
- Until `1.0.0`, breaking API reductions require an explicit migration note in
  `CHANGELOG.md`. Select the next semantic version from the actual public API
  change; do not assume a patch increment.
- Never update `Documentation/PublicAPISymbols.json` to hide an accidental
  removal. Regenerate it from production symbols and review each difference.

## Early-access releases

An early 0.x release may be published with physical-device behavior still
unverified, provided its release notes say so plainly and request privacy-safe
bug reports. It must not be called device-, route-, interruption-, or
endurance-qualified. Do not cite a test count or simulator result the
candidate revision did not actually produce.

## Candidate checklist

From a clean checkout with Xcode 26:

```sh
python3 Scripts/lint-repository.py
python3 Scripts/validate-documentation.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
Scripts/emit-public-symbol-graph.sh /tmp/AppLocalVoice-symbols /tmp/AppLocalVoice-derived
python3 Scripts/validate-public-api.py --symbol-graph /tmp/AppLocalVoice-symbols
python3 Scripts/validate-public-docs.py \
  --symbol-graph /tmp/AppLocalVoice-symbols/AppLocalVoice.symbols.json \
  --baseline Documentation/PublicAPISymbols.json
xcodebuild test -project Testing/AppLocalVoice.xcodeproj -scheme AppLocalVoiceTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO -maximum-parallel-testing-workers 1
```

Then work through the physical-device matrix in
[Documentation/DeviceMatrix.md](Documentation/DeviceMatrix.md) on the devices
the release claims to support, and list every untested cell as unknown in the
release notes.

## API comparison

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

Pull-request CI validates the candidate against the checked-in baseline only.
The tag workflow (`.github/workflows/release-validation.yml`) is the
fail-closed gate for the previous-tag comparison: it builds strictly, runs the
complete simulator suite on an iPhone and an iPad simulator, emits both symbol
graphs with the release toolchain, compares them, and creates the source
archive. The first semantic tag has no prior graph and skips only the
comparison step.

## Source archive

Create the release notes from `CHANGELOG.md`. Publish the source archive and a
SHA-256 checksum alongside the tag with:

```sh
Scripts/create-source-archive.sh v0.1.0 dist
```

The argument must be an exact `vMAJOR.MINOR.PATCH` tag, the tag must resolve
to the current `HEAD`, and the worktree must be clean. The archive is a Git
tar stream followed by `gzip -n`, so repeated runs for the same commit produce
identical bytes. The checksum file contains only the archive basename and is
relocatable with the archive:

```sh
shasum -a 256 -c dist/AppLocalVoice-v0.1.0.tar.gz.sha256
tar -tzf dist/AppLocalVoice-v0.1.0.tar.gz | head
```

## Git-host requirements

Branch protection on `main`, CODEOWNERS mapped to real maintainers, required
CI checks, private vulnerability reporting, and a reviewed release commit are
GitHub release-owner responsibilities. Both workflows pin every third-party
action to an immutable commit; `Scripts/lint-repository.py` fails on an
unpinned action.
