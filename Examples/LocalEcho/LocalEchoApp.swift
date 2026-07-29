import SwiftUI
import AppLocalVoice

@main
struct LocalEchoApp: App {
    // The app, not a transient view, owns the one voice service. Features are
    // given the same model/service instance and must never retire it merely
    // because one view leaves the hierarchy.
    @State private var model = LocalEchoModel(voice: AppLocalVoice())

    var body: some Scene {
        WindowGroup { LocalEchoView(model: model) }
    }
}
