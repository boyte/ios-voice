import Foundation
import Observation
import AppLocalVoice

@MainActor
@Observable
final class LocalEchoModel {
    var transcript = ""
    var status = "Ready"
    var modelStatus = "Checking on-device speech availability…"
    var error: String?
    var voiceTip: String?
    var isListening = false
    var isPreparing = false
    var isFinalizing = false
    var isSpeaking = false
    var isPaused = false

    private let voice: AppLocalVoice
    private var activeSessionID: RecognitionSessionID?

    init(voice: AppLocalVoice) {
        self.voice = voice
    }

    /// Only the app-owned model retires the shared voice service.
    func close() async {
        if case .blocked = await voice.close() {
            error = "Voice cleanup is still pending. Try again before starting another turn."
        }
    }

    func observeEvents() async {
        let events = await voice.voiceEvents()
        await refreshReadiness()
        do {
            for try await event in events {
                try Task.checkCancellation()
                apply(event)
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            await reconcile()
        }
    }

    private func apply(_ event: VoiceEventStreamEvent) {
        switch event {
        case .snapshot(let snapshot):
            apply(snapshot)
        case .recognition(let event):
            guard event.sessionID == activeSessionID else { return }
            switch event.kind {
            case .stateChanged(let state):
                isPreparing = state == .preparing
                isListening = state == .listening
                isFinalizing = state == .finalizing
                status = state.label
            case .transcript(.preview(let preview)):
                transcript = preview.text
            case .transcript(.finalTranscript(let final)):
                transcript = final.text
            case .outcome(.completed), .outcome(.durationLimitReached), .outcome(.cancelled),
                 .outcome(.interrupted), .outcome(.failed):
                activeSessionID = nil
                isPreparing = false
                isListening = false
                isFinalizing = false
                status = "Ready"
            default:
                break
            }
        case .speechQueue(let event):
            switch event.kind {
            case .started, .resumed:
                isSpeaking = true
                isPaused = false
                status = "Speaking…"
            case .paused:
                isPaused = true
            case .outcome:
                isSpeaking = false
                isPaused = false
                status = "Ready"
            case .accepted:
                break
            }
        case .speechProgress, .recovery:
            break
        }
    }

    private func apply(_ snapshot: VoiceRuntimeSnapshot) {
        switch snapshot.state {
        case .idle: status = "Ready"
        case .preparing: status = "Preparing…"
        case .listening: status = "Listening…"
        case .finalizing: status = "Finalizing…"
        case .speaking: status = "Speaking…"
        case .failed: status = "Voice unavailable"
        }
        isPreparing = snapshot.state == .preparing
        isListening = snapshot.state == .listening
        isFinalizing = snapshot.state == .finalizing
        isSpeaking = snapshot.state == .speaking
        activeSessionID = snapshot.recognition?.sessionID
    }

    private func reconcile() async {
        apply(await voice.runtimeSnapshot())
    }

    private func refreshReadiness() async {
        let readiness = await voice.capabilitySnapshot()
        switch readiness.recognition.modelReadiness {
        case .installed:
            modelStatus = "On-device speech model ready."
        case .notInstalled(let installationAvailable):
            modelStatus = installationAvailable
                ? "On-device model will be installed when you choose Listen."
                : "On-device speech model is not installed."
        case .unavailable, .unknown:
            modelStatus = "On-device speech is unavailable for this locale."
        }
        let voices = await voice.availableVoices()
        if voices.isEmpty {
            voiceTip = "No Apple voices are currently available for this locale."
        }
    }

    func startRecognition() async {
        error = nil
        do {
            let session = try await voice.startSession(configuration: .init(
                recognition: .init(policy: .allowModelInstallation)
            ))
            activeSessionID = session.sessionID
        } catch {
            self.error = error.localizedDescription
        }
    }

    func finishRecognition() async {
        guard let activeSessionID else { return }
        error = nil
        do {
            transcript = try await voice.finishSession(id: activeSessionID).text
            self.activeSessionID = nil
            status = "Ready to speak"
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancelRecognition() async {
        guard let activeSessionID else { return }
        await voice.cancelSession(id: activeSessionID)
        self.activeSessionID = nil
        status = "Ready"
    }

    func speakTranscript() async {
        error = nil
        do {
            let acceptance = try await voice.enqueueSpeech(transcript)
            _ = try await voice.waitForSpeechPlayback(id: acceptance.playbackID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func pauseQueue() async { _ = await voice.pauseSpeechQueue() }
    func resumeQueue() async { _ = await voice.resumeSpeechQueue() }
    func stopQueue() async { _ = await voice.stopSpeechQueue() }
}

private extension RecognitionSessionState {
    var label: String {
        switch self {
        case .preparing: "Preparing…"
        case .listening: "Listening…"
        case .finalizing: "Finalizing…"
        }
    }
}
