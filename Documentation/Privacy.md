# Privacy boundary

AppLocalVoice is a local speech transport layer. The core package contains no
HTTP client, WebSocket client, analytics, persistence, account system, or
credential storage.

## What stays local

The default implementation passes microphone buffers to Apple's on-device
speech APIs and passes text to Apple's local synthesizer. It does not send raw
microphone audio or transcript text to an AppLocalVoice server because there is
no AppLocalVoice server.

Apple may manage speech assets according to the operating system's documented
behavior. The package reports model availability and does not claim control over
Apple's internal implementation.

## What the host controls

If a host sends returned text to a chat, agent, MCP, or custom endpoint, that is
outside this package and subject to the host's privacy policy, credentials, and
network behavior. The host is responsible for deciding whether synthesized
response text may be spoken or logged.

## Logging rule

Production diagnostics must not contain audio, transcript text, speech text,
voice content, credentials, or arbitrary exception payloads copied from user
input. Safe diagnostics may include lifecycle state, operation id, route class,
locale identifier, timing, and stable error category.

The package's public opt-in diagnostic sink is narrower than that general host rule:
it excludes locale identifiers and reports only a coarse route class. It is
disabled by default, emits no records without a host-provided sink,
and never persists or exports records. See [privacy-safe diagnostics](Diagnostics.md)
for the host integration contract.

## Release artifact scanner

Before release, scan retained evidence directories with:

```sh
python3 Scripts/validate-privacy-artifacts.py \
  --metadata-allowlist Documentation/PrivacyMetadataAllowlist.json \
  Documentation/evidence
```

The scanner recursively inspects only Markdown, JSON, text, and log files. It
fails closed on unreadable files, symlinks, malformed JSON, credential-like
content, raw audio or speech/transcript/TTS content, and private absolute paths.
Diagnostics are sorted and stable in the form `path:line:CODE: message`; exit
status 1 means a privacy finding and exit status 2 means invalid scanner input
or policy.

Structured evidence may use only the scanner's documented safe metadata fields
(for example `operationId`, `state`, `routeClass`, `localeIdentifier`, timing,
and stable `errorCategory`). An explicit, sorted allowlist can extend those
fields only with names already approved by the scanner:

```json
{"metadata": ["event"]}
```

Pass it with `--metadata-allowlist`. An allowlist never permits credential
fields, private paths, or fields named `transcript`, `utterance`, `speechText`,
`ttsText`, or raw audio.

The checked-in [PrivacyMetadataAllowlist.json](PrivacyMetadataAllowlist.json)
contains the reviewed benchmark metadata paths (`measurements[].name` and
`measurements[].notes`) and artifact manifest logical paths
(`artifacts[].path`). These permit labels, controlled measurement notes, and
relative filenames only; absolute private paths and raw user speech remain
rejected.

For retained text logs, sanitize before publication:

```sh
python3 Scripts/sanitize-evidence-log.py input.log output.log
```

The sanitizer is deterministic and line-preserving. It replaces absolute paths
and username assignments with stable placeholders. A line matching likely
speech payload or credential content is replaced as a whole with an explicit
`[REDACTED: ...]` marker and counted in the CLI summary; it never invents or
partially reconstructs speech text. Invalid UTF-8, binary/control bytes,
symlinks, and logs over the 10 MiB default limit are rejected before output is
written.
