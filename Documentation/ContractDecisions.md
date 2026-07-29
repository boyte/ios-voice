# Contract decisions for the host-ready rebuild

Status: E0 contract decisions are documented and in progress. The source,
tests, public API baseline, and independent review must still prove these
decisions before first release; this documentation pass makes no source-code
claim and makes no source-code change.

This document records E0-T01 through E0-T06 decisions for the
standalone AppLocalVoice rebuild. The end-to-end host flow and adoption modes
are in [AdoptionMatrix.md](AdoptionMatrix.md). The current implemented contract
and release boundary are described in [Compatibility.md](Compatibility.md),
[StateMachine.md](StateMachine.md), and [Recovery.md](Recovery.md) until the
corresponding implementation, tests, API baseline, and public documentation
land together.

“Must” and “never” below are normative. E1 may adjust a proposed Swift spelling
only through an explicit contract-change record; it may not merge meanings or
weaken identity, ordering, boundedness, or ownership guarantees. When this
document and a provisional, non-baselined source declaration disagree, this
document is the E0 authority and the source declaration must be reconciled
before E1 acceptance.

## Decision register

| ID | Decision | Status |
|---|---|---|
| CD-001 | The rebuild is additive first: current facade calls remain compatibility adapters over the new engines until a separately documented removal window | Frozen |
| CD-002 | One app-scoped facade owns one queue, while one process-wide runtime lease arbitrates all audio/session mutation | Frozen |
| CD-003 | `RecognitionSessionID`, `SpeechItemID`, and `SpeechPlaybackID` are opaque, library-generated identities; `SpeechPlaybackID` identifies one playback attempt | Frozen |
| CD-004 | Preview, stable chunk, recognition-final transcript, host draft, and host-submitted text are five different concepts | Frozen |
| CD-005 | There are exactly three transcript publication policies; editable draft is host behavior built from `previewAndFinal`, never a fourth policy or library draft value | Frozen |
| CD-006 | Stable chunks use contiguous half-open UTF-16 ranges, an unchanged-prefix rule, and a validated 1...30-second interval; successful completion reconstructs the final transcript exactly | Frozen |
| CD-007 | Speech item identity survives replay; every accepted first enqueue and replay gets a distinct `SpeechPlaybackID` | Frozen |
| CD-008 | The queue defaults, valid bounds, priorities, four placement policies, two overflow policies, replay behavior, and mutation/event order in this document are authoritative | Frozen |
| CD-009 | Logical operation completion and physical resource reconciliation are separate host-visible facts | Frozen |
| CD-010 | Backgrounding, interruption, route invalidation, and media-services reset never silently restart recognition or playback | Frozen |
| CD-011 | Advisory previews/state may coalesce; canonical stable data and lifecycle events never silently drop, and subscriber admission or delivery overflow fails explicitly | Frozen |
| CD-012 | The host backend callback, messages, persistence, autoplay choice, editing, submit, and discard remain outside the package | Frozen |
| CD-013 | Text, queue, replay history, event subscribers, and event buffers are finite; diagnostics remain content-free | Frozen |
| CD-014 | E0-T06 approves iOS 26, Xcode 26.x, Swift tools 6.2/Swift 6, and ordinary iPhone/iPad app targets | Frozen |
| CD-015 | The independent E0 review returned changes requested; this document records the requested first-release semantics for implementation and review | Local implementation and independent source review complete; physical/repository release gates pending |
| CD-016 | Existing shipped methods remain source-compatible adapters over one canonical engine; new host-ready calls and a throwing durable event stream are additive | Accepted; strict build, API baseline, and simulator verification complete |
| CD-017 | One-shot `speak` uses a dedicated immediate lane and never inherits suspended chat-queue mode | Accepted; deterministic scheduler regressions complete |
| CD-018 | `stop` retains pending work and suspends; `stop-and-clear` is a separate command that clears pending work | Accepted; public command and terminal-order regressions complete |
| CD-019 | First release supports external-audio policy and stop-and-require-explicit-resume for interruption, background, and invalid route; unsupported lifecycle options are removed before release | Accepted locally; physical lifecycle matrix pending |
| CD-020 | `voiceEvents` subscription is side-effect free for existing subscribers, delivers only its own recovery snapshot, and exposes queryable recovery state | Accepted; subscriber-isolation and durable recovery-transition regressions complete |
| CD-021 | A lost facade owner is safely reclaimable; unresolved physical cleanup remains a typed blocked/retry condition | Accepted locally; deterministic lease and close audit complete |
| CD-022 | Finishing an admitted session while preparing latches finalization for that exact session; it returns a final transcript or typed startup/cleanup failure, never ordinary early-release `invalidState` or automatic cancellation | Implementation in progress; deterministic regression required |

## E0 release acceptance matrix

The following table is the acceptance boundary for this E0 documentation pass.
“Proposed” means the semantic decision is recorded but source and regression
evidence are not yet complete. A first release cannot promote a row until its
source/API, deterministic test, and documentation evidence all agree.

| E0 decision | Required observable contract | Required evidence | Status |
|---|---|---|---|
| One-shot lane | Direct `speak` is an immediate-lane request, is not inserted into or gated by suspended chat-queue mode, cannot clear unrelated queue work, and reaches one terminal result or bounded typed failure | Scheduler/queue, cancellation, close/reuse, strict build, and simulator suite | Accepted locally |
| Stop versus stop-and-clear | `stop` terminalizes only active work as stopped, retains pending attempts, and suspends; separate stop-and-clear terminalizes active and pending work and suspends | Deterministic event/result order, public command audit, and simulator suite | Accepted locally |
| First-release lifecycle subset | External-audio policy is honored; interruption, background, and invalid route stop active work, retain pending work, suspend, and require explicit host resume; unsupported alternatives are rejected or removed | Typed cause regressions, public API audit, and simulator suite | Accepted locally; physical matrix pending |
| Recovery subscription | `voiceEvents` does not publish a recovery event when a subscriber is created; only the new subscriber receives its current snapshot; recovery is independently queryable | Two-subscriber reconciling/blocked and snapshot-query regressions | Accepted locally |
| Lost owner | Losing the facade owner cannot permanently hold `serviceInUse`; safe cleanup/reconciliation completes before reuse, or exposes bounded typed blocked/retry state | Deterministic lease and cleanup/reuse audit | Accepted locally |
| Early finish | Release during preparing latches finalization and returns that session's final transcript or typed startup/cleanup failure, with one terminal outcome and no ordinary `invalidState` error | Recognition facade preparation-release, cancellation-precedence, and startup-failure regressions | In progress |

## Contract-change records

### CCR-001 — Canonical E1 identity spellings

- **Date:** 2026-07-11
- **Status:** accepted contract amendment; independent release verification is
  pending
- **Decision:** the implemented E1 names `RecognitionSessionID` and
  `SpeechPlaybackID` are canonical. `SpeechPlaybackID` means one playback
  attempt, never the immutable item. `SpeechItemID` remains the immutable item
  identity that survives replay.
- **Creation:** all three accepted identities are library-generated with
  nonpublic constructors. `startSession` returns
  `RecognitionSessionAcceptance`; first enqueue/replay returns
  `SpeechPlaybackAcceptance`. Pre-admission rejection returns no accepted ID.
  Replay retains `SpeechItemID` and creates a fresh `SpeechPlaybackID`.
- **Compatibility:** the discarded proposal names `SpeechSessionID` and
  `SpeechPlaybackAttemptID` never entered the checked-in public API baseline, so
  no compatibility aliases are required or approved for shipment. They must not
  be added as parallel public types. The existing `SpeechItemEvent` alias to
  `SpeechQueueEvent` is unrelated lifecycle vocabulary and creates no second
  identity type.

### CCR-002 — Canonical event-delivery failures

- **Date:** 2026-07-11
- **Status:** accepted contract amendment; source and regression implementation complete
- **Decision:** subscriber admission failure and durable delivery overflow are
  different machine-readable failures. `eventSubscriberLimitReached` rejects
  only the new subscription. `eventDeliveryOverflow` terminates only an already
  admitted slow subscriber and identifies the first durable event not delivered.
- **Context:** both failures carry the configured maximum; delivery overflow also
  carries the typed event scope and first-undelivered ordinal defined in the
  event-delivery section. Context is content-free and mandatory, not best effort.

## Current baseline and migration boundary

The current facade is `@MainActor AppLocalVoice`. It exposes explicit
`startListening`, `finishListening`, and `cancelListening`; full
`TranscriptUpdate` snapshots with `isFinal`; direct `speak`, pause, resume, and
stop; a bounded `VoiceEvent` stream; actionable state; and retryable
`close() -> CleanupResult` cleanup.

The current source and tests already establish useful invariants that the
rebuild must preserve:

- one serialized active recognition or direct-speech operation per facade;
- generation checks suppress stale provider callbacks;
- a recognition terminal reason is emitted at most once;
- speech has one of finished, cancelled, or failure as its terminal result;
- background, interruption, route loss, and media-services invalidation end
  active work and do not auto-restart it;
- unresolved microphone or synthesizer cleanup remains failed until close can
  reconcile it;
- event subscribers and text requests are bounded; and
- `close()` is idempotent, leaves existing event streams open, and permits
  reuse after confirmed cleanup.

The rebuild adds typed transcript kinds, public identities, a public queue,
playback attempts, policy types, recovery state, and a canonical throwing event
stream. It must not implement a parallel path beside the old facade:

- legacy recognition calls adapt to one target recognition session and preserve
  their existing return/throw behavior;
- legacy direct `speak` adapts to the dedicated immediate lane, never to a
  suspended chat-queue mode, and awaits only its own attempt;
- legacy pause, resume, stop, and stop-and-clear delegate to the queue owner;
- The pre-release `close() -> Bool` shape was removed before the first tag.
  Swift cannot overload a method solely by return type, so keeping it beside
  canonical `close() -> CleanupResult` would create the very parallel cleanup
  contract this rebuild forbids.

The host-ready surface is additive. The canonical start operation is
`startSession(configuration:) async throws -> RecognitionSessionAcceptance`; it
returns the library-generated `RecognitionSessionID` and accepted ordinal
without changing `startListening(configuration:)`.
The legacy method delegates to the same admitted session, waits for provider
startup as it does today, and returns or throws using the existing contract.
`finishListening`, `cancelListening`, `speak`, pause, resume, stop, and `close`
likewise delegate to the canonical session/queue/runtime owners. Legacy
`events() -> AsyncStream<VoiceEvent>` remains a bounded compatibility projection;
the new host-ready stream has a distinct name and throwing overflow semantics.
No legacy method is removed or signature-changed in the host-ready release.

Changing the event meaning, actor isolation, ownership, or ordering of a
legacy call requires compatibility and migration documentation even when the
method signature still compiles.

### Current implementation status

Some value-level E1 models and the additive recognition-session seam are
present in the current checkout, but the E0 decisions below remain source and
test gates. Existing declarations are not proof that behavior is implemented:

| Current E1 source | Contract status and remaining work |
|---|---|
| `SpeechSessionTypes.swift` defines library-created `RecognitionSessionID`, exactly three publication policies, 1...30-second `StableChunkPolicy`, and 8/32 delivery limits | Existing declarations; E0 behavior and release baseline still pending |
| `TranscriptPublicationTypes.swift` defines transcript payload/value models and recognition acceptance/outcome values | Existing declarations; deterministic E0/E1 evidence still pending |
| `SpeechQueueTypes.swift` defines identity-free requests, queue identities, bounds, placements, and overflow values | Existing declarations; dedicated lane and stop semantics still pending |
| `VoiceError` includes event-delivery and cleanup categories | Existing declarations; typed lifecycle rejection/removal audit still pending |
| `AppLocalVoice` and `VoiceCoordinator` expose the legacy path plus additive session, queue, lifecycle, and canonical-event APIs | Surface exists in part; ownership, recovery, lifecycle, and event side-effect behavior remain implementation gates |

## Library and host ownership ledger

| Concern | Sole owner | Contract |
|---|---|---|
| Apple recognition and synthesis providers | Library | Provider types and callbacks remain internal |
| Microphone, synthesizer, and `AVAudioSession` | Library | One process-wide arbiter; no host escape hatch |
| Active recognition generation | Library | One admitted session at a time; stale callbacks cannot mutate a later session |
| Transcript assembly and publication classification | Library | Preview, stable chunk, and recognition-final values are never interchangeable |
| Recognition turn boundary | Host | Host explicitly starts, finishes, or cancels; no silence-based implicit submit |
| Composer and keyboard UI | Host | Library never owns selection, draft range, editing, or button state |
| Host draft and submitted text | Host | Submit reads the edited composer; no library commit API exists |
| Backend callback and transport | Host | No HTTP, WebSocket, SSE, agent, or backend callback enters the package |
| Messages and persistence | Host | Library receives no message model or store |
| Speech item contents after acceptance | Library queue | Item text/configuration are immutable for that item ID |
| Queue order and playback controls | Library queue | Host issues policy-bearing commands; host does not mirror a second speech queue |
| Autoplay choice | Host | Autoplay occurs only because the host enqueues while the queue is running |
| Host message to speech item mapping | Host | Host IDs never enter library diagnostics |
| Interruption, route, background, and media-services observation | Library | Provider/runtime observation is centralized and content-free |
| View and scene lifetime | Host | Host cancels observation and explicitly closes a retired service |
| Resource ownership truth and recovery state | Library | Host never guesses readiness from UI state or elapsed time |
| Retry timing and explanation | Host | Retry is explicit and never a tight library loop |

### Process-wide ownership decision

The recommended integration creates one AppLocalVoice facade at application or
shared-service scope. The first admitted start, enqueue, replay, queue-control,
or other audio-mutating call on a facade atomically acquires the package's one
process runtime lease. The facade keeps that lease through idle periods so its
queue, item history, and event ordering cannot compete with another facade. A
successful close releases it; operation completion alone never does.

Capability and installed-voice queries do not acquire the lease. A mutating
call from another facade while the lease is held fails before queue mutation or
provider admission with a stable `serviceInUse` category and creates no session,
item, or attempt identity. It may try again only after the owning facade
successfully closes. An implementation may internally share one runtime, but it
may not create a second process queue or audio owner to make the second call
appear successful.

Calling close on a facade that does not own the runtime is an idempotent
released no-op. It must never close, stop, clear, or otherwise mutate work owned
by another facade.

Explicit close remains the preferred release contract, but a lost facade owner
must be reclaimable. A lease-owner token or equivalent lifetime record must
atomically identify that the owner is dead, prevent unsafe concurrent reuse,
drain or reconcile provider/audio cleanup, and then either release the process
lease or publish a typed blocked/retry state. Deallocation must not permanently
return `serviceInUse`, and it must never silently claim that physical cleanup
completed when ownership is unresolved.

| Lost-owner outcome | Required behavior | Forbidden behavior |
|---|---|---|
| Cleanup reconciles successfully | Release the dead owner's process lease; a new facade may acquire it | Permanent `serviceInUse` lock |
| Cleanup remains unresolved | Retain safe ownership/reconciliation barrier and expose queryable typed blocked/retry state | Unsafe concurrent audio reuse or false ready state |
| A new facade races reclamation | Wait only on a bounded reclamation path or receive typed recovery result | Mutate the old owner's queue or bypass the process lease |

## Proposed public semantic ledger

## API-02 — frozen host-ready facade sketch

This is the sole naming and ownership authority for new host-ready calls. It
is deliberately a sketch rather than a promise that the corresponding source
already exists. A ticket that implements one of these calls must land its
value types, documentation, deterministic tests, and public-symbol baseline
change together. There is no first-release overload that accepts a backend,
chat message, UI binding, or host persistence object.

```swift
@MainActor
public final class AppLocalVoice {
    public init(configuration: VoiceServiceConfiguration = .init())

    public func capabilitySnapshot(
        for locale: Locale = .current
    ) async -> VoiceCapabilitySnapshot

    public func prepareRecognition(
        for locale: Locale = .current,
        policy: SpeechModelPolicy = .installedModelsOnly,
        progress: RecognitionPreparationProgressHandler? = nil
    ) async throws -> RecognitionPreparationResult

    public func runtimeSnapshot() async -> VoiceRuntimeSnapshot
    public func voiceEvents() async -> VoiceEventStream

    public func startSession(
        configuration: RecognitionSessionConfiguration = .init()
    ) async throws -> RecognitionSessionAcceptance
    public func finishSession(
        id: RecognitionSessionID
    ) async throws -> FinalTranscript
    public func cancelSession(id: RecognitionSessionID) async

    public func speakImmediately(
        _ text: String,
        configuration: SpeechConfiguration = .init()
    ) async throws -> SpeechPlaybackAcceptance
    public func enqueueSpeech(
        _ request: SpeechItemRequest,
        policy: SpeechEnqueuePolicy = .append
    ) async throws -> SpeechPlaybackAcceptance
    public func replaySpeech(
        _ itemID: SpeechItemID,
        policy: SpeechEnqueuePolicy = .append
    ) async throws -> SpeechPlaybackAcceptance
    public func waitForSpeechPlayback(
        id: SpeechPlaybackID
    ) async throws -> SpeechPlaybackResult
    public func pauseSpeechQueue() async -> SpeechControlResult
    public func resumeSpeechQueue() async -> SpeechControlResult
    public func stopSpeechQueue() async -> [SpeechPlaybackResult]
    public func stopAndClearSpeechQueue() async -> [SpeechPlaybackResult]
    public func skipSpeechQueue() async -> SpeechPlaybackResult?
    public func clearPendingSpeechQueue() async -> [SpeechPlaybackResult]

    public func close() async -> CleanupResult
    public func diagnostics() -> VoiceDiagnosticsStream
}
```

`VoiceServiceConfiguration` contains only package-owned, immutable-at-service
construction settings: queue limits/policy, audio integration mode, and
diagnostics opt-in. A host creates one instance at app/shared-service scope and
injects that instance into its feature models. The library intentionally does
not publish a general `VoiceService` protocol. A host that needs a mock owns a
narrow protocol in its own target and adapts `AppLocalVoice` to it.

`capabilitySnapshot` is side-effect clear: it does not prompt, install an
asset, open the microphone, acquire the runtime lease, configure audio, or
start playback. `prepareRecognition` is the only API permitted to prompt for
required permissions or request an opted-in model installation; it never
creates a session ID or microphone/audio lease. `runtimeSnapshot` is a
coherent, finite current-state query. `voiceEvents` first supplies that
snapshot, then later events; it is not a replay log.

`prepareRecognition` returns a post-preparation capability snapshot and whether
this call owned a successful system installation request. Joining an existing
download, finding a preinstalled model, or receiving a nil request returns
false. Preparation holds an exclusive coordinator admission reservation across
all awaits; another preparation or voice start is rejected, and close fails
closed until the caller cancels/joins preparation. It is rejected while capture
or cleanup is active, so it cannot race model reservations with a live provider.
Its optional main-actor progress handler carries only checking, download
progress, and installed phases. Apple's `downloading` asset status is
in-flight, never a terminal failure: preparation waits cancellably with a
fixed polling cadence and no arbitrary wall-clock deadline for a normal system
download. Progress reaching 100% and `downloadAndInstall()` returning do not
prove readiness: after an owned request, joined download, or nil request,
both `downloading` and `supported` remain cancellable nonterminal reconciliation
states until exact `installed`. An authoritative `unsupported` state maps to
on-device unavailability. Genuine provider failures retain only NSError domain
and numeric code; localized descriptions and userInfo are discarded.
The default session duration is 120 seconds after the provider reaches
listening; the supported finite range is 1...600 seconds, and `nil` means no
library duration limit. Expiry uses normal finalization and produces the typed
`durationLimitReached` terminal outcome when cleanup succeeds.

`speakImmediately` accepts an identified immediate-lane attempt; its return
does not await audible completion. `waitForSpeechPlayback` waits only for the
identified attempt. Cancelling that task cancels the wait, never playback,
queue state, or another caller's wait. Progress is carried by the canonical
event stream as advisory `SpeechPlaybackProgress` values correlated by
`SpeechPlaybackID`; ranges are original-text UTF-16 ranges and never a timing
or phoneme promise.

`close` is the only ordinary service-retirement boundary. It returns
`CleanupResult`, never a Boolean; `.released` means all package-owned
providers and a library-managed session transition have been observed clean.
`.blocked` retains the typed cause and requires explicit retry. Deinit is not
a substitute for calling `close`.

All facade mutation is `@MainActor`; every public value carried across tasks
is `Sendable`. Identity initializers remain nonpublic. Public asynchronous
operations are cancellation-aware, but cancellation of a caller's observation
does not silently alter another accepted session or playback attempt.

### Compatibility disposition

Until API-01's symbol table is accepted, current calls retain their behavior
only as adapters: `startListening`/`finishListening`/`cancelListening`,
`events`, `recognitionEvents`, `speak`, `pauseSpeaking`, `resumeSpeaking`, and
`stopSpeaking`. The first release documentation teaches only the sketch above.
The implementation must either retain each adapter with a stated migration
path or remove it before the first tag; it must not describe both pathways as
co-equal canonical APIs. `capabilities(for:) -> SpeechCapabilities` is
superseded by `capabilitySnapshot(for:)`; it is not a second capability model.
The former `close() -> Bool` shape was a deliberate pre-1.0 source-breaking
removal, not an adapter, because return-type-only overloading is impossible in
Swift. The shipped API returns `CleanupResult`.

These names are the canonical E0 spellings. All value types are `Sendable` and,
where identity or dictionary use applies, `Hashable`. The facade and callbacks
that mutate lifecycle state remain main-actor isolated.

| Proposed name | One meaning | Creator and owner | Ordering or serialization rule |
|---|---|---|---|
| `AppLocalVoice` | App-facing local voice facade | Host creates; library controls internals | `@MainActor`; mutation serialized through one runtime lease |
| `RecognitionSessionID` | One admitted recognition generation | Library after admission succeeds | Unique for process lifetime; never reused; no text embedded; host input cannot choose it |
| `TranscriptPublicationPolicy` | Which transcript payload kinds are published | Host configures; library enforces | Fixed for one session |
| `StableChunkPolicy` | Stability interval from 1...30 seconds inclusive and finite delivery bound | Host configures within valid range | Fixed for one session; default interval is five seconds |
| `TranscriptPreview` | Volatile complete transcript snapshot | Library | Revision starts at zero and strictly increases per session; coalescible |
| `StableTranscriptChunk` | Immutable append-only transcript segment with a half-open UTF-16 range | Library | Sequence starts at zero; sequence and text range are contiguous and never repeat or rewrite |
| `FinalTranscript` | Immutable complete recognition result | Library | At most once and before the successful session terminal |
| `RecognitionEvent` | Typed session acceptance, state, transcript, and terminal event | Library | Carries session ID and monotonic event ordinal |
| `RecognitionOutcome` | Exactly-once logical terminal result | Library | Completed, cancelled, interrupted, or failed; never advisory |
| `SpeechItemID` | Identity of one immutable speakable value | Library on accepted first enqueue | Stable through replays; never reused; host input cannot choose it |
| `SpeechPlaybackID` | Identity of one accepted attempt to play an item | Library on accepted first enqueue/replay | New for every attempt; exactly one terminal outcome |
| `SpeechItemRequest` | Host input text, optional priority, and speech configuration without identity | Host creates; library validates | Rejection creates no accepted identity |
| `SpeechItem` | Immutable accepted text and configuration behind an item ID | Library creates from an accepted request | No mutation; changed text requires a new request and item ID |
| `SpeechQueueConfiguration` | Finite pending/history bounds and defaults | Host configures; library validates | Fixed until queue is empty or close succeeds |
| `SpeechPriority` | `normal` or `userInitiated` pending order | Host chooses per request; default is `normal` | User-initiated before normal; FIFO within priority; never implicit preemption |
| `SpeechEnqueuePolicy` | Append, play-next, replace-current, or replace-all placement | Host chooses per attempt | Applied atomically before accepted event |
| `SpeechQueueOverflowPolicy` | Reject-new or drop-oldest-pending behavior | Host configures | Active item is never overflow victim |
| `SpeechControlResult` | Applied, already-applied, no-active-playback, or provider-rejected result of pause/resume | Library | Returned for each target queue control; never inferred from button state |
| `SpeechQueueEvent` | Item/attempt lifecycle plus queue snapshots | Library | Carries item ID, attempt ID when applicable, and monotonic queue event ordinal |
| `SpeechPlaybackOutcome` | Exactly-once terminal result for an accepted attempt | Library | Finished, cancelled with reason, skipped, interrupted, or failed |
| `VoiceEventStream` | Canonical throwing stream for recognition, transcript, queue, and recovery events | Library creates after subscriber admission | Durable events do not coalesce; delivery gaps terminate the affected stream explicitly |
| `EventSubscriberLimitContext` | Machine-readable rejected-subscription counts | Library | Carries maximum and active subscriber counts; no content |
| `EventDeliveryCursor` | First durable event not delivered to one subscriber | Library | Typed recognition, queue/playback, or process-runtime scope plus exact ordinal |
| `EventDeliveryOverflowContext` | Machine-readable slow-subscriber gap | Library | Carries durable capacity 32 and one `EventDeliveryCursor`; no content |
| `VoiceRecoveryState` | Whether new audio work is safe | Library | Ready, reconciling, or blocked; never inferred from elapsed time |
| `CleanupResult` | Result of one explicit close/reconcile request | Library | Released or blocked with stable category; content-free |

There is deliberately no public `SubmittedTranscript`, `CommittedTranscript`,
`ChatMessage`, `Backend`, or `Conversation` type. Submitted text is the host's
current composer value, not a transformation performed by AppLocalVoice.

## Transcript contract

### Five distinct concepts

| Concept | Mutable? | Safe to replace? | Safe to stream as immutable input? | Means submitted? |
|---|---:|---:|---:|---:|
| Preview snapshot | Yes, by a later revision | Yes | No | No |
| Stable chunk | No | No | Yes, with its session/sequence and terminal status | No |
| Recognition-final transcript | No | No | Yes as a completed recognition result | No |
| Host composer draft | Yes, by the user | Yes | Host policy only | No |
| Host-submitted text | No for that submit action | No | It is the host's durable input | Yes |

Apple provider “final” flags remain internal evidence. The library's
`FinalTranscript` is produced only by the explicit host finalization boundary.
A provider-final callback alone cannot commit text, end the host turn, or invoke
a backend.

### Publication policies

`TranscriptPublicationPolicy` has exactly three policies:

- `previewAndFinal`: emit preview snapshots and one final transcript;
- `finalOnly`: suppress previews and chunks, then emit one final transcript;
- `stableChunks`: emit previews for UI, stable chunks for a separate sink, and
  one final transcript.

The four required host capabilities are live preview, final-only commands,
stable streaming, and editable draft. Editable draft is not a fourth transcript
payload, policy case, alias, or package-owned state: it is host behavior built
from `previewAndFinal`. The host places previews/final text into its composer and
owns editing, submit, and discard. The package exposes no `TranscriptDraft`,
`draftUntilSubmitted`, submit, discard, or committed-transcript semantic.

The target stable interval defaults to five seconds and accepts values from one
through thirty seconds inclusive. Values outside 1...30 seconds fail validation
before session admission. Five-second and ten-second configurations must both
have deterministic examples and tests.

### Session identity and ordering

`startSession(configuration:)` has one admission boundary and returns
`RecognitionSessionAcceptance`:

1. Validate configuration, recovery readiness, overlap policy, and the
   process-wide lease. A rejection here throws, allocates no public session ID,
   and emits no session event.
2. Atomically acquire/reserve ownership and generate a `RecognitionSessionID`.
3. Record `.accepted` with event ordinal zero as the first event for that ID.
4. Return `RecognitionSessionAcceptance` containing that ID and accepted ordinal
   zero, then perform provider preparation. Event observation may race caller
   resumption, but `.accepted` is already recorded and no other event for the ID
   can precede it.

After step 3 the session is admitted: `startSession` does not throw a later
startup result. Permission, model, provider, interruption, or cancellation
failures are represented by the exactly-once terminal event for that ID. The
legacy `startListening` adapter may continue awaiting preparation and throwing
the corresponding legacy error, but it observes the same canonical session and
must not create a second identity or terminal.

Every recognition event carries a monotonically increasing event ordinal within
the session. Host code rejects an event whose session ID is stale and may
deduplicate an identical ordinal. The accepted ordinal is zero; later event
ordinals strictly increase. Preview revisions and stable-chunk sequences are
separate counters that each start at zero and strictly increase in their own
channels.

Successful per-session ordering is:

1. exactly one accepted event at ordinal zero;
2. zero or more preparing states, then exactly one listening state;
3. zero or more preview snapshots and, only under `stableChunks`, stable chunks;
4. exactly one finalizing state after the host requests finish;
5. under `stableChunks`, zero or one final nonempty tail chunk;
6. exactly one final transcript, including an explicitly empty result;
7. exactly one completed terminal; and
8. no later event for that session ID.

Resource reconciliation is process-scoped, not another session event. A ready,
reconciling, or blocked recovery transition follows the logical terminal when
cleanup was not already resolved; a completed session does not by itself prove
that new audio work is safe.

Cancellation, interruption, and failure may occur after any admitted
nonterminal event and produce exactly one matching terminal. They produce no
final transcript after that decision. A cancellation race may preserve stable
chunks already published, but it suppresses every later preview, chunk, final,
state, and completion callback for that session ID.

An explicit finish for an admitted session that is still preparing is an early
release, not an invalid host state. The session owner records the finish intent,
continues preparation, and, once capture can start, immediately runs the normal
stop/finalization path. It returns the authoritative final transcript (which
may be empty) or the typed startup/cleanup/interruption failure that actually
wins. It never converts a short press into cancellation merely because
listening had not begun, and it never throws ordinary `invalidState` because
the user released quickly.

| Finish timing | Required result | Forbidden result |
|---|---|---|
| Before admission | Rejected request with no session ID or terminal event | Fabricated session identity |
| After admission, while preparing | Latched normal finalization with exactly one session terminal; return final transcript or the typed startup/cleanup/interruption failure that wins | Automatic cancellation or `invalidState` solely because listening has not begun |
| Listening or finalizing | Existing explicit finish/cancel semantics with exactly one terminal | Duplicate final/terminal or stale callback mutation |

### Stable chunk rules

A stable chunk contains session ID, zero-based sequence, nonempty text,
`utf16Range`, and optional provider timing. `utf16Range` is a half-open integer
range measured in UTF-16 code units from the start of the eventual final
transcript; it is not a Swift `String.Index`, byte range, or timing range.
Timing is descriptive; identity, sequence, and UTF-16 range are authoritative.

Stability is operationally defined. When a UTF-16 prefix first appears, the
publisher starts its maturity interval and requires every later complete
snapshot received before that interval elapses to contain the same prefix
code-unit for code-unit. The mature frontier is the longest prefix satisfying
that rule.
When the interval elapses, it emits the largest not-yet-emitted prefix ending at
a sentence boundary, then a word boundary, then an extended-grapheme boundary.
It emits nothing when no nonempty boundary has matured. Successful finalization
first verifies the final text still begins with the emitted prefix, then flushes
the remaining nonempty tail without waiting another interval.

The library promises:

- sequences have no gap, duplicate, overlap, or reorder;
- the first range starts at zero and every later lower bound equals the previous
  upper bound;
- each range length equals `chunk.text.utf16.count`, and emitted text/range never
  change;
- preview text is never routed through the stable-chunk case;
- finalization flushes a remaining nonempty stable tail before final output;
- on successful nonempty completion, the last upper bound equals
  `finalTranscript.text.utf16.count`, and concatenating chunks in sequence
  equals the final transcript exactly; an empty final emits no chunks; and
- on cancellation or interruption, already emitted chunks remain an immutable
  prefix, but the terminal marks the stream incomplete.

If a provider attempts to revise an already published stable range, the
library must fail the session with `transcriptConsistency`; it must not rewrite
the chunk or publish a contradictory successful final transcript.

### Empty text

An empty or whitespace-only recognition-final value is a successful empty
result, not an automatic backend submission and not synthesis input. The host
keeps submit disabled for the voice contribution and may show a “no speech
captured” affordance. Stable mode emits no empty chunk.

## Speech item, queue, and replay contract

### Dedicated one-shot lane

Direct `speak` is a one-shot request, not a hidden enqueue into the chat
queue. It uses a dedicated immediate lane with its own request/playback
identity and terminal result. The immediate lane shares the process-wide audio
owner and scheduler serialization, but it never reads the chat queue's running
or suspended mode as an admission gate, never changes pending chat items, and
never uses stop-and-clear as cancellation scope. If the shared audio provider
cannot safely admit the immediate request, the request returns a bounded typed
failure; it is not left waiting behind a suspended chat queue.

| Case | One-shot lane | Chat queue lane |
|---|---|---|
| Initial queue mode is suspended | One-shot may be admitted immediately | Accepted attempts remain pending until explicit resume |
| Queue was stopped | One-shot is independent of stopped queue mode | Pending attempts remain retained and suspended |
| One-shot cancellation | Terminalizes only that one-shot attempt | Active/pending chat items are unchanged |
| Queue stop-and-clear | Does not clear or cancel an unrelated one-shot | Cancels active and pending queue work as specified below |
| Shared provider is unavailable or unsafe | Return one bounded typed failure or cancellation | Each accepted queue attempt receives its own terminal outcome |

The exact active-output arbitration is scheduler-owned, but every branch has
one terminal outcome or a bounded typed rejection. A one-shot request must not
be represented as a chat `SpeechItemID`, and cancellation must name the
one-shot request/playback identity it owns.

### Identity and privacy

The host submits a `SpeechItemRequest` containing text, optional priority, and
speech configuration but no accepted identity. The library generates
`SpeechItemID` and `SpeechPlaybackID` only after it can atomically accept
the first enqueue. A rejected enqueue creates neither ID. The host stores its
own mapping from message ID to speech-item ID; host IDs and message types never
cross the package boundary.

The first accepted enqueue creates one item ID and one attempt ID. Replaying a
retained item keeps the item ID and creates a new attempt ID. Every lifecycle
event for an attempt carries both. Text is never present in lifecycle events,
diagnostics, errors, or retained evidence.

If the host edits or replaces returned text, it enqueues a new item. The
library never mutates text behind an existing item ID.

### Bounds

The target defaults are:

- 32 pending attempts, excluding the active attempt;
- 64 completed item records retained for replay;
- valid pending capacity 1 through 128;
- valid replay-history capacity 0 through 256;
- the existing 1,048,576 UTF-16-code-unit ceiling for each item's complete
  text, before provider chunking.

Configuration outside these ranges fails before queue ownership changes. The
pending bound counts accepted attempts, not unique item IDs, and excludes the
active attempt. Replay history contains at most one immutable record per item
ID; when an item becomes eligible after its latest terminal attempt, it moves to
the newest history position. Eviction removes the oldest eligible item that has
no active or pending attempt. A capacity of zero makes completed items
immediately unavailable for replay. Replay of an unavailable ID fails with
`itemUnavailable`, creates no attempt ID, and leaves the queue unchanged; the
host may enqueue its persisted message text as a new item with a new item ID.

These numeric defaults are compatibility-sensitive after release. Performance
work may recommend a change before the first release only through a recorded
contract amendment with memory evidence.

### Ordering and enqueue policies

The only priorities are `normal` and `userInitiated`; omitted priority means
`normal`. Normal append is stable FIFO within each priority, and
`userInitiated` append attempts sort ahead of normal append attempts. Priority
never preempts the active attempt. The same four placement policies apply to a
first enqueue and replay:

| Policy | Active attempt | Existing pending attempts | New attempt |
|---|---|---|---|
| `append` | Unchanged | Retained | Insert at the tail of its priority bucket |
| `playNext` | Unchanged | Retained | Insert at the absolute pending head; a later `playNext` goes ahead of earlier pending work |
| `replaceCurrent` | If present, terminal-cancel as replaced after admission is guaranteed | Retained | Insert at the absolute pending head and start after replaced-output cleanup; without an active attempt, behave as `playNext` |
| `replaceAll` | If present, terminal-cancel as replaced after admission is guaranteed | Terminal-cancel in current queue order | Become the only accepted attempt and start after cleanup when the queue is running |

Attempts placed at the absolute head are not displaced by a later priority-based
`append`; a later `playNext` or `replaceCurrent` becomes the newer absolute head.

Admission first validates the request/item, placement, lease, recovery state,
and post-replacement capacity without mutating the queue. Once admission is
guaranteed, it allocates identity and commits one mutation. Terminals for the
active replacement, then removed pending attempts in their pre-mutation queue
order, are recorded before the new accepted event; the new started event comes
only after required provider cleanup. Provider callbacks from a replaced
attempt ID cannot advance or finish the replacement.

### Overflow

There are exactly two overflow policies. `rejectNew` is the default. If the
post-replacement pending queue would exceed its configured capacity, it returns
`queueFull` atomically, creates no item/attempt ID, and leaves current and
pending work unchanged.

`dropOldestPending` selects the pending attempt with the smallest original
acceptance ordinal, regardless of current priority or placement, terminal-
cancels it with reason overflow, and records that terminal before the new
accepted event. It never drops the active attempt. If no pending attempt can be
dropped, the new request is rejected with no new identity or mutation. No
`dropLowestPriority`/`discardLowestPriorityPending` policy is part of E0.

### Playback controls

| Control | Contract |
|---|---|
| Pause | If active playback pauses, return applied and suspend queue advancement; if already paused or inactive, return the matching idempotent result; if the provider rejects pause, return provider-rejected, keep playback/queue running, and emit no paused event |
| Resume | If paused playback resumes, return applied; if already running or inactive, return the matching idempotent result; if the provider rejects resume, return provider-rejected, remain paused, and emit no resumed event |
| Stop | Cancel the active attempt with reason stopped, suspend the queue, and retain pending attempts |
| Skip | End the active attempt as skipped and, if the queue is running, start the next pending attempt |
| Clear pending | Cancel every pending attempt with reason cleared; leave the active attempt unchanged |
| Stop and clear | Stop the active attempt, cancel every pending attempt, and leave the queue suspended |
| Replay | Schedule the retained immutable item with a new attempt ID and one of the four explicit placement policies; unavailable item or capacity rejection creates no attempt ID |

The target pause/resume controls return `SpeechControlResult`. Legacy
nonthrowing pause/resume methods delegate to them and ignore the result for
source compatibility; they still must not publish a false state transition.

Accepted, started, paused, and resumed are ordered nonterminal events. Finished,
cancelled, skipped, interrupted, and failed are mutually exclusive terminal
outcomes. Every accepted playback-attempt ID, including one removed before it
starts, gets exactly one terminal outcome. An item ID may therefore have many
terminals over time, but never more than one for the same attempt ID.

### Autoplay and recognition conflict

The queue has running and suspended modes and starts running by default. Enqueue
while running means “play when ordered and safe”; enqueue while suspended
retains the attempt until an explicit resume. A host that disables autoplay
starts with the queue suspended and uses an explicit start/resume command. The
library never enqueues a backend result on its own.

Legacy/default overlap remains reject-new-operation. The canonical chat profile
selects recognition-over-playback: starting recognition cancels the active
playback attempt as superseded-by-recognition, suspends pending playback, and
releases output ownership before microphone admission. It does not silently
resume after recognition. The host explicitly resumes or waits to enqueue the
new returned response.

## Lifecycle and recovery contract

### First-release lifecycle policy

The first public release exposes only lifecycle semantics that are fully
guaranteed. `externalAudio` remains configurable and is honored by the audio
session owner. Interruption, application backgrounding, and invalid/material
route changes all use stop-and-require-explicit-resume semantics for active
speech/recognition and pending chat-queue work. They never advance pending work
or restart it when the app returns to the foreground or the route recovers.

The following options are not first-release promises. They must be removed
from the public release surface before release rather than accepted and
silently ignored. If an intermediate source still declares one, selecting it
is a release-blocking compatibility defect until the declaration is removed or
replaced by an explicit typed pre-admission rejection.

| Policy/value | First-release disposition | Recognition | Active playback | Pending queue | Recovery/host action |
|---|---|---|---|---|---|
| `externalAudio` (`mix`, `duck`, `interrupt`, `reject`) | Supported when the audio session owner can prove the selected behavior | Admission honors the selected external-audio policy | Audio-session behavior follows the selected policy | Queue ownership is unchanged | Report typed admission/provider failure when the selected policy cannot be honored |
| Interruption: stop-and-require-explicit-resume | Supported target semantic | Terminalize active recognition as interrupted | Terminalize active playback as interrupted | Retain pending work and suspend queue | Query recovery, then explicitly retry recognition or resume queue |
| Background: stop-and-require-explicit-resume | Supported target semantic | Terminalize active recognition as backgrounded | Terminalize active playback as interrupted/backgrounded | Retain pending work and suspend queue | On foreground, query recovery and explicitly retry/resume |
| Invalid/material route: stop-and-require-explicit-resume | Supported target semantic | Terminalize active recognition as route change | Terminalize active playback as route change | Retain pending work and suspend queue | Recheck route/recovery, then explicitly retry/resume |
| `pauseSpeechAndStopListening` background option | Remove before release, or typed-reject before admission while transitional | No pause-on-background promise | No pause-on-background promise | No automatic continuation | Host must use the supported stop-and-resume semantic |
| `continueWhenPossible` route option | Remove before release, or typed-reject before admission while transitional | No continue-on-route promise | No continue-on-route promise | Never auto-advance | Host must explicitly retry/resume |
| `retryOnceThenRequireExplicitRetry` cleanup option | Remove before release, or typed-reject before admission while transitional | No implicit cleanup retry promise | No implicit cleanup retry promise | Queue remains suspended while unresolved | Host explicitly retries close/reconcile |

The supported target is intentionally narrower than the current provisional
enum inventory. No public documentation may describe the three unsupported
options as accepted first-release behavior.

### Recovery states

| State | Meaning | Allowed host actions |
|---|---|---|
| Ready | No unresolved provider or audio ownership; a mutating operation may be admitted | Start recognition, enqueue/play, query capabilities, or close |
| Reconciling | Cleanup is actively being checked or retried | Await result, query state, or request idempotent close; no new audio work |
| Blocked | Cleanup did not complete or ownership cannot be proven released | Query state/capabilities and retry close/reconcile only |

An operation terminal describes what happened to that logical session or
playback attempt. Recovery state describes whether another audio operation is
safe. They are separate even when delivered in one event value.

An ordinary denied permission, unsupported locale, invalid configuration, or
provider failure may end with recovery already ready because no resource is
owned. Cleanup timeout, rejected synthesizer stop, analyzer noncooperation,
tap-removal failure, or session-restoration failure ends blocked. New
recognition and queue start attempts fail with `cleanupPending` while blocked.

### Close and reuse

Close is idempotent and means “retire all work owned by this facade now”:

1. invalidate the active recognition generation;
2. terminal-cancel the active playback attempt;
3. terminal-cancel all pending attempts;
4. clear replay history;
5. reconcile microphone, analyzer, synthesizer, and audio-session ownership;
6. return released or blocked; and
7. release the process runtime lease only on released.

A released facade is reusable. A later mutating call acquires a new runtime
lease and all new session, item, and playback-attempt IDs remain distinct from earlier
ones. Existing event streams stay open across a successful close for source
compatibility; observers cancel their own iteration when no longer needed.

A blocked close is not partial success. The same facade retains the runtime
lease and remains blocked until a later close/reconcile proves release.

### Scene, view, and process lifecycle

| Lifecycle input | Library behavior | Host behavior |
|---|---|---|
| Scene becomes inactive while app remains foreground | No inferred terminal solely from scene UI state; real audio interruption notifications remain authoritative | Update UI as desired; explicitly cancel if product policy requires it |
| Application enters background | End active recognition as interrupted/backgrounded; end active playback as interrupted; suspend and retain pending queue; reconcile resources | Restore pre-voice draft when no final exists; show retry/resume on foreground |
| Application returns foreground | Never auto-restart capture or playback; publish/query current recovery and capability state | Explicitly retry recognition, resume queue, or recheck capabilities |
| System interruption begins | End active work exactly once; suspend pending queue; release resources | Wait until interruption ends, then explicit retry/resume |
| Route is invalidated or materially changes | End active work; discard stale format/converter; suspend queue | Show route-aware retry; never reuse stale preview as final |
| Media services lost or reset | Invalidate provider generation and synthesizer identity; end active work; reconcile | Explicit retry after ready; physical validation required |
| Voice view disappears | No automatic service close if service is app-scoped | Cancel that view's observation task; cancel its active turn if appropriate |
| Scene-owned service is permanently discarded | No deinit guarantee | Await close before releasing the final owner |
| Facade deallocates without close | Reclaim the dead lease owner safely; reconcile provider/audio cleanup before reuse; if unresolved, retain typed blocked/retry state | Prefer explicit close, but a lost owner must not permanently poison later facades; await/query recovery before new work |
| Process terminates or crashes | In-memory sessions, queue, item history, and event streams are lost | Create a fresh service on launch; use persisted host messages to re-enqueue explicitly |

Cancellation of a view task does not automatically cancel the app-scoped
service. The host must decide whether that task was only an observer or owned
the active recognition request.

## Event classification, delivery, and ordering

This section governs the new canonical `VoiceEventStream`, not the legacy
`events() -> AsyncStream<VoiceEvent>` compatibility projection. “Durable” means
noncoalescible and either delivered in order to an admitted subscriber or
reported as an explicit stream gap; it does not mean disk persistence or replay
across process termination.

### Side-effect-free `voiceEvents` subscription

`voiceEvents()` is an observation operation. Creating a subscriber must not
publish `.ready`, alter recovery state, advance a global event ordinal, finish
or mutate an existing subscriber, or otherwise change operation state. The new
subscriber receives exactly one current recovery snapshot for its own stream
when the snapshot is available; that snapshot is not broadcast to any other
subscriber. Recovery state is also available through a query/snapshot API, so a
host can reconcile after overflow, stream cancellation, or a missed advisory
event without manufacturing a subscription.

| Subscription action | New subscriber | Existing subscribers | Global state |
|---|---|---|---|
| Subscribe while ready | Receives its own `.ready` snapshot | No new event | Unchanged |
| Subscribe while reconciling/blocked | Receives its own current non-ready snapshot | No false `.ready` or history change | Unchanged |
| Query recovery | Reads current authoritative state | No stream event | Unchanged |
| Subscriber admission rejected | Receives only typed admission failure | All existing streams continue unchanged | Unchanged |
| Subscriber cancels/overflows | Its stream ends or fails explicitly | Other streams continue | Recovery/operation state is unchanged |

| Event kind | Advisory or terminal | Coalescing rule |
|---|---|---|
| Recognition/queue/recovery state snapshot | Advisory | May coalesce to the latest snapshot with the same scope |
| Transcript preview | Advisory and volatile | May coalesce to latest revision for the same session |
| Stable transcript chunk | Durable nonterminal data | Never silently drop, coalesce, or rewrite |
| Final transcript | Durable final data | At most once; never silently drop |
| Session accepted | Durable lifecycle | At most once and before payloads |
| Playback accepted/started | Durable lifecycle | At most once per playback-attempt ID |
| Paused/resumed | Ordered advisory lifecycle | Duplicate no-op calls emit nothing |
| Recognition outcome | Terminal | Exactly once per admitted session |
| Playback outcome | Terminal | Exactly once per accepted playback-attempt ID |
| Recovery blocked/released transition | Durable lifecycle | State-queryable even if an observer detaches |

Each canonical stream is finite in memory. The target admits at most eight
active canonical subscribers. A subscription request beyond that limit fails
the new request with `eventSubscriberLimitReached`; it does not finish or alter
an existing subscriber. Its typed context must report
`maximumSubscriberCount: 8` and the observed `activeSubscriberCount` and must not
encode either value only in display text. Cancellation or normal termination
immediately frees the subscriber slot.

Each admitted subscriber holds at most 32 durable events, plus coalesced slots
for the latest preview per active session and the latest advisory state per
scope. Preview/state replacement does not consume durable capacity. Durable
events are enqueued in their authoritative session/queue order and are never
replaced by a newer event.

If a subscriber exhausts durable capacity, the library does not report the next
durable event as delivered. It terminates only that subscriber's throwing stream
with `eventDeliveryOverflow`. Its typed context is mandatory and contains
`maximumDurableEventCount: 32` plus the first undelivered durable cursor:

- recognition: `RecognitionSessionID` and recognition `eventOrdinal`;
- queue/playback: `SpeechItemID`, `SpeechPlaybackID`, and queue `eventOrdinal`;
  or
- process recovery/runtime: a process-scope `eventOrdinal`.

The cursor is the earliest undelivered durable event in that scope's
authoritative order, never a later convenience snapshot. No transcript, speech
text, provider description, or host message ID may enter either overflow
context. The stable category and typed context must be machine-readable; a
localized string alone is insufficient.

The underlying recognition/queue operation and other subscribers continue. The
host marks that stream incomplete and reconciles with the canonical operation
result and current session/queue/recovery snapshots; it must never infer a
missing terminal or claim a complete stable stream. Restarting observation
begins a new live subscription and does not replay the gap.

The legacy event projection retains its documented newest-eight buffer and
oldest-subscriber eviction solely for source compatibility. It carries no new
stable-chunk or queue-attempt contract. New host-ready examples and adapters
must use the canonical throwing stream.

No global ordering is promised between unrelated advisory snapshots. Ordering
is strict within a recognition session and within a playback-attempt ID; queue
acceptance and terminal events additionally follow queue mutation order.

## Stable machine-facing failure categories

The existing categories remain unless compatibility review explicitly replaces
one. The rebuild needs these additional content-free categories:

| Category | Meaning |
|---|---|
| `serviceInUse` | Another facade owns the process runtime lease |
| `queueFull` | Overflow policy rejected a new attempt |
| `itemUnavailable` | Replay history no longer contains the requested item |
| `eventSubscriberLimitReached` | The process already has eight admitted canonical event subscribers; context includes maximum and active counts |
| `eventDeliveryOverflow` | One admitted subscriber could not receive its first undelivered durable event; context includes capacity and the typed recognition/queue/runtime cursor |
| `transcriptConsistency` | A provider revision contradicted an emitted stable prefix |
| `cleanupPending` | Resource release is unresolved; only close/reconcile is safe |

Associated display text and provider descriptions are not machine contracts and
must not enter diagnostics. Interruption reasons are typed content-free values,
such as system interruption, route change, app background, or media-services
reset.

## Failure matrix

“Terminal” below refers to the affected admitted session or accepted playback
attempt. A rejected request that never receives identity has no terminal event.

| Condition | Owner detecting it | Observable result | Terminal rule | Host action | Planned evidence |
|---|---|---|---|---|---|
| Microphone denied/restricted | Library | Permission category; recovery ready | Reserved session fails once | Explain Settings and wait for user retry | Deterministic permission matrix; device Settings pass |
| Speech permission denied/restricted | Library | Speech-permission category; recovery ready | Reserved session fails once | Explain permission and retry explicitly | Deterministic matrix |
| Unsupported locale | Library | Unsupported-locale category; recovery ready | Reserved session fails once | Choose locale | Deterministic capability test; device locale matrix |
| Model absent in installed-only mode | Library | Model-unavailable category; recovery ready | Reserved session fails once | Offer explicit install policy or locale change | Fake model matrix; physical clean-install case |
| Model installation fails/cancels | Library/system | Model-unavailable or cancelled; ready/blocked reflects cleanup | One session terminal | Show storage/network/system guidance; explicit retry | Deterministic install seam; device install evidence |
| Second facade mutates while runtime lease held | Library | `serviceInUse`; no provider or queue mutation | Rejected request has no new identity | Reuse app-scoped facade or close owner | Multi-instance deterministic test |
| Recognition overlaps playback under reject policy | Library | Invalid-state category; no new session ID | Rejected request only | Stop playback or select input-wins policy | Policy matrix test |
| Input-wins recognition starts during playback | Library | Active playback cancelled as superseded; queue suspended | One playback terminal; recognition proceeds | Update controls; resume explicitly later | Cross-operation ordering test; device audio test |
| Preview subscriber is slow | Library delivery layer | Newest preview replaces older preview | No operation terminal solely for preview coalescing | Render latest revision | Bounded slow-consumer test |
| Ninth canonical subscriber is requested | Library delivery layer | `eventSubscriberLimitReached(maximum: 8, active: 8)`; existing streams unchanged | No operation terminal | Reuse/cancel an observer, then retry | Subscriber-admission/context test |
| Durable event subscriber overflows | Library delivery layer | `eventDeliveryOverflow(capacity: 32, firstUndelivered: typed cursor)`; operation state remains queryable | Stream fails explicitly; operation terminal remains authoritative elsewhere | Mark stream incomplete and reconcile/query | Deterministic buffer/context exhaustion test |
| Provider revises stable prefix | Library publication layer | `transcriptConsistency`; no contradictory final | Session fails once | Abort sink transaction or mark partial stream failed | Stable-prefix regression test |
| Transcript exceeds text ceiling | Library | Text-too-long category; rejected text absent from diagnostics | Session fails once | Discard/shorten and retry | Boundary and Unicode tests |
| Host cancels while preparing/listening/finalizing | Library | Cancelled outcome; no later preview/final | Session terminal exactly once | Restore composer snapshot | Race/cancellation stress tests |
| Finalization provider fails | Library | Typed recognition/audio failure | Session fails once; ready or blocked based on cleanup | Keep draft unsubmitted; retry fresh turn | Existing finalization harness plus target event tests |
| Empty final transcript | Library value; host policy | Completed empty final; recovery ready | Completed once | Disable voice submit; show no-speech affordance | Deterministic empty-result test |
| User discards after successful final | Host | Host draft removed/restored | No new library terminal | Restore pre-turn composer | Host adapter test |
| Backend callback fails | Host | Host backend error only | No library terminal or recovery mutation | Keep edited composer/message retry UI | Host callback acceptance test |
| Returned text is blank | Host before enqueue | No enqueue | No item/attempt identity | Keep message; omit autoplay | Host adapter test |
| Speech item exceeds text ceiling | Library | Text-too-long; queue unchanged | Rejected enqueue has no identity | Truncate/summarize by host policy | Queue boundary test |
| Queue full with reject-new | Library queue | `queueFull`; queue unchanged | No identity for rejected enqueue | Keep message and offer manual play later | Queue overflow test |
| Queue full with drop-oldest | Library queue | Old pending attempt cancelled/overflow before new acceptance | Exactly one terminal for evicted attempt | Reflect cancellation if visible | Ordering/overflow test |
| Replay history evicted item | Library queue | `itemUnavailable`; queue unchanged | Rejected replay has no attempt ID | Enqueue persisted message text as new item | History-bound test |
| Requested voice unavailable | Library | Voice-unavailable category | Attempt fails once if accepted; queue advances only after terminal | Choose installed voice or open voice Settings | Deterministic catalog tests; device voice matrix |
| Invalid speech configuration | Library preflight | Invalid-configuration category | Reject before provider; no accepted identity when known before acceptance | Correct configuration | Fuzz/configuration tests |
| Synthesizer watchdog expires | Library | Synthesis-unavailable category | Active attempt fails once; pending queue suspends if ownership uncertain | Show replay; retry after ready | Existing watchdog seam plus queue tests |
| Pause/resume rejected by provider | Library/provider | `SpeechControlResult.providerRejected`; no false paused/resumed event | Attempt remains in its prior state; no terminal | Keep controls consistent with returned result | Provider seam and physical test |
| Stop request rejected | Library/provider | Recovery blocked; current item retained as owned | Attempt terminal emitted once; no next item starts | Retry close/stop; do not resume queue | Existing rejected-stop seam plus queue gate |
| Skip/replace races provider completion | Library queue | One winning terminal by playback-attempt ID | Exactly once; stale completion ignored | None beyond rendering result | Deterministic race test |
| System interruption | Library | Typed interrupted session/attempt; pending queue suspended | One terminal per active entity | Wait for end, then explicit retry/resume | Notification seam; phone/Siri/alarm device matrix |
| Route change/loss | Library | Typed interrupted terminal; recovery ready or blocked | One terminal; stale format discarded | Show route retry | Notification seam; Bluetooth/wired matrix |
| Application background | Library | Active entities interrupted; pending queue suspended | One terminal per active entity | Restore draft if needed; retry/resume on foreground | Lifecycle seam; physical background/foreground |
| Media services loss/reset | Library | Active entities interrupted; provider identities invalidated | One terminal per active entity | Retry only after ready | Seam plus physical daemon-reset evidence |
| Cleanup times out or tap/session release fails | Library | `cleanupPending`; recovery blocked | Affected entity has one failed terminal | Disable audio controls and retry close without tight loop | Existing cleanup tests plus target recovery matrix |
| Close during active work | Library | Active and pending entities cancelled; released or blocked result | Exactly one terminal for every accepted identity | Await result; retry if blocked | Close race and idempotence tests |
| View observer is cancelled | Host/event layer | That observer ends; service work is unchanged | No manufactured operation terminal | Decide separately whether to cancel active turn | Host lifetime test |
| Facade is deallocated without close | Host misuse/library best effort | No cleanup guarantee | No promised event delivery | Fix ownership; create app-scoped service | Deallocation audit and documentation test |
| Process crash/termination | Process | In-memory state lost | No in-process terminal promise | Fresh service; re-enqueue persisted message text explicitly | Host crash/relaunch report |

## Contract threat model

| Risk | Contract mitigation | Required test or review |
|---|---|---|
| Preview is submitted as durable input | Distinct preview type; backend callback exists only in host; submit reads edited composer | Static backend-boundary review and host test proving previews never call submit |
| Recognition-final is mistaken for submitted | Final type/documentation explicitly says unsubmitted; no commit API | API naming review and draft edit/submit/discard test |
| Two audio owners mutate `AVAudioSession` | Process runtime lease and package-only audio owner | Static ownership search and competing-facade test |
| Host and library both queue returned text | Supported modes require library queue; host stores only ID mapping and autoplay decision | Generic host review and no-second-queue search |
| Item replay produces ambiguous duplicate terminals | Stable item ID plus unique playback-attempt ID; terminal guarantee applies per attempt ID | Replay/stop/completion race tests |
| Old recognition callback changes a later composer | Session ID, generation token, revision check, and invalidation before cleanup | Stale callback and rapid restart tests |
| Provider rewrites already streamed text | Stable-prefix invariant; contradiction fails explicitly | Timed chunk and revision fuzz tests |
| Slow consumer causes unbounded memory or silent loss | Finite buffers; preview coalescing; explicit durable-event overflow | Buffer saturation tests and memory budget |
| Queue overflow silently loses returned messages | Host persists message first; explicit reject/drop policy and terminal reason | Overflow tests and host acceptance scenario |
| Interruption/background restarts microphone unexpectedly | Active work terminates; foreground never auto-restarts | Lifecycle matrix and physical route/interruption tests |
| Cleanup failure is mistaken for idle | Separate blocked recovery state; runtime lease retained; admission rejected | Injected cleanup failures and repeated close tests |
| Associated error text leaks user/provider content | Stable content-free categories only; text excluded from diagnostics/events | Privacy validator and diagnostics tests |
| Deinit is treated as async cleanup | Explicit close contract and app-scoped ownership | Lifetime test and adoption review |
| Backend failure mutates voice recovery | Backend callback remains host-only | Adapter test with backend failure during ready/queued states |
| Stable stream is complete after cancellation | Terminal marks incomplete and no final is emitted | Cancel-after-chunks test |

## E0-T06 support approval gate

[SupportDecision.md](SupportDecision.md) is approved for implementation by the
package maintainer on 2026-07-11. It fixes iOS 26 as the minimum deployment,
Xcode 26.x, Swift tools 6.2 in Swift 6 language mode, ordinary iPhone and iPad
application targets, runtime locale/model/voice capability checks, and
physical-device evidence before production audio claims. Custom keyboard
extensions remain out of scope.

## E0-T04 API review gate

### Contract-author review

- [x] Source compatibility has an additive adapter strategy.
- [x] The facade remains main-actor isolated; public values and IDs are
  `Sendable`.
- [x] Every proposed public semantic name has one owner and one meaning.
- [x] Session, item, and playback-attempt identities have explicit creation and reuse
  rules.
- [x] Preview, stable, final, host-draft, and submitted text cannot be confused
  by event kind or documented meaning.
- [x] Queue, replay history, text, subscribers, and event delivery are finite.
- [x] Per-session and per-attempt event ordering is explicit.
- [x] Cleanup readiness is separate from logical operation completion.
- [x] All adoption modes can be implemented without provider, backend, chat,
  message-store, or SwiftUI types in the core package.
- [x] Existing tests that establish useful compatibility invariants are named
  as preserved baseline behavior.

### Independent reviewer sign-off

Required reviewer: someone other than the contract author, following review
the package's documented recognition, queue, and recovery contracts.

The independent E0 review returned **changes requested**. This revision
reconciles its publication-policy, identity, start ordering, stable
range/interval, queue, durable-delivery, runtime-lease, compatibility, and
support-status findings. The following checks are now implementation-verified;
the fresh reviewer records the final release decision:

- [x] Confirm actor isolation and `Sendable` choices.
- [x] Confirm the additive compatibility adapters do not leave a second queue
  or coordinator path.
- [x] Confirm numeric bounds are sufficient and finite.
- [x] Confirm all canonical host steps are expressible using only public types.
- [x] Confirm failure and terminal rules are deterministic under cancellation,
  overflow, interruption, and cleanup failure.
- [ ] Record reviewer identity, date, decision, and any approved amendments.

Release promotion remains gated on the independent signature, clean current
verification, and physical-device evidence. E0-T06 support approval is already
recorded; no implementation task should reopen E0-T01 through E0-T05 or E0-T07
semantics without a new decision record.
