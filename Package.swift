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
        .trait(name: "Kokoro", description: "Builds the AppLocalVoiceKokoro product on MLX (device-only).")
    ],
    dependencies: [
        // Used only by the trait-gated Kokoro engine; pruned entirely when the
        // trait is off. Versions are the set proven against the vendored
        // KokoroSwift 1.0.9 sources (see Vendor/KokoroSwift/VENDOR.md):
        // MLXUtilsLibrary 0.0.7 removed BenchmarkTimer, so it stays pinned.
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.6")),
        .package(url: "https://github.com/mlalma/MisakiSwift", exact: "1.0.5"),
        .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6")
    ],
    targets: [
        .target(name: "AppLocalVoiceAudioEngineSafe", path: "Sources/AppLocalVoiceAudioEngineSafe"),
        .target(name: "AppLocalVoice", dependencies: ["AppLocalVoiceAudioEngineSafe"]),
        .target(
            name: "KokoroSwift",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MLXNN", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MLXRandom", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MLXFFT", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MLXFast", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MisakiSwift", package: "MisakiSwift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary", condition: .when(traits: ["Kokoro"]))
            ],
            path: "Vendor/KokoroSwift",
            exclude: ["LICENSE", "VENDOR.md"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AppLocalVoiceKokoro",
            dependencies: [
                "AppLocalVoice",
                "KokoroSwift",
                .product(name: "MLX", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary", condition: .when(traits: ["Kokoro"]))
            ]
        ),
        .testTarget(name: "AppLocalVoiceTests", dependencies: ["AppLocalVoice"])
    ],
    swiftLanguageModes: [.v6]
)
