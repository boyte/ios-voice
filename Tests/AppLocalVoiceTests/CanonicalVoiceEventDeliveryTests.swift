import XCTest
@testable import AppLocalVoice

@MainActor
final class CanonicalVoiceEventDeliveryTests: XCTestCase {
    func testOverflowCoalescesAdvisoriesPreservesThirtyTwoDurableEventsAndIsolatesSubscriber() async throws {
        let registry = CanonicalEventSubscriberRegistry()
        var delivery = CanonicalVoiceEventDelivery(registry: registry)
        let affectedStream = delivery.subscribe { _ in }
        let sessionID = RecognitionSessionID()

        for ordinal in 0..<UInt64(RecognitionEventDeliveryLimits.maximumDurableEventCountPerSubscriber) {
            delivery.publish(.recovery(VoiceRecoveryEvent(eventOrdinal: ordinal, kind: .ready)))
        }

        let latestRevision: UInt64 = 7
        for revision in 0...latestRevision {
            delivery.publish(canonicalPreview(sessionID: sessionID, revision: revision))
            delivery.publish(canonicalState(
                sessionID: sessionID,
                revision: revision,
                state: revision == latestRevision ? .finalizing : .listening
            ))
        }

        let itemID = SpeechItemID()
        let playbackID = SpeechPlaybackID()
        let firstUndelivered = SpeechQueueEvent(
            itemID: itemID,
            playbackID: playbackID,
            eventOrdinal: 32,
            kind: .outcome(.finished)
        )
        let healthyStream = delivery.subscribe { _ in }
        delivery.publish(.speechQueue(firstUndelivered))

        var affectedIterator = affectedStream.makeAsyncIterator()
        var affectedEvents: [VoiceEventStreamEvent] = []
        for _ in 0..<34 {
            guard let event = try await affectedIterator.next() else {
                XCTFail("Affected stream ended before its buffered events were delivered")
                return
            }
            affectedEvents.append(event)
        }

        do {
            _ = try await affectedIterator.next()
            XCTFail("Expected the affected canonical subscriber to report overflow")
        } catch let error as VoiceError {
            XCTAssertEqual(
                error,
                .eventDeliveryOverflow(
                    capacity: RecognitionEventDeliveryLimits.maximumDurableEventCountPerSubscriber,
                    firstUndelivered: .speechQueue(
                        itemID: itemID,
                        playbackID: playbackID,
                        eventOrdinal: firstUndelivered.eventOrdinal
                    )
                )
            )
        }

        XCTAssertEqual(
            registry.activeSubscriberCount,
            1,
            "Overflow must release only the affected subscriber"
        )
        XCTAssertEqual(
            affectedEvents.filter {
                if case .recovery = $0 { return true }
                return false
            }.count,
            RecognitionEventDeliveryLimits.maximumDurableEventCountPerSubscriber
        )
        XCTAssertEqual(
            affectedEvents.compactMap { event -> UInt64? in
                guard case .recovery(let recovery) = event else { return nil }
                return recovery.eventOrdinal
            },
            Array(0..<UInt64(RecognitionEventDeliveryLimits.maximumDurableEventCountPerSubscriber))
        )
        XCTAssertEqual(
            affectedEvents.compactMap { event -> UInt64? in
                guard case .recognition(let recognition) = event,
                      case .transcript(.preview(let preview)) = recognition.kind else { return nil }
                return preview.revision
            },
            [latestRevision]
        )
        XCTAssertEqual(
            affectedEvents.compactMap { event -> RecognitionSessionState? in
                guard case .recognition(let recognition) = event,
                      case .stateChanged(let state) = recognition.kind else { return nil }
                return state
            },
            [.finalizing]
        )

        var healthyIterator = healthyStream.makeAsyncIterator()
        let receivedOverflowEvent = try await healthyIterator.next()
        XCTAssertEqual(receivedOverflowEvent, .speechQueue(firstUndelivered))

        let postOverflowEvent = VoiceEventStreamEvent.recovery(
            VoiceRecoveryEvent(eventOrdinal: 33, kind: .reconciling)
        )
        delivery.publish(postOverflowEvent)
        let receivedPostOverflowEvent = try await healthyIterator.next()
        XCTAssertEqual(receivedPostOverflowEvent, postOverflowEvent)
    }
}

private func canonicalPreview(
    sessionID: RecognitionSessionID,
    revision: UInt64
) -> VoiceEventStreamEvent {
    .recognition(RecognitionEvent(
        sessionID: sessionID,
        eventOrdinal: revision * 2,
        kind: .transcript(.preview(TranscriptPreview(
            sessionID: sessionID,
            revision: revision,
            text: "preview"
        )))
    ))
}

private func canonicalState(
    sessionID: RecognitionSessionID,
    revision: UInt64,
    state: RecognitionSessionState
) -> VoiceEventStreamEvent {
    .recognition(RecognitionEvent(
        sessionID: sessionID,
        eventOrdinal: revision * 2 + 1,
        kind: .stateChanged(state)
    ))
}
