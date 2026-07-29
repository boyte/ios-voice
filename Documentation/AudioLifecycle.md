# Audio lifecycle

Audio hardware is shared system state. The most important AppLocalVoice rule is
that a process-wide broker serializes `AVAudioSession` mutations and attributes
each logical lease to the controller that acquired it. One voice service still
serializes its own operations; independent services cannot release one
another's lease.

## Host-facing ownership contract

`AVAudioSession` is process-wide, so the host must choose one ownership mode at
composition time. The mode applies to listening and speaking; it is not safe to
let one operation use library-managed behavior and the other use host-managed
behavior without an explicit coordination adapter.

### Library-managed mode (default)

AppLocalVoice owns the session transition for the duration of each lease. The
host may choose the external-audio policy (`mix`, `duck`, `interrupt`, or
`reject`) through the library lifecycle configuration, but it must not directly
call `setCategory`, `setMode`, preferred-I/O setters, `setPreferredInput`, or
`setActive` while an AppLocalVoice lease is active. A host that needs to change
those values must first stop/close the voice operation, wait for successful
cleanup, make its own session change, and start a new voice operation.

The library-managed transaction is:

1. Read and retain the host configuration snapshot before the first voice
   configuration in the outermost lease. The snapshot includes category, mode,
   route-sharing policy, category options, preferred sample rate, preferred I/O
   buffer duration, and preferred input UID. It is not an active/inactive
   snapshot.
2. Apply the role configuration (`record`/measurement for listening, or
   `playback`/voicePrompt for speaking) and the requested external-audio
   policy.
3. Activate the session, then start the provider's Apple audio objects.
4. Stop those objects before releasing the lease: stop the engine and remove
   the tap for listening; stop the synthesizer/output for speaking.
5. On the final lease release only, prove that AppLocalVoice still owns the
   category/mode/route-policy/options transition, deactivate with
   `setActive(false, options: .notifyOthersOnDeactivation)`, and restore the
   host configuration with a three-way merge. Preferred sample rate, I/O
   buffer duration, and input restore to their pre-lease values only when they
   still equal the package-managed snapshot; a newer current value is
   preserved. The deactivation is one normal final-release transition, not one
   call per nested lease.

`notifyOthersOnDeactivation` is required in this mode when AppLocalVoice
activated the session and still owns it. It tells interrupted podcast/music
sessions that they may resume. AppLocalVoice must not use that option merely to
repair a session that may now be host-owned.

### Host-managed/coordinated mode

This mode is for a host that already owns an audio engine, call stack, camera
session, or an application-wide `AVAudioSession` lifecycle. The host remains
the sole owner of session configuration, activation, deactivation, and
restoration. AppLocalVoice may request a coordinated listening or speaking
lease, but it must not snapshot, configure, activate, deactivate, or restore
the host's session itself.

The host coordination seam must provide these boundaries:

- `begin`: accept or reject the requested role and external-audio policy, then
  make the session ready and active before AppLocalVoice starts its provider;
- `end`: receive notification only after AppLocalVoice has stopped its Apple
  audio objects, then perform any host-owned deactivation/restoration policy;
- `invalidate`: tell AppLocalVoice that a route/media-service reset or another
  owner invalidated the coordinated session, so the host can establish a fresh
  boundary before retry.

The exact public spelling of this seam is still an AUD-01 source decision. Until
it exists, an app with an independently managed session must use its own
serialization around the current library API and must not assume that the
current snapshot broker is coordinated mode. A host callback that only says
“session is active” is insufficient: it must also establish the requested
category/mode/options and own the corresponding end transition.

### Policy decision table

The policy is a request about audio already playing outside AppLocalVoice. In
library-managed mode the library performs the row's session mutation. In
host-managed/coordinated mode the host adapter performs it or rejects the
request before the provider starts; AppLocalVoice performs no direct session
mutation.

| Policy | Other audio is playing | Listening request | Speaking request | Host action |
| --- | --- | --- | --- | --- |
| `mix` | Yes | Use play-and-record/measurement with mix and Bluetooth HFP support | Use playback/voicePrompt with mix | Accept only if coexistence is supported; otherwise reject before mutation |
| `duck` | Yes | Use play-and-record/measurement with mix + duck and Bluetooth HFP support | Use playback/voicePrompt with mix + duck | Accept only if ducking is supported; otherwise reject before mutation |
| `interrupt` | Yes | Use record/measurement so the voice turn takes priority | Use playback/voicePrompt without mix/duck | Accept the interruption; external audio may stop and must not be promised to resume until final deactivation |
| `reject` | Yes | Reject before configure/activate | Reject before configure/activate | Return a typed audio-ownership failure; do not alter the session |
| Any policy | No | Configure the listening role, activate, then start capture | Configure the speaking role, activate, then start output | A later host mutation is not part of the supported transaction |

Nested leases from the same owner must use the same role and external-audio
policy. Releasing a non-final nested lease performs no system transition. A
different owner may share the already active role/policy, but it cannot release,
restore, or reconcile another owner's lease. A role or policy change requires
the outer lease to end successfully first.

## Final release and snapshot reconciliation

The snapshot is a restoration candidate, not permission to overwrite whatever is
currently in the singleton. Before deactivation or restoration, the broker must
compare ownership metadata/generation and the current session configuration
with the values AppLocalVoice applied. The rules are:

- If the applied values are unchanged and the library still owns the active
  transition, perform final deactivation with
  `.notifyOthersOnDeactivation`, then restore the retained snapshot.
- If a host changed category, mode, route-sharing policy, options, or active
  ownership during the lease, preserve the newer host state. Do not restore
  the stale snapshot and do not defer a later deactivation that could
  deactivate the newly host-owned session. Return a typed ownership conflict
  (or require an explicit host acknowledgement through the coordination seam)
  rather than reporting a clean automatic restore.
- Preferred sample rate, preferred I/O buffer duration, and preferred input
  are not package-authored configuration fields. AVFAudio may normalize them
  after activation, and without the coordinated-mode generation seam a direct
  host preference change is observationally identical. Library-managed mode
  already forbids the host from making that change during a lease. The broker
  therefore preserves any preference that differs from the package-managed
  snapshot and restores the pre-lease value only when the current value still
  equals the managed value. This preserves newer state without manufacturing
  an ownership conflict from normal system drift.
- If deactivation or restoration fails because the system is busy, the logical
  lease is closed but reconciliation remains pending. A later library-managed
  acquisition must reconcile before configuring or activating a new lease. It
  may retry deactivation with `.notifyOthersOnDeactivation` and restoration only
  while the broker has no active leases and the exact process state observed
  after the failed transition is unchanged. Any intervening change abandons
  the stale reconciliation and returns a typed ownership conflict.
- If the host has acquired a lease, reconciliation must not run against it. If
  ownership cannot be proven, stop and return the ownership conflict; never
  repair by blindly deactivating.
- A media-services reset or equivalent invalidation makes the old snapshot
  untrustworthy. Discard or quarantine it, require the host/system boundary to
  be re-established, and require an explicit retry. Do not restore pre-reset
  values over a newly established host session.

The host integration sequence is therefore: create one app-owned service;
select the ownership mode; route every voice operation through that service;
avoid direct session mutations in library-managed mode; stop/close and observe
the cleanup result before taking the session back; and retry only after a typed
ownership or cleanup failure has been handled. A child view or non-owner
consumer must not call `close()` on a shared service.

### Implementation and evidence status

This section is the AUD-01 contract; it is not a claim that all rows are
implemented. `AudioSessionController` currently provides the process-wide
broker, owner-scoped nested leases, guarded configuration snapshots, final
deactivation with `notifyOthersOnDeactivation`, three-way preferred-I/O
restoration, and exact post-failure configuration proof under library-managed
exclusivity before reconciliation. Active-state/generation ownership proof
remains part of the future coordinated-mode seam.
Stable managed-configuration changes fail closed without overwriting the newer
host state. `VoiceCoordinator` sequences provider cleanup and forwards
`AudioLifecyclePolicy`, but it does not yet expose the coordinated mode or a
host ownership adapter.

The remaining AUD-02–AUD-05 source work is the public facade/provider
coordination seam: add ownership mode and generation metadata so a host-managed
audio stack can establish explicit begin/end/invalidate boundaries.
`VoiceCoordinator` must keep provider stop/cleanup ahead of the final lease
boundary and surface typed conflict/cleanup results to the host.

Required deterministic tests in `AudioSessionControllerTests` and
`VoiceCoordinatorTests` include nested and cross-owner lease balance,
exactly-once final deactivation with the notify option, all four policies for
listen and speak, activation/deactivation-busy and restore failures, mutation
of category/mode/options/preferred I/O between acquire and release, stale
reconciliation beside a new host lease, media reset invalidation, coordinated
mode callbacks, and reentrant/concurrent enter/exit/reconcile races. Physical
device evidence is still required for external-audio resumption, routes,
interruptions, and host-owned engine coexistence; simulator tests cannot close
those evidence gaps.

## Capture startup

Before installing a microphone tap, the implementation must validate permission, locale/model availability, external-audio policy, current hardware format, and engine readiness. The safe Objective-C bridge protects known `AVAudioEngine` exception points.

The microphone path uses an internal safety adapter around that bridge. Tap
installation, engine preparation, engine start, and tap removal each fail
closed. The adapter is injectable only inside the package test target; the
public API remains unchanged. Tests verify operation ordering and failure
propagation without pretending to reproduce Apple's hardware or audio-daemon
behavior.

The input format is not cached across route changes. A route change invalidates the active capture pipeline and requires a fresh explicit start.

## Interruptions

When a system interruption begins, AppLocalVoice stops capture, removes the tap, cancels analysis, stops speech, emits an interruption/failure event as appropriate, and returns to a recoverable state. It never silently restarts recording.

Typical interruptions include phone calls, Siri, alarms, and other applications taking audio priority.

Loss or reset of `AVAudioSession` media services is treated as the same
terminal boundary. The current generation is invalidated and the host must
retry explicitly after the system audio services are usable again.

Entering the application background is also a terminal boundary for active
voice work. The Apple adapters stop capture or speech, release their audio
resources, and report an interrupted operation; they never keep a microphone
pipeline alive for background capture. Returning to the foreground does not
auto-restart anything. The host presents its normal explicit retry affordance.

## Route changes

AirPods, wired headsets, speaker routing, and Bluetooth HFP can change the hardware format. AppLocalVoice tears down the old tap and converter rather than continuing with stale assumptions. The host should provide a clear “tap to try again” affordance.

## TTS and repeated turns

TTS uses the same process-wide audio-session broker. Host code should stop or
finish speech before starting a new recording. `close()` is the lifecycle
boundary for a voice surface and is idempotent.

If the final library-managed lease release reports a deactivation or restore
error, the logical lease is closed but the controller records that the system
transition is unresolved. The next operation does not activate immediately:
its first internal action is an ownership-checked, idempotent reconciliation.
Only after that reconciliation succeeds does it configure and activate a new
lease. Repeated reconciliation failures are returned to the caller and do not
acquire a lease; this is what lets non-throwing cleanup paths remain recoverable
without expanding the public API. In host-managed/coordinated mode, the host
coordination seam owns this retry and restoration policy.

If microphone-tap removal itself fails, the coordinator does not publish a
clean idle state. It remains in `.failed`, rejects new operations, and reports
an audio-session cleanup error. Calling `close()` retries provider cleanup;
only after the provider confirms that its tap, analyzer, and session resources
are released does the service return to `.idle`.

## Finalization ordering and timeout policy

Recognition finalization is deliberately ordered:

1. stop the audio engine;
2. remove the microphone tap;
3. flush the converter and yield its trailing frames;
4. finish the analyzer input stream;
5. ask the analyzer to finalize through end-of-input;
6. await the analyzer/result task;
7. release the audio-session lease;
8. return the provider's final transcript snapshot.

The package does not impose an undocumented wall-clock timeout on
`finishListening()`. A timeout would need to define whether partial text is
returned, whether the host receives a failure, and how a non-cooperative Apple
framework task is isolated. In 0.1 the host owns that policy: it may cancel the
calling task or call `cancelListening()` from its own bounded task. Cancellation
always takes the normal teardown path and a cancelled generation cannot emit a
later final transcript. A future timeout API must be additive and specify all
three outcomes—returned text, typed failure, and resource cleanup—before it is
introduced.

## Verification checklist

Validate on physical devices with built-in audio, AirPods, wired headsets, music already playing, incoming calls, Siri, backgrounding, rapid cancel/restart, and at least 30 minutes of repeated turns. The simulator cannot prove these behaviors.
