import AVFAudio
import CoreMedia
import XCTest
@testable import AppLocalVoice

final class AudioBufferConverterTests: XCTestCase {
    func testSameFormatPreservesBufferAndTimestamp() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try makeBuffer(format: format, frameCount: 4, values: [0.1, 0.2, 0.3, 0.4])
        let frame = LocalAnalyzerInputConverter.CapturedAudioFrame(
            buffer: buffer,
            time: AVAudioTime(sampleTime: 480, atRate: 16_000)
        )

        let output = try LocalAnalyzerInputConverter(targetFormat: format).convert(frame)

        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(output[0].buffer === buffer)
        XCTAssertEqual(output[0].buffer.frameLength, 4)
        XCTAssertEqual(output[0].bufferStartTime, CMTime(value: 480, timescale: 16_000))
    }

    func testSampleRateAndChannelConversionProducesTargetFormat() throws {
        let sourceFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 2))
        let targetFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try makeBuffer(format: sourceFormat, frameCount: 32, values: Array(repeating: 0.25, count: 32))
        let frame = LocalAnalyzerInputConverter.CapturedAudioFrame(
            buffer: buffer,
            time: AVAudioTime(sampleTime: 160, atRate: 8_000)
        )

        let output = try LocalAnalyzerInputConverter(targetFormat: targetFormat).convert(frame)

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].buffer.format.sampleRate, 16_000)
        XCTAssertEqual(output[0].buffer.format.channelCount, 1)
        XCTAssertGreaterThan(output[0].buffer.frameLength, 0)
        // Resampling/converter priming can shift the first output sample. The
        // input adapter intentionally omits the source timestamp on this
        // path and relies on contiguous analyzer sequence order.
        XCTAssertNil(output[0].bufferStartTime)
    }

    func testMultipleFramesPreserveInputOrderAndIndependentTimestamps() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = LocalAnalyzerInputConverter(targetFormat: format)
        let first = try makeBuffer(format: format, frameCount: 2, values: [0.1, 0.1])
        let second = try makeBuffer(format: format, frameCount: 2, values: [0.9, 0.9])

        let firstOutput = try converter.convert(.init(
            buffer: first,
            time: AVAudioTime(sampleTime: 0, atRate: 16_000)
        ))
        let secondOutput = try converter.convert(.init(
            buffer: second,
            time: AVAudioTime(sampleTime: 2, atRate: 16_000)
        ))

        XCTAssertEqual(firstOutput.count, 1)
        XCTAssertEqual(secondOutput.count, 1)
        let firstChannels = try XCTUnwrap(firstOutput[0].buffer.floatChannelData)
        let secondChannels = try XCTUnwrap(secondOutput[0].buffer.floatChannelData)
        XCTAssertEqual(firstChannels[0][0], 0.1, accuracy: 0.0001)
        XCTAssertEqual(secondChannels[0][0], 0.9, accuracy: 0.0001)
        XCTAssertEqual(firstOutput[0].bufferStartTime, CMTime(value: 0, timescale: 16_000))
        XCTAssertEqual(secondOutput[0].bufferStartTime, CMTime(value: 2, timescale: 16_000))
    }

    func testFlushEmitsTailAtMostOnceAndNoInputIsSafe() throws {
        let sourceFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let targetFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = LocalAnalyzerInputConverter(targetFormat: targetFormat)
        let buffer = try makeBuffer(format: sourceFormat, frameCount: 257, values: Array(repeating: 0.5, count: 257))

        _ = try converter.convert(.init(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 44_100)))
        let firstFlush = try converter.flush()
        let secondFlush = try converter.flush()

        XCTAssertTrue(firstFlush.allSatisfy { $0.buffer.frameLength > 0 })
        XCTAssertEqual(secondFlush.count, 0)
        XCTAssertThrowsError(try converter.convert(.init(
            buffer: buffer,
            time: AVAudioTime(sampleTime: 257, atRate: 44_100)
        ))) { error in
            guard case VoiceError.invalidState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFlushWithoutConversionReturnsEmpty() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = LocalAnalyzerInputConverter(targetFormat: format)

        XCTAssertTrue(try converter.flush().isEmpty)
        XCTAssertTrue(try converter.flush().isEmpty)
        let buffer = try makeBuffer(format: format, frameCount: 1, values: [0.1])
        XCTAssertThrowsError(try converter.convert(.init(
            buffer: buffer,
            time: AVAudioTime(sampleTime: 0, atRate: 16_000)
        ))) { error in
            guard case VoiceError.invalidState = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testEmptyBufferIsRejectedInsteadOfForwarded() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        let frame = LocalAnalyzerInputConverter.CapturedAudioFrame(
            buffer: empty,
            time: AVAudioTime(sampleTime: 0, atRate: 16_000)
        )

        XCTAssertThrowsError(try LocalAnalyzerInputConverter(targetFormat: format).convert(frame)) { error in
            guard case VoiceError.audioSessionUnavailable(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("empty"))
        }
    }

    func testInvalidFormatsAreRejectedAtConverterBoundary() throws {
        let validSource = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let sourceBuffer = try makeBuffer(format: validSource, frameCount: 1, values: [0.25])
        let invalidTargets = [
            try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)),
            try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 0)),
            try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 0, interleaved: false))
        ]

        for target in invalidTargets {
            XCTAssertThrowsError(try LocalAnalyzerInputConverter(targetFormat: target).convert(.init(
                buffer: sourceBuffer,
                time: AVAudioTime(sampleTime: 0, atRate: 16_000)
            ))) { error in
                guard case VoiceError.audioSessionUnavailable(let message) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertTrue(message.contains("invalid PCM format"))
            }
        }
    }

    func testNegativeSampleTimeProducesNoAnalyzerTimestamp() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try makeBuffer(format: format, frameCount: 1, values: [0.25])
        let frame = LocalAnalyzerInputConverter.CapturedAudioFrame(
            buffer: buffer,
            time: AVAudioTime(sampleTime: -1, atRate: 16_000)
        )

        let output = try LocalAnalyzerInputConverter(targetFormat: format).convert(frame)

        XCTAssertNil(output[0].bufferStartTime)
    }

    func testExplicitlyInvalidSampleTimeProducesNoAnalyzerTimestamp() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try makeBuffer(format: format, frameCount: 1, values: [0.25])
        let frame = LocalAnalyzerInputConverter.CapturedAudioFrame(
            buffer: buffer,
            sampleTime: 10,
            sampleRate: 16_000,
            isSampleTimeValid: false
        )

        let output = try LocalAnalyzerInputConverter(targetFormat: format).convert(frame)

        XCTAssertNil(output[0].bufferStartTime)
    }

    func testBackwardsSampleTimesFailClosedBeforeTheyReachTheAnalyzer() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = LocalAnalyzerInputConverter(targetFormat: format)
        let buffer = try makeBuffer(format: format, frameCount: 4, values: [0.25])

        _ = try converter.convert(.init(
            buffer: buffer,
            sampleTime: 10,
            sampleRate: 16_000
        ))

        XCTAssertThrowsError(try converter.convert(.init(
            buffer: buffer,
            sampleTime: 12,
            sampleRate: 16_000
        ))) { error in
            guard case VoiceError.audioSessionUnavailable(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("timestamps moved backwards"))
        }
    }

    private func makeBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount, values: [Float]) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channels = Int(format.channelCount)
        for channel in 0..<channels {
            guard let samples = buffer.floatChannelData?[channel] else {
                throw XCTSkip("The test helper requires float PCM buffers; this format is not float PCM.")
            }
            for index in 0..<Int(frameCount) {
                samples[index] = values[index % values.count]
            }
        }
        return buffer
    }
}
