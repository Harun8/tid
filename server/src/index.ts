import "dotenv/config";
import express from "express";
import { randomUUID } from "node:crypto";
import type { NextFunction, Request, Response } from "express";

const app = express();
app.disable("x-powered-by");
app.use(express.json({ limit: "1mb" }));

const port = parsePort(process.env.PORT);
const openAIRealtimeCallsURL = "https://api.openai.com/v1/realtime/calls";
const openAIClientSecretsURL = "https://api.openai.com/v1/realtime/client_secrets";
const requestTimeoutMS = parsePositiveInteger(process.env.OPENAI_REQUEST_TIMEOUT_MS, 15_000, 1_000, 60_000);
const defaultRealtimeModel = clean(process.env.OPENAI_REALTIME_MODEL) ?? "gpt-realtime-mini";
const defaultRealtimeVoice = clean(process.env.OPENAI_REALTIME_VOICE) ?? "marin";
const disableBackendAuth = truthy(process.env.TID_DISABLE_BACKEND_AUTH);
const traceEnabled = truthy(process.env.TID_TRACE);
const allowedRealtimeModels = envList("OPENAI_ALLOWED_REALTIME_MODELS", [
  defaultRealtimeModel,
  "gpt-realtime-2",
  "gpt-realtime"
]);
const allowedRealtimeVoices = envList("OPENAI_ALLOWED_REALTIME_VOICES", [
  defaultRealtimeVoice,
  "alloy",
  "ash",
  "ballad",
  "coral",
  "echo",
  "marin",
  "shimmer",
  "verse"
]);

type SessionOverrides = {
  model?: string;
  voice?: string;
  timeZone?: string;
  locale?: string;
};

type TraceFields = Record<string, string | number | boolean | undefined>;

app.use((req, res, next) => {
  if (!traceEnabled) {
    next();
    return;
  }

  const traceID = requestTraceID(req);
  const startedAt = performance.now();
  tracePoint(traceID, "http.request.start", {
    method: req.method,
    path: req.path,
    content_length: req.get("content-length"),
    remote_address: req.socket.remoteAddress
  });

  res.on("finish", () => {
    tracePoint(traceID, "http.request.finish", {
      method: req.method,
      path: req.path,
      status: res.statusCode,
      duration_ms: elapsedMilliseconds(startedAt)
    });
  });

  next();
});

app.get("/health", (_req, res) => {
  const checks = {
    openAIAPIKey: Boolean(clean(process.env.OPENAI_API_KEY)),
    backendAuth: disableBackendAuth || Boolean(clean(process.env.TID_BACKEND_TOKEN)),
    backendAuthDisabled: disableBackendAuth
  };

  res.status(checks.openAIAPIKey && checks.backendAuth ? 200 : 503).json({
    ok: checks.openAIAPIKey && checks.backendAuth,
    service: "tid-realtime-backend",
    checks
  });
});

app.get("/config", (_req, res) => {
  res.json({
    model: defaultRealtimeModel,
    voice: defaultRealtimeVoice,
    defaultDurationMinutes: 60
  });
});

app.use("/realtime", requireBackendToken);

app.post(
  "/realtime/sdp",
  express.text({ type: ["application/sdp", "text/plain"], limit: "2mb" }),
  async (req, res) => {
    const traceID = requestTraceID(req);
    const startedAt = performance.now();
    res.setHeader("X-Tid-Trace-Id", traceID);

    try {
      tracePoint(traceID, "realtime.sdp.start", {
        content_length: req.get("content-length"),
        has_model_override: Boolean(headerValue(req.get("X-Tid-Model"))),
        has_voice_override: Boolean(headerValue(req.get("X-Tid-Voice")))
      });

      const sdp = typeof req.body === "string" ? req.body : "";

      if (!sdp.includes("v=0")) {
        tracePoint(traceID, "realtime.sdp.badRequest", { duration_ms: elapsedMilliseconds(startedAt) });
        res.status(400).json({ error: "Expected raw SDP offer in request body." });
        return;
      }

      const apiKey = requireOpenAIKey();

      const session = traceSync(traceID, "buildRealtimeSession", () => {
        return buildRealtimeSession({
          model: headerValue(req.get("X-Tid-Model")),
          voice: headerValue(req.get("X-Tid-Voice")),
          timeZone: headerValue(req.get("X-Tid-Time-Zone")),
          locale: headerValue(req.get("X-Tid-Locale"))
        });
      });
      tracePoint(traceID, "realtime.session.config", {
        model: session.model,
        output_modalities: session.output_modalities.join(","),
        transcription_model: session.audio.input.transcription.model,
        turn_detection: session.audio.input.turn_detection === null ? "manual" : "server",
        tool_count: session.tools.length,
        max_output_tokens: session.max_output_tokens
      });

      const form = new FormData();
      form.set("sdp", sdp);
      form.set("session", JSON.stringify(session));

      const upstream = await traceAsync(traceID, "openai.realtime.calls.fetch", () => {
        return fetchWithTimeout(openAIRealtimeCallsURL, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${apiKey}`,
            "OpenAI-Safety-Identifier": safetyIdentifier(req)
          },
          body: form
        });
      });

      const answer = await traceAsync(
        traceID,
        "openai.realtime.calls.readText",
        () => upstream.text(),
        { status: upstream.status }
      );

      if (!upstream.ok) {
        tracePoint(traceID, "realtime.sdp.upstreamError", {
          duration_ms: elapsedMilliseconds(startedAt),
          status: upstream.status
        });
        res.status(upstream.status).type("application/json").send(
          JSON.stringify({
            error: "OpenAI Realtime call setup failed.",
            status: upstream.status,
            details: answer
          })
        );
        return;
      }

      tracePoint(traceID, "realtime.sdp.finish", {
        bytes: answer.length,
        duration_ms: elapsedMilliseconds(startedAt),
        status: upstream.status
      });
      res.status(upstream.status).type("application/sdp").send(answer);
    } catch (error) {
      tracePoint(traceID, "realtime.sdp.error", {
        duration_ms: elapsedMilliseconds(startedAt),
        error: errorMessage(error)
      });
      res.status(500).json({ error: errorMessage(error) });
    }
  }
);

app.post("/realtime/client-secret", async (req, res) => {
  const traceID = requestTraceID(req);
  const startedAt = performance.now();
  res.setHeader("X-Tid-Trace-Id", traceID);

  try {
    tracePoint(traceID, "realtime.clientSecret.start");

    const apiKey = requireOpenAIKey();
    const body = req.body as SessionOverrides | undefined;
    const payload = traceSync(traceID, "buildRealtimeClientSecretPayload", () => ({
      expires_after: {
        anchor: "created_at",
        seconds: 600
      },
      session: buildRealtimeSession({
        model: body?.model,
        voice: body?.voice,
        timeZone: body?.timeZone,
        locale: body?.locale
      })
    }));

    const upstream = await traceAsync(traceID, "openai.realtime.clientSecrets.fetch", () => {
      return fetchWithTimeout(openAIClientSecretsURL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
          "OpenAI-Safety-Identifier": safetyIdentifier(req)
        },
        body: JSON.stringify(payload)
      });
    });

    const text = await traceAsync(
      traceID,
      "openai.realtime.clientSecrets.readText",
      () => upstream.text(),
      { status: upstream.status }
    );
    tracePoint(traceID, "realtime.clientSecret.finish", {
      bytes: text.length,
      duration_ms: elapsedMilliseconds(startedAt),
      status: upstream.status
    });
    res.status(upstream.status).type(upstream.headers.get("content-type") ?? "application/json").send(text);
  } catch (error) {
    tracePoint(traceID, "realtime.clientSecret.error", {
      duration_ms: elapsedMilliseconds(startedAt),
      error: errorMessage(error)
    });
    res.status(500).json({ error: errorMessage(error) });
  }
});

app.listen(port, () => {
  console.log(`Tid Realtime backend listening on http://localhost:${port}`);
});

function buildRealtimeSession(overrides: SessionOverrides = {}) {
  const model = allowedValue(clean(overrides.model), allowedRealtimeModels, defaultRealtimeModel);
  const voice = allowedValue(clean(overrides.voice), allowedRealtimeVoices, defaultRealtimeVoice);
  const locale = validLocale(clean(overrides.locale)) ?? "da_DK";
  const timeZone = validTimeZone(clean(overrides.timeZone)) ?? "Europe/Copenhagen";

  return {
    type: "realtime",
    model,
    instructions: systemInstructions(locale, timeZone),
    output_modalities: ["text"],
    audio: {
      input: {
        transcription: {
          model: "gpt-realtime-whisper",
          language: "da",
          delay: "low"
        },
        turn_detection: null
      }
    },
    tools: [calendarDraftTool()],
    tool_choice: "auto",
    max_output_tokens: 1200
  };
}

function systemInstructions(locale: string, timeZone: string) {
  return [
    "Du er Tid, en dansk stemmestyret kalenderassistent.",
    `Brugerens locale er ${locale}, og brugerens tidszone er ${timeZone}.`,
    "Forstå naturlig dansk tale, inklusiv fyldord som øhh, altså og hmm.",
    "Din opgave er at oprette kladder til Apple Kalender-aftaler, ikke at gemme dem direkte.",
    "Titel er ikke et påkrævet brugerinput. Hvis brugeren ikke giver en tydelig titel, skal du bruge en rolig standardtitel som Aftale, eller Møde hvis det tydeligt er et møde.",
    "Hvis brugeren siger, hvem mødet er med, skal navnet indgå i titlen: 'møde med Per' bliver 'Møde med Per'. Hvis der hverken er person eller emne, skal titlen bare være 'Møde'.",
    "Hvis brugeren både angiver et emne og en person, skal titlen være kort og naturlig, fx 'Status med Per' eller 'Budgetmøde med Anna'.",
    "Hvis brugeren nævner personer med formuleringer som 'med Per', 'sammen med Anna' eller 'hos Jonas', skal du udfylde attendees med navnene. Brug ikke generiske ord som kunde, læge eller team som attendee-navne, medmindre de er egentlige navne.",
    "Hvis brugeren nævner et sted med formuleringer som 'på Café Paludan', 'hos lægen', 'i mødelokale 3' eller 'på kontoret', skal du udfylde location med den korte stedtekst.",
    "Hvis brugeren udtrykkeligt nævner en kalender, fx 'i arbejdskalenderen', 'på familiekalenderen' eller 'i privat', skal du udfylde calendarName med den korte kalendertekst. Spørg ikke om kalenderen.",
    "Hvis brugeren ikke nævner en kalender, men aftalen tydeligt hører til arbejde, privat eller familie, må du udfylde calendarCategory med work, personal eller family. Brug kun category når signalet er tydeligt; ellers udelad feltet og lad appen bruge standardkalenderen.",
    "Spørg aldrig brugeren kun for at få en titel.",
    "Tid skal føles som en hurtig kommando, ikke en samtale. Spørg kun, når aftalen ikke kan oprettes uden svaret.",
    "Spørg kun om opklaring, hvis datoen mangler helt, starttidspunktet mangler helt, dato/tid er umulig eller modstridende, eller brugeren beder om flere aftaler i samme besked.",
    "Spørg aldrig om påmindelse, titel, kalender, varighed, sted, deltagere eller sluttidspunkt, hvis brugeren ikke nævner det.",
    "Hvis dato eller starttidspunkt mangler helt, skal du stille præcis et kort opklarende spørgsmål på dansk.",
    "Hvis brugeren ikke angiver varighed eller sluttidspunkt, skal du bruge 60 minutter.",
    "Hvis brugeren beder om en påmindelse et par, få eller nogle minutter før, skal du bruge 5 minutter.",
    "Påmindelsesregler: 'lige før' eller 'kort før' betyder 5 minutter; 'lidt før' betyder 10 minutter; 'i god tid' betyder 30 minutter; 'en halv time før' betyder 30 minutter; 'dagen før' betyder 1440 minutter; 'samme morgen' betyder 180 minutter, medmindre brugeren siger et præcist tidspunkt.",
    "Hvis brugeren beder om flere påmindelser, skal alle medtages og deduplikeres, fx 'dagen før og 10 minutter før' -> [1440, 10].",
    "Hvis brugeren ikke beder om påmindelser, skal alarmsMinutesBefore være en tom liste.",
    "Relative datoer skal beregnes direkte, ikke bekræftes. Eksempler: i morgen, på tirsdag, tirsdag om to uger, første mandag i august.",
    "Naturlige danske perioder skal tolkes pragmatisk: morgen/formiddag er typisk før 12, eftermiddag 12-17, aften 17-22. Hvis brugeren også giver et konkret klokkeslæt, har klokkeslættet forrang.",
    "Gentagelser skal udfyldes som recurrenceRule, når brugeren siger fx 'hver mandag', 'hver uge', 'hver anden tirsdag', 'dagligt', 'hver måned' eller 'årligt'. Startdatoen skal være første forekomst i brugerens tidszone.",
    "Hvis brugeren siger 'de næste 5 gange', brug recurrenceRule.occurrenceCount = 5. Hvis brugeren siger 'indtil 1. september', brug recurrenceRule.endISO8601.",
    "Hvis brugeren siger en relativ dato og et starttidspunkt, skal du kalde stage_calendar_event. Spørg ikke 'mener du datoen?' eller lignende.",
    "Når alle påkrævede kalenderfelter er kendte, skal du kalde stage_calendar_event med ISO 8601-tider.",
    "Tal ikke tilbage til brugeren, og generér ikke lydsvar. Når alle felter er kendte, skal du kalde stage_calendar_event direkte uden bekræftende tekst eller smalltalk.",
    "Hvis et valgfrit felt mangler, skal du vælge standarden og ikke spørge. Standarder: ingen påmindelser, 60 minutter, standardkalender, standardtitel, ingen location, ingen attendees, ingen recurrenceRule.",
    "Hvis noget påkrævet mangler, må du kun stille et kort tekstspørgsmål i appen.",
    "Brug altid brugerens tidszone ved relative datoer og danske formuleringer som i morgen, tirsdag d. 23 eller i formiddag.",
    "Hvis du skal spørge om manglende oplysninger, skal spørgsmålet være kort og roligt. Gentag ikke lange transskriptioner."
  ].join("\n");
}

function calendarDraftTool() {
  return {
    type: "function",
    name: "stage_calendar_event",
    description:
      "Prepare a calendar event draft for the iOS app to confirm and save.",
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        title: {
          type: "string",
          description: "Short Danish event title. Include a named participant when the user says who the meeting is with, e.g. 'møde med Per' -> 'Møde med Per'. Use 'Møde' only when it is clearly a meeting but no person or subject is present; otherwise use 'Aftale'."
        },
        startISO8601: {
          type: "string",
          description: "Event start date-time as ISO 8601 with timezone offset."
        },
        endISO8601: {
          type: "string",
          description: "Event end date-time as ISO 8601 with timezone offset."
        },
        timeZone: {
          type: "string",
          description: "IANA timezone identifier, e.g. Europe/Copenhagen."
        },
        alarmsMinutesBefore: {
          type: "array",
          description: "Reminder offsets in minutes before start. 5 hours is 300. Use [] when the user did not request reminders.",
          items: {
            type: "integer",
            minimum: 0
          }
        },
        location: {
          type: "string",
          description: "Short location text when the user states a place, e.g. 'Café Paludan', 'mødelokale 3', 'hos lægen'. Use an empty string only if no location was mentioned."
        },
        attendees: {
          type: "array",
          description: "Named people explicitly mentioned as participants, e.g. 'med Per og Anna' -> ['Per', 'Anna']. Do not include generic roles unless they are used as names.",
          items: {
            type: "string"
          }
        },
        recurrenceRule: {
          type: "object",
          additionalProperties: false,
          description: "Recurrence rule when the user asks for a repeating event. Omit this field when the event is not recurring.",
          properties: {
            frequency: {
              type: "string",
              enum: ["daily", "weekly", "monthly", "yearly"],
              description: "Repeat frequency."
            },
            interval: {
              type: "integer",
              minimum: 1,
              description: "Repeat interval. Use 1 for every week/day/month/year, 2 for every other week, etc."
            },
            endISO8601: {
              type: "string",
              description: "Optional recurrence end date-time as ISO 8601 with timezone offset when the user gives an end date."
            },
            occurrenceCount: {
              type: "integer",
              minimum: 1,
              description: "Optional number of occurrences when the user says e.g. 'de næste 5 gange'."
            }
          },
          required: ["frequency"]
        },
        calendarName: {
          type: "string",
          description: "Short calendar name explicitly spoken by the user, e.g. 'Arbejde', 'Familie', 'Privat'. Omit when the user did not explicitly name a calendar."
        },
        calendarCategory: {
          type: "string",
          enum: ["work", "personal", "family"],
          description: "High-confidence category inferred from the event content when no explicit calendar was named. Use work for work/client/office events, personal for private appointments/training/doctor, and family for family/children/partner events. Omit when unclear."
        },
        notes: {
          type: "string"
        },
        confidence: {
          type: "number",
          minimum: 0,
          maximum: 1
        },
        originalUtterance: {
          type: "string"
        }
      },
      required: [
        "title",
        "startISO8601",
        "endISO8601",
        "timeZone",
        "alarmsMinutesBefore",
        "confidence",
        "originalUtterance"
      ]
    }
  };
}

function requireOpenAIKey() {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new Error("OPENAI_API_KEY is not configured. Copy .env.example to .env and set the key on the server only.");
  }
  return apiKey;
}

function clean(value: string | undefined) {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function headerValue(value: string | undefined) {
  return clean(value);
}

function errorMessage(error: unknown) {
  if (error instanceof DOMException && error.name == "AbortError") {
    return "OpenAI request timed out.";
  }

  return error instanceof Error ? error.message : "Unknown server error.";
}

function requireBackendToken(req: Request, res: Response, next: NextFunction) {
  if (disableBackendAuth) {
    next();
    return;
  }

  const expectedToken = clean(process.env.TID_BACKEND_TOKEN);
  if (!expectedToken) {
    res.status(503).json({
      error: "TID_BACKEND_TOKEN is not configured. Set it on the server and send it as a Bearer token from trusted clients."
    });
    return;
  }

  const token = bearerToken(req.get("Authorization"));
  if (token !== expectedToken) {
    res.status(401).json({ error: "Missing or invalid Tid backend token." });
    return;
  }

  next();
}

function bearerToken(headerValue: string | undefined) {
  const match = headerValue?.match(/^Bearer\s+(.+)$/i);
  return clean(match?.[1]);
}

function safetyIdentifier(req: Request) {
  const headerIdentifier = clean(req.get("X-Tid-User-Hash"));
  // TODO: Replace the development fallback with a stable hash of the authenticated app user.
  return headerIdentifier ?? clean(process.env.OPENAI_SAFETY_IDENTIFIER) ?? "dev-user-hash";
}

async function fetchWithTimeout(url: string, init: RequestInit) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), requestTimeoutMS);

  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

function requestTraceID(req: Request) {
  return clean(req.get("X-Tid-Trace-Id")) ?? clean(req.get("X-Request-Id")) ?? randomUUID().slice(0, 8);
}

function tracePoint(traceID: string, event: string, fields: TraceFields = {}) {
  if (!traceEnabled) {
    return;
  }

  const payload: Record<string, string | number | boolean> = {
    level: "debug",
    trace: "tid",
    trace_id: traceID,
    event,
    timestamp: new Date().toISOString()
  };

  for (const [key, value] of Object.entries(fields)) {
    if (value !== undefined) {
      payload[key] = value;
    }
  }

  console.log(JSON.stringify(payload));
}

function traceSync<T>(traceID: string, name: string, operation: () => T, fields: TraceFields = {}) {
  if (!traceEnabled) {
    return operation();
  }

  const startedAt = performance.now();
  tracePoint(traceID, `${name}.start`, fields);

  try {
    const value = operation();
    tracePoint(traceID, `${name}.end`, { ...fields, duration_ms: elapsedMilliseconds(startedAt) });
    return value;
  } catch (error) {
    tracePoint(traceID, `${name}.error`, {
      ...fields,
      duration_ms: elapsedMilliseconds(startedAt),
      error: errorMessage(error)
    });
    throw error;
  }
}

async function traceAsync<T>(traceID: string, name: string, operation: () => Promise<T>, fields: TraceFields = {}) {
  if (!traceEnabled) {
    return operation();
  }

  const startedAt = performance.now();
  tracePoint(traceID, `${name}.start`, fields);

  try {
    const value = await operation();
    tracePoint(traceID, `${name}.end`, { ...fields, duration_ms: elapsedMilliseconds(startedAt) });
    return value;
  } catch (error) {
    tracePoint(traceID, `${name}.error`, {
      ...fields,
      duration_ms: elapsedMilliseconds(startedAt),
      error: errorMessage(error)
    });
    throw error;
  }
}

function elapsedMilliseconds(startedAt: number) {
  return Number((performance.now() - startedAt).toFixed(1));
}

function allowedValue(candidate: string | undefined, allowedValues: Set<string>, fallback: string) {
  return candidate && allowedValues.has(candidate) ? candidate : fallback;
}

function envList(key: string, fallback: string[]) {
  const configured = process.env[key]
    ?.split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  return new Set(configured?.length ? configured : fallback);
}

function truthy(value: string | undefined) {
  return ["1", "true", "yes", "on"].includes(value?.trim().toLowerCase() ?? "");
}

function validLocale(value: string | undefined) {
  if (!value || value.length > 35) {
    return undefined;
  }

  try {
    return new Intl.Locale(value.replace("_", "-")).toString().replace("-", "_");
  } catch {
    return undefined;
  }
}

function validTimeZone(value: string | undefined) {
  if (!value || value.length > 64 || !/^[A-Za-z0-9_+\-/]+$/.test(value)) {
    return undefined;
  }

  try {
    Intl.DateTimeFormat("en-US", { timeZone: value });
    return value;
  } catch {
    return undefined;
  }
}

function parsePort(value: string | undefined) {
  return parsePositiveInteger(value, 3000, 1, 65_535);
}

function parsePositiveInteger(value: string | undefined, fallback: number, minimum: number, maximum: number) {
  const parsed = Number(value);
  if (Number.isInteger(parsed) && parsed >= minimum && parsed <= maximum) {
    return parsed;
  }

  return fallback;
}
