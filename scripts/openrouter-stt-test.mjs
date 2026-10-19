#!/usr/bin/env node
// Feasibility test: Wispr-style two-stage dictation via OpenRouter.
//   1. ASR       -> POST /api/v1/audio/transcriptions
//   2. Formatter -> POST /api/v1/chat/completions (cleanup, like Wispr's "formatter" stage)
//
// Usage:
//   export OPENROUTER_API_KEY=sk-or-...
//   node scripts/openrouter-stt-test.mjs path/to/audio.wav [stt-model] [llm-model]
//
// Make a test clip on macOS:
//   say -o /tmp/t.wav --data-format=LEI16@16000 "um so I think we should uh ship it on friday"

import { readFile } from "node:fs/promises";
import { extname } from "node:path";

const API = "https://openrouter.ai/api/v1";
const key = process.env.OPENROUTER_API_KEY;
const [file, sttModel = "openai/whisper-large-v3-turbo", llmModel = "google/gemini-3.5-flash-lite"] =
  process.argv.slice(2);

if (!key || !file) {
  console.error("Set OPENROUTER_API_KEY and pass an audio file path.");
  process.exit(1);
}

const headers = { Authorization: `Bearer ${key}`, "Content-Type": "application/json" };

async function post(path, body) {
  const t0 = performance.now();
  const res = await fetch(`${API}${path}`, { method: "POST", headers, body: JSON.stringify(body) });
  const ms = Math.round(performance.now() - t0);
  if (!res.ok) throw new Error(`${path} ${res.status}: ${await res.text()}`);
  return { json: await res.json(), ms };
}

const audio = await readFile(file);
const format = extname(file).slice(1).toLowerCase() || "wav";

const stt = await post("/audio/transcriptions", {
  model: sttModel,
  input_audio: { data: audio.toString("base64"), format },
});
const raw = stt.json.text;
console.log(`\n[ASR ${sttModel}] ${stt.ms} ms`);
console.log(raw);
console.log("usage:", stt.json.usage);

const fmt = await post("/chat/completions", {
  model: llmModel,
  temperature: 0,
  messages: [
    {
      role: "system",
      content:
        "You clean up dictated text. Remove filler words (um, uh, like), fix punctuation and " +
        "capitalization, apply self-corrections (\"no wait, I mean X\" -> X). Keep the speaker's " +
        "wording otherwise. Output only the cleaned text.",
    },
    { role: "user", content: raw },
  ],
});
console.log(`\n[Formatter ${llmModel}] ${fmt.ms} ms`);
console.log(fmt.json.choices[0].message.content);
console.log(`\nTotal latency: ${stt.ms + fmt.ms} ms`);
