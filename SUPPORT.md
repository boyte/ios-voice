# Support

AppLocalVoice is a pre-release Swift package for local Apple speech input and
output. This checkout does not yet have a hosted issue tracker, discussion
forum, or support contact. Do not treat this file as a promise of a response
channel until the first-release hosting steps are complete.

## Before asking for help

- Start with the [README](README.md), [Quickstart](Documentation/Quickstart.md),
  [Troubleshooting](Documentation/Troubleshooting.md), and
  [Support Matrix](Documentation/SupportMatrix.md).
- Confirm the host is an ordinary iPhone or iPad app targeting iOS 26, not a
  keyboard extension or background-recording use case.
- Check model, locale, voice, and permission readiness at runtime. Those are
  Apple/device capabilities, not fixed package guarantees.
- Distinguish simulator findings from device findings. Routes, interruptions,
  AirPods, external audio, model installation, and endurance require a
  physical-device report.

## Once the repository is hosted

Use the hosted project's issue tracker for reproducible bugs and narrowly
scoped feature proposals. Include the package version/tag, iOS and Xcode
versions, device class, locale, audio route, exact lifecycle action, expected
result, observed typed error/state, and a minimal reproduction that contains
no user speech.

The project accepts bug reports and focused proposals. External pull requests
may illustrate a proposed fix, but are not accepted directly; see the
contribution policy in [README](README.md#contributing).

## Security, privacy, and conduct

Do **not** report a security or privacy issue in a public tracker. Follow
[SECURITY.md](SECURITY.md) once the host configures private vulnerability
reporting. Never attach microphone recordings, transcripts, TTS text,
credentials, raw crash dumps, or unredacted logs.

Conduct reports require a private channel. The release owner must add that
channel to [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before publication; do not
put sensitive allegations in a public issue.
