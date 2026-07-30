# Recovery

Voice operations can fail because permission, locale assets, routes, or iOS
audio services change. AppLocalVoice reports typed failures and leaves the next
action to the host.

| Condition | Host response |
| --- | --- |
| Microphone or speech permission denied | Explain the required setting and let the user try again. |
| Locale or local model unavailable | Show that voice input is unavailable, or offer explicit preparation when installation is available. |
| Audio activation, interruption, route loss, backgrounding, or media-services reset | End the active UI state and offer an explicit retry after the system is ready. |
| Voice unavailable or invalid speech configuration | Select an installed voice or correct the host configuration. |
| Event delivery failure | Fetch `runtimeSnapshot()` and rebuild host controls from it. |
| `close()` returns `.blocked` | Keep voice controls disabled and retry `close()` from the service owner. |

Never retry capture in a tight loop and never replace a blocked service with a
new instance. `recoveryState` is the authority for whether a new audio
operation may begin.

The package deliberately keeps diagnostics content-free. Bug reports should
include a package version, device class, OS/Xcode version, route class, typed
failure, and lifecycle sequence. Do not include audio, transcript text, spoken
text, credentials, raw crash dumps, or unredacted logs.

Deterministic tests cover the package's provider seams. Route behavior,
interruptions, Apple assets, and endurance still require physical-device
testing.
