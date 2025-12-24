# grabthis (macOS)

Push-to-talk screenshot + dictation overlay for macOS.

## What it does
- Hold `fn` (or fallback hotkey) to start a session
- Captures the active window screenshot
- Shows live transcription in a floating “liquid glass” overlay
- On release: copies transcript and attempts auto-insert into the active app (Cursor-friendly fallbacks)
- Optional: Send screenshot + transcript to an LLM (WIP)

## Building / Running

Use the packaged `.app` bundle (not a raw SwiftPM executable) so macOS permissions behave correctly:

```bash
export GRABTHIS_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
scripts/build_app_bundle.sh
open "build/GrabThisApp.app"
```

## Permissions / TCC

If permissions feel “lost” or you keep seeing prompts, it’s almost always **app identity** (bundle id + signing) or launching multiple copies of the app. See:

- `docs/permissions.md`

## Troubleshooting

### Auto-insert doesn’t paste into Cursor
Auto-insert uses a few strategies (AX insert, Edit → Paste menu press, Cmd+V). Make sure:
- System Settings → Privacy & Security → Accessibility: **grabthis ON**
- Cursor is focused in an editor at key-up.

To inspect what happened:

```bash
log show --last 5m --predicate 'process == "GrabThisApp" && (category == "autoInsert" || category == "session")' --style compact | tail -n 220
```


