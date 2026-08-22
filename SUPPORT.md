# Support

AppLocalVoice is an early 0.x Swift package for local Apple speech input and
output. Use the hosted GitHub repository's issue tracker for reproducible bugs
and focused proposals; this document does not promise response times.

## Before asking for help

- Start with the [README](README.md), [Quickstart](Documentation/Quickstart.md),
  [Recovery guide](Documentation/Recovery.md), and
  [on-device speech guide](Documentation/OnDeviceSpeech.md).
- Confirm the host is an ordinary iPhone or iPad app targeting iOS 26, not a
  keyboard extension or background-recording use case.
- Check model, locale, voice, and permission readiness at runtime. Those are
  Apple/device capabilities, not fixed package guarantees.
- Distinguish simulator findings from device findings. Routes, interruptions,
  AirPods, external audio, model installation, and endurance require a
  physical-device report.

## Filing an issue

Use the GitHub issue tracker for reproducible bugs and narrowly
scoped feature proposals. Include the package version/tag, iOS and Xcode
versions, device class, locale, audio route, exact lifecycle action, expected
result, observed typed error/state, and a minimal reproduction that contains
no user speech.

The project accepts bug reports and focused proposals. External pull requests
may illustrate a proposed fix, but are not accepted directly; see the
contribution policy in [README](README.md#contributing).

## Security, privacy, and conduct

Do **not** report a security or privacy issue in a public tracker. Follow
[SECURITY.md](SECURITY.md). Never attach microphone recordings, transcripts, TTS text,
credentials, raw crash dumps, or unredacted logs.

Conduct reports require a private channel; see
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Do not put sensitive allegations in
a public issue.
