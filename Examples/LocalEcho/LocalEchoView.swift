import SwiftUI
import AppLocalVoice

struct LocalEchoView: View {
    @Bindable var model: LocalEchoModel

    var body: some View {
        VStack(spacing: 20) {
            Text(model.status)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(model.modelStatus)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let voiceTip = model.voiceTip {
                Text(voiceTip)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(model.transcript.isEmpty ? "Your transcript will appear here." : model.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }

            HStack(spacing: 12) {
                if model.isPreparing || model.isListening || model.isFinalizing {
                    Button("End") {
                        Task { await model.endListening() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isFinalizing)
                    .accessibilityLabel("End listening")

                    Button("Cancel") {
                        Task { await model.cancelListening() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Cancel listening")
                } else {
                    Button("Listen") {
                        Task { await model.startListening() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSpeaking)
                    .accessibilityLabel("Start listening")
                }
            }

            HStack(spacing: 12) {
                Button("Speak") {
                    Task { await model.speak() }
                }
                .buttonStyle(.bordered)
                .disabled(model.transcript.isEmpty || model.isPreparing || model.isListening || model.isFinalizing || model.isSpeaking)
                .accessibilityLabel("Speak transcript")

                Button("Pause") {
                    Task { await model.pauseSpeaking() }
                }
                .buttonStyle(.bordered)
                .disabled(!model.isSpeaking || model.isPaused)
                .accessibilityLabel("Pause speech")

                Button("Resume") {
                    Task { await model.resumeSpeaking() }
                }
                .buttonStyle(.bordered)
                .disabled(!model.isSpeaking || !model.isPaused)
                .accessibilityLabel("Resume speech")

                Button("Stop") {
                    Task { await model.stopSpeaking() }
                }
                .buttonStyle(.bordered)
                .disabled(!model.isSpeaking)
                .accessibilityLabel("Stop speech")
            }

            if let error = model.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .navigationTitle("Local Echo")
        .task { await model.observeEvents() }
    }
}
