# grabthis (macOS)

Push-to-talk screenshot + dictation overlay for macOS with AI integration, inspired by [boring.notch](https://github.com/TheBoredTeam/boring.notch).

## What it does
- Hold `fn` (or fallback hotkey) to start a session
- Captures the active window screenshot
- Shows live transcription in a floating notch overlay
- On release: copies transcript and attempts auto-insert into the active app
- Send screenshot + transcript to AI (Gemini 3 Flash) for context-aware responses
- Multi-turn chat conversations with voice or text input

## Features

### Notch UI (boring.notch inspired)
- **Single continuous black island** that extends from the hardware notch
- **Grow-from-top animation** when expanding (content scales from 0.8 to 1.0, anchored at top)
- **First-launch rainbow glow animation** - traces the notch perimeter on app start
- **Split listening mode** on MacBooks with notch - pulsing dot on left, audio visualizer on right
- **Smooth state transitions** between idle, listening, processing, and response states
- **Hover to expand** - hover over closed notch to see last session or full controls

### Now Playing (boring.notch style)
- **Dynamic notch wings** - album art on left, visualizer on right when music plays
- Supports **Apple Music** and **Spotify**
- **Expanded view on hover** - full album art, track info, progress bar, and controls
- Play/pause, next/prev, shuffle, repeat, seek, and volume controls
- Toggle in Settings → Media

### AI Integration
- **Gemini 3 Flash Preview** (`gemini-3-flash-preview`) for fast, context-aware responses
- Screenshot analysis with transcript for visual context
- Multi-turn conversation support with chat UI
- Follow-up via voice (hold fn) or text input

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

### Now Playing (NowPlayingService.swift)
- Uses `MediaRemote.framework` (private API) + AppleScript fallback
- Async notification streams for Apple Music and Spotify (boring.notch pattern)
- `NowPlayingCompactView` - wings layout (album art + visualizer)
- `NowPlayingExpandedView` - full player with controls and progress

### Animation Components
- `NotchGlowAnimation` - Rainbow glow that traces the notch perimeter
- `AudioSpectrumView` - 4-bar animated visualizer for music playback
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
