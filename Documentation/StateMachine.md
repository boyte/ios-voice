# State machine

The serialized lifecycle coordinator has one active lifecycle operation at a time. The
following model is the contract that tests and implementations must preserve.

```text
                 startListening
                      │
                      ▼
                    idle ◄──────────────┐
                      │                 │
                      ▼                 │ cancel / failure
                 preparing ─────────────┘
                      │
                      ▼
                 listening ──finish──► finalizing
                      │                    │
                      └─cancel────────────┘

idle ──speak──► speaking ──stop / natural completion / failure──► idle
```

Interruption and failure are externally observable terminal reasons, not
long-lived states. Recovery must end in `idle` before a new operation is
accepted. The current implementation reports them through terminal events and
must never leave audio resources active after a terminal path.

## Legal operations

| State | Operation | Result |
|---|---|---|
| `idle` | `startListening` | `preparing`, then permission/model/audio preflight and `listening` |
| `preparing` | `cancelListening`/`close` | cancel startup and return to `idle`, or remain `.failed` if cleanup is pending |
| `idle` | `speak` | `speaking` until completion or stop |
| `listening` | transcript stream | zero or more full snapshots |
| `listening` | `finishListening` | `finalizing`, then final text and `idle` |
| `listening` | `cancelListening` | cancel resources and return to `idle` |
| `finalizing` | `close` | cancel finalization and release resources |
| `speaking` | `pauseSpeaking`/`resumeSpeaking` | synthesizer pause/resume |
| `speaking` | `stopSpeaking` | stop playback and return to `idle` |
| any state | `close` | idempotent teardown and `idle` |

## Illegal operations

Starting a second listening operation, finishing while idle, or speaking while
an incompatible operation is active must fail with `VoiceError.invalidState`.
`pauseSpeaking()` and `resumeSpeaking()` are intentionally idempotent
nonthrowing controls: when speech is inactive, they do nothing. The
implementation must reject incompatible operations before allocating new audio
resources.

## Event ordering

For a successful recognition turn, consumers may rely on:

1. `stateChanged(.preparing)`;
2. `stateChanged(.listening)`;
3. zero or more `.transcript` snapshots while recognition is active;
4. `stateChanged(.finalizing)` after `finishListening()` begins;
5. zero or more buffered or provider-late transcript snapshots. Differing final phrase
   snapshots are allowed; only exact duplicate final text is suppressed;
6. exactly one `.listeningFinished(.completed)`;
7. `stateChanged(.idle)`.

The provider's `isFinal` flag describes its current transcript snapshot; it is
not the host-controlled end-of-turn signal. A provider may deliver that
snapshot immediately before or immediately after the `.finalizing` state
transition when both operations are already in flight. The string returned by
`finishListening()` and the `.listeningFinished(.completed)` event are
authoritative for the end of the turn. If a provider has already emitted a
final snapshot, a differing value returned by `stop()` is returned to the
caller and may produce one replacement final snapshot, but never a duplicate
of the same text.

For a failure after an operation has entered an active state,
`VoiceEvent.failure`, then `listeningFinished(.failed(failure))`, and the
transient `stateChanged(.failed)` are emitted before recovery to idle. A
startup failure emits `VoiceEvent.failure`, then a
transient `stateChanged(.failed)`, then `stateChanged(.idle)`; the eventual
public state is idle because no active operation remains. An interruption has
its own terminal reason and does not emit a duplicate generic failure event.
Cancellation emits no generic failure event unless provider cleanup itself
fails. In that case the terminal reason is a typed audio-session failure, the
service remains `.failed`, and `close()` must reconcile cleanup before a new
operation can start. All terminal reasons are emitted exactly once, including
when cleanup requires multiple close attempts.

Speech synthesis has a separate event contract: one request produces exactly
one of `speechFinished`, `speechCancelled`, or `failure`. Speech returns to
`idle` on natural completion; there is no callable `finish` operation for
speaking. An interruption is a failure with
`VoiceErrorCategory.interrupted`; it is not represented as a separate public
TTS termination enum.

Cancellation and failure are terminal for that generation. Late analyzer,
engine, or synthesizer callbacks are ignored. No event for an old generation
may mutate a later operation.

`close()` is idempotent teardown, not event-stream invalidation. Existing
`events()` streams remain open after close so a service can be reused; consumers
must cancel their own stream iteration when the voice surface is discarded.

## Resource ownership invariant

At every terminal boundary, exactly zero of these may remain owned by the
operation: microphone tap, audio engine run, analyzer task, converter, input
continuation, audio-session activation, and synthesizer request. Repeated
`cancel`, `stop`, and `close` calls must not double-release any resource.
