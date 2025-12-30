# GrabThis (macOS)

Push-to-talk dictation overlay for macOS with AI integration, inspired by [boring.notch](https://github.com/TheBoredTeam/boring.notch).

## What it does
- Hold `fn` (or fallback hotkey) to start a session
- Shows live transcription in a floating notch overlay
- On release: copies transcript and attempts auto-insert into the active app
- Optional: Send transcript + screenshot to AI (Gemini 3 Flash) for context-aware responses
- Multi-turn chat conversations with voice or text input

## Features

### Notch UI (boring.notch inspired)
- **Single continuous black island** that extends from the hardware notch
- **Grow-from-top animation** when expanding (content scales from 0.8 to 1.0, anchored at top)
- **First-launch rainbow glow animation** - traces the notch perimeter on app start
- **Tab-based navigation** - Switch between Voice AI and Now Playing with visual tabs
- **Split listening mode** on MacBooks with notch - pulsing dot on left, audio visualizer on right
- **Smooth state transitions** between idle, listening, processing, and response states
- **Hover to expand** - hover over closed notch to see last session or full controls

### Now Playing (boring.notch style)
- **Dynamic notch wings** - album art on left, 4-bar audio visualizer on right
- **iOS 26-style morph** - album art morphs into mic icon during dictation
- Supports **Apple Music** and **Spotify**
- **Expanded view on hover** - large album art (100x100), track info, progress bar, and controls
- Play/pause, next/prev, seek controls
- **Auto-pause during dictation** - music pauses automatically when you hold fn, resumes after
- Toggle in Settings → Media

### AI Integration
- **Gemini 3 Flash Preview** (`gemini-3-flash-preview`) for fast, context-aware responses
- Screenshot analysis with transcript for visual context
- Multi-turn conversation support with chat UI
- Follow-up via voice (hold fn) or text input

### Transcription
- **macOS 26+**: On-device `SpeechAnalyzer` with `DictationTranscriber` for fast, private transcription with automatic punctuation
- **macOS 14-15**: Cloud-based `SFSpeechRecognizer` fallback
- **Anti-regression**: Tracks longest partial to prevent text from disappearing during re-evaluation
- **Graceful stop**: Captures audio tail after key-up for complete words

### Auto-insert (Cursor-friendly)
- Skip activation if Cursor is already frontmost
- Prefer robust Cmd+V injection (Cmd-down -> V-down/up -> Cmd-up)
- Skip menu-based paste for Cursor (avoids menu bar flicker)

## Building / Running

Use the packaged `.app` bundle (not a raw SwiftPM executable) so macOS permissions behave correctly:

```bash
export GRABTHIS_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
scripts/build_app_bundle.sh
open "build/GrabThisApp.app"
```

## Permissions / TCC

If permissions feel "lost" or you keep seeing prompts, it's almost always **app identity** (bundle id + signing) or launching multiple copies of the app. See:

- `docs/permissions.md`

## Architecture

### Overlay Panel (OverlayPanel.swift)
Uses the **boring.notch pattern** for animations:
- Header is ALWAYS present (content changes based on state)
- Body is ADDED when open (with `.transition(.scale(scale: 0.8, anchor: .top))`)
- `effectiveClosedWidth` dynamically expands for Now Playing wings
- This ensures transitions fire correctly on every open/close cycle

### Tab System (NotchCoordinator.swift)
- `NotchPage` enum: `.transcription` (Voice AI) or `.nowPlaying`
- `NotchCoordinator` manages page state and music auto-detection
- `NotchTabBar` provides visual tab switching in expanded view
- Auto-switches to Now Playing when music starts (if on Voice AI tab)

### Now Playing (NowPlayingService.swift)
- Uses `MediaRemote.framework` (private API) + AppleScript fallback
- Async notification streams for Apple Music and Spotify (boring.notch pattern)
- `NowPlayingCompactView` - wings layout (album art + visualizer)
- `NowPlayingExpandedView` - iOS 26-style player with large album art, controls, and progress

### Animation Components
- `NotchGlowAnimation` - Rainbow glow that traces the notch perimeter
- `AudioSpectrumView` - 4-bar animated visualizer matching boring.notch (CABasicAnimation with autoreverses)
- Rainbow gradient: blue -> purple -> red -> mint -> indigo -> pink -> blue

## Troubleshooting

### Auto-insert doesn't paste into Cursor
Auto-insert uses a few strategies (AX insert, Edit -> Paste menu press, Cmd+V). Make sure:
- System Settings -> Privacy & Security -> Accessibility: **grabthis ON**
- Cursor is focused in an editor at key-up.

To inspect what happened:

```bash
log show --last 5m --predicate 'process == "GrabThisApp" && (category == "autoInsert" || category == "session")' --style compact | tail -n 220
```

### Reset first-launch animation
To see the glow animation again, quit and relaunch the app (it runs once per session).

### Now Playing not showing
1. Make sure **Settings → Media → Show Now Playing** is enabled
2. Play music in Apple Music or Spotify
3. Check debug logs:
```bash
log show --last 2m --predicate 'process == "GrabThisApp"' --style compact | grep "🎵"
```

### Settings
Open settings from the menu bar icon or use Cmd+, when the app is focused.

### Crash with long transcripts
If the app crashes with very long transcripts, check the console:
```bash
log show --last 5m --predicate 'process == "GrabThisApp"' --style compact | tail -n 100
```
Report any crash logs as GitHub issues.
