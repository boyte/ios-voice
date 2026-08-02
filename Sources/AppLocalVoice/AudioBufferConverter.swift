import AVFAudio
import CoreMedia
import Foundation
import Speech

/// Converts microphone buffers into the format selected by SpeechAnalyzer.
/// This local adapter keeps AppLocalVoice buildable across SDKs where Apple's
/// documented AnalyzerInputConverter symbol is not exposed to SwiftPM targets.
final class LocalAnalyzerInputConverter {
    /// A frame is created and consumed on the provider actor. It deliberately
    /// stores scalar timing data rather than carrying AVAudioTime across an
    /// isolation boundary.
    final class CapturedAudioFrame {
        let buffer: AVAudioPCMBuffer
        let sampleTime: AVAudioFramePosition
        let sampleRate: Double
        let isSampleTimeValid: Bool

        init(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
            self.buffer = buffer
            self.sampleTime = time.sampleTime
            self.sampleRate = time.sampleRate
            self.isSampleTimeValid = time.isSampleTimeValid
        }

        init(
            buffer: AVAudioPCMBuffer,
            sampleTime: AVAudioFramePosition,
            sampleRate: Double,
            isSampleTimeValid: Bool = true
        ) {
            self.buffer = buffer
            self.sampleTime = sampleTime
            self.sampleRate = sampleRate
            self.isSampleTimeValid = isSampleTimeValid
        }
    }

    /// SAFETY: `AVAudioConverter.convert` invokes its input block synchronously.
    /// The actor-confined caller owns the buffer for that complete invocation,
    /// and neither this wrapper nor the block mutates it.
    private final class SendableBuffer: @unchecked Sendable {
        let value: AVAudioPCMBuffer
        init(_ value: AVAudioPCMBuffer) { self.value = value }
    }

    /// SAFETY: this state is created for one synchronous converter invocation
    /// and is touched only by that invocation's non-escaping input block.
    private final class ConversionState: @unchecked Sendable {
        var supplied = false
    }

    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormatDescription: String?
    private var didFlush = false
    private var lastSourceSampleEnd: AVAudioFramePosition?

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func convert(_ frame: CapturedAudioFrame) throws -> [AnalyzerInput] {
        let buffer = frame.buffer
        try validate(buffer: buffer)
        guard !didFlush else {
            throw VoiceError.invalidState("Audio conversion was requested after finalization.")
        }

        let timestampIsUsable = frame.isSampleTimeValid &&
            frame.sampleRate.isFinite && frame.sampleRate > 0 &&
            frame.sampleTime >= 0
        if timestampIsUsable {
            let (sampleEnd, overflowed) = frame.sampleTime.addingReportingOverflow(
                AVAudioFramePosition(buffer.frameLength)
            )
            guard !overflowed, sampleEnd >= frame.sampleTime else {
                throw VoiceError.audioSessionUnavailable("Microphone audio timestamp overflowed.")
            }
            if let lastSourceSampleEnd, frame.sampleTime < lastSourceSampleEnd {
                throw VoiceError.audioSessionUnavailable("Microphone audio timestamps moved backwards.")
            }
            lastSourceSampleEnd = sampleEnd
        }

        let converted: AVAudioPCMBuffer
        let didConvert: Bool
        if buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == targetFormat.channelCount,
           buffer.format.commonFormat == targetFormat.commonFormat,
           buffer.format.isInterleaved == targetFormat.isInterleaved {
            converted = buffer
            didConvert = false
        } else {
            let sourceDescription = "\(buffer.format.sampleRate):\(buffer.format.channelCount):\(buffer.format.commonFormat.rawValue):\(buffer.format.isInterleaved)"
            if converter == nil || sourceFormatDescription != sourceDescription {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
                sourceFormatDescription = sourceDescription
                didFlush = false
                lastSourceSampleEnd = nil
            }
            guard let converter else {
                throw VoiceError.audioSessionUnavailable("Unable to convert microphone audio.")
            }
            let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw VoiceError.audioSessionUnavailable("Unable to allocate converted microphone audio.")
            }
            let input = SendableBuffer(buffer)
            let state = ConversionState()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, status in
                if state.supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                state.supplied = true
                status.pointee = .haveData
                return input.value
            }
            if let conversionError { throw conversionError }
            guard status != .error, status != .endOfStream else {
                throw VoiceError.audioSessionUnavailable("Microphone audio conversion terminated unexpectedly.")
            }
            guard output.frameLength > 0 else {
                throw VoiceError.audioSessionUnavailable("Microphone audio conversion produced no samples.")
            }
            converted = output
            didConvert = true
        }

        // Apple warns that a source timestamp cannot in general be reused
        // after resampling/conversion because converter priming can shift the
        // first output sample. The analyzer receives a contiguous sequence,
        // so omit timestamps for converted blocks and let it use sequence
        // order. Preserve timestamps only for the no-op format path.
        let startTime: CMTime?
        if !didConvert, timestampIsUsable {
            startTime = CMTime(
                value: CMTimeValue(frame.sampleTime),
                timescale: CMTimeScale(frame.sampleRate.rounded())
            )
        } else {
            startTime = nil
        }
        return [AnalyzerInput(buffer: converted, bufferStartTime: startTime)]
    }

    func flush() throws -> [AnalyzerInput] {
        guard !didFlush else { return [] }
        guard let converter else {
            didFlush = true
            return []
        }

        var results: [AnalyzerInput] = []
        // A converter can have more than one output block of priming/tail
        // data. Bound the loop so a broken converter cannot trap finalization.
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else {
                throw VoiceError.audioSessionUnavailable("Unable to allocate final microphone audio.")
            }

            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if let conversionError { throw conversionError }
            guard status != .error else {
                throw VoiceError.audioSessionUnavailable("Final microphone audio conversion failed.")
            }
            if output.frameLength > 0 {
                results.append(AnalyzerInput(buffer: output, bufferStartTime: nil))
            }
            if status == .endOfStream || output.frameLength == 0 {
                break
            }
        }
        didFlush = true
        return results
    }

    private func validate(buffer: AVAudioPCMBuffer) throws {
        guard targetFormat.sampleRate.isFinite, targetFormat.sampleRate > 0,
              targetFormat.channelCount > 0,
              buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
              buffer.format.channelCount > 0 else {
            throw VoiceError.audioSessionUnavailable("Audio conversion received an invalid PCM format.")
        }
        guard buffer.frameLength > 0 else {
            throw VoiceError.audioSessionUnavailable("Audio conversion received an empty PCM buffer.")
        }
        guard buffer.frameLength <= buffer.frameCapacity else {
            throw VoiceError.audioSessionUnavailable("Audio conversion received an invalid PCM buffer length.")
        }
    }
}

/// A bounded, preallocated handoff for the legacy AVAudioEngine tap API.
///
/// The current iOS 26.5 Swift SDK in this package does not expose Apple's
/// newer `installAudioTap`/`AVReadOnlyAudioPCMBuffer` surface. The legacy tap
/// therefore copies the bytes into one of these owned slots immediately and
/// returns. Only the slot token and scalar timing cross into the provider
/// actor; a mutable AVAudioPCMBuffer never does. A single pump task drains the
/// ring off the realtime callback, so the callback creates no Task and no
/// per-frame Swift object.
/// SAFETY: the lock protects every slot-state transition and all shared ring
/// counters. A producer owns a `.writing` slot exclusively until publishing it
/// as `.ready`; a consumer owns a `.reading` slot until `Frame.release()`. Raw
/// storage is copied only inside those ownership windows and is never exposed.
final class AudioFrameRing: @unchecked Sendable {
    private static let maximumTotalStorageBytes = 16 * 1024 * 1024

    struct Frame: Sendable {
        fileprivate let ring: AudioFrameRing
        fileprivate let slotIndex: Int
        let sampleTime: AVAudioFramePosition
        let sampleRate: Double
        let isSampleTimeValid: Bool

        func makePCMBuffer() -> AVAudioPCMBuffer? {
            ring.makePCMBuffer(for: self)
        }

        func release() {
            ring.release(self)
        }
    }

    private enum SlotState {
        case free
        case writing
        case ready
        case reading
    }

    private final class Slot {
        let storage: UnsafeMutableRawPointer
        let storageByteCapacity: Int
        let byteSizes: UnsafeMutablePointer<UInt32>
        let bufferCount: Int
        var state: SlotState = .free
        var frameLength: AVAudioFrameCount = 0
        var sampleTime: AVAudioFramePosition = 0
        var sampleRate: Double = 0
        var isSampleTimeValid = false

        init(storageByteCapacity: Int, bufferCount: Int) {
            self.storageByteCapacity = storageByteCapacity
            self.bufferCount = bufferCount
            self.storage = .allocate(byteCount: storageByteCapacity, alignment: MemoryLayout<UInt64>.alignment)
            self.byteSizes = .allocate(capacity: bufferCount)
            self.byteSizes.initialize(repeating: 0, count: bufferCount)
        }

        deinit {
            storage.deallocate()
            byteSizes.deinitialize(count: bufferCount)
            byteSizes.deallocate()
        }
    }

    private let lock = NSLock()
    private let format: AVAudioFormat
    private let capacity: Int
    private let maxFrames: AVAudioFrameCount
    private let bufferCount: Int
    private let bytesPerSlot: Int
    private let slots: [Slot]

    private var writeIndex = 0
    private var readIndex = 0
    private var readyCount = 0
    private var reservedCount = 0
    private var accepting = true
    private var overflowed = false

    init(format: AVAudioFormat, capacity: Int = 32, maxFrames: AVAudioFrameCount = 8_192) throws {
        guard capacity > 1, maxFrames > 0,
              format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0,
              format.commonFormat != .otherFormat else {
            throw VoiceError.audioSessionUnavailable("Unable to create the microphone handoff ring.")
        }

        let description = format.streamDescription.pointee
        let channels = max(1, Int(description.mChannelsPerFrame))
        let bytesPerFrame = max(1, Int(description.mBytesPerFrame))
        let bufferCount = max(1, channels)
        // `mBytesPerFrame` already includes every channel for an interleaved
        // format; non-interleaved formats report the per-channel width.
        let channelMultiplier = format.isInterleaved ? 1 : channels
        let (frameBytes, frameOverflow) = Int(maxFrames).multipliedReportingOverflow(by: bytesPerFrame)
        let (bytesPerSlot, storageOverflow) = frameBytes.multipliedReportingOverflow(by: channelMultiplier)
        let (totalBytes, totalOverflow) = bytesPerSlot.multipliedReportingOverflow(by: capacity)
        guard !frameOverflow, !storageOverflow, !totalOverflow,
              bytesPerSlot > 0,
              totalBytes <= Self.maximumTotalStorageBytes else {
            throw VoiceError.audioSessionUnavailable("The microphone handoff ring format is too large.")
        }

        self.format = format
        self.capacity = capacity
        self.maxFrames = maxFrames
        self.bufferCount = bufferCount
        self.bytesPerSlot = bytesPerSlot
        self.slots = (0..<capacity).map { _ in
            Slot(storageByteCapacity: bytesPerSlot, bufferCount: bufferCount)
        }
    }

    /// Called synchronously by the legacy audio tap. It performs only a
    /// bounded slot reservation, byte copy, and state transition.
    @discardableResult
    func push(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) -> Bool {
        guard matchesExpectedFormat(buffer),
              buffer.frameLength > 0,
              buffer.frameLength <= maxFrames else {
            markOverflow()
            return false
        }
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        guard sourceBuffers.count <= bufferCount else {
            markOverflow()
            return false
        }

        let slotIndex: Int
        let slot: Slot
        lock.lock()
        guard accepting, reservedCount < capacity else {
            overflowed = true
            lock.unlock()
            return false
        }

        // A frame is normally released in FIFO order by the single pump, but
        // the ownership contract does not require a future consumer to do so.
        // Find an actually free slot instead of assuming writeIndex still
        // points at one; otherwise an out-of-order release could overwrite a
        // frame that is still being read.
        var probes = 0
        while probes < capacity, slots[writeIndex].state != .free {
            writeIndex = (writeIndex + 1) % capacity
            probes += 1
        }
        guard probes < capacity else {
            overflowed = true
            lock.unlock()
            return false
        }
        slotIndex = writeIndex
        writeIndex = (writeIndex + 1) % capacity
        slot = slots[slotIndex]
        slot.state = .writing
        reservedCount += 1
        lock.unlock()

        var offset = 0
        var copied = true
        for index in 0..<sourceBuffers.count {
            let source = sourceBuffers[index]
            let byteCount = Int(source.mDataByteSize)
            guard byteCount >= 0, byteCount <= bytesPerSlot - offset, let data = source.mData else {
                copied = false
                break
            }
            memcpy(slot.storage.advanced(by: offset), data, byteCount)
            slot.byteSizes[index] = UInt32(byteCount)
            offset += byteCount
        }
        if sourceBuffers.count < bufferCount {
            for index in sourceBuffers.count..<bufferCount {
                slot.byteSizes[index] = 0
            }
        }

        lock.lock()
        if copied {
            slot.frameLength = buffer.frameLength
            slot.sampleTime = time.sampleTime
            slot.sampleRate = time.sampleRate
            slot.isSampleTimeValid = time.isSampleTimeValid
            slot.state = .ready
            readyCount += 1
        } else {
            slot.state = .free
            reservedCount -= 1
            overflowed = true
        }
        lock.unlock()
        return copied
    }

    func pop() -> Frame? {
        lock.lock()
        guard readyCount > 0 else {
            lock.unlock()
            return nil
        }

        // Normally the next slot is ready. Scanning the bounded ring also
        // handles a consumer releasing frames out of order without treating a
        // later ready slot as permanently unavailable.
        var probes = 0
        while probes < capacity, slots[readIndex].state != .ready {
            readIndex = (readIndex + 1) % capacity
            probes += 1
        }
        guard probes < capacity else {
            lock.unlock()
            return nil
        }
        let slotIndex = readIndex
        readIndex = (readIndex + 1) % capacity
        let slot = slots[slotIndex]
        slot.state = .reading
        readyCount -= 1
            let frame = Frame(
                ring: self,
                slotIndex: slotIndex,
                sampleTime: slot.sampleTime,
                sampleRate: slot.sampleRate,
                isSampleTimeValid: slot.isSampleTimeValid
            )
        lock.unlock()
        return frame
    }

    func stopAccepting() {
        lock.lock()
        accepting = false
        lock.unlock()
    }

    var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting
    }

    var isDrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reservedCount == 0
    }

    var hasOverflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
    }

    private func markOverflow() {
        lock.lock()
        overflowed = true
        lock.unlock()
    }

    private func matchesExpectedFormat(_ buffer: AVAudioPCMBuffer) -> Bool {
        buffer.format.sampleRate == format.sampleRate &&
            buffer.format.channelCount == format.channelCount &&
            buffer.format.commonFormat == format.commonFormat &&
            buffer.format.isInterleaved == format.isInterleaved
    }

    private func makePCMBuffer(for frame: Frame) -> AVAudioPCMBuffer? {
        lock.lock()
        let slot = slots[frame.slotIndex]
        guard slot.state == .reading else {
            lock.unlock()
            return nil
        }
        let frameLength = slot.frameLength
        lock.unlock()

        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        output.frameLength = frameLength
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)

        // A caller normally releases a frame immediately after this method
        // returns, but keep the copy itself inside the reading ownership
        // window as well. This makes the Frame contract safe even if a host
        // accidentally calls `release()` from another task while a buffer is
        // being materialized: the slot cannot be reused until every byte has
        // been copied out.
        lock.lock()
        let slotStillOwned = slot.state == .reading
        guard slotStillOwned else {
            lock.unlock()
            return nil
        }
        var offset = 0
        for index in 0..<destinationBuffers.count {
            let byteCount = Int(slot.byteSizes[index])
            guard byteCount >= 0, byteCount <= bytesPerSlot - offset,
                  let data = destinationBuffers[index].mData else {
                lock.unlock()
                return nil
            }
            memcpy(data, slot.storage.advanced(by: offset), byteCount)
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
            offset += byteCount
        }
        lock.unlock()
        return output
    }

    private func release(_ frame: Frame) {
        lock.lock()
        let slot = slots[frame.slotIndex]
        guard slot.state == .reading else {
            lock.unlock()
            return
        }
        slot.state = .free
        reservedCount = max(0, reservedCount - 1)
        lock.unlock()
    }
}
