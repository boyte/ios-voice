import AVFAudio
import UIKit
import XCTest
@testable import AppLocalVoice

final class AudioEngineSafetyTests: XCTestCase {
    func testSafetySeamPreservesTapPrepareStartRemoveOrder() {
        let safety = RecordingAudioEngineSafety()
        let engine = AVAudioEngine()
        let node = engine.inputNode

        XCTAssertTrue(safety.installTap(on: node, bus: 0, bufferSize: 256, format: nil) { _, _ in })
        XCTAssertTrue(safety.prepare(engine))
        XCTAssertTrue(safety.start(engine))
        XCTAssertTrue(safety.removeTap(on: node, bus: 0))

        XCTAssertEqual(safety.operations, [.installTap, .prepare, .start, .removeTap])
    }

    func testSafetySeamFailsClosedAtEachOperationWithoutChangingLaterCalls() {
        let safety = RecordingAudioEngineSafety()
        let engine = AVAudioEngine()
        let node = engine.inputNode

        safety.failures = [.installTap, .prepare, .start, .removeTap, .outputFormat]

        XCTAssertFalse(safety.installTap(on: node, bus: 0, bufferSize: 256, format: nil) { _, _ in })
        XCTAssertFalse(safety.prepare(engine))
        XCTAssertFalse(safety.start(engine))
        XCTAssertFalse(safety.removeTap(on: node, bus: 0))
        XCTAssertNil(safety.outputFormat(on: node, bus: 0))
        XCTAssertEqual(safety.operations, [.installTap, .prepare, .start, .removeTap, .outputFormat])
    }

    func testInterruptionMappingOnlyMapsBeginning() {
        let began = Notification(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        let ended = Notification(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )

        XCTAssertEqual(audioNotificationAction(for: began), .interruptionBegan)
        XCTAssertNil(audioNotificationAction(for: ended))
    }

    func testApplicationBackgroundMappingIsTerminal() {
        XCTAssertEqual(
            audioNotificationAction(for: Notification(name: UIApplication.didEnterBackgroundNotification)),
            .applicationBackgrounded
        )
    }

    func testRouteChangesClassifyLossSeparatelyFromSelfInducedNotifications() {
        for reason: AVAudioSession.RouteChangeReason in [
            .oldDeviceUnavailable,
            .noSuitableRouteForCategory
        ] {
            let notification = Notification(
                name: AVAudioSession.routeChangeNotification,
                object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
            )
            XCTAssertEqual(audioNotificationAction(for: notification), .routeChanged)
        }

        for reason in [
            AVAudioSession.RouteChangeReason.newDeviceAvailable,
            AVAudioSession.RouteChangeReason.categoryChange,
            .override,
            .wakeFromSleep
        ] {
            let notification = Notification(
                name: AVAudioSession.routeChangeNotification,
                object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
            )
            XCTAssertNil(audioNotificationAction(for: notification))
        }

        let configurationChange = Notification(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue
            ]
        )
        XCTAssertEqual(audioNotificationAction(for: configurationChange), .routeChanged)
        XCTAssertNil(audioNotificationAction(for: configurationChange, consumer: .output))
    }

    func testMalformedHardwareFormatsFailClosed() throws {
        let valid = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        XCTAssertNoThrow(try validateHardwareAudioFormat(valid))

        guard let tooManyChannels = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 9) else {
            throw XCTSkip("This simulator SDK cannot construct a nine-channel standard format.")
        }
        XCTAssertThrowsError(try validateHardwareAudioFormat(tooManyChannels))

        guard let otherFormat = AVAudioFormat(
            commonFormat: .otherFormat,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw XCTSkip("This simulator SDK cannot construct AVAudioFormat.otherFormat.")
        }
        XCTAssertThrowsError(try validateHardwareAudioFormat(otherFormat))
    }

    func testRingCopiesOwnedAudioAndReleasesItsSlot() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let ring = try AudioFrameRing(format: format, capacity: 2, maxFrames: 8)
        let source = makeRingBuffer(format: format, frameLength: 4, value: 0.25)

        XCTAssertTrue(ring.push(source, time: AVAudioTime(sampleTime: 7, atRate: format.sampleRate)))
        let frame = try XCTUnwrap(ring.pop())
        let copy = try XCTUnwrap(frame.makePCMBuffer())
        XCTAssertEqual(copy.frameLength, 4)
        let firstSample = try XCTUnwrap(copy.floatChannelData?[0][0])
        XCTAssertEqual(firstSample, 0.25, accuracy: 0.0001)

        frame.release()
        XCTAssertNil(frame.makePCMBuffer())
        XCTAssertTrue(ring.isDrained)
    }

    func testRingFindsFreeSlotsAndReadyFramesAfterOutOfOrderRelease() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let ring = try AudioFrameRing(format: format, capacity: 3, maxFrames: 8)

        for sampleTime in 0..<3 {
            let source = makeRingBuffer(format: format, frameLength: 4, value: Float(sampleTime))
            XCTAssertTrue(ring.push(source, time: AVAudioTime(sampleTime: AVAudioFramePosition(sampleTime), atRate: format.sampleRate)))
        }

        let first = try XCTUnwrap(ring.pop())
        let second = try XCTUnwrap(ring.pop())
        // Leave the first frame owned while releasing the second. The next
        // write must skip the still-reading slot instead of overwriting it.
        second.release()

        let replacement = makeRingBuffer(format: format, frameLength: 4, value: 3)
        XCTAssertTrue(ring.push(replacement, time: AVAudioTime(sampleTime: 3, atRate: format.sampleRate)))

        let third = try XCTUnwrap(ring.pop())
        XCTAssertEqual(third.sampleTime, 2)
        third.release()
        let replacementFrame = try XCTUnwrap(ring.pop())
        XCTAssertEqual(replacementFrame.sampleTime, 3)
        replacementFrame.release()
        first.release()

        XCTAssertTrue(ring.isDrained)
    }

    func testRingFailsClosedWhenCapacityIsExhausted() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        XCTAssertThrowsError(try AudioFrameRing(format: format, capacity: 32, maxFrames: 5_000_000))
        let ring = try AudioFrameRing(format: format, capacity: 2, maxFrames: 8)
        let first = makeRingBuffer(format: format, frameLength: 4, value: 1)
        let second = makeRingBuffer(format: format, frameLength: 4, value: 2)
        let overflow = makeRingBuffer(format: format, frameLength: 4, value: 3)

        XCTAssertTrue(ring.push(first, time: AVAudioTime(sampleTime: 0, atRate: format.sampleRate)))
        XCTAssertTrue(ring.push(second, time: AVAudioTime(sampleTime: 4, atRate: format.sampleRate)))
        XCTAssertFalse(ring.push(overflow, time: AVAudioTime(sampleTime: 8, atRate: format.sampleRate)))
        XCTAssertTrue(ring.hasOverflowed)

        let firstFrame = try XCTUnwrap(ring.pop())
        let secondFrame = try XCTUnwrap(ring.pop())
        firstFrame.release()
        secondFrame.release()
        XCTAssertTrue(ring.isDrained)
    }
}

private func makeRingBuffer(
    format: AVAudioFormat,
    frameLength: AVAudioFrameCount,
    value: Float
) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)!
    buffer.frameLength = frameLength
    if let channels = buffer.floatChannelData {
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frameLength) {
                channels[channel][frame] = value
            }
        }
    }
    return buffer
}

private final class RecordingAudioEngineSafety: AudioEngineSafety {
    enum Operation: Hashable {
        case installTap
        case prepare
        case start
        case removeTap
        case outputFormat
    }

    var operations: [Operation] = []
    var failures: Set<Operation> = []

    func installTap(on node: AVAudioInputNode, bus: AVAudioNodeBus,
                    bufferSize: AVAudioFrameCount, format: AVAudioFormat?,
                    block: @escaping AVAudioNodeTapBlock) -> Bool {
        operations.append(.installTap)
        return !failures.contains(.installTap)
    }

    func prepare(_ engine: AVAudioEngine) -> Bool {
        operations.append(.prepare)
        return !failures.contains(.prepare)
    }

    func start(_ engine: AVAudioEngine) -> Bool {
        operations.append(.start)
        return !failures.contains(.start)
    }

    func removeTap(on node: AVAudioInputNode, bus: AVAudioNodeBus) -> Bool {
        operations.append(.removeTap)
        return !failures.contains(.removeTap)
    }

    func outputFormat(on node: AVAudioInputNode, bus: AVAudioNodeBus) -> AVAudioFormat? {
        operations.append(.outputFormat)
        if failures.contains(.outputFormat) { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
    }
}
