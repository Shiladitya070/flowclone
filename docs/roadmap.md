# FlowClone: from MVP to daily driver

Based on what's in Wispr Flow 1.6 (see `wispr-flow-analysis.md`) and what a single-user Mac app actually needs.

## Architecture decision

Wispr is an Electron UI with a native Swift helper (about 300 MB of Chromium) because it ships on four platforms.
FlowClone only needs macOS, so it **stays one native Swift app** and adds **SwiftUI** windows for
settings, onboarding and history. Same capabilities, a fraction of the RAM, and no IPC layer.

```
FlowClone.app (Swift, menu bar, LSUIElement)
├─ HotkeyManager    hold / double-tap lock / Esc cancel        ← Wispr: keybind gestures doubleTap, holdStart/holdEnd, EscapeMode
├─ AudioCapture     mic picker, device changes, media pause    ← Wispr: MediaRemoteAdapter, shouldPauseAudio/shouldMuteAudio
├─ ContextReader    app, before/after cursor, selection        ← Wispr: Context{app, textbox, vocabulary}
├─ Transcriber      OpenRouter (Flash-Lite, opt-in Flash)      ← Wispr: TranscriptionService (ASR + formatter)
├─ TextInserter     AX set → clipboard+⌘V → verify → restore   ← Wispr: "direct AXValue set… falling back to clipboard paste"
├─ Store            SQLite: history, dictionary, snippets      ← Wispr: flow.sqlite, StaticVocabulary, Replacements
└─ UI (SwiftUI)     overlay pill, onboarding, settings, history ← Wispr: overlay / hub renderers, FlowPermissionGuide.app
```

## Phase 1: daily driver (reliability + feel) ✅ done

| # | Feature | Why | Wispr equivalent |
|---|---|---|---|
| 1 | **Stable code signature + install to /Applications + launch at login** (`SMAppService`) | Permissions survive updates; starts when the Mac starts | Signed app, `openAtLogin` |
| 2 | **Onboarding window** with live permission status (Mic, Accessibility) and the "🌐 key: Do Nothing" tip | Fixes the first-run pain | `FlowPermissionGuide.app` |
| 3 | **Hands-free mode**: double-tap Fn to lock recording on, tap again to stop; **Esc cancels** | Long dictations without holding a key | `doubleTap` gesture, `EscapeMode` |
| 4 | **Mute other audio while dictating**, restore after (pausing needs private MediaRemote APIs) | Cleaner audio, less annoying | MediaRemoteAdapter, `shouldPauseAudio` |
| 5 | **Mic picker** + survive AirPods connecting/disconnecting | Daily reality | mic selection |
| 6 | **Robust insertion**: try AX direct insert, fall back to paste, detect failed paste, skip clipboard restore if you copied something meanwhile | No lost text, no clobbered clipboard | failed-paste timer, `DisableClipboardRestore` |
| 7 | **"Paste last transcript"** shortcut + menu item, **retry** a failed dictation from saved audio | Nothing is ever lost | `PasteLastTranscript` |
| 8 | **Overlay animations**: spring in/out, live waveform, shimmer while transcribing, success tick | Feels finished | overlay renderer |
| 9 | Sounds on/off | Preference | `soundEffects` |

## Phase 2: gets smarter

| # | Feature | Wispr equivalent |
|---|---|---|
| 10 | **Settings + History window** (search, copy, re-run with Flash, cost and latency stats) | Hub |
| 11 | **Dictionary + snippets** ("my email" → expands; names spelled right) | `StaticVocabulary`, `Replacements`, snippets |
| 12 | **Auto-learn from your edits**: after pasting, watch the field briefly; words you correct go into the dictionary | "capture edits of a dictated text" |
| 13 | **Per-app style**: casual in WhatsApp/Slack, formal in Mail/Docs | `StyleConfig`, `override_style` |
| 14 | **Command mode**: select text, hold a different key, say "make this shorter / translate to Hindi" | Command mode |

## Phase 3: speed and polish

- Chunked transcription while speaking (only the last few seconds are left at key-up).
- SQLite store replacing `history.jsonl`; usage dashboard with monthly cost.
- Crash/error log file; Sparkle auto-update only if you share the app.

## Out of scope

Meeting notetaker, teams/enterprise, cloud sync, mobile apps.
