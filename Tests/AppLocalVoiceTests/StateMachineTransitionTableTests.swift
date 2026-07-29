import XCTest
@testable import AppLocalVoice

private typealias LegalTransition = @Sendable (VoiceCoordinator, ControlledSpeechInput, ControlledSpeechOutput) async throws -> VoiceState
private typealias TransitionPreparation = @Sendable (VoiceCoordinator, ControlledSpeechOutput) async throws -> Void
private typealias IllegalTransition = @Sendable (VoiceCoordinator) async throws -> Void

/// Executable rows for Documentation/StateMachine.md. Each row constructs a
/// fresh coordinator, performs the documented operation, and checks the
/// resulting public state or typed rejection.
final class StateMachineTransitionTableTests: XCTestCase {
    func testLegalTransitionTable() async throws {
        let rows: [(name: String, run: LegalTransition)] = [
            ("idle.startListening", { coordinator, _, _ in
                try await coordinator.startListening()
                return await coordinator.state
            }),
            ("idle.close", { coordinator, _, _ in
                await coordinator.close()
                return await coordinator.state
            }),
            ("idle.speak", { coordinator, _, output in
                let task = Task { try await coordinator.speak("table") }
                await output.waitUntilStarted()
                let state = await coordinator.state
                await coordinator.stopSpeaking()
                _ = try? await task.value
                return state
            }),
            ("listening.finishListening", { coordinator, input, _ in
                try await coordinator.startListening()
                _ = try await coordinator.endListening()
                return await coordinator.state
            }),
            ("listening.cancelListening", { coordinator, _, _ in
                try await coordinator.startListening()
                await coordinator.cancelListening()
                return await coordinator.state
            }),
            ("speaking.pauseResume", { coordinator, _, output in
                let task = Task { try await coordinator.speak("table") }
                await output.waitUntilStarted()
                await coordinator.pauseSpeaking()
                await coordinator.resumeSpeaking()
                let state = await coordinator.state
                await coordinator.stopSpeaking()
                _ = try? await task.value
                return state
            }),
            ("speaking.stop", { coordinator, _, output in
                let task = Task { try await coordinator.speak("table") }
                await output.waitUntilStarted()
                await coordinator.stopSpeaking()
                _ = try? await task.value
                return await coordinator.state
            }),
            ("any.close", { coordinator, _, _ in
                try await coordinator.startListening()
                await coordinator.close()
                return await coordinator.state
            })
        ]

        for row in rows {
            let ledger = ResourceLedger()
            let input = ControlledSpeechInput(ledger: ledger)
            let output = ControlledSpeechOutput(ledger: ledger)
            let coordinator = VoiceCoordinator(input: input, output: output)

            let state = try await withBoundedTimeout {
                try await row.run(coordinator, input, output)
            }
            let expectedState: VoiceState = switch row.name {
            case "idle.startListening": .listening
            case "idle.speak", "speaking.pauseResume": .speaking
            default: .idle
            }
            XCTAssertEqual(state, expectedState, row.name)
            await coordinator.close()
            let balanced = await ledger.isBalanced()
            XCTAssertTrue(balanced, row.name)
        }
    }

    func testIllegalTransitionTableRejectsBeforeProviderReentry() async throws {
        let rows: [(name: String, prepare: TransitionPreparation, operation: IllegalTransition)] = [
            ("idle.finishListening", { _, _ in }, { coordinator in _ = try await coordinator.endListening() }),
            ("listening.startListening", { coordinator, _ in try await coordinator.startListening() }, { coordinator in try await coordinator.startListening() }),
            ("listening.speak", { coordinator, _ in try await coordinator.startListening() }, { coordinator in try await coordinator.speak("blocked") }),
            ("speaking.finishListening", { coordinator, output in
                let task = Task { try await coordinator.speak("active") }
                await output.waitUntilStarted()
                _ = task
            }, { coordinator in _ = try await coordinator.endListening() })
        ]

        for row in rows {
            let ledger = ResourceLedger()
            let input = ControlledSpeechInput(ledger: ledger)
            let output = ControlledSpeechOutput(ledger: ledger)
            let coordinator = VoiceCoordinator(input: input, output: output)

            try await row.prepare(coordinator, output)
            do {
                try await withBoundedTimeout { try await row.operation(coordinator) }
                XCTFail("\(row.name) unexpectedly succeeded")
            } catch let error as VoiceError {
                let expectedError: VoiceError = switch row.name {
                case "idle.finishListening", "speaking.finishListening":
                    .invalidState("Voice input is not active.")
                default:
                    .invalidState("A voice operation is already active.")
                }
                XCTAssertEqual(error, expectedError, row.name)
            } catch {
                XCTFail("\(row.name) returned unexpected error: \(error)")
            }

            await coordinator.close()
            let balanced = try await withBoundedTimeout {
                while !(await ledger.isBalanced()) { await Task.yield() }
                return true
            }
            let starts = await input.starts
            XCTAssertEqual(starts, row.name == "idle.finishListening" ? 0 : (row.name.hasPrefix("listening") ? 1 : 0), row.name)
            XCTAssertTrue(balanced, row.name)
        }
    }
}
