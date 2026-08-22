# Architecture

AppLocalVoice has one narrow responsibility:

```text
speech → local text
local text → speech
```

The host app owns chat, agents, network requests, persistence, credentials, and UI.

## Runtime layers

```text
AppLocalVoice facade
        │
        ▼
VoiceCoordinator actor
        ├── SpeechInput
        ├── SpeechOutput
        └── AudioSessionController actor
                └── process-wide AudioSessionBroker
                        └── AVAudioSession
```

`AppleSpeechInput` is the only component that owns the microphone engine and Apple speech analyzer. `AppleSpeechOutput` owns the Apple synthesizer. The coordinator serializes public operations and publishes value-type events.

## Concurrency rules

- The coordinator is actor-isolated.
- Audio-session mutations are actor-isolated.
- The broker uses owner-scoped leases so one facade cannot release another
  facade's audio session.
- The host never mutates lifecycle state directly.
- Cancellation and teardown are safe to call repeatedly.
- Providers must not retain host UI objects.
- Speech content is not written to diagnostics.

The provider protocols and Apple adapter types are internal seams used for
deterministic tests. They do not expand the package into a chat framework or
become a permanent public compatibility burden.

## Provider boundary

The Apple implementation is the default and has no third-party runtime
dependency. Text-to-speech is pluggable through one public protocol,
`SpeechSynthesizer` (text in, mono Float32 PCM out): a host passes any engine
to `AppLocalVoice(synthesizer:)`, and the package's engine-agnostic
`PCMSpeechOutput` owns chunking, playing the first chunk while the next is
synthesized, the audio-session lease, interruptions, barge-in, pause/resume,
and exact completed-chunk progress. The engine is chosen at construction and
never hot-switched.

`AppLocalVoiceKokoro` is the first engine product (Kokoro-82M on MLX). It is
gated behind the package trait `Kokoro` so consumers that never enable it
fetch and build nothing beyond the core; it runs on Apple GPUs only (no
simulator). Speech recognition remains Apple-only; a full conversational
provider remains outside this package.
