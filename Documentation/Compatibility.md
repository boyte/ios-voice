# Compatibility contract

This document defines what downstream applications may rely on when importing
`AppLocalVoice`. It is part of the public product, not an implementation note.

Release status: **pre-release and not yet published.** This document records
the intended downstream contract for the current source surface, but no
versioned compatibility promise exists until a first tagged release completes
the [first-release handoff](FirstOpenSourceRelease.md). Public API/test
evidence is being reconciled; release notes must not quote historical
inventory totals or silently promote provisional behavior to a published
guarantee.

## Supported platform

- Minimum deployment target: iOS 26.
- Supported devices: iPhone and iPad devices on a supported iOS 26 release.
- Recognition uses Apple's `SpeechAnalyzer`/`SpeechTranscriber` APIs.
- Synthesis uses Apple's `AVSpeechSynthesizer` APIs.
- The package has no application or cloud speech-service dependency and no
  third-party runtime dependency. Apple may require connectivity when the host
  explicitly permits system model installation.

Apple may change locale, model, route, and voice availability between OS point
releases. AppLocalVoice reports those conditions at runtime; it does not claim
that every locale or voice is available on every device.

## Semantic versioning

Until 1.0, a minor release may still require source changes when an API or
behavior is explicitly marked experimental. Experimental APIs must be marked in
DocC and in the changelog. After 1.0:

- patch releases fix bugs without intentionally changing the public contract;
- minor releases add source-compatible APIs and documentation;
- major releases may remove APIs or change lifecycle semantics.

Changing actor isolation, `Sendable` conformance, error meaning, event ordering,
state-transition rules, or resource ownership is a breaking change even if the
Swift compiler accepts the source unchanged.

`VoiceState` and `VoiceEvent` are public enums. `VoiceState.preparing` means a
listening operation owns the lifecycle but is waiting on permission, model
readiness, audio-session activation, or engine startup. Downstream exhaustive switches
should include `default` or `@unknown default` so a future case can be handled
without making an app fail to compile. Adding a public enum case is treated as
a source-compatibility change and is called out in API and migration notes.

## Stable versus descriptive values

- `SpeechVoice.id` is the stable identifier to persist or pass back as
  `SpeechConfiguration.voiceIdentifier`. `name` is display text and may change.
- `SpeechVoice.languageIdentifier` is informational and follows Apple's voice
  metadata; do not use it as proof that recognition supports that locale.
- `SpeechCapabilities.reason` is diagnostic text and is not a stable error code.
- `VoiceError` cases are stable categories. Associated strings are for humans,
  not machine parsing.
- `TranscriptUpdate.text` is a full snapshot, not a delta. Consumers should
  replace their displayed transcript with each update.

## Cancellation and ownership

A single recognition transcript or synthesis request is limited to 1,048,576
UTF-16 code units. Exceeding that bound fails closed with
VoiceError.textTooLong; the bound prevents a stalled or accidental host
request from creating unbounded in-memory text state.

All lifecycle methods are async. The host owns the `AppLocalVoice` instance and
must call `close()` when its voice surface is discarded. `cancelListening()` and
`stopSpeaking()` are idempotent. A cancelled generation must not emit a later
final transcript or completion event.

If provider cleanup fails, the service remains in `.failed` and rejects new
operations until a later `close()` succeeds. The library never reports a clean
`.idle` state while it still owns a microphone tap, analyzer, or audio-session
lease.

Synthesis completion is bounded by an internal recovery watchdog (30 seconds
minimum, 300 seconds maximum per utterance, reset by delegate progress). A no-callback failure is reported
as `VoiceError.speechSynthesisUnavailable`; hosts should discard that turn and
offer an explicit retry. The timing is an implementation safety boundary, not
a stable latency promise.

The package has one process-wide audio owner and a scheduler with two distinct
speech lanes. Direct `speak` uses a dedicated immediate one-shot lane and never
inherits a suspended chat-queue mode, never clears unrelated queue work, and
must return one terminal result or a bounded typed failure. Chat queue attempts
obey queue controls and mode. If the shared audio provider cannot safely admit
an immediate request, the request fails in a bounded, typed way; it is not
silently stranded behind suspended queue work.

`startListening` has no public progress callback and no implicit session
timeout. While Apple performs an explicitly permitted model installation, the
host may show indeterminate progress and cancel the task; capability lookups
are live rather than cached. The host owns any maximum-duration policy.

`pauseSpeaking()` and `resumeSpeaking()` are nonthrowing and idempotent. They do
nothing when no synthesis request is active; hosts do not need to track a
separate paused state. Queue `stop` retains pending work and suspends it;
`stop-and-clear` is a separate command that cancels pending work. These commands
must not be documented or implemented as aliases.

An empty or whitespace-only string passed to `speak` is a no-op with no speech
events. It does not reserve an operation and bypasses speech configuration and
voice validation. Non-whitespace text is validated by the synthesis provider.

`close()` is idempotent resource teardown and returns `.released` only when all
owned cleanup has been observed. A `.blocked(VoiceFailure)` result leaves
cleanup unresolved; retry `close()` before starting another operation. It does not finish existing
`events()` streams. Consumers should cancel stream iteration when the voice
surface is discarded. A service may be reused after `close()`.

The text-size ceiling is checked before synthesis chunking and during transcript
assembly. A rejected text result does not replace the last valid transcript
snapshot, and the host must discard the failed turn or submit a shorter one.

The legacy event projection keeps its documented bounded compatibility behavior.
The canonical `voiceEvents()` subscription is side-effect free: creating it
does not publish a recovery event or alter existing observers, and only the new
subscriber receives its own current recovery snapshot. Recovery is also
queryable independently. The first-release canonical stream must preserve the
typed admission and durable-overflow rules in the contract documentation.

Losing a facade owner must not permanently strand the process lease. Safe
reclamation either releases the lease after provider/audio cleanup or exposes a
bounded typed blocked/retry state; a later facade must never bypass unresolved
ownership.

Finishing an admitted recognition session while it is preparing latches normal
finalization for that exact session. It returns the final transcript (possibly
empty) or the typed startup/cleanup/interruption failure that wins; it must not
turn an ordinary quick release into cancellation or report
`VoiceError.invalidState` merely because listening has not begun.

## First-release compatibility acceptance matrix

| Area | First-release promise | Removal/rejection requirement | Evidence status |
|---|---|---|---|
| One-shot `speak` | Dedicated immediate lane, independent of suspended chat queue, own cancellation/result | No hidden queue append, indefinite wait, or unrelated queue clear | Accepted locally; deterministic and simulator tests complete |
| Queue stop | Retains pending work and suspends queue | Stop cannot retain one meaning in one API and clear in another | Accepted locally; deterministic and simulator tests complete |
| Stop-and-clear | Separate command that clears pending work and suspends | Must not be an alias for `stop` | Accepted locally; API and simulator tests complete |
| Lifecycle policy | External-audio policy plus stop-and-require-explicit-resume on interruption/background/invalid route | Remove or typed-reject pause-on-background, continue-on-route, and retry-on-cleanup options before release | Accepted locally; physical lifecycle matrix pending |
| `voiceEvents` | Side-effect-free subscription, own recovery snapshot only, queryable recovery | No broadcast snapshot or false `.ready` to existing observers | Accepted locally; subscriber isolation and simulator tests complete |
| Lost owner | Safe lease reclamation or bounded typed blocked/retry state | No permanent `serviceInUse` after owner loss | Accepted locally; deterministic lease audit complete |
| Early finish | Preparing release latches normal finalization and returns final text or typed startup/cleanup failure | No automatic cancellation or ordinary `invalidState` for fast press/release | In progress; preparation-release regression compiles locally |

## Compatibility evidence

Every release must record the Swift/Xcode toolchain, iOS SDK, simulator result,
public symbol graph, DocC result, and physical-device matrix. A public behavior
change requires a changelog entry, migration note, and regression test or a
written device-only justification.

For the current pre-release baseline, record the local portion with the symbol
graph and validator command in [PublicAPI.md](PublicAPI.md#machine-checking-and-release-upgrades),
then run the warnings-as-errors DocC command in
[ReleaseAudit.md](ReleaseAudit.md#open-task-acceptance-matrix). These commands
do not satisfy the previous-release comparison or physical-device matrix;
those remain release-blocking open evidence.
