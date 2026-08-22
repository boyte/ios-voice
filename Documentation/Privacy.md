# Privacy boundary

AppLocalVoice is a local speech transport layer. The core package contains no
HTTP client, WebSocket client, analytics, persistence, account system, or
credential storage.

## What stays local

The default implementation passes microphone buffers to Apple's on-device
speech APIs and passes text to Apple's local synthesizer. It does not send raw
microphone audio or transcript text to an AppLocalVoice server because there is
no AppLocalVoice server.

A host that constructs `AppLocalVoice(synthesizer:)` with a plug-in engine
(for example `AppLocalVoiceKokoro`) sends speech text to that engine inside the
app process; the engine must not retain, log, or transmit it, and the package
still never does. Engine model files are host-bundled; the package downloads
nothing.

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

## Provider error text

Public `VoiceError` values use package-authored, stable messages when an Apple
provider returns an unclassified failure. The package never forwards an
Apple `localizedDescription` into its public errors or diagnostics. Hosts may
present the typed error category and recommended action, but should not treat
the generic message as provider diagnostic detail.
