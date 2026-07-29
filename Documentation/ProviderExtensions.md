# Provider extensions

The default AppLocalVoice package is Apple-native and dependency-free. It owns the host-facing behavior, lifecycle, events, and cancellation contract.

Future providers may use an adapter package with an internal implementation
boundary equivalent to the test seams in this repository:

- a local model recognizer;
- a cloud TTS provider;
- an AudioKit-backed input source;
- a provider-specific realtime voice system.

Do not add provider SDKs to the default target or make the default package's
public API depend on provider protocols. Do not force a full-duplex provider
into the simple STT/TTS interfaces. Provider capabilities must be reported
honestly, especially whether audio leaves the device.
