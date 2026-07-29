# Security policy

AppLocalVoice has no network service, account, credential store, or telemetry. It is designed so microphone audio stays on the device within Apple’s speech APIs.

Do not include microphone recordings, transcript text, TTS text, credentials, or private app data in issues or pull requests.

For a suspected security or privacy issue, use this repository's GitHub
**Report a vulnerability** flow. Do not disclose the issue publicly. Include
the affected version, iOS version, device, reproduction steps that do not
contain personal speech, and the expected versus observed behavior.

Maintainers should acknowledge a report within 7 days, keep the reporter
updated while triaging it, and publish a coordinated fix and advisory when a
report is confirmed. Do not attach raw crash dumps, recordings, transcripts,
or credentials.

## Safe diagnostic data

The preferred diagnostic record contains only package/version, OS/device,
locale identifier, route class, lifecycle state, operation identifier, timing,
and stable error category. Do not attach crash dumps or logs containing raw
audio, transcript text, synthesized text, credentials, or arbitrary user input
without first redacting them.
