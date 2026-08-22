import AVFAudio
import CoreMedia
import Foundation
import Speech
import UIKit
import AppLocalVoiceAudioEngineSafe

// Provider seams and support types for `AppleSpeechInput`: transcript
// mapping, engine-safety and notification-center boundaries, analyzer driver,
// model preparation runtime, and the one-shot gates they use.

/// Converts Apple's attributed SpeechTranscriber result into the internal
/// provider-neutral transcript model. Apple Speech types do not cross this
/// seam into the assembler.
struct AppleSpeechTranscriptMapper {
    static func map(_ result: SpeechTranscriber.Result) -> TranscriptAssemblerResult {
        map(text: result.text, range: result.range, isFinal: result.isFinal)
    }

    static func map(
        text: AttributedString,
        range: CMTimeRange,
        isFinal: Bool
    ) -> TranscriptAssemblerResult {
        let segments = text.runs.map { run in
            TranscriptTextSegment(
                text: String(text[run.range].characters),
                timeRange: run.attributes[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
            )
        }
        return TranscriptAssemblerResult(range: range, segments: Array(segments), isFinal: isFinal)
    }
}

/// Internal seam around the Objective-C exception barrier. The production
/// adapter calls the real barrier; tests can verify operation ordering without
/// pretending to emulate Apple audio hardware.
protocol AudioEngineSafety: AnyObject {
    func installTap(on node: AVAudioInputNode, bus: AVAudioNodeBus,
                    bufferSize: AVAudioFrameCount, format: AVAudioFormat?,
                    block: @escaping AVAudioNodeTapBlock) -> Bool
    func prepare(_ engine: AVAudioEngine) -> Bool
    func start(_ engine: AVAudioEngine) -> Bool
    func removeTap(on node: AVAudioInputNode, bus: AVAudioNodeBus) -> Bool
    func outputFormat(on node: AVAudioInputNode, bus: AVAudioNodeBus) -> AVAudioFormat?
}

/// Maintains tap ownership conservatively across the Objective-C exception
/// barrier. A failed removal is not proof that AVAudioEngine removed the tap;
/// ownership therefore remains set so a later cleanup attempt can retry.
@inline(__always)
func removeTapOwnership(isInstalled: inout Bool, remove: () -> Bool) -> Bool {
    guard isInstalled else { return true }
    guard remove() else { return false }
    isInstalled = false
    return true
}

protocol AudioNotificationCenter: AnyObject, Sendable {
    func addObserver(forName name: Notification.Name?, object obj: Any?,
                     queue: OperationQueue?, using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol
    func removeObserver(_ observer: Any)
}

final class DefaultAudioNotificationCenter: AudioNotificationCenter {
    private let center: NotificationCenter

    init(center: NotificationCenter = .default) { self.center = center }

    func addObserver(forName name: Notification.Name?, object obj: Any?,
                     queue: OperationQueue?, using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        center.addObserver(forName: name, object: obj, queue: queue, using: block)
    }

    func removeObserver(_ observer: Any) { center.removeObserver(observer) }
}

typealias AnalyzerInput = Speech.AnalyzerInput

protocol SpeechAnalyzerDriver: AnyObject, Sendable {
    func analyzeSequence(_ sequence: AsyncStream<AnalyzerInput>) async throws -> CMTime?
    func finalizeAndFinish(through sample: CMTime) async throws
    func finalizeAndFinishThroughEndOfInput() async throws
    func cancelAndFinishNow() async
}

final class DefaultSpeechAnalyzerDriver: SpeechAnalyzerDriver {
    private let analyzer: SpeechAnalyzer

    init(_ analyzer: SpeechAnalyzer) { self.analyzer = analyzer }

    func analyzeSequence(_ sequence: AsyncStream<AnalyzerInput>) async throws -> CMTime? {
        try await analyzer.analyzeSequence(sequence)
    }

    func finalizeAndFinish(through sample: CMTime) async throws {
        try await analyzer.finalizeAndFinish(through: sample)
    }

    func finalizeAndFinishThroughEndOfInput() async throws {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    func cancelAndFinishNow() async { await analyzer.cancelAndFinishNow() }
}

/// Finalizes an orderly end-of-input for both sampled and empty captures.
/// `cancelAndFinishNow()` is the abort path; using it for a valid empty PTT
/// turn can leave `SpeechTranscriber.results` open on a physical device.
func finalizeAnalyzerInput(
    lastSample: CMTime?,
    analyzer: any SpeechAnalyzerDriver
) async throws {
    if let lastSample {
        try await analyzer.finalizeAndFinish(through: lastSample)
    } else {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }
}

enum SpeechAnalysisWorkerResult: Sendable {
    case resultsFinished
    case analyzerFinished(hasInput: Bool)
}

func runSpeechAnalysisWorkers(
    consumeResults: @escaping @Sendable () async throws -> Void,
    analyzeAndFinalize: @escaping @Sendable () async throws -> CMTime?
) async throws {
    try await withThrowingTaskGroup(of: SpeechAnalysisWorkerResult.self) { group in
        group.addTask {
            try await consumeResults()
            return .resultsFinished
        }
        group.addTask {
            let lastSample = try await analyzeAndFinalize()
            return .analyzerFinished(hasInput: lastSample != nil)
        }

        var resultsFinished = false
        var sampledAnalyzerFinished = false
        while let result = try await group.next() {
            switch result {
            case .resultsFinished:
                resultsFinished = true
            case .analyzerFinished(hasInput: false):
                // Apple's analyzer can finish a zero-buffer sequence without
                // closing `SpeechTranscriber.results`. Cancel here, while the
                // consumer is still a structured child, so leaving this scope
                // joins it before an empty turn is reported as successful.
                group.cancelAll()
                return
            case .analyzerFinished(hasInput: true):
                sampledAnalyzerFinished = true
            }

            if resultsFinished && sampledAnalyzerFinished { return }
        }
    }
}

final class DefaultAudioEngineSafety: AudioEngineSafety {
    func installTap(on node: AVAudioInputNode, bus: AVAudioNodeBus,
                    bufferSize: AVAudioFrameCount, format: AVAudioFormat?,
                    block: @escaping AVAudioNodeTapBlock) -> Bool {
        AppLocalVoiceAudioEngineSafe.installTap(on: node, bus: UInt(bus),
                                                bufferSize: bufferSize,
                                                format: format, block: block)
    }

    func prepare(_ engine: AVAudioEngine) -> Bool {
        AppLocalVoiceAudioEngineSafe.prepare(engine)
    }

    func start(_ engine: AVAudioEngine) -> Bool {
        AppLocalVoiceAudioEngineSafe.start(engine)
    }

    func removeTap(on node: AVAudioInputNode, bus: AVAudioNodeBus) -> Bool {
        AppLocalVoiceAudioEngineSafe.removeTap(on: node, bus: UInt(bus))
    }

    func outputFormat(on node: AVAudioInputNode, bus: AVAudioNodeBus) -> AVAudioFormat? {
        AppLocalVoiceAudioEngineSafe.outputFormat(for: node, bus: UInt(bus))
    }
}

enum AudioNotificationAction: Equatable {
    case interruptionBegan
    case routeChanged
    case applicationBackgrounded
    case mediaServicesInvalidated
}

enum AudioNotificationConsumer {
    case input
    case output
}

/// Maps documented AVAudioSession notification payloads. The system's actual
/// route/interruption behavior remains a physical-device concern.
func audioNotificationAction(
    for notification: Notification,
    consumer: AudioNotificationConsumer = .input
) -> AudioNotificationAction? {
    if notification.name == UIApplication.didEnterBackgroundNotification {
        return .applicationBackgrounded
    }
    if notification.name == AVAudioSession.mediaServicesWereLostNotification ||
        notification.name == AVAudioSession.mediaServicesWereResetNotification {
        return .mediaServicesInvalidated
    }
    if notification.name == AVAudioSession.interruptionNotification {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return nil }
        return .interruptionBegan
    }
    guard notification.name == AVAudioSession.routeChangeNotification,
          let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return nil }
    // Discovery, category, override, and wake notifications are commonly
    // emitted by our own session setup or while a route is settling. They do
    // not prove that an active input tap is invalid. A configuration change is
    // different: it can preserve the scalar format while replacing the
    // physical input port, so the active generation must end conservatively.
    switch reason {
    case .oldDeviceUnavailable, .noSuitableRouteForCategory:
        return .routeChanged
    case .newDeviceAvailable, .categoryChange, .override, .wakeFromSleep:
        return nil
    case .routeConfigurationChange:
        // An active input tap is tied to the physical port configuration and
        // must be rebuilt. Output is owned by AVSpeechSynthesizer, which can
        // follow a settling route (for example, between two connected
        // Bluetooth outputs); treating that notification as terminal can stop
        // a just-started utterance before its first audible frame.
        return consumer == .input ? .routeChanged : nil
    case .unknown:
        return .routeChanged
    @unknown default:
        return .routeChanged
    }
}

func validateHardwareAudioFormat(_ format: AVAudioFormat) throws {
    guard format.sampleRate.isFinite, format.sampleRate > 0,
          format.channelCount > 0, format.channelCount <= 8,
          format.commonFormat != .otherFormat else {
        throw VoiceError.audioSessionUnavailable("The microphone returned an unsupported audio format.")
    }
}

/// The exact module configuration used for live microphone recognition.
///
/// AssetInventory evaluates a module's full configuration, not just its
/// locale. Capability queries, preparation, and capture must therefore build
/// the same module or they can disagree about whether its assets are ready.
func liveRecognitionTranscriberPreset() -> SpeechTranscriber.Preset {
    var preset = SpeechTranscriber.Preset.progressiveTranscription
    preset.attributeOptions.insert(.audioTimeRange)
    return preset
}

func makeLiveRecognitionTranscriber(locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(locale: locale, preset: liveRecognitionTranscriberPreset())
}

@inline(__always)
func recognitionModuleIsInstalled(_ status: AssetInventory.Status) -> Bool {
    // `installedLocales` is a broad transcriber catalog. Only the status for
    // this exact configured module proves that the assets it will use are
    // installed and ready.
    status == .installed
}

enum RecognitionModelAssetStatus: Sendable, Equatable {
    case unsupported
    case supported
    case downloading
    case installed
}

func recognitionModelAssetStatus(from status: AssetInventory.Status) -> RecognitionModelAssetStatus {
    switch status {
    case .unsupported: .unsupported
    case .supported: .supported
    case .downloading: .downloading
    case .installed: .installed
    @unknown default: .unsupported
    }
}

func modelDownloadProgress(from progress: Progress) -> RecognitionModelDownloadProgress {
    guard progress.totalUnitCount > 0 else { return .indeterminate }
    let fraction = progress.fractionCompleted
    guard fraction.isFinite else { return .indeterminate }
    return .fractionCompleted(min(max(fraction, 0), 1))
}

/// Type-erased ownership of one provider reservation. Keeping this internal
/// lets lifecycle tests exercise the real preparation paths without attempting
/// to construct Apple's concrete `AssetInstallationRequest`.
struct RecognitionAssetInstallationRequest: Sendable {
    let downloadProgress: @Sendable () -> RecognitionModelDownloadProgress
    let downloadAndInstall: @Sendable () async throws -> Void
}

/// Internal boundary around the static Speech/AssetInventory calls used while
/// preparing the exact live transcriber module. Production always uses `live`;
/// tests can deterministically drive provider errors and cancellation races.
struct RecognitionPreparationRuntime: Sendable {
    let requestMicrophonePermission: @Sendable () async -> Bool
    let supportedLocale: @Sendable (Locale) async -> Locale?
    let transcriberIsAvailable: @Sendable () -> Bool
    let assetStatus: @Sendable (SpeechTranscriber) async -> RecognitionModelAssetStatus
    let assetInstallationRequest: @Sendable (SpeechTranscriber) async throws -> RecognitionAssetInstallationRequest?
    let releaseReservation: @Sendable (Locale) async -> Void

    static let live = RecognitionPreparationRuntime(
        requestMicrophonePermission: {
            await AVAudioApplication.requestRecordPermission()
        },
        supportedLocale: { locale in
            await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        },
        transcriberIsAvailable: {
            SpeechTranscriber.isAvailable
        },
        assetStatus: { transcriber in
            recognitionModelAssetStatus(
                from: await AssetInventory.status(forModules: [transcriber])
            )
        },
        assetInstallationRequest: { transcriber in
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) else { return nil }
            return RecognitionAssetInstallationRequest(
                downloadProgress: {
                    modelDownloadProgress(from: request.progress)
                },
                downloadAndInstall: {
                    try await request.downloadAndInstall()
                }
            )
        },
        releaseReservation: { locale in
            _ = await AssetInventory.release(reservedLocale: locale)
        }
    )
}

func recognitionModelInstallationFailure(
    locale: Locale,
    underlying error: Error
) -> VoiceError {
    let providerError = error as NSError
    return .recognitionModelInstallationFailed(
        locale,
        providerError: VoiceProviderErrorCode(
            domain: providerError.domain,
            code: providerError.code
        )
    )
}

/// Transfers a reserved asset request to its download worker without a
/// cancellation gap. Before `start` begins, this scope still owns release;
/// after it begins, the worker decides retention from the installation-result
/// gate's atomic winner.
func handOffReservedAssetRequest(
    release: @escaping @Sendable () async -> Void,
    start: @escaping @Sendable () async throws -> Void
) async throws {
    do {
        try Task.checkCancellation()
    } catch {
        await release()
        throw error
    }
    try await start()
}

/// A locale reservation is the app's subscription to its speech assets, not a
/// temporary download lock. The provider result atomically winning the gate
/// means the request was accepted and the reservation must remain subscribed,
/// even if the provider's initial attempt failed. If caller cancellation won
/// first, the late provider result has no owner and must release its reservation.
func releaseModelReservationIfResultDidNotPublish(
    _ didPublish: Bool,
    release: @escaping @Sendable () async -> Void
) async {
    guard !didPublish else { return }
    await release()
}

/// SAFETY: `lock` protects the one-shot result and waiter. The continuation is
/// removed while locked and resumed only after unlocking.
final class ModelInstallationResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Result<Void, Error>, Never>?

    func wait() async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
        return true
    }
}

func awaitRecognitionModelInstalled(
    locale: Locale,
    pollInterval: Duration,
    status: @escaping @Sendable () async throws -> RecognitionModelAssetStatus,
    downloadProgress: @escaping @Sendable () -> RecognitionModelDownloadProgress,
    progress: RecognitionPreparationProgressHandler?
) async throws {
    while true {
        try Task.checkCancellation()
        switch try await status() {
        case .installed:
            await progress?(.modelInstalled)
            return
        case .downloading:
            await progress?(.downloadingModel(downloadProgress()))
            try await Task.sleep(for: pollInterval)
        case .supported:
            // `downloadAndInstall()` and Progress reaching 100% do not prove
            // that AssetInventory has published `.installed`. On device the
            // framework can remain `.supported` well beyond 30 seconds while
            // finalizing the system asset. Keep the preparation cancellable
            // and honest instead of manufacturing a terminal install failure.
            await progress?(.downloadingModel(downloadProgress()))
            try await Task.sleep(for: pollInterval)
        case .unsupported:
            throw VoiceError.onDeviceRecognitionUnavailable(locale)
        }
    }
}
