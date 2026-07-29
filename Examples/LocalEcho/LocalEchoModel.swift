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

    init(voice: AppLocalVoice) {
        self.voice = voice
    }

    /// Retires the app-owned voice service at an explicit app lifecycle
    /// boundary. Views and child feature models must not call this.
    func close() async {
        if case .blocked = await voice.close() {
            error = "Voice cleanup is still pending. Try again before starting another turn."
        }
    }

    func observeEvents() async {
        await withTaskCancellationHandler(operation: {
            // Register before any capability/catalog lookup so the first
            // lifecycle event cannot be lost while the UI is appearing.
            let events = await voice.events()
            await refreshModelStatus()
            let voices = await voice.availableVoices()
            if voices.isEmpty {
                voiceTip = "No Apple voices are currently available for this locale. Check Settings → Accessibility → Read & Speak → Voices."
            } else if !voices.contains(where: { $0.quality == .enhanced || $0.quality == .premium }) {
                voiceTip = "For a more natural voice, install an Enhanced or Premium Quality voice in Settings → Accessibility → Read & Speak → Voices."
            }
            for await event in events {
                switch event {
                case .stateChanged(let state):
                    status = state.label
                    isListening = state == .listening
                    isPreparing = state == .preparing
                    isFinalizing = state == .finalizing
                    isSpeaking = state == .speaking
                    if state != .speaking { isPaused = false }
                case .transcript(let update):
                    transcript = update.text
                case .failure(let failure):
                    error = failure.localizedDescription
                case .listeningFinished:
                    status = "Ready to speak"
                case .speechStarted:
                    isPaused = false
                case .speechFinished, .speechCancelled:
                    isPaused = false
                }
            }
        }, onCancel: {
            Task { @MainActor in await voice.close() }
        })
        await voice.close()
    }

    private func refreshModelStatus() async {
        let capabilities = await voice.capabilities()
        if capabilities.supportsOnDevice {
            modelStatus = "On-device speech model ready for \(capabilities.locale.identifier)."
        } else if capabilities.isSupported {
            modelStatus = "On-device model is not ready. Listen will ask Apple to install it when needed."
        } else {
            modelStatus = capabilities.reason ?? "On-device speech is unavailable for this locale."
        }
    }

    func startListening() async {
        error = nil
        do {
            try await voice.startListening(configuration: .init(policy: .allowModelInstallation))
        } catch let caughtError { error = caughtError.localizedDescription }
    }

    func endListening() async {
        error = nil
        do {
            transcript = try await voice.finishListening()
            status = "Ready to speak"
        } catch let caughtError { error = caughtError.localizedDescription }
    }

    func cancelListening() async {
        error = nil
        await voice.cancelListening()
        status = "Ready"
    }

    func speak() async {
        error = nil
        do { try await voice.speak(transcript) }
        catch let caughtError { error = caughtError.localizedDescription }
    }

    func pauseSpeaking() async {
        await voice.pauseSpeaking()
        isPaused = true
    }

    func resumeSpeaking() async {
        await voice.resumeSpeaking()
        isPaused = false
    }

    func stopSpeaking() async {
        await voice.stopSpeaking()
        isPaused = false
    }
}

private extension VoiceState {
    var label: String {
        switch self {
        case .idle: "Ready"
        case .preparing: "Preparing…"
        case .listening: "Listening…"
        case .finalizing: "Finalizing…"
        case .speaking: "Speaking…"
        case .failed: "Voice unavailable"
        }
    }
}
