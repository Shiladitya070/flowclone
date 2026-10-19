# FlowClone

**I didn't want to pay for dictation, so I built it.** FlowClone is a Wispr Flow–style dictation app for macOS. I built it as an experiment with Claude. Hold **Fn**, speak in any mix of English, Hindi and Bengali, and clean text appears wherever your cursor is. Transcription happens in the cloud through your own [OpenRouter](https://openrouter.ai) key.

- **About 2 s** from releasing Fn to text in your app
- **Under $2 a month** for heavy daily use (Gemini 3.5 Flash-Lite)
- **34 MB idle, 0% CPU**: native Swift, no bundled browser, no local model
- Hold-to-talk, hands-free mode, dictionary, snippets, per-app style, history with retry

> Unofficial and independent. Not affiliated with or endorsed by Wispr. "Wispr Flow" is a trademark of its owner.

## Why

I loved Wispr Flow but didn't want another subscription for something I suspected I could build. I also didn't want the open-source local apps, because they run models on your Mac and eat resources. I wanted cloud transcription that's fast and cheap, on a key I control. OpenRouter now serves 25+ transcription models behind one API. So the experiment was: decompile the Wispr Flow app on my Mac, understand how it works, and rebuild the parts I use with Claude. It worked, and I've dictated most of this project into itself.

It's done its job as an experiment. **Take it, rebuild it, make it yours.**

## Install

One line in Terminal (no "can't be opened" warning):

```bash
curl -fsSL https://raw.githubusercontent.com/Shiladitya070/flowclone/main/site/install.sh | bash
```

Or download `FlowClone.zip` from [Releases](../../releases/latest), move the app to Applications, and use System Settings › Privacy & Security › **Open Anyway**. The Setup Guide then asks for Microphone and Accessibility access and your OpenRouter API key. Recommended: System Settings › Keyboard › "Press 🌐 key to" → **Do Nothing**.

## Inviting friends (they don't need an OpenRouter account)

Give each friend their own key with a spending cap, created from your OpenRouter **management key** (put `OPENROUTER_MANAGEMENT_KEY=…` in `.env`):

```bash
node scripts/invite.mjs create "Riya"            # $2.50 cap by default; --limit 5 to change
node scripts/invite.mjs list                     # credit used per friend
node scripts/invite.mjs revoke "Riya"
```

`create` prints a message to send. It contains a one-line install command with their key built in, plus a `flowclone://setup?key=…` link for people who already have the app. Each friend's audio goes straight from their Mac to OpenRouter with zero data retention. You only see credit used per key, never content, as long as input/output logging stays **off** in your OpenRouter privacy settings.

Release builds (`mac/package.sh`) are locked to Gemini 3.5 Flash-Lite, so an invite's credit can't be drained by the ~18× pricier Flash. `LOCK_MODEL=0 mac/package.sh` builds an unlocked release.

## Build from source

Requires macOS 14+ and Xcode command-line tools.

```bash
git clone https://github.com/Shiladitya070/flowclone && cd flowclone
echo "OPENROUTER_API_KEY=sk-or-..." > .env   # copied into the app's config on first build
mac/install.sh                               # build, install to /Applications, launch
```

Development loop and testing tools are described in [mac/README.md](mac/README.md).

## What's in the repo

| Path | What |
|---|---|
| [`mac/`](mac) | The app: Swift + SwiftUI, built with plain `swiftc` (no Xcode project) |
| [`site/`](site) | The landing page (single static `index.html`, ready for GitHub Pages) |
| [`docs/wispr-flow-analysis.md`](docs/wispr-flow-analysis.md) | How Wispr Flow works (from decompiling it), language benchmarks, cost analysis |
| [`docs/roadmap.md`](docs/roadmap.md) | What's done and ideas for what to build next |
| [`scripts/`](scripts) | OpenRouter speech-to-text tests and a multi-model Hinglish benchmark |

## Release a download

```bash
mac/package.sh                                   # universal build → dist/FlowClone.zip
gh release create v0.1.0 dist/FlowClone.zip --title "FlowClone 0.1.0"
```

The landing page links to `releases/latest/download/FlowClone.zip`. Set your repo URL in `GITHUB_REPO` at the top of the `<script>` in `site/index.html`. To host it, set Settings › Pages › Source to **GitHub Actions**. The included workflow (`.github/workflows/pages.yml`) then publishes `site/` on every push to `main`. You can also deploy that folder to any static host.

## Ideas for your fork

Windows port · command mode ("make this shorter") · learning from your edits · streaming while you speak · tuning the prompt for your language. See [`docs/roadmap.md`](docs/roadmap.md).
