# Tid

Production-quality MVP scaffold for a Danish voice calendar assistant.

- iOS app: `ios/VoiceCalendarAssistant`
- Realtime backend: `server`

The app uses a `RealtimeClient` protocol. Leaving the backend token blank keeps the simulator/demo mock client active; setting a backend token switches the assistant to the native WebRTC client. The backend uses OpenAI Realtime through the GA `/v1/realtime/calls` WebRTC setup flow and never exposes the OpenAI API key to iOS.

For latency tracing, run the backend with `TID_TRACE=1 npm run dev` and watch the iOS debug logs for the `Trace` category. Client and server spans share `trace_id` during Realtime setup.
