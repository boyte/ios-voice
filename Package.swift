// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppLocalVoice",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "AppLocalVoice", targets: ["AppLocalVoice"]),
        .library(name: "AppLocalVoiceKokoro", targets: ["AppLocalVoiceKokoro"])
    ],
    traits: [
        .trait(name: "Kokoro", description: "Builds the AppLocalVoiceKokoro product on kokoro-ios / MLX (device-only).")
    ],
    dependencies: [
        .package(url: "https://github.com/mlalma/kokoro-ios.git", exact: "1.0.9")
    ],
    targets: [
        .target(name: "AppLocalVoiceAudioEngineSafe", path: "Sources/AppLocalVoiceAudioEngineSafe"),
        .target(name: "AppLocalVoice", dependencies: ["AppLocalVoiceAudioEngineSafe"]),
        .target(
            name: "AppLocalVoiceKokoro",
            dependencies: [
                "AppLocalVoice",
                .product(name: "KokoroSwift", package: "kokoro-ios", condition: .when(traits: ["Kokoro"]))
            ]
        ),
        .testTarget(name: "AppLocalVoiceTests", dependencies: ["AppLocalVoice"])
    ],
    swiftLanguageModes: [.v6]
)
