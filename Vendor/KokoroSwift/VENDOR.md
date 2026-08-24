# Vendored: KokoroSwift

- Origin: https://github.com/mlalma/kokoro-ios
- Version: tag `1.0.9`, commit `87602d0738306758921df1aeef55785b091104e7`
- License: MIT (see `LICENSE` in this directory; upstream author Lassi
  Maksimainen)
- Imported: 2026-08-23

Vendored because the published 1.0.9 package does not build on Xcode 26:
its manifest omits the `MLXFast` product dependency that
`BuildingBlocks/LayerNormInference.swift` imports, and its open
`MLXUtilsLibrary from: 0.0.6` range resolves to 0.0.7, which removed the
`BenchmarkTimer` API that `TTSEngine/KokoroTTS.swift` calls. Both are fixed
here at the manifest level (this repository's `Package.swift` declares
`MLXFast` and pins `MLXUtilsLibrary` exactly at 0.0.6); the Swift sources
are unmodified except as listed below.

Local modifications:

1. Every `.swift` file is wrapped in `#if Kokoro` … `#endif` so the target
   compiles to an empty module unless the package trait `Kokoro` is
   enabled (MLX cannot build without Xcode's Metal toolchain and does not
   run on the iOS simulator).
2. `Resources/config.json` moved from the upstream repository root into
   this target directory as `KokoroData/config.json`, and
   `TTSEngine/KokoroConfig.swift` looks it up with
   `subdirectory: "KokoroData"` instead of `subdirectory: "Resources"`.
   The directory must not be named `Resources`: `codesign` rejects a
   resource bundle whose root contains one ("bundle format unrecognized,
   invalid, or unsuitable"), which fails the Xcode Cloud archive.
3. The target builds in Swift 5 language mode (upstream's mode); the rest
   of the package uses Swift 6.
4. `TTSEngine/KokoroTTS.swift` gains a `KokoroTTSError.noSpeakableContent`
   case and guards `prepareInputTensors` against an empty token array.
   Upstream passes `inputIds.count` to `extractStyleEmbeddings`, which
   indexes the voice tensor at `tokenCount - 1`; text that phonemizes to no
   in-vocabulary tokens (`\n` and `-` are not in Kokoro's 114-entry vocab)
   makes that index -1 and aborts the process instead of throwing.

To update: diff upstream at the new tag against this directory minus the
`#if Kokoro` wrappers, review, re-apply the wrappers, and update this file.
