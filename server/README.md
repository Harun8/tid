# Tid Realtime Backend

Small Express backend for the Tid iOS MVP. It keeps the OpenAI API key on the server and exposes the WebRTC setup contract used by the native client.

## Setup

```bash
cd server
npm install
cp .env.example .env
```

Set `OPENAI_API_KEY` and `TID_BACKEND_TOKEN` in `.env`, then run:

```bash
npm run dev
```

## Tracing latency

Enable backend timing logs while developing:

```bash
TID_TRACE=1 npm run dev
```

The iOS debug build logs trace spans through `OSLog` with the `Trace` category. The app sends `X-Tid-Trace-Id` to the backend during Realtime setup, and the backend includes the same `trace_id` in each JSON trace line. Use that ID to connect app-side spans such as `RealtimeWebRTCClient.createRealtimeCallAnswer` with server spans such as `openai.realtime.calls.fetch`.

Useful things to compare:

- `VoiceAssistantViewModel.startListening`: total button-to-listening time in the app.
- `RealtimeWebRTCClient.connect`: WebRTC setup, including SDP offer/answer.
- `URLSession.realtimeSDP`: iOS-to-backend network time for `/realtime/sdp`.
- `openai.realtime.calls.fetch`: backend-to-OpenAI setup time.
- `RealtimeWebRTCClient.serverEvent`: time from `response.create` to Realtime events such as transcript completion, function-call arguments, and `response.done`.
- `CalendarService.createEvent`: EventKit save time after confirmation.

## Endpoints

- `GET /health` checks the service.
- `GET /config` returns the default Realtime model, voice, and duration.
- `POST /realtime/sdp` accepts a raw `application/sdp` WebRTC offer from the iOS client, posts multipart `sdp` plus `session` config to `https://api.openai.com/v1/realtime/calls`, and returns OpenAI's SDP answer.
- `POST /realtime/client-secret` creates a short-lived Realtime client secret for development experiments.

Realtime endpoints require `Authorization: Bearer <TID_BACKEND_TOKEN>` unless `TID_DISABLE_BACKEND_AUTH=true` is set for local LAN testing. Production should replace this with app/user authentication before exposing the server.

The production flow uses the current OpenAI Realtime unified WebRTC interface. `OpenAI-Safety-Identifier` uses `X-Tid-User-Hash` when the client sends it, otherwise it falls back to `OPENAI_SAFETY_IDENTIFIER` and then `dev-user-hash`; replace the fallback with a stable hashed internal user ID before shipping.

`OPENAI_ALLOWED_REALTIME_MODELS` and `OPENAI_ALLOWED_REALTIME_VOICES` constrain client-supplied overrides. Unsupported values fall back to the configured defaults.
