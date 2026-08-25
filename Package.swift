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
        //
        // mlx-swift is held at 0.30.2 — the version kokoro-ios 1.0.9 itself
        // resolved — because 0.31.x adds the `CudaBuild` build-tool plugin.
        // That plugin is a no-op on Apple platforms, but Xcode still refuses
        // to run an untrusted plugin and Xcode Cloud has no way to trust one,
        // so 0.31.x cannot be archived in CI. 0.30.2 exposes every product we
        // use (MLX, MLXNN, MLXRandom, MLXFFT, MLXFast) and no plugins.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
        .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6")
    ],
    targets: [
        .target(name: "AppLocalVoiceAudioEngineSafe", path: "Sources/AppLocalVoiceAudioEngineSafe"),
        .target(name: "AppLocalVoice", dependencies: ["AppLocalVoiceAudioEngineSafe"]),
        .target(
            name: "MisakiSwift",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MLXNN", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                // Imported by the sources; without it the module only links
                // because KokoroSwift happens to pull MLXRandom in alongside
                // it, which the Swift dependency scanner rightly warns about.
                .product(name: "MLXRandom", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary", condition: .when(traits: ["Kokoro"]))
            ],
            path: "Vendor/MisakiSwift",
            exclude: ["LICENSE", "VENDOR.md"],
            // Must not be named "Resources": codesign rejects a resource
            // bundle whose root holds a directory with that name.
            resources: [.copy("MisakiData")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KokoroSwift",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MLXNN", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MLXRandom", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MLXFFT", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                .product(name: "MLXFast", package: "mlx-swift", condition: .when(traits: ["Kokoro"])),
                "MisakiSwift",
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary", condition: .when(traits: ["Kokoro"]))
            ],
            path: "Vendor/KokoroSwift",
            exclude: ["LICENSE", "VENDOR.md"],
            // Must not be named "Resources" (see MisakiSwift target above).
            resources: [.copy("KokoroData")],
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
