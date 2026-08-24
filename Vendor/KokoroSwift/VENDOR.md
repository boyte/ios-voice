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

5. `Decoder/Generator.swift` calls `MLX.eval` on the harmonic source, after
   each residual block is folded into the running sum, and at the end of
   each upsample stage. Upstream never evaluates: the entire
   graph from the text encoder through both vocoder stages and the inverse
   STFT is built lazily and evaluated once, at `asArray` in
   `KokoroTTS.generateAudio`. Peak live memory and the size of a single
   Metal command buffer therefore scale with the whole utterance rather
   than one stage, which on-device is the difference between a short reply
   and a long one. Staging the evaluation bounds both. Output is unchanged
   — `eval` forces work that would happen anyway, it does not alter it.

6. `TTSEngine/WeightLoader.swift`, `TTSEngine/KokoroTTS.swift`, and
   `Decoder/Generator.swift` accept a precision. `loadWeights` casts
   floating-point weights to the requested `DType` (integer tensors are
   left alone), `KokoroTTS` records it as `modelDType`, and `generateAudio`
   casts the alignment matrix to it — that matrix is built from Swift
   `Float`s, so left as float32 it would promote the whole decoder back
   through its two matmuls and undo the saving. `Generator` forces the
   magnitude spectrogram to float32 before `exp`: float16 saturates at
   ~65504, so an activation above about 11 would become `inf` and the
   utterance would come out as noise. That slice is only `n_fft/2+1`
   channels wide, so the cast costs little. Upstream is float32 only, and
   float32 remains the default here.

To update: diff upstream at the new tag against this directory minus the
`#if Kokoro` wrappers, review, re-apply the wrappers, and update this file.
