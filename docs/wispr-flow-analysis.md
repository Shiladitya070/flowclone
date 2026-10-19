# Wispr Flow — how it works (v1.6.1102, macOS)

Source: static analysis of `/Applications/Wispr Flow.app` (ASAR extracted with `@electron/asar`,
analyzed with `npx rea-agents analyze-javascript-application`, plus `strings` on the Swift helper).
The decompiled code itself is NOT checked into this repo; only these notes are.

REA caveat: its worker ran out of heap on `.webpack/main/index.js` (9.7 MB bundle) and skipped
semantic analysis on the renderers, so most details below come from targeted reads of the bundles.

## 1. Process architecture

| Piece | Tech | Job |
|---|---|---|
| Main process | Electron + webpack (`.webpack/main/index.js`) | Orchestration, gRPC client to the inference backend, REST client for `api.wisprflow.ai`, SQLite (`flow.sqlite`, `node_sqlite3.node`), Sentry/PostHog |
| Renderers | React windows: `hub` (main UI), `overlay` (the floating pill), `status`, `scratchpad`, `contextMenu`, `feature_tour`, `meeting_recorder` | UI + **microphone capture** |
| Swift helper | `Resources/swift-helper-app-dist/Wispr Flow.app` (native) | Global hotkey (Fn/Globe via `IOHIDManager` + `CGEventTap`), reading focused text field via Accessibility (`AXUIElement`), **inserting text** (clipboard + synthetic ⌘V, then restore the clipboard) |
| Native add-on | `panel_activation.node` | Show the overlay panel without stealing focus |

Main ↔ helper IPC uses a JSON-schema contract (`src/api/helper/schema.json` → generated TS/Swift/C# models).

## 2. Dictation pipeline

```
Fn key down (Swift helper, IOHID/CGEventTap)
  → helper captures context via Accessibility: app name/bundle id/URL, text before/after cursor, selected text
  → renderer: getUserMedia({channelCount:1, echoCancellation:false, noiseSuppression:false, autoGainControl:false})
     AudioContext @ 16 kHz, latencyHint "interactive", AudioWorklet → Opus encoder worker
  → main: bidi gRPC stream  flow_api.v1.TranscriptionService/TranscribeStream
     host: inference.wisprflow.com (allow-list also includes Baseten `model-*.grpc.api.baseten.co`
     and a Modal endpoint; the host is refreshed from inference-info.wisprflow.com/dictation_url.txt,
     and the lowest-latency Baseten region is picked by a TCP probe)
Fn key up → Request{commit}
  ← Response stream: State{raw_text, formatted_text, progress}, Heartbeat, finally Result{output: Transcription{html, plaintext}}
  → Swift helper pastes the plaintext/html into the focused field and restores the clipboard
  → watches later edits to the pasted text ("capture edits") to learn dictionary entries / style
```

The server runs two stages: a **transcriber** (ASR) and then a **formatter** (LLM cleanup).
`Progress` reports them separately.

## 3. gRPC protocol (`flow_api.v1`, protobuf-ts)

```proto
service TranscriptionService {
  rpc Transcribe(Request) returns (Response);
  rpc TranscribeStream(stream Request) returns (stream Response);
}
message Request  { Init init=1; Context context=2; Payload payload=3; Commit commit=4; /* SkipAhead … */ }
message Init     { Metadata metadata=1; Preferences preferences=2; State state=3; }
message Metadata { string user_id=1; string session_id=2; string request_id=3; AudioEncoding audio_encoding=4; /* WAV=1, OPUS=2 */ }
message Payload  { oneof audio { AudioPackets audio_packets=1; AudioFile audio_file=2; } }
message AudioPackets { repeated bytes items=1; }   // 1..18000 Opus packets
message Context  { App app=1; Textbox textbox=2; DynamicVocabulary vocabulary=3; string user_identifier=4;
                   string content_text=5; string content_html=6; repeated App session_dictation_apps=7;
                   bytes screenshot=8; Conversation conversation=9; }
message Textbox  { optional string contents=1, before_text=2, selected_text=3, after_text=4; }
message DynamicVocabulary { repeated string screen_content_ax=1, screen_content_ocr=2, variable_names=3, file_names=4; }
message Preferences { User user=1; repeated Language language=2; /* StyleConfig, StaticVocabulary, Replacements … */ }
message StaticVocabulary { repeated string dictionary_personal=1, dictionary_team=2, …starred=3,4; }
message Replacements { map<string,string> replacements_personal=1, replacements_team=2, snippets_personal=3, snippets_team=4; }
message StyleConfig { GeneralWritingStyle general_style=1; WritingStyle override_style=2; /* per-app tone */ }

message Response { Result result=1; State state=2; repeated State all_states=3; Heartbeat heartbeat=4; }
message State    { Progress progress=1; Text raw_text=2; Text formatted_text=3; Confidence confidence=4; }
message Result   { Transcription output=1; Duration audio_duration=2; /*response_time*/ … }
message Transcription { string html=1; string plaintext=2; uint32 num_tokens=3; repeated Language languages=4; }
```

What makes the output good is **context**: the text around the cursor, the app/URL, on-screen words
(AX and OCR), and personal dictionaries all go to the formatter LLM.

## 4. Other features in the bundle (not needed for an MVP)

Command mode ("instruct"), snippets, team dictionaries, notes/scratchpad, a meeting notetaker
(system audio via `getDisplayMedia`), calendar/connectors, MCP (`api.wisprflow.ai/connect/mcp`),
and an OpenAI OAuth integration in `311.js`.

## 5. Clone blueprint (mapping to OpenRouter)

| Wispr stage | Clone with OpenRouter |
|---|---|
| Hotkey + AX context + paste | Same approach: Swift helper or Tauri/Electron + `uiohook`/AX APIs |
| 16 kHz mono capture | Same; encode to WAV/FLAC/Opus-in-OGG |
| Streaming ASR (gRPC) | `POST /api/v1/audio/transcriptions` (batch; send once on key release) |
| Formatter | `POST /api/v1/chat/completions` with a fast LLM, plus the cursor context, dictionary and style in the prompt |
| Paste | Clipboard + ⌘V, then restore the clipboard |

### Hinglish

- Output script matters as much as accuracy. Most STT models write Hindi words in Devanagari,
  but Hinglish users usually type in Roman script, so the formatter stage should romanize.
- Shortlist on OpenRouter: `elevenlabs/scribe-v2` (best published Hindi-English code-switch numbers
  among OpenRouter models), `assemblyai/universal-3-6-pro` (claims Hinglish code-switching),
  `microsoft/mai-transcribe-2` (code-switching, top on FLEURS), and `google/gemini-3.5-flash`
  through chat completions with a "write in Roman Hinglish" prompt. That last one lets the prompt control the output script.
- Not on OpenRouter: Sarvam Saaras v3/v4 leads on conversational Hindi-English in third-party evals and
  has a code-mixed mode. It needs its own API key.
- Compare on your own voice with `scripts/hinglish-bench.mjs`.

#### Results on `clips/Cooch Behar` (24 s; Bengali + Hindi + English; target is Roman script)

| Model | WER (run 1 / 2) | Latency | Cost / clip | Notes |
|---|---|---|---|---|
| `google/gemini-3.5-flash` (chat, prompt) | 14.8 / 13.0 % | ~4 s | ~$0.010 | Roman output directly, gets the Bengali right ("baadi giye … hok") |
| `google/gemini-3.5-flash-lite` (chat, prompt) | 18.5 / 14.8 % | ~2.4 s | ~$0.0004 | Fastest and cheapest; sometimes drops a Bengali word ("giye"→"ye") |
| `microsoft/mai-transcribe-2` | 14.8 / 14.8 % | ~4.6 s | ~$0.0007 | Devanagari output, so it needs a romanize pass; rejects m4a (send WAV) |
| `elevenlabs/scribe-v2` | 18.5 / 16.7 % | ~3.5 s | ~$0.0008 | Devanagari output |
| `openai/gpt-transcribe` | 18.5–20.4 % | ~2.5 s | ~$0.002 | Paraphrases ("great"→"creative") |
| `assemblyai/universal-3-6-pro`, `deepgram/nova-3` | 27.8 % | ~3 s | ~$0.002 | |
| `openai/gpt-4o-transcribe` | 44.4 % | | | Translated part of the speech into Hindi |
| `google/gemini-3.5-transcribe`, `whisper-large-v3-turbo` | 65–78 % | | | Dropped or translated the Indic speech |

WER counts romanization spelling differences ("main"/"mein", "hoon"/"hu") as errors, so the leaders are closer than the numbers suggest.
Choice: **Gemini 3.5 Flash-Lite as default** (one call does ASR, romanization and cleanup), with Gemini 3.5 Flash as a "high accuracy" option.

### Economics vs Wispr Flow Pro ($12/mo annual, $15/mo monthly; free tier 2,000 words/week)

Assumptions: 140 wpm, 20 s average dictation, ~1,000 context tokens per call, ~5.5% OpenRouter
credit fee, 22 workdays a month. Audio cost comes from the benchmark runs above.

| Words / workday | Audio / month | Flash-Lite | Flash | Wispr Pro |
|---|---|---|---|---|
| 1,000 | 2.6 h | $0.31 | $5.49 | $12–15 |
| 2,000 | 5.2 h | $0.62 | $10.99 | $12–15 |
| 5,000 | 13 h | $1.55 | $27.47 | $12–15 |
| 10,000 | 26 h | $3.10 | $54.94 | $12–15 |

Break-even against $12: Flash-Lite at ~39k words/workday (more than 4 h of speaking every day, so never
in practice); Flash at ~2.2k words/workday. Flash-Lite is the economic case; Flash should be
opt-in only (e.g. a "re-do this dictation" action).

Gap: OpenRouter's transcription endpoint is request/response, not a live stream, so you get
no partial text while speaking. For short dictations (under about 30 s) the delay after key release is usually fine.
