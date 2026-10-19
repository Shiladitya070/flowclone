# FlowClone (macOS)

Hold **Fn/🌐**, speak (English / Hindi / Bengali, mixed is fine), release. The text is typed into
whatever app has focus, in Roman script.

| Gesture | Action |
|---|---|
| Hold Fn | Dictate while held |
| Double-tap Fn | Hands-free: keeps recording; tap Fn again to finish |
| Esc | Cancel recording or transcription (nothing is typed) |
| ⌃⌥V | Paste the last transcript again |

Menu bar: microphone picker, model (Flash-Lite / Flash), dictation key, mute other audio while
dictating, sounds, launch at login, retry last failed dictation, setup guide.

```
Fn down → read focused app + text before cursor (Accessibility) → record mic @16 kHz mono, mute other audio
Fn up   → m4a → OpenRouter (Gemini 3.5 Flash-Lite, audio in) → ASR + romanization + cleanup in one call
        → strip leftover fillers → paste via lazy clipboard + ⌘V (detects failed pastes) → restore clipboard
```

## Install for daily use

```bash
mac/install.sh
```

This builds, copies the app to `/Applications/FlowClone.app`, and opens it. The Setup Guide opens until
Microphone, Accessibility and the API key are all set. Then turn on **Launch at Login** from the menu.

Permissions survive updates only with a stable signing identity. Sign into Xcode with a free Apple ID
(Settings › Accounts) to get an "Apple Development" certificate, and `build.sh` will use it
automatically. With ad-hoc signing, re-enable Accessibility after each install.

## Build & run (development)

```bash
mac/build.sh && open mac/build/FlowClone.app
```

Also set **System Settings › Keyboard › "Press 🌐 key to" → Do Nothing**. Otherwise Fn opens the
emoji picker or Apple Dictation.

## Config (`~/Library/Application Support/FlowClone/config.env`)

| Key | Default | |
|---|---|---|
| `OPENROUTER_API_KEY` | — | required |
| `MODEL` | `google/gemini-3.5-flash-lite` | `google/gemini-3.5-flash` is more accurate but costs about 25× more |
| `HOTKEY` | `fn` | `right_option`, `right_command`, `right_control` (or pick from the menu) |
| `DICTIONARY` | — | comma-separated names/terms to spell exactly, e.g. `Shiladitya, Cooch Behar, OpenRouter` |
| `SEND_CONTEXT` | `1` | `0` stops sending app name and text-before-cursor to OpenRouter |
| `MIC` | system default | input device UID (set from the menu) |
| `MUTE_AUDIO` | `1` | mute other audio while recording |
| `SOUNDS` | `1` | start/stop sounds |

Changes to the file apply the next time you open the menu bar menu (no restart).
Every dictation is logged to `history.jsonl` in the same folder, with audio length, latency and text.

## Fast dev loop

```bash
mac/dev.sh
```

This rebuilds, stops any running copy, and runs FlowClone in the foreground with logs. Launched this way,
macOS charges Microphone and Accessibility to **your terminal app**, so rebuilds no longer reset them.
Grant your terminal (Terminal, iTerm, Ghostty…) both permissions once. Press Ctrl+C to quit. Each
dictation prints `[audio → latency] App: text`.

`dev.sh` also sets `SAVE_AUDIO=1`, so every real dictation is saved to
`~/Library/Application Support/FlowClone/recordings/` (`.m4a` audio plus `.out.txt` with what was typed).

**Changing the prompt without rebuilding:** put a system prompt in
`~/Library/Application Support/FlowClone/prompt.txt`. It's re-read on every dictation. Delete the file to go back to the
built-in prompt in `Sources/Transcriber.swift`.

**Replaying without speaking:** this runs the real pipeline on files or folders, in parallel:

```bash
mac/build/FlowClone.app/Contents/MacOS/FlowClone --transcribe clips/ "$HOME/Library/Application Support/FlowClone/recordings"
```

If a `name.txt` exists next to `name.m4a`, it's shown as the reference. Environment variables override
`config.env`, e.g. `MODEL=google/gemini-3.5-flash … --transcribe clips/` or `FORMAT=wav`.
For WER (word error rate) scoring across many models, use `node scripts/hinglish-bench.mjs clips/*.m4a`.

## Known MVP limits

- No streaming: text appears about 2–3 s after you release the key.
- Recordings under 0.35 s or near-silent are dropped without calling the API.
- Cmd+V uses the US key position, so non-QWERTY layouts may need a fix.
- No command mode, snippets, or per-app style yet (Phase 2 in `docs/roadmap.md`).
