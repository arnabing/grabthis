
<p align="center">![gif](https://github.com/user-attachments/assets/e90c4d2c-2e82-463b-ad6d-fa9fc8a602ae)</p>


<h1 align="center">GrabThis</h1>

<p align="center">
  <b>Push-to-talk voice AI that lives in your notch</b><br>
  Hold fn, speak, release — your words appear exactly where you need them.
</p>

<p align="center">
  <a href="https://github.com/arnabing/grabthis/releases">
    <img src="https://img.shields.io/badge/Download-DMG-blue?style=for-the-badge" alt="Download DMG"/>
  </a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=for-the-badge" alt="macOS 14+"/>
  <img src="https://img.shields.io/badge/Swift-6-orange?style=for-the-badge" alt="Swift 6"/>
</p>

---

## What is GrabThis?

GrabThis transforms your MacBook's notch from a camera cutout into a **voice-powered AI assistant**. Hold the `fn` key, speak naturally, and watch your words flow directly into any app. Need more? Send your transcript + a screenshot to AI for context-aware responses.

It's like having a personal stenographer who also happens to be connected to an AI brain.

---

## Features

### Voice Dictation
- **Push-to-talk** — Hold `fn` to record, release to transcribe & auto-insert
- **On-device transcription** — Fast, private speech recognition (macOS 26+)
- **Auto-punctuation** — Proper capitalization and punctuation, no "period" needed
- **Smart auto-insert** — Pastes directly into the active app (Cursor, VS Code, browsers, etc.)

### AI Integration
- **Screenshot + voice context** — Ask AI about what's on your screen
- **Multi-turn conversations** — Follow up with voice or text
- **Gemini Flash** — Fast responses powered by Google's latest model

### Now Playing (boring.notch style)
- **Dynamic notch wings** — Album art on left, audio visualizer on right
- **Apple Music & Spotify** — Full playback controls in the notch
- **Auto-pause during dictation** — Music pauses when you talk, resumes when done

### Beautiful UI
- **Seamless notch integration** — Grows naturally from your MacBook's hardware notch
- **Rainbow glow animation** — First-launch delight that traces the notch perimeter
- **Tab navigation** — Switch between Voice AI and Now Playing
- **Hover to expand** — See your last session or full controls on hover

---

## Installation

### Download (Recommended)

1. Download the latest `.dmg` from [**Releases**](https://github.com/arnabing/grabthis/releases)
2. Drag **GrabThis.app** to Applications
3. Open and grant permissions when prompted (Accessibility, Microphone, Screen Recording)

> **Note:** On first launch, macOS may show a security dialog. Right-click the app → Open → Open to bypass Gatekeeper.

### Build from Source

```bash
# Clone the repo
git clone https://github.com/arnabing/grabthis.git
cd grabthis

# Build and run (requires Xcode 16+)
export GRABTHIS_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
./scripts/build_app_bundle.sh
open build/GrabThisApp.app
```

**Requirements:**
- macOS 14+ (Sonoma or later)
- macOS 26+ recommended for on-device transcription
- Xcode 16+ for building from source

---

## Permissions

GrabThis needs a few permissions to work its magic:

| Permission | Why |
|------------|-----|
| **Accessibility** | Auto-insert text into apps |
| **Microphone** | Voice transcription |
| **Screen Recording** | Screenshot context for AI |

If permissions feel stuck, see [docs/permissions.md](docs/permissions.md).

---

## Troubleshooting

<details>
<summary><b>Auto-insert doesn't work in Cursor</b></summary>

Make sure:
- System Settings → Privacy & Security → Accessibility → **GrabThis ON**
- Cursor is focused in an editor when you release `fn`

Debug logs:
```bash
log show --last 5m --predicate 'process == "GrabThisApp"' --style compact | tail -n 100
```
</details>

<details>
<summary><b>Now Playing not showing</b></summary>

1. Enable in **Settings → Media → Show Now Playing**
2. Play music in Apple Music or Spotify
3. Check logs: `log show --last 2m --predicate 'process == "GrabThisApp"' | grep "🎵"`
</details>

<details>
<summary><b>Reset the rainbow glow animation</b></summary>

The glow animation runs once per app launch. Quit and reopen to see it again.
</details>

---

## Inspiration & Credits

GrabThis stands on the shoulders of some incredible projects:

- **[boring.notch](https://github.com/TheBoredTeam/boring.notch)** — The OG notch app that proved the MacBook notch could be beautiful. Our Now Playing wings, animation patterns, and overall notch philosophy are directly inspired by their work.

- **[Alcove](https://tryalcove.com/)** — Showed us that the notch could be more than a media player — it could be a productivity powerhouse.

- **[Wispr Flow](https://wisprflow.ai/)** — The gold standard for voice-to-text on Mac. Their push-to-talk UX inspired our `fn` key interaction model.

---

## License

MIT — Use it, fork it, make it yours.

---

<p align="center">
  Made with ❤️ by Arnab Raychaudhuri
</p>
