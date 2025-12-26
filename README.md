# grabthis (macOS)

Push-to-talk screenshot + dictation overlay for macOS, inspired by [boring.notch](https://github.com/TheBoredTeam/boring.notch).

## What it does
- Hold `fn` (or fallback hotkey) to start a session
- Captures the active window screenshot
- Shows live transcription in a floating notch overlay
- On release: copies transcript and attempts auto-insert into the active app
- Optional: Send screenshot + transcript to an LLM (WIP)

## Features

### Notch UI (boring.notch inspired)
- **Single continuous black island** that extends from the hardware notch
- **Grow-from-top animation** when expanding (content scales from 0.8 to 1.0, anchored at top)
- **First-launch hello animation** - glowing rainbow snake traces "hello" on first app start
- **Split listening mode** on MacBooks with notch - pulsing dot on left, audio visualizer on right
- **Smooth state transitions** between idle, listening, processing, and response states

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
- This ensures transitions fire correctly on every open/close cycle

### Animation Components (HelloAnimation.swift)
- `HelloShape` - Custom bezier path that draws cursive "hello"
- `GlowingSnake` - Animatable view with trim + multi-layer blur glow
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
To see the hello animation again:
```bash
defaults delete com.grabthis.app hasShownFirstHint
```
Then relaunch the app.
