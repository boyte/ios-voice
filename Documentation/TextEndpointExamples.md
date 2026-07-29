# Text endpoint examples

AppLocalVoice returns text. A host app may pass that text to any endpoint and speak the returned text locally.

Possible endpoints include:

- a personal Mac Mini agent;
- Hermes, OpenClaw, or Cloud Code channels;
- an MCP-connected workflow;
- a local or cloud Chat Completions service;
- a custom HTTP or WebSocket service.

The endpoint integration is deliberately outside AppLocalVoice. The host app owns authentication, request cancellation, history, retries, and endpoint privacy. Raw microphone audio remains inside the phone regardless of the selected text endpoint.
