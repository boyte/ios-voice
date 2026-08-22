# Completed audio-file recognition

This document defines the AppLocalVoice half of the optional Watch companion
integration. It is deliberately useful to any iPhone or iPad app that already
has a completed local audio recording.

## Public shape

The additive session configuration will select one input:

```swift
let accepted = try await voice.startSession(configuration: .init(
    input: .audioFile(.init(url: recordingURL))
))
let final = try await voice.finishSession(id: accepted.sessionID)
```

`RecognitionAudioFile` is a value containing a local file URL and bounded
decode policy. `RecognitionInput` has two cases: `.microphone` and
`.audioFile`. Microphone remains the default, so existing callers keep their
current behavior.

The API deliberately accepts a completed file rather than `AVAudioPCMBuffer`,
an `AsyncSequence`, or a WatchConnectivity request. Those alternatives would
make ownership, real-time backpressure, retention, and concurrency part of the
public core contract. They are not required for the record-then-transfer use
case.

## Admission and lifecycle

File input uses the existing process-wide recognition admission, session ID,
event delivery, cancellation, final transcript, and exactly-once terminal
outcome model. A host calls `finishSession(id:)` to request orderly
finalization, just as it does for microphone capture. The provider may finish
a completed file before that call; the terminal outcome remains retrievable by
the same ID.

Unlike microphone input, file input must never request microphone permission,
acquire the microphone audio lease, configure `AVAudioSession`, install an
engine tap, or subscribe to route/interruption notifications. It still checks
Speech permission, supported locale, and local model readiness.

## Validation and bounds

The implementation rejects a non-file URL, an unreadable/non-regular file,
unsupported or corrupt decodable media, declared files above the byte limit,
and decoded content above the selected duration limit. It feeds bounded PCM
blocks through the existing analyzer conversion path, so no complete decoded
recording is retained in memory.

The default file duration must support a 20-minute meeting recording. The
implementation uses a separate file-input bound; it does not reinterpret the
existing microphone PTT duration default. Hosts may choose a smaller bounded
duration for their own product.

Errors are typed through existing recognition configuration/availability
categories unless a new category is necessary after implementation evidence.
They must not include a pathname, audio content, transcript, or decoder text.

## Ownership boundary

AppLocalVoice reads the supplied file only while the accepted session is
active. The host must keep it readable until a terminal outcome is observed.
The host owns all durable receipt, duplicate suppression, transfer retry,
assistant invocation, result persistence, and deletion decisions. The library
does not copy the recording to durable storage.

## Compatibility gate

The future AppLocalVoiceWatch bridge must depend on a tagged AppLocalVoice
release that contains this API and its public API baseline. It must not use a
local package path, private source import, internal provider, or a copied
implementation.
