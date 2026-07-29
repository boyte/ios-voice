# Privacy-safe diagnostics

Diagnostics are deliberately opt-in. Call `diagnostics()` to receive a bounded
`VoiceDiagnosticsStream`, or pass a `VoiceDiagnosticsSink` to
`AppLocalVoice(queueConfiguration:lifecyclePolicy:diagnostics:)` when a
callback fits the host architecture. The package provides no logger,
persistence layer, telemetry client, or export mechanism.

The sink receives records for logical `listening`, `speaking`, and `close`
operations. Listening and speaking records use one `operationID` from start to
terminal outcome. `durationNanoseconds` is monotonic elapsed time, not a wall
clock or timestamp.

Canonical recognition sessions started with `startSession` use the UUID backing
their `RecognitionSessionID` as the diagnostic `operationID`. The `.started`
diagnostic follows publication of that session's `.accepted` event. Exactly one
terminal diagnostic follows its canonical outcome: normal completion and the
duration limit are `.completed`, explicit cancellation is `.cancelled`, and
interruptions or typed failures are `.failed` with a stable content-free error
category. A successful terminal record is emitted only after input resources are
observed released; an unresolved release is instead a failed terminal record,
with a later `close` operation recording cleanup retry truth under its own ID.
Legacy `startListening` calls retain their existing facade-generated operation
identity and do not receive a duplicate canonical record.

Each record contains only operation identity, operation and phase, serialized
state, a stable error category when applicable, a coarse route class, and
monotonic elapsed duration. It never contains microphone audio, transcript
text, synthesized text, voice names, device names, route identifiers, locale
identifiers, credentials, or provider error messages.

The callback is not a logger, persistence layer, analytics client, or crash
reporter. AppLocalVoice does not retain or export records. Passing no sink
preserves the zero-diagnostics default and does not change lifecycle behavior.

## Recovery evidence

Group records by `operationID`, inspect the terminal phase and
`errorCategory`, then compare `routeClass`, `state`, and elapsed duration.
Use `VoiceEvent` and the public error for user-facing recovery. Operation IDs
are correlation tokens, not durable user or device identifiers; do not combine
them with speech content in a shared telemetry payload.
