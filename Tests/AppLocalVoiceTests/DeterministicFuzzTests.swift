import Foundation
import XCTest
@testable import AppLocalVoice

/// A bounded, reproducible campaign for pure values and the host-facing
/// lifecycle contract. This intentionally is not a general-purpose fuzzer:
/// every loop has a small hard cap so CI cannot be made unbounded by an
/// environment variable or by malformed input.
final class DeterministicFuzzTests: XCTestCase {
    func testLocaleIdentifiersAndConfigurationsAreTotal() {
        let campaign = FuzzCampaign()
        for (index, seed) in campaign.seeds.enumerated() {
            var random = DeterministicRandom(seed: seed)
            for _ in 0..<campaign.caseCount {
                let identifier = randomLocaleIdentifier(using: &random)
                let locale = Locale(identifier: identifier)
                let policy: SpeechModelPolicy = random.nextInt(2) == 0
                    ? .installedModelsOnly
                    : .allowModelInstallation
                let configuration = RecognitionConfiguration(
                    locale: locale,
                    policy: policy
                )

                // Foundation owns locale parsing. Test the package-owned
                // invariants independently: configuration preserves the
                // requested policy and the exact identifier supplied by the
                // caller, including malformed identifiers.
                XCTAssertEqual(configuration.policy, policy, "seed \(seed), case \(index)")
                XCTAssertEqual(configuration.locale.identifier, locale.identifier, "seed \(seed), case \(index)")
            }
        }
    }

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
                let stream = await coordinator.events()
                try await coordinator.startListening()

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

                let result = try await coordinator.endListening()
                XCTAssertFalse(result.isEmpty, "seed \(seed)")
                let observed = await collectEventsThroughIdle(stream, limit: 64)
                XCTAssertFalse(observed.truncated, "event stream exceeded bounded tail for seed \(seed)")
                XCTAssertEqual(
                    observed.events.filter { event in
                        if case .listeningFinished = event { return true }
                        return false
                    }.count,
                    1,
                    "seed \(seed)"
                )
                let finalTexts = observed.events.compactMap { event -> String? in
                    guard case .transcript(let update) = event, update.isFinal else { return nil }
                    return update.text
                }
                XCTAssertEqual(
                    finalTexts.count,
                    Set(finalTexts).count,
                    "exact duplicate final transcript for seed \(seed)"
                )
                XCTAssertEqual(observed.events.filter { $0 == .stateChanged(.idle) }.count, 1, "seed \(seed)")
                let state = await coordinator.state
                let balanced = await input.ledger.isBalanced()
                XCTAssertEqual(state, .idle, "seed \(seed)")
                XCTAssertTrue(balanced, "resource leak for seed \(seed)")
            }
        }
    }

    private func randomLocaleIdentifier(using random: inout DeterministicRandom) -> String {
        let known = [
            "en-US", "vi-VN", "zh-Hant-TW", "de_DE", "", "-", "_", "en--US",
            "x-private", "123", "@@@", "\u{0000}", "🗣️", "a/\\b"
        ]
        if random.nextInt(3) != 0 { return known[random.nextInt(known.count)] }

        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789-_@")
        let length = random.nextInt(48)
        return String((0..<length).map { _ in alphabet[random.nextInt(alphabet.count)] })
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
    let events: [VoiceEvent]
    let truncated: Bool
}

private func collectEventsThroughIdle(_ stream: AsyncStream<VoiceEvent>, limit: Int) async -> BoundedEvents {
    var events: [VoiceEvent] = []
    for await event in stream {
        events.append(event)
        if event == .stateChanged(.idle) {
            return BoundedEvents(events: events, truncated: false)
        }
        if events.count >= limit {
            return BoundedEvents(events: events, truncated: true)
        }
    }
    return BoundedEvents(events: events, truncated: false)
}
