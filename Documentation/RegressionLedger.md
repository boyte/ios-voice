# Regression ledger

This is the short, durable index of lifecycle defects that must never return.
It contains no speech content, credentials, recordings, or app-private data.
Each shipped fix gets one row and a deterministic test or an explicit device
report reference.

| ID | Failure class | Protection | Evidence | Status |
| --- | --- | --- | --- | --- |
| R-001 | stale transcript callback | generation token rejects callbacks from an older turn | `StateMachineHardeningTests.swift` | protected |
| R-002 | duplicate terminal completion | one coordinator cleanup path plus resource ledger | `DeterministicFailureHarnessTests.swift` | protected |
| R-003 | audio-session lease imbalance | reference-counted session controller with injected driver failures | `AudioSessionControllerTests.swift` | protected |
| R-004 | Unicode utterance split | grapheme-safe bounded chunker | `SpeechTextChunkerTests.swift`, `DeterministicFuzzTests.swift` | protected |
| R-005 | slow consumer retains unbounded events | newest-value bounded event stream with final snapshot guarantee | `StateMachineHardeningTests.swift` | protected |
| R-006 | Apple audio call throws Objective-C exception | safe Objective-C adapter boundary | `AudioEngineSafe.m`, `AudioEngineSafetyTests.swift` | protected; device validation pending |
| R-007 | concurrent stop/close races | actor serialization and seeded stress campaign | `DeterministicRaceCancellationStressTests.swift` | protected; device validation pending |
| R-008 | cancelled startup resurrects a generation | generation checks after every asynchronous startup boundary and stale-error normalization | `VoiceCoordinatorTests.swift`, `DeterministicRaceCancellationStressTests.swift` | protected |
| R-009 | finalization returns stale success after independent cancellation | generation validation before and after provider/analyzer finalization | `FinalizationCancellationTests.swift` | protected |
| R-010 | converter accepts audio after an empty flush | flush marks the converter finalized even without a resampler | `AudioBufferConverterTests.swift` | protected |
| R-011 | pre-cancelled speech re-enters the output provider | cancellation check before operation reservation and provider invocation | `VoiceCoordinatorTests.swift` | protected |
| R-012 | test seams inflate the shipped API | internal provider/coordinator/diagnostic types plus production-only symbol graph | `PublicAPISymbols.json`, `PublicAPI.md` | protected |
| R-013 | deactivation failure leaves system-session state ambiguous | failed final release closes the logical lease; next `enter()` retries deactivation and refuses activation until reconciliation succeeds | `AudioSessionControllerTests.swift` | protected |
| R-014 | successful speech is misclassified as failed when AVFAudio normalizes preferred I/O during release | ownership proof covers package-authored configuration; three-way restoration preserves newer preferences without skipping package deactivation | `AudioSessionControllerTests.swift`, `AppleSpeechOutputSeamTests.swift`; physical-device failure and recovery traces | protected |
| R-015 | stale cleanup retry overwrites a host session established after release failed | reconciliation is allowed only while the exact post-failure process snapshot remains unchanged | `AudioSessionControllerTests.swift` | protected |
| R-016 | model download reaches 100% but slow `AssetInventory` publication is misclassified as installation failure | `downloading` and `supported` remain cancellable nonterminal reconciliation states with no synthetic deadline; only exact `installed` is ready | `AppleSpeechInputSeamTests.swift`; provider-less physical-device timeout trace | protected in simulator; physical retest pending |

## Adding a row

1. Give the defect a stable `R-###` identifier.
2. Classify it as API, lifecycle, Apple behavior, test infrastructure, or
   documentation/release.
3. Add the smallest deterministic regression test that reproduces it.
4. If deterministic reproduction is impossible, add the device report path,
   route, OS build, and expected result instead.
5. Link the row from the pull request and update the public changelog or
   release evidence when the behavior affects adopters.
6. Never include raw audio, transcript text, TTS text, credentials, or private
   app identifiers in the row or its evidence.
