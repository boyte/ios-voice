# Vendored: MisakiSwift

- Origin: https://github.com/mlalma/MisakiSwift
- Version: tag `1.0.5`, commit `bb5e3e3671ef550dc545a98f4a4c15f58ee649ec`
- License: Apache-2.0 (see `LICENSE` in this directory)
- Imported: 2026-08-23

Vendored because the published package produces a resource bundle that
cannot be code-signed. Its manifest declares `resources: [.copy("../../Resources/")]`,
which copies a directory literally named `Resources` into
`MisakiSwift_MisakiSwift.bundle`. `codesign` rejects a bundle whose root
contains a `Resources` directory:

    MisakiSwift_MisakiSwift.bundle: bundle format unrecognized, invalid, or unsuitable

Every published version (1.0.2–1.0.6) has this shape, so no upgrade avoids
it. It only bites when code signing actually runs, which is why local
builds with `CODE_SIGNING_ALLOWED=NO` passed while the Xcode Cloud archive
failed. The `../../` escape also made the package fragile to consume
remotely.

Local modifications:

1. `Resources/` is imported here as `MisakiData/`, and the four
   `Bundle.module.url(..., subdirectory: "Resources")` lookups in
   `English/Lexicon/DataResourcesUtil.swift` and
   `English/FallbackNetwork/EnglishFallbackNetwork.swift` now say
   `subdirectory: "MisakiData"`. The bundle therefore has no root
   `Resources` directory and signs cleanly.
2. Every `.swift` file is wrapped in `#if Kokoro` … `#endif` so the target
   compiles to an empty module unless the package trait `Kokoro` is enabled.
3. The target builds in Swift 5 language mode (upstream's default), while
   the rest of the package uses Swift 6.

To update: diff upstream at the new tag against this directory minus the
`#if Kokoro` wrappers and the `MisakiData` rename, then re-apply both.
