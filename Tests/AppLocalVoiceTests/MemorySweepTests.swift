import Darwin
import XCTest
@testable import AppLocalVoice

/// Long deterministic lifecycle sweeps. RSS is reported as a diagnostic
/// signal, while the hard invariant is that every provider resource returns
/// to zero after each turn. These are simulator/provider-proxy measurements,
/// not physical-device energy or thermal evidence.
final class MemorySweepTests: XCTestCase {
    func testResourceAndResidentMemorySweepAcrossTurnBudgets() async throws {
        let budgets = [100, 1_000, 10_000]
        var samples: [(turns: Int, before: UInt64?, after: UInt64?)] = []

        for budget in budgets {
            let ledger = ResourceLedger()
            let input = ControlledSpeechInput(ledger: ledger)
            let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput(ledger: ledger))
            let before = residentMemoryBytesForSweep()

            for _ in 0..<budget {
                try await coordinator.startListening()
                await coordinator.cancelListening()
            }

            await coordinator.close()
            let after = residentMemoryBytesForSweep()
            samples.append((budget, before, after))
            let balanced = await ledger.isBalanced()
            let state = await coordinator.state
            XCTAssertTrue(balanced, "resource leak after \(budget) turns")
            XCTAssertEqual(state, .idle, "non-idle after \(budget) turns")
        }

        for sample in samples {
            print("AppLocalVoice memory sweep turns=\(sample.turns) before=\(String(describing: sample.before)) after=\(String(describing: sample.after))")
        }
    }
}

private func residentMemoryBytesForSweep() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return UInt64(info.resident_size)
}
