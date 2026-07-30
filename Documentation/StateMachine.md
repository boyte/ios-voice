# State machine

AppLocalVoice serializes microphone capture and speech playback. A recognition
session is admitted with an identity before provider startup completes; it
progresses through preparing, listening, finalizing, then one terminal outcome.

```text
idle → startSession → preparing → listening → finishSession → finalizing → idle
                              └──────── cancelSession ────────────────→ idle

idle → enqueueSpeech / speakImmediately → speaking → terminal playback result → idle
```

The canonical stream carries session state, previews, final transcript, queue
events, recovery transitions, and a reconciliation snapshot. Hosts filter by
the session or playback identity they own. Previews can coalesce; final
transcripts and terminal outcomes cannot be inferred from a preview.

`close()` cancels active work and proves whether resources were released. When
it returns `.blocked`, the process remains unavailable for new audio work until
the app-owned service owner retries close successfully. Late provider callbacks
cannot mutate a later session or playback attempt.

The coordinator owns no host text or message history. Queue, event, preview,
and result retention are bounded, and diagnostics contain no content.
