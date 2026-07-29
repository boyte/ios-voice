// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppLocalVoice",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "AppLocalVoice", targets: ["AppLocalVoice"])
    ],
    targets: [
        .target(name: "AppLocalVoiceAudioEngineSafe", path: "Sources/AppLocalVoiceAudioEngineSafe"),
        .target(name: "AppLocalVoice", dependencies: ["AppLocalVoiceAudioEngineSafe"]),
        .testTarget(
            name: "AppLocalVoiceTests",
            dependencies: ["AppLocalVoice"],
            exclude: ["AUDIO_SESSION_DEVICE_LIMITS.md", "COVERAGE_LIMITATIONS.md"]
        )
    ],
    swiftLanguageModes: [.v6]
)
