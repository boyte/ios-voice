// swift-tools-version: 6.2
import PackageDescription

// Xcode app projects cannot enable a package dependency's traits directly,
// so this one-file package turns on AppLocalVoice's `Kokoro` trait and
// re-exports the engine module to the Local Echo app. Copy this pattern into
// any Xcode-project host that wants the Kokoro engine.
let package = Package(
    name: "LocalEchoKokoro",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "LocalEchoKokoro", targets: ["LocalEchoKokoro"])
    ],
    dependencies: [
        .package(path: "../../..", traits: ["Kokoro"])
    ],
    targets: [
        // "ios-voice" is the package identity SwiftPM derives from the
        // repository's folder name; keep the checkout folder named ios-voice
        // (the default for this repository's clone URL).
        .target(
            name: "LocalEchoKokoro",
            dependencies: [.product(name: "AppLocalVoiceKokoro", package: "ios-voice")]
        )
    ]
)
