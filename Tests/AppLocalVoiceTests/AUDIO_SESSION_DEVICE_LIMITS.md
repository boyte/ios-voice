# Audio-session behavior that remains device-only

The injected `AudioSessionDriver` proves the lease manager's logic without
pretending to reproduce Apple's audio daemon. The following behaviors still
require a physical iPhone or iPad and are intentionally not claimed by these
tests:

- Whether `AVAudioSession.setCategory` and `setActive` are accepted for a
  particular hardware route, app state, entitlement configuration, or current
  system interruption.
- Actual coexistence with another app's audio, including the value and timing
  of `isOtherAudioPlaying`.
- Bluetooth HFP, AirPods, wired-headset, receiver, speaker, and route-change
  transitions.
- Phone calls, Siri, alarms, media interruptions, lock-screen transitions,
  background suspension, and foreground reactivation.
- The operating system's timing and error behavior when activation or
  deactivation is rejected.

The fake driver covers deterministic activation, deactivation, configuration,
and other-audio observations. A device report must cover the system behaviors
above before a release can claim hardware audio-session compatibility.
