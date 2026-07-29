# Deterministic test coverage limitations

The test suite uses actor-isolated fakes and deterministic fault injection. It
proves the coordinator contract without requiring a microphone, installed
speech models, a particular audio route, or a network service.

The deterministic harness covers the coordinator's public mapping for
restricted authorization, model-installation failure, and model-installation
cancellation. The following provider behaviors still require physical-device
validation because the iOS Simulator cannot faithfully provide the relevant
hardware or operating-system behavior:

- SpeechAnalyzer and SpeechTranscriber model installation and finalization,
  including Apple's download, storage, and cancellation behavior.
- Microphone capture across supported iPhone and iPad hardware.
- Audio-session activation with another app already playing audio.
- Phone, FaceTime, Siri, alarm, notification, and media interruptions.
- Wired headset insertion/removal and Bluetooth/AirPods route changes.
- App backgrounding, foreground restoration, screen lock, and audio-session
  deactivation while a recognition operation is active.
- Enhanced Apple voice availability, voice download prompts, and playback
  quality on each supported OS/device/locale combination.
- Long-running capture and synthesis memory stability under thermal pressure.
- Device-specific latency, audio glitches, and recovery after an interrupted
  engine start.

Unicode and long-text behavior is covered by the internal pure chunker tests;
AVSpeech delegate callback timing and actual playback remain device/framework
behavior. The tests cover Unicode scalars, extended grapheme clusters,
UTF-16 boundaries, CJK punctuation, unbroken text, and empty-input behavior.
