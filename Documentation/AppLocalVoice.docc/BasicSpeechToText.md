# Speech to text

Use an identified recognition session for push-to-talk. Start one session when
the user presses the control, mirror preview events into the host-owned draft,
and await its final transcript when the user releases it. The final transcript
is text only; the host decides whether to submit it.

```swift
let events = await voice.voiceEvents()
let session = try await voice.startSession()

// On release:
let final = try await voice.finishSession(id: session.sessionID)
composerText = final.text
```

Subscribe before beginning the turn. Filter recognition events by `sessionID`
when more than one consumer observes the shared app-owned service. To abandon a
turn, call `cancelSession(id:)`; a stale ID cannot cancel a later session.

See <doc:ModelInstallation> before enabling a first voice turn on a device
that may need a local recognition model.
