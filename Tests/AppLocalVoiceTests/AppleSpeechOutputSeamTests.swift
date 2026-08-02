import AVFoundation
import UIKit
import XCTest
@testable import AppLocalVoice

@MainActor
final class AppleSpeechOutputSeamTests: XCTestCase {
    func testProgressMapsValidatedAppleRangesToOriginalChunkUTF16Offsets() async throws {
        let driver = FailingSpeechSynthesizerDriver()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: OutputNotificationCenter(),
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )
        let collector = ProgressCollector()
        await output.setProgressHandler { range in await collector.append(range) }
        let task = Task { @MainActor in
            try await output.speak("👩🏽‍💻 hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()
        driver.emitProgress(NSRange(location: 0, length: 7))
        driver.emitProgress(NSRange(location: 0, length: 7))
        driver.emitProgress(NSRange(location: 999, length: 1))
        await collector.waitUntilCount(1)

        let values = await collector.values
        XCTAssertEqual(values, [0..<7])
        driver.cancelCurrentUtterance()
        _ = try? await task.value
    }

    func testSynthesizerCancellationIsDeliveredThroughInjectedDriver() async throws {
        let driver = FailingSpeechSynthesizerDriver()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: OutputNotificationCenter(),
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )

        let task = Task { @MainActor in
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()
        driver.cancelCurrentUtterance()

        do {
            try await task.value
            XCTFail("expected injected synthesizer cancellation")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(driver.speakCount, 1)
    }

    func testNoCallbackWatchdogFailsRequestAndStopsSynthesizer() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let sessionDriver = OutputAudioSessionDriver()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(driver: sessionDriver),
            synthesizer: driver,
            notificationCenter: OutputNotificationCenter(),
            watchdogSleep: { _ in },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )

        do {
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
            XCTFail("expected the no-callback watchdog to fail the request")
        } catch let error as VoiceError {
            XCTAssertEqual(
                error,
                .speechSynthesisUnavailable("The speech synthesizer did not report completion within the recovery deadline.")
            )
        }

        XCTAssertEqual(driver.speakCount, 1)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(driver.applicationAudioSessionConfigurationCount, 1)
        XCTAssertEqual(sessionDriver.deactivationCalls, 0)
    }

    func testWatchdogFailureRetainsOwnershipWhenStopIsRejected() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        driver.stopResult = false
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: OutputNotificationCenter(),
            watchdogSleep: { _ in },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )

        do {
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
            XCTFail("the watchdog must fail a request that cannot be stopped")
        } catch let error as VoiceError {
            XCTAssertEqual(
                error,
                .speechSynthesisUnavailable(
                    "The speech synthesizer did not report completion within the recovery deadline."
                )
            )
        }

        let retainedResources = await output.resourcesAreReleased()
        XCTAssertFalse(retainedResources)
        XCTAssertEqual(driver.stopCount, 1)

        driver.stopResult = true
        await output.stop()
        let releasedResources = await output.resourcesAreReleased()
        XCTAssertTrue(releasedResources)
    }

    func testLateTerminalCallbacksAfterWatchdogRestoreReuse() async throws {
        for shouldCancel in [true, false] {
            let driver = NoCallbackSpeechSynthesizerDriver()
            let output = AppleSpeechOutput(
                audioSession: AudioSessionController(),
                synthesizer: driver,
                notificationCenter: OutputNotificationCenter(),
                watchdogSleep: { _ in },
                voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
            )

            let first = Task { @MainActor in
                try await output.speak("first", configuration: .init(locale: Locale(identifier: "en-US")))
            }
            await driver.waitUntilSpoken(count: 1)

            do {
                try await first.value
                XCTFail("expected the watchdog to fail the first request")
            } catch let error as VoiceError {
                XCTAssertEqual(
                    error,
                    .speechSynthesisUnavailable(
                        "The speech synthesizer did not report completion within the recovery deadline."
                    )
                )
            }
            let retainedResources = await output.resourcesAreReleased()
            XCTAssertFalse(retainedResources)

            if shouldCancel {
                driver.emitLateCancellation()
            } else {
                driver.emitLateCompletion()
            }
            let releasedResources = await waitUntilReleased(output)
            XCTAssertTrue(releasedResources)

            let reuse = Task { @MainActor in
                try await output.speak("reuse", configuration: .init(locale: Locale(identifier: "en-US")))
            }
            await driver.waitUntilSpoken(count: 2)
            do {
                try await reuse.value
                XCTFail("expected the watchdog to fail the reused request")
            } catch let error as VoiceError {
                XCTAssertEqual(
                    error,
                    .speechSynthesisUnavailable(
                        "The speech synthesizer did not report completion within the recovery deadline."
                    )
                )
            }
            if shouldCancel {
                driver.emitLateCancellation()
            } else {
                driver.emitLateCompletion()
            }
            let reusedResources = await waitUntilReleased(output)
            XCTAssertTrue(reusedResources)
        }
    }

    func testFailedStopKeepsSpeechOwnedUntilAStopRetryIsAccepted() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: OutputNotificationCenter(),
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )

        let speech = Task { @MainActor in
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()

        driver.stopResult = false
        await output.stop()
        let retainedAfterFailedStop = await output.resourcesAreReleased()
        XCTAssertFalse(retainedAfterFailedStop)
        XCTAssertEqual(driver.stopCount, 1)

        driver.stopResult = true
        await output.stop()
        let releasedAfterRetry = await output.resourcesAreReleased()
        XCTAssertTrue(releasedAfterRetry)
        do {
            try await speech.value
            XCTFail("accepted stop must cancel the pending speech request")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testAudioSessionRestoreFailureRemainsVisibleUntilCloseRetry() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let sessionDriver = OutputAudioSessionDriver()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(driver: sessionDriver),
            synthesizer: driver,
            notificationCenter: OutputNotificationCenter(),
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )

        let speech = Task { @MainActor in
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()
        sessionDriver.setRestoreFailure(true)
        await output.stop()
        _ = try? await speech.value

        let failedRelease = await output.resourcesAreReleased()
        XCTAssertFalse(failedRelease)
        sessionDriver.setRestoreFailure(false)
        await output.stop()
        let retriedRelease = await output.resourcesAreReleased()
        XCTAssertTrue(retriedRelease)
    }

    func testDidFinishPreservesRuntimePreferenceDriftAndCompletesPlayback() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let sessionDriver = OutputAudioSessionDriver()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(driver: sessionDriver),
            synthesizer: driver,
            notificationCenter: OutputNotificationCenter(),
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )

        let speech = Task { @MainActor in
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()
        sessionDriver.mutatePreferences(
            sampleRate: 48_000,
            bufferDuration: 0.012,
            inputUID: "runtime-input"
        )
        driver.emitLateCompletion()

        try await speech.value
        let released = await output.resourcesAreReleased()
        XCTAssertTrue(released)
        XCTAssertEqual(sessionDriver.deactivationCalls, 1)
        XCTAssertEqual(sessionDriver.snapshot().preferredSampleRate, 48_000)
        XCTAssertEqual(sessionDriver.snapshot().preferredIOBufferDuration, 0.012)
        XCTAssertEqual(sessionDriver.snapshot().preferredInputUID, "runtime-input")
    }

    func testInterruptionNotificationFailsOnlyTheActiveRequest() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let center = OutputNotificationCenter()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: center,
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )
        XCTAssertEqual(center.names, [
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
            UIApplication.didEnterBackgroundNotification,
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification
        ])
        let task = Task { @MainActor in
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()

        center.post(Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        ))

        do {
            try await task.value
            XCTFail("expected interruption failure")
        } catch let error as VoiceLifecycleInterruption {
            XCTAssertEqual(error.reason, .systemInterruption)
        }
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testInterruptionEndDoesNotResumeOrCompleteActiveSpeech() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let center = OutputNotificationCenter()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: center,
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )
        let task = Task { @MainActor in
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()

        center.post(Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        ))
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(driver.stopCount, 0)
        let resourcesAreReleased = await output.resourcesAreReleased()
        XCTAssertFalse(resourcesAreReleased)

        await output.stop()
        do {
            try await task.value
            XCTFail("explicit stop must cancel speech after an interruption end notification")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testRouteChangeNotificationFailsTheActiveRequest() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let center = OutputNotificationCenter()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: center,
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )
        let task = Task { @MainActor in
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()

        center.post(Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        ))

        do {
            try await task.value
            XCTFail("expected route-change failure")
        } catch let error as VoiceLifecycleInterruption {
            XCTAssertEqual(error.reason, .routeChange)
        }
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testInterruptionRetainsOwnershipWhenStopIsRejectedUntilRetry() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        driver.stopResult = false
        let center = OutputNotificationCenter()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: center,
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )
        let task = Task { @MainActor in
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()

        center.post(Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        ))

        do {
            try await task.value
            XCTFail("expected interruption failure")
        } catch let error as VoiceLifecycleInterruption {
            XCTAssertEqual(error.reason, .systemInterruption)
        }
        let retainedResources = await output.resourcesAreReleased()
        XCTAssertFalse(retainedResources)

        driver.stopResult = true
        await output.stop()
        let releasedResources = await output.resourcesAreReleased()
        XCTAssertTrue(releasedResources)
        XCTAssertEqual(driver.stopCount, 2)
    }

    func testTaskCancellationRetainsOwnershipWhenStopIsRejectedUntilRetry() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        driver.stopResult = false
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: OutputNotificationCenter(),
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )
        let task = Task { @MainActor in
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()
        task.cancel()

        do {
            try await task.value
            XCTFail("cancelled speech must not complete successfully")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // Task cancellation may win before the provider normalizes it.
        }
        let retainedResources = await output.resourcesAreReleased()
        XCTAssertFalse(retainedResources)

        driver.stopResult = true
        await output.stop()
        let releasedResources = await output.resourcesAreReleased()
        XCTAssertTrue(releasedResources)
        XCTAssertEqual(driver.stopCount, 2)
    }

    func testRouteDiscoveryDoesNotCancelActiveSpeech() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let center = OutputNotificationCenter()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: center,
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )
        let task = Task { @MainActor in
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()

        center.post(Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
        ))
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(driver.stopCount, 0)

        await output.stop()
        _ = try? await task.value
    }

    func testRouteConfigurationSettlingDoesNotCancelActiveSpeech() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let center = OutputNotificationCenter()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: center,
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )
        let task = Task { @MainActor in
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()

        center.post(Notification(
            name: AVAudioSession.routeChangeNotification,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue
            ]
        ))
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(driver.stopCount, 0)

        await output.stop()
        _ = try? await task.value
    }

    func testApplicationBackgroundFailsTheActiveRequest() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let sessionDriver = OutputAudioSessionDriver()
        let center = OutputNotificationCenter()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(driver: sessionDriver),
            synthesizer: driver,
            notificationCenter: center,
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )
        let task = Task { @MainActor in
            try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
        }
        await driver.waitUntilSpoken()

        center.post(Notification(name: UIApplication.didEnterBackgroundNotification))

        do {
            try await task.value
            XCTFail("expected background failure")
        } catch let error as VoiceLifecycleInterruption {
            XCTAssertEqual(error.reason, .appBackground)
        }
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testMediaServicesLossAndResetFailTheActiveRequest() async throws {
        let cases: [(Notification.Name, String)] = [
            (AVAudioSession.mediaServicesWereLostNotification, "The audio media services were lost."),
            (AVAudioSession.mediaServicesWereResetNotification, "The audio media services were reset.")
        ]

        for (name, _) in cases {
            let driver = NoCallbackSpeechSynthesizerDriver()
            let center = OutputNotificationCenter()
            let output = AppleSpeechOutput(
                audioSession: AudioSessionController(),
                synthesizer: driver,
                notificationCenter: center,
                watchdogSleep: { _ in try await Task.never() },
                voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
            )
            let task = Task { @MainActor in
                try await output.speak("hello", configuration: .init(locale: Locale(identifier: "en-US")))
            }
            await driver.waitUntilSpoken()
            center.post(Notification(name: name))

            do {
                try await task.value
                XCTFail("expected media-services failure")
            } catch let error as VoiceLifecycleInterruption {
                XCTAssertEqual(error.reason, .mediaServicesReset)
            }
            XCTAssertEqual(driver.stopCount, 1)
            if name == AVAudioSession.mediaServicesWereResetNotification {
                XCTAssertEqual(driver.resetCount, 1)
            } else {
                XCTAssertEqual(driver.resetCount, 0)
            }
        }
    }

    func testMediaServicesResetRebuildsTheSynthesizerEvenWhileIdle() async {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let center = OutputNotificationCenter()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: center,
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )

        center.post(Notification(name: AVAudioSession.mediaServicesWereResetNotification))
        for _ in 0..<32 where driver.resetCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(driver.resetCount, 1)
        for _ in 0..<32 {
            if await output.resourcesAreReleased() { break }
            await Task.yield()
        }
        let releasedResources = await output.resourcesAreReleased()
        XCTAssertTrue(releasedResources)
    }

    func testConcurrentSecondRequestIsRejected() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: OutputNotificationCenter(),
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )

        let configuration = SpeechConfiguration(locale: Locale(identifier: "en-US"))
        let first = Task { @MainActor in try await output.speak("first", configuration: configuration) }
        await driver.waitUntilSpoken()
        do {
            try await output.speak("second", configuration: configuration)
            XCTFail("a concurrent second request must be rejected")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .invalidState("Speech output is already active."))
        }
        XCTAssertEqual(driver.speakCount, 1)

        await output.stop()
        _ = try? await first.value
    }

    func testCompletedRequestDoesNotAutoAdvanceARejectedRequest() async throws {
        let driver = DelayedCompletionSpeechSynthesizerDriver()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: OutputNotificationCenter(),
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )

        let configuration = SpeechConfiguration(locale: Locale(identifier: "en-US"))
        let first = Task { @MainActor in try await output.speak("first", configuration: configuration) }
        await driver.waitUntilSpoken(count: 1)
        do {
            try await output.speak("second", configuration: configuration)
            XCTFail("a concurrent second request must be rejected")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .invalidState("Speech output is already active."))
        }

        driver.complete(index: 0)
        try await first.value
        XCTAssertEqual(driver.utterances.count, 1, "a rejected request must not auto-advance")
    }

    func testInterruptionFailsOnlyTheActiveRequest() async throws {
        let driver = NoCallbackSpeechSynthesizerDriver()
        let center = OutputNotificationCenter()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: center,
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )

        let first = Task { @MainActor in try await output.speak("first") }
        await driver.waitUntilSpoken()

        center.post(Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        ))

        do {
            try await first.value
            XCTFail("expected first request to fail")
        } catch let error as VoiceLifecycleInterruption {
            XCTAssertEqual(error.reason, .systemInterruption)
        }
        XCTAssertEqual(driver.speakCount, 1)
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testLateCompletionFromAnOldUtteranceCannotCompleteTheNextRequest() async throws {
        let driver = DelayedCompletionSpeechSynthesizerDriver()
        let output = AppleSpeechOutput(
            audioSession: AudioSessionController(),
            synthesizer: driver,
            notificationCenter: OutputNotificationCenter(),
            watchdogSleep: { _ in try await Task.never() },
            voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
        )

        let first = Task { @MainActor in try await output.speak("first") }
        await driver.waitUntilSpoken(count: 1)
        await output.stop()
        _ = try? await first.value

        let second = Task { @MainActor in try await output.speak("second") }
        await driver.waitUntilSpoken(count: 2)
        let completionFlag = CompletionFlag()
        let observer = Task {
            _ = try? await second.value
            await completionFlag.mark()
        }
        driver.complete(index: 0)
        try? await Task.sleep(for: .milliseconds(10))
        let completedByOldCallback = await completionFlag.value
        XCTAssertFalse(completedByOldCallback)
        driver.complete(index: 1)
        try await second.value
        await observer.value
    }

    func testDeallocationRemovesObservers() async {
        let center = OutputNotificationCenter()
        let driver = NoCallbackSpeechSynthesizerDriver()
        weak var deallocatedOutput: AppleSpeechOutput?
        do {
            let output = AppleSpeechOutput(
                audioSession: AudioSessionController(),
                synthesizer: driver,
                notificationCenter: center,
                watchdogSleep: { _ in try await Task.never() },
                voiceResolver: { _ in nil as AVSpeechSynthesisVoice? }
            )
            deallocatedOutput = output
            for _ in 0..<32 where center.names.count < 5 { await Task.yield() }
        }
        XCTAssertNil(deallocatedOutput)
        XCTAssertEqual(center.removeCount, 5)
    }

    private func waitUntilReleased(_ output: AppleSpeechOutput) async -> Bool {
        // Delegate callbacks cross from AVFoundation into a main-actor task.
        // Counting yields is scheduler-sensitive on a loaded hosted runner,
        // so use a short, explicit deadline while still failing closed if the
        // terminal callback never releases the retained watchdog ownership.
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if await output.resourcesAreReleased() { return true }
            await Task.yield()
        }
        return await output.resourcesAreReleased()
    }
}

@MainActor
private final class FailingSpeechSynthesizerDriver: SpeechSynthesizerDriver {
    weak var delegate: AVSpeechSynthesizerDelegate?
    private var utterance: AVSpeechUtterance?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var speakCount = 0

    func speak(_ utterance: AVSpeechUtterance) {
        speakCount += 1
        self.utterance = utterance
        waiter?.resume()
        waiter = nil
    }

    func waitUntilSpoken() async {
        if utterance != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func cancelCurrentUtterance() {
        guard let utterance else { return }
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didCancel: utterance)
    }

    func emitProgress(_ range: NSRange) {
        guard let utterance else { return }
        delegate?.speechSynthesizer?(
            AVSpeechSynthesizer(),
            willSpeakRangeOfSpeechString: range,
            utterance: utterance
        )
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
    func continueSpeaking() -> Bool { true }
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
}

private actor ProgressCollector {
    private(set) var values: [Range<Int>] = []
    func append(_ value: Range<Int>) { values.append(value) }

    func waitUntilCount(_ count: Int) async {
        while values.count < count {
            await Task.yield()
        }
    }
}

@MainActor
private final class NoCallbackSpeechSynthesizerDriver: SpeechSynthesizerDriver {
    weak var delegate: AVSpeechSynthesizerDelegate?
    private var utterances: [AVSpeechUtterance] = []
    private(set) var speakCount = 0
    private(set) var stopCount = 0
    private(set) var resetCount = 0
    private(set) var applicationAudioSessionConfigurationCount = 0
    var stopResult = true

    func resetAfterMediaServicesReset() {
        resetCount += 1
    }

    func configureForApplicationAudioSession() {
        applicationAudioSessionConfigurationCount += 1
    }

    func speak(_ utterance: AVSpeechUtterance) {
        speakCount += 1
        utterances.append(utterance)
    }

    func waitUntilSpoken(count: Int = 1) async {
        for _ in 0..<128 {
            if speakCount >= count { return }
            await Task.yield()
        }
    }

    func emitLateCancellation() {
        guard let utterance = utterances.last else { return }
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didCancel: utterance)
    }

    func emitLateCompletion() {
        guard let utterance = utterances.last else { return }
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
    func continueSpeaking() -> Bool { true }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopCount += 1
        return stopResult
    }
}

@MainActor
private final class DelayedCompletionSpeechSynthesizerDriver: SpeechSynthesizerDriver {
    weak var delegate: AVSpeechSynthesizerDelegate?
    private(set) var utterances: [AVSpeechUtterance] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func speak(_ utterance: AVSpeechUtterance) {
        utterances.append(utterance)
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func configureForApplicationAudioSession() {}
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
    func continueSpeaking() -> Bool { true }
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }

    func waitUntilSpoken(count: Int) async {
        guard utterances.count < count else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func complete(index: Int) {
        guard utterances.indices.contains(index) else { return }
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterances[index])
    }
}

private actor CompletionFlag {
    private(set) var value = false

    func mark() { value = true }
}

/// SAFETY: `lock` protects the handler table and counters. `post` copies its
/// matching callbacks while locked and invokes them only after unlocking.
private final class OutputNotificationCenter: @unchecked Sendable, AudioNotificationCenter {
    private let lock = NSLock()
    private var handlers: [NSObject: (Notification.Name?, @Sendable (Notification) -> Void)] = [:]
    private var recordedNames: [Notification.Name?] = []
    private var recordedRemoveCount = 0

    var names: [Notification.Name?] { lock.withLock { recordedNames } }
    var removeCount: Int { lock.withLock { recordedRemoveCount } }

    func addObserver(
        forName name: Notification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        let token = NSObject()
        lock.withLock {
            handlers[token] = (name, block)
            recordedNames.append(name)
        }
        return token
    }

    func removeObserver(_ observer: Any) {
        guard let token = observer as? NSObject else { return }
        lock.withLock {
            recordedRemoveCount += 1
            handlers.removeValue(forKey: token)
        }
    }

    func post(_ notification: Notification) {
        let callbacks = lock.withLock {
            handlers.values
                .filter { $0.0 == notification.name }
                .map { $0.1 }
        }
        callbacks.forEach { $0(notification) }
    }
}

/// SAFETY: the internal lock protects all mutable fixture state. Production
/// protocol calls and direct test inspection therefore use the same ordering
/// domain, and no callback runs while the lock is held.
private final class OutputAudioSessionDriver: @unchecked Sendable, AudioSessionDriver {
    private let lock = NSLock()
    private var recordedDeactivationCalls = 0
    private var restoreFailure = false
    private var currentSnapshot = AudioSessionSnapshot.empty

    var deactivationCalls: Int { lock.withLock { recordedDeactivationCalls } }

    var isOtherAudioPlaying: Bool { false }

    func configureForVoice() throws {}

    func snapshot() -> AudioSessionSnapshot { lock.withLock { currentSnapshot } }

    func setActive(_ active: Bool) throws {
        if !active { lock.withLock { recordedDeactivationCalls += 1 } }
    }

    func restore(_ snapshot: AudioSessionSnapshot) throws {
        try lock.withLock {
            if restoreFailure {
                throw VoiceError.audioSessionUnavailable("fixture restore failure")
            }
            currentSnapshot = snapshot
        }
    }

    func setRestoreFailure(_ failed: Bool) {
        lock.withLock { restoreFailure = failed }
    }

    func mutatePreferences(
        sampleRate: Double,
        bufferDuration: Double,
        inputUID: String?
    ) {
        lock.withLock {
            currentSnapshot = AudioSessionSnapshot(
                category: currentSnapshot.category,
                mode: currentSnapshot.mode,
                routeSharingPolicy: currentSnapshot.routeSharingPolicy,
                categoryOptions: currentSnapshot.categoryOptions,
                preferredSampleRate: sampleRate,
                preferredIOBufferDuration: bufferDuration,
                preferredInputUID: inputUID
            )
        }
    }
}

private extension Task where Success == Never, Failure == Never {
    static func never() async throws {
        try await Task.sleep(for: .seconds(60 * 60))
    }
}
