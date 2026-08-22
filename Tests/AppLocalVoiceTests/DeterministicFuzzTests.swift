import Foundation
import XCTest
@testable import AppLocalVoice

/// A bounded, reproducible campaign for pure values and the host-facing
/// lifecycle contract. This intentionally is not a general-purpose fuzzer:
/// every loop has a small hard cap so CI cannot be made unbounded by an
/// environment variable or by malformed input.
final class DeterministicFuzzTests: XCTestCase {
    @MainActor
    func testMalformedSpeechConfigurationsFailDeterministically() async {
        let output = AppleSpeechOutput()
        let malformed: [SpeechConfiguration] = [
            SpeechConfiguration(rate: -.leastNonzeroMagnitude),
            SpeechConfiguration(rate: 1.0001),
            SpeechConfiguration(rate: .nan),
            SpeechConfiguration(rate: .infinity),
            SpeechConfiguration(rate: -.infinity),
            SpeechConfiguration(volume: -.leastNonzeroMagnitude),
            SpeechConfiguration(volume: 1.0001),
            SpeechConfiguration(volume: .nan),
            SpeechConfiguration(volume: .infinity),
            SpeechConfiguration(volume: -.infinity),
            SpeechConfiguration(maximumCharactersPerUtterance: 127),
            SpeechConfiguration(maximumCharactersPerUtterance: 0),
            SpeechConfiguration(maximumCharactersPerUtterance: -1),
            SpeechConfiguration(maximumCharactersPerUtterance: 32_001)
        ]

        for (index, configuration) in malformed.enumerated() {
            do {
                try await output.speak("deterministic malformed \(index)", configuration: configuration)
                XCTFail("configuration \(index) unexpectedly succeeded")
            } catch let error as VoiceError {
                XCTAssertEqual(error.category, .invalidSpeechConfiguration, "configuration \(index)")
            } catch {
                XCTFail("configuration \(index) returned an unexpected error: \(error)")
            }
        }
        await output.stop()
    }

    func testChunkSizesAndUnicodePreserveBoundariesWithinBoundedCampaign() {
        let campaign = FuzzCampaign()
        let alphabet = ["a", "é", "🙂", "👩🏽‍💻", "。", "！", "?", "\u{0301}"]

        for seed in campaign.seeds {
            var random = DeterministicRandom(seed: seed)
            for _ in 0..<campaign.caseCount {
                let count = 1 + random.nextInt(96)
                let source = (0..<count).map { _ in alphabet[random.nextInt(alphabet.count)] }.joined()
                // The generated alphabet has no single Character wider than
                // seven UTF-16 code units. Keep the limit above that bound so
                // the size property is meaningful for every generated input.
                let maximum = 8 + random.nextInt(121)
                let chunks = SpeechTextChunker.split(source, maximumUTF16Length: maximum)

                XCTAssertFalse(chunks.isEmpty, "seed \(seed)")
                XCTAssertEqual(chunks.joined(), source, "seed \(seed), maximum \(maximum)")
                XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= maximum },
                              "seed \(seed), maximum \(maximum), lengths \(chunks.map { $0.utf16.count })")
                XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty }, "seed \(seed)")
            }
        }

        // Invalid chunk limits are intentionally total for the pure helper:
        // they return the original text rather than entering a split loop.
        let source = "🙂é。"
        for maximum in [-1024, -1, 0] {
            XCTAssertEqual(SpeechTextChunker.split(source, maximumUTF16Length: maximum), [source])
        }
    }

    func testDuplicateNotificationsAndTranscriptTimingHaveOneTerminalOutcome() async throws {
        let campaign = FuzzCampaign()
        for seed in campaign.seeds {
            print("Deterministic fuzz seed: \(seed), steps: \(campaign.stepCount)")
            try await withBoundedTimeout(.seconds(2)) {
                var random = DeterministicRandom(seed: seed)
                let input = ControlledSpeechInput()
                let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
                let stream = await coordinator.voiceEvents()
                let sessionID = try await coordinator.startTurn()

                for step in 0..<campaign.stepCount {
                    let text = "seed-\(seed)-step-\(step)-🙂"
                    switch random.nextInt(5) {
                    case 0:
                        await input.send(TranscriptUpdate(text: text, isFinal: false))
                    case 1:
                        // Duplicate provider notification: both callbacks have
                        // the same payload and must not create lifecycle events.
                        let update = TranscriptUpdate(text: text, isFinal: random.nextInt(2) == 0)
                        await input.send(update)
                        await input.send(update)
                    case 2:
                        await input.sendStale(TranscriptUpdate(text: "stale-\(text)", isFinal: false))
                    case 3:
                        await Task.yield()
                    default:
                        await input.send(TranscriptUpdate(text: text, isFinal: true))
                        await input.send(TranscriptUpdate(text: text, isFinal: true))
                    }
                }

                let result = try await coordinator.finishTurn()
                XCTAssertFalse(result.isEmpty, "seed \(seed)")
                // The stream is drained after the turn ended, exactly as the
                // legacy campaign did. Previews and advisory states coalesce
                // for a subscriber that is not waiting, so the bounded tail
                // stays meaningful while the terminal outcome stays durable.
                let observed = try await collectEventsThroughOutcome(stream, sessionID: sessionID, limit: 64)
                XCTAssertFalse(observed.truncated, "event stream exceeded bounded tail for seed \(seed)")
                let kinds = observed.events.compactMap { event -> RecognitionEventKind? in
                    guard case .recognition(let recognition) = event,
                          recognition.sessionID == sessionID else { return nil }
                    return recognition.kind
                }
                XCTAssertEqual(kinds.filter(\.isTerminal).count, 1, "seed \(seed)")
                XCTAssertEqual(kinds.last, .outcome(.completed), "seed \(seed)")
                let finalTexts = kinds.compactMap { kind -> String? in
                    guard case .transcript(.finalTranscript(let transcript)) = kind else { return nil }
                    return transcript.text
                }
                XCTAssertEqual(
                    finalTexts,
                    [result],
                    "exact duplicate final transcript for seed \(seed)"
                )
                let state = await coordinator.state
                let balanced = await input.ledger.isBalanced()
                XCTAssertEqual(state, .idle, "seed \(seed)")
                XCTAssertTrue(balanced, "resource leak for seed \(seed)")
            }
        }
    }

}

private struct FuzzCampaign {
    let seeds: [UInt64]
    let caseCount: Int
    let stepCount: Int

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let defaultSeed: UInt64 = 0xA11CE5EED
        let requestedSeed = Self.parseUInt64(environment["APPLOCALVOICE_FUZZ_SEED"]) ?? defaultSeed
        // DeterministicRandom reserves zero as its canonical fallback state;
        // normalize it here so the printed/replayed seed names the actual
        // campaign rather than an alias.
        let seed = requestedSeed == 0 ? defaultSeed : requestedSeed
        let requestedCases = Int(environment["APPLOCALVOICE_FUZZ_CASES"] ?? "24") ?? 24
        let requestedSteps = Int(environment["APPLOCALVOICE_FUZZ_STEPS"] ?? "32") ?? 32
        let boundedCases = min(max(requestedCases, 1), 64)
        let boundedSteps = min(max(requestedSteps, 1), 64)

        seeds = (0..<boundedCases).map { seed &+ UInt64($0) }
        caseCount = boundedCases
        stepCount = boundedSteps
    }

    private static func parseUInt64(_ value: String?) -> UInt64? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("0x") || value.hasPrefix("0X") {
            return UInt64(value.dropFirst(2), radix: 16)
        }
        return UInt64(value)
    }
}

private struct BoundedEvents: Sendable {
    let events: [VoiceEventStreamEvent]
    let truncated: Bool
}

/// Drains the canonical stream only through the session's terminal outcome,
/// with a hard cap on the tail so a misbehaving producer cannot make the
/// campaign unbounded. The stream remains open for later turns.
private func collectEventsThroughOutcome(
    _ stream: VoiceEventStream,
    sessionID: RecognitionSessionID,
    limit: Int
) async throws -> BoundedEvents {
    var events: [VoiceEventStreamEvent] = []
    for try await event in stream {
        events.append(event)
        if case .recognition(let recognition) = event,
           recognition.sessionID == sessionID,
           recognition.kind.isTerminal {
            return BoundedEvents(events: events, truncated: false)
        }
        if events.count >= limit {
            return BoundedEvents(events: events, truncated: true)
        }
    }
    return BoundedEvents(events: events, truncated: false)
}
