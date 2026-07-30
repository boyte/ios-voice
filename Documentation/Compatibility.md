# Compatibility policy

AppLocalVoice is pre-1.0. The package may make deliberate breaking changes
between minor releases when they reduce ambiguity or remove an unsafe contract.
Each change is recorded in `CHANGELOG.md` and validated against a generated
production symbol graph.

The public contract is the canonical API in [PublicAPI.md](PublicAPI.md):
identified recognition sessions, `voiceEvents()`, capability snapshots and
explicit preparation, and identified speech playback. Hosts should retain their
own message and composer models, not depend on package internals or test seams.

Published release candidates are compared with the immediately preceding tag.
Physical-device observations remain host/device evidence and are never implied
by simulator or build results.
