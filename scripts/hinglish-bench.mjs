#!/usr/bin/env node
// Hinglish STT shoot-out on OpenRouter, run on your own recordings.
//
// For each audio file, every model transcribes it. Because models disagree on script (Devanagari
// vs Roman), each transcript is also normalized to Roman Hinglish by an LLM, then scored against
// an optional reference (`clip.txt` next to `clip.wav`, written the way you want the output).
//
// Usage:
//   export OPENROUTER_API_KEY=sk-or-...
//   node scripts/hinglish-bench.mjs clips/*.wav
//   MODELS=elevenlabs/scribe-v2,deepgram/nova-3 node scripts/hinglish-bench.mjs clips/a.wav
//
// Record a clip (Ctrl+C to stop):
//   ffmpeg -f avfoundation -i ":0" -ac 1 -ar 16000 clips/01.wav

import { readFile, access } from "node:fs/promises";
import { extname } from "node:path";

const API = "https://openrouter.ai/api/v1";
const key = process.env.OPENROUTER_API_KEY;
const files = process.argv.slice(2);
if (!key || files.length === 0) {
  console.error("Set OPENROUTER_API_KEY and pass one or more audio files.");
  process.exit(1);
}

// Dedicated STT models (POST /audio/transcriptions). `language` hints are per-model where a
// code-switching mode exists; otherwise auto-detect.
const STT = {
  "elevenlabs/scribe-v2": {},
  "assemblyai/universal-3-6-pro": {},
  "microsoft/mai-transcribe-2": {},
  "deepgram/nova-3": { language: "multi" },
  "openai/gpt-transcribe": {},
  "openai/gpt-4o-transcribe": {},
  "google/gemini-3.5-transcribe": {},
  "openai/whisper-large-v3-turbo": {},
};
// Audio-in chat models (POST /chat/completions) — lets you dictate the output script directly.
const CHAT_ASR = ["google/gemini-3.5-flash", "google/gemini-3.5-flash-lite"];

const NORMALIZER = process.env.NORMALIZER ?? "google/gemini-3.5-flash-lite";
const only = process.env.MODELS?.split(",").map((s) => s.trim());
const pick = (id) => !only || only.includes(id);

const HINGLISH_PROMPT =
  "Transcribe this audio verbatim. The speaker freely mixes English with Indian languages (Hindi, " +
  "Bengali, etc.), sometimes within one sentence. Write EVERYTHING in Roman (Latin) script: Hindi and " +
  "Bengali words romanized the way Indians type them in chat (e.g. 'kal meeting hai', 'baadi jabo', " +
  "'theek hai'), English words in normal English spelling. Keep each word in the language it was " +
  "spoken in. Do not translate. Output only the transcript.";

async function post(path, body) {
  const t0 = performance.now();
  const res = await fetch(`${API}${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const ms = Math.round(performance.now() - t0);
  const text = await res.text();
  if (!res.ok) throw new Error(`${res.status} ${text.slice(0, 200)}`);
  return { json: JSON.parse(text), ms };
}

async function transcribe(model, audio, format) {
  if (CHAT_ASR.includes(model)) {
    const { json, ms } = await post("/chat/completions", {
      model,
      temperature: 0,
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: HINGLISH_PROMPT },
            { type: "input_audio", input_audio: { data: audio, format } },
          ],
        },
      ],
    });
    return { text: json.choices[0].message.content.trim(), ms, cost: json.usage?.cost };
  }
  const { json, ms } = await post("/audio/transcriptions", {
    model,
    input_audio: { data: audio, format },
    ...STT[model],
  });
  return { text: json.text.trim(), ms, cost: json.usage?.cost };
}

async function romanize(text) {
  if (!/[ऀ-෿]/.test(text)) return text; // no Indic script, already Roman
  const { json } = await post("/chat/completions", {
    model: NORMALIZER,
    temperature: 0,
    messages: [
      {
        role: "system",
        content:
          "Transliterate any Indic-script text (Devanagari, Bengali, etc.) in the user's text to Roman " +
          "script the way Indians type in chat (Hinglish/Banglish). Keep English words and everything else unchanged. Do not translate. Output only the text.",
      },
      { role: "user", content: text },
    ],
  });
  return json.choices[0].message.content.trim();
}

// Word error rate on loosely normalized Roman text. Romanization spelling varies (hai/he, nahi/nahin),
// so treat WER as a rough signal and read the transcripts too.
const norm = (s) =>
  s.toLowerCase().replace(/[^\p{L}\p{N}\s']/gu, " ").replace(/\s+/g, " ").trim().split(" ").filter(Boolean);
function wer(ref, hyp) {
  const r = norm(ref), h = norm(hyp);
  const d = Array.from({ length: r.length + 1 }, (_, i) => [i, ...Array(h.length).fill(0)]);
  for (let j = 1; j <= h.length; j++) d[0][j] = j;
  for (let i = 1; i <= r.length; i++)
    for (let j = 1; j <= h.length; j++)
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (r[i - 1] === h[j - 1] ? 0 : 1));
  return r.length ? d[r.length][h.length] / r.length : 0;
}

const models = [...Object.keys(STT), ...CHAT_ASR].filter(pick);
const totals = Object.fromEntries(models.map((m) => [m, { wer: [], ms: [], cost: 0, errors: 0 }]));

for (const file of files) {
  const audio = (await readFile(file)).toString("base64");
  const format = extname(file).slice(1).toLowerCase();
  const refPath = file.replace(/\.[^.]+$/, ".txt");
  const ref = await access(refPath).then(() => readFile(refPath, "utf8").then((s) => s.trim()), () => null);

  console.log(`\n━━ ${file}${ref ? `\n   REF: ${ref}` : ""}`);
  const results = await Promise.all(
    models.map(async (m) => {
      try {
        const r = await transcribe(m, audio, format);
        const roman = await romanize(r.text);
        return { m, ...r, roman };
      } catch (e) {
        return { m, error: e.message };
      }
    }),
  );
  for (const r of results) {
    const t = totals[r.m];
    if (r.error) {
      t.errors++;
      console.log(`\n ✗ ${r.m}: ${r.error}`);
      continue;
    }
    t.ms.push(r.ms);
    t.cost += r.cost ?? 0;
    const w = ref ? wer(ref, r.roman) : null;
    if (w !== null) t.wer.push(w);
    console.log(`\n • ${r.m}  ${r.ms} ms${w !== null ? `  WER ${(w * 100).toFixed(1)}%` : ""}`);
    console.log(`   raw:   ${r.text}`);
    if (r.roman !== r.text) console.log(`   roman: ${r.roman}`);
  }
}

const avg = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : NaN);
console.log("\n━━ Summary (lower is better)");
console.table(
  models
    .map((m) => ({
      model: m,
      "WER %": totals[m].wer.length ? +(avg(totals[m].wer) * 100).toFixed(1) : "-",
      "avg ms": Math.round(avg(totals[m].ms)) || "-",
      "cost $": +totals[m].cost.toFixed(5),
      errors: totals[m].errors,
    }))
    .sort((a, b) => (a["WER %"] === "-" ? 1 : b["WER %"] === "-" ? -1 : a["WER %"] - b["WER %"])),
);
