# Audio lifecycle

`AVAudioSession` is process-wide state. AppLocalVoice serializes its own speech
operations and coordinates the session while listening or speaking. A host
should create one service and avoid changing the audio session directly during
an active AppLocalVoice operation.

## What the package does

For each listening or playback operation, the package configures and activates
the audio session, starts Apple’s input or output object, then stops that object
before releasing its lease. On the final release it deactivates with
`.notifyOthersOnDeactivation` when it still owns the transition. This lets
interrupted external audio resume when iOS permits it.

The package does not restore configuration over a newer host change. If it
cannot prove cleanup, `close()` returns `.blocked` and `recoveryState` remains
blocked. Starting another voice operation is rejected until cleanup succeeds.

## Host rules

- Keep one app-owned `AppLocalVoice` instance.
- Do not create simultaneous recognition and synthesis work; the package
  serializes them.
- Do not silently restart after an interruption, route change, backgrounding,
  or media-services reset. Show an explicit retry action.
- Cancel event observers before the owner calls `close()`.
- If the host owns a broader audio engine, establish a clear app-level boundary
  around every voice operation. The package does not expose a separate
  host-managed audio-session adapter.

## What needs a device test

Simulator tests cannot prove route changes, AirPods, wired headsets, external
audio resumption, interruptions, background behavior, or endurance. Test those
paths on the devices and routes your app supports. See [DeviceMatrix.md](DeviceMatrix.md).
