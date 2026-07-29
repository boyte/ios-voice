import Darwin
import Foundation
import XCTest
@testable import AppLocalVoice

/// Bounded, hardware-free regression measurements.
///
/// These are deliberately proxy measurements: they exercise the serialized
/// coordinator, deterministic providers, chunker, bounded event stream, and
/// resource ledger. They do not claim microphone, SpeechAnalyzer, AVAudioSession,
/// voice-download, energy, or thermal performance.
final class BenchmarkTests: XCTestCase {
    private let samples = 5
    private let startupIterations = 16
    private let repeatedTurnIterations = 16
    private let chunkIterations = 500
    private let slowConsumerIterations = 8

    func testBoundedProxiesEmitBenchmarkArtifact() async throws {
        var measurements: [BenchmarkMeasurement] = []

        measurements.append(await measureStartupAndTeardown())
        measurements.append(await measureRepeatedTurns())
        measurements.append(measureChunkTransitions())
        measurements.append(await measureSlowConsumer())
        measurements.append(await measureResourceCounts())

        let artifact = BenchmarkArtifact(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            environment: BenchmarkEnvironment.current,
            hardwareFree: true,
            measurements: measurements
        )
        try await BenchmarkArtifactWriter.write(artifact)

        XCTAssertEqual(measurements.count, 5)
        XCTAssertTrue(measurements.allSatisfy { $0.samples == samples })
        XCTAssertTrue(measurements.allSatisfy { $0.medianNanoseconds >= 0 })
        XCTAssertTrue(measurements.allSatisfy { $0.p95Nanoseconds >= $0.medianNanoseconds })
        XCTAssertTrue(measurements.allSatisfy { $0.maxNanoseconds >= $0.p95Nanoseconds })
        XCTAssertTrue(measurements.allSatisfy { $0.resourceCounts.values.allSatisfy { $0 >= 0 } })
    }

    /// Also records XCTest's native clock and memory metrics in the result
    /// bundle. The custom artifact above is the stable, machine-readable form.
    func testChunkProxyWithXCTestClockAndMemoryMetrics() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0..<64 {
                _ = SpeechTextChunker.split(
                    String(repeating: "hello world. ", count: 24),
                    maximumUTF16Length: 256
                )
            }
        }
    }

    private func measureStartupAndTeardown() async -> BenchmarkMeasurement {
        await measureAsync(
            name: "startup_teardown_proxy",
            iterations: startupIterations,
            deviceOnly: false,
            notes: "ControlledSpeechInput start followed by cancellation; excludes microphone and SpeechAnalyzer startup."
        ) {
            let ledger = ResourceLedger()
            let input = ControlledSpeechInput(ledger: ledger)
            let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput(ledger: ledger))
            try await coordinator.startListening()
            await coordinator.cancelListening()
            let state = await coordinator.state
            let balanced = await ledger.isBalanced()
            XCTAssertEqual(state, .idle)
            XCTAssertTrue(balanced)
        }
    }

    private func measureRepeatedTurns() async -> BenchmarkMeasurement {
        await measureAsync(
            name: "repeated_turns_proxy",
            iterations: repeatedTurnIterations,
            deviceOnly: false,
            notes: "Controlled start, one final transcript, and endListening cycle."
        ) {
            let ledger = ResourceLedger()
            let input = ControlledSpeechInput(ledger: ledger)
            let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput(ledger: ledger))
            try await coordinator.startListening()
            await input.send(TranscriptUpdate(text: "benchmark final", isFinal: true))
            let result = try? await coordinator.endListening()
            let balanced = await ledger.isBalanced()
            XCTAssertEqual(result, "benchmark final")
            XCTAssertTrue(balanced)
        }
    }

    private func measureChunkTransitions() -> BenchmarkMeasurement {
        measureSync(
            name: "tts_chunk_transitions_proxy",
            iterations: chunkIterations,
            deviceOnly: false,
            notes: "Pure Unicode-safe chunking; no AVSpeechSynthesizer or audible output."
        ) {
            let chunks = SpeechTextChunker.split(
                String(repeating: "Sentence one. Sentence two. 🙂 ", count: 80),
                maximumUTF16Length: 256
            )
            precondition(!chunks.isEmpty)
        }
    }

    private func measureSlowConsumer() async -> BenchmarkMeasurement {
        await measureAsync(
            name: "slow_consumer_proxy",
            iterations: slowConsumerIterations,
            deviceOnly: false,
            notes: "256 unconsumed partials followed by a final transcript; validates bounded newest-value buffering."
        ) {
            let input = ControlledSpeechInput()
            let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
            let stream = await coordinator.events()
            try await coordinator.startListening()
            for index in 0..<256 {
                await input.send(TranscriptUpdate(text: "partial-\(index)", isFinal: false))
            }
            await input.send(TranscriptUpdate(text: "slow consumer final", isFinal: true))
            let result = try? await coordinator.endListening()
            XCTAssertEqual(result, "slow consumer final")
            let events = await collectUntilIdle(stream)
            XCTAssertLessThanOrEqual(events.count, 32)
            XCTAssertTrue(events.contains(.listeningFinished(.completed)))
        }
    }

    private func measureResourceCounts() async -> BenchmarkMeasurement {
        var acquired: [String: Int] = [:]
        var released: [String: Int] = [:]

        let measurement = await measureAsync(
            name: "resource_counts_proxy",
            iterations: 12,
            deviceOnly: false,
            notes: "ResourceLedger acquisition/release counts across capture and speech operations."
        ) {
            let ledger = ResourceLedger()
            let input = ControlledSpeechInput(ledger: ledger)
            let output = ControlledSpeechOutput(ledger: ledger)
            let coordinator = VoiceCoordinator(input: input, output: output)

            try await coordinator.startListening()
            await coordinator.cancelListening()

            let speech = Task { try? await coordinator.speak("resource benchmark") }
            await output.waitUntilStarted()
            await output.complete(.success(()))
            _ = await speech.value

            let microphone = await ledger.count(.microphone)
            let speechCounts = await ledger.count(.speech)
            acquired["microphone", default: 0] += microphone.acquired
            released["microphone", default: 0] += microphone.released
            acquired["speech", default: 0] += speechCounts.acquired
            released["speech", default: 0] += speechCounts.released
            let balanced = await ledger.isBalanced()
            XCTAssertTrue(balanced)
        }

        return BenchmarkMeasurement(
            name: measurement.name,
            samples: measurement.samples,
            iterations: measurement.iterations,
            medianNanoseconds: measurement.medianNanoseconds,
            p95Nanoseconds: measurement.p95Nanoseconds,
            maxNanoseconds: measurement.maxNanoseconds,
            memoryBeforeBytes: measurement.memoryBeforeBytes,
            memoryAfterBytes: measurement.memoryAfterBytes,
            peakResidentBytes: measurement.peakResidentBytes,
            resourceCounts: [
                "microphone_acquired": acquired["microphone"] ?? 0,
                "microphone_released": released["microphone"] ?? 0,
                "speech_acquired": acquired["speech"] ?? 0,
                "speech_released": released["speech"] ?? 0
            ],
            deviceOnly: measurement.deviceOnly,
            notes: measurement.notes
        )
    }

    private func measureAsync(
        name: String,
        iterations: Int,
        deviceOnly: Bool,
        notes: String,
        operation: () async throws -> Void
    ) async -> BenchmarkMeasurement {
        for _ in 0..<1 {
            do {
                try await operation()
            } catch {
                XCTFail("benchmark warm-up failed for \(name): \(error)")
            }
        }
        var durations: [UInt64] = []
        var peak = residentMemoryBytes() ?? 0
        let before = residentMemoryBytes()
        for _ in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                do {
                    try await operation()
                } catch {
                    XCTFail("benchmark operation failed for \(name): \(error)")
                }
            }
            durations.append(DispatchTime.now().uptimeNanoseconds - start)
            peak = max(peak, residentMemoryBytes() ?? peak)
        }
        return BenchmarkMeasurement(
            name: name,
            samples: samples,
            iterations: iterations,
            medianNanoseconds: percentile(durations, 0.50),
            p95Nanoseconds: percentile(durations, 0.95),
            maxNanoseconds: durations.max() ?? 0,
            memoryBeforeBytes: before,
            memoryAfterBytes: residentMemoryBytes(),
            peakResidentBytes: peak == 0 ? nil : peak,
            resourceCounts: [:],
            deviceOnly: deviceOnly,
            notes: notes
        )
    }

    private func measureSync(
        name: String,
        iterations: Int,
        deviceOnly: Bool,
        notes: String,
        operation: () -> Void
    ) -> BenchmarkMeasurement {
        for _ in 0..<1 { operation() }
        var durations: [UInt64] = []
        var peak = residentMemoryBytes() ?? 0
        let before = residentMemoryBytes()
        for _ in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { operation() }
            durations.append(DispatchTime.now().uptimeNanoseconds - start)
            peak = max(peak, residentMemoryBytes() ?? peak)
        }
        return BenchmarkMeasurement(
            name: name,
            samples: samples,
            iterations: iterations,
            medianNanoseconds: percentile(durations, 0.50),
            p95Nanoseconds: percentile(durations, 0.95),
            maxNanoseconds: durations.max() ?? 0,
            memoryBeforeBytes: before,
            memoryAfterBytes: residentMemoryBytes(),
            peakResidentBytes: peak == 0 ? nil : peak,
            resourceCounts: [:],
            deviceOnly: deviceOnly,
            notes: notes
        )
    }
}

private struct BenchmarkArtifact: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let environment: BenchmarkEnvironment
    let hardwareFree: Bool
    let measurements: [BenchmarkMeasurement]
}

private struct BenchmarkEnvironment: Codable {
    let os: String
    let processArchitecture: String
    let swiftVersion: String

    static var current: Self {
        Self(
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            processArchitecture: ProcessInfo.processInfo.environment["CURRENT_ARCH"] ?? "unknown",
            swiftVersion: ProcessInfo.processInfo.environment["SWIFT_VERSION"] ?? "unknown"
        )
    }
}

private struct BenchmarkMeasurement: Codable {
    let name: String
    let samples: Int
    let iterations: Int
    let medianNanoseconds: UInt64
    let p95Nanoseconds: UInt64
    let maxNanoseconds: UInt64
    let memoryBeforeBytes: UInt64?
    let memoryAfterBytes: UInt64?
    let peakResidentBytes: UInt64?
    let resourceCounts: [String: Int]
    let deviceOnly: Bool
    let notes: String
}

@MainActor
private enum BenchmarkArtifactWriter {
    static func write(_ artifact: BenchmarkArtifact) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(artifact)
        let path = ProcessInfo.processInfo.environment["APPLOCALVOICE_BENCHMARK_OUTPUT"]
            ?? NSTemporaryDirectory() + "AppLocalVoice-benchmarks.json"
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        // Simulator test processes do not consistently expose host-side
        // environment paths. Emit a bounded, machine-readable copy so the
        // host script can reconstruct the artifact from xcodebuild's log.
        if let json = String(data: data, encoding: .utf8) {
            print("APPLOCALVOICE_BENCHMARK_JSON_BEGIN")
            print(json)
            print("APPLOCALVOICE_BENCHMARK_JSON_END")
        }
        XCTContext.runActivity(named: "Benchmark artifact: \(url.path)") { _ in }
    }
}

private func percentile(_ values: [UInt64], _ fraction: Double) -> UInt64 {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
    return sorted[index]
}

private func residentMemoryBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return UInt64(info.resident_size)
}

private func collectUntilIdle(_ stream: AsyncStream<VoiceEvent>) async -> [VoiceEvent] {
    var events: [VoiceEvent] = []
    for await event in stream {
        events.append(event)
        if event == .stateChanged(.idle) { break }
    }
    return events
}
