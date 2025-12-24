# grabthis (macOS)

Push-to-talk screenshot + dictation overlay for macOS.

## What it does
- Hold `fn` (or fallback hotkey) to start a session
- Captures the active window screenshot
- Shows live transcription in a floating “liquid glass” overlay
- On release: copies transcript and attempts auto-insert into the active app (Cursor-friendly fallbacks)
- Optional: Send screenshot + transcript to an LLM (WIP)

## Wispr-like “smooth auto-insert” notes (Cursor)
Cursor (Electron) can behave differently than native apps:
- Some Accessibility “text set” APIs may report success without actually committing text in the editor.
- Menu-based paste attempts can cause **visible menu bar flicker**.
- The app can be “frontmost” before the editor/caret is ready to receive input.

To match Wispr Flow’s feel (fast + invisible), our approach is:
- **Avoid menu interaction** for Cursor (no Edit/Paste menu opening).
- **Avoid activation churn**: if Cursor is already frontmost, do not re-activate it.
- Prefer **robust Cmd+V injection** (Cmd-down → V-down/up → Cmd-up with tiny delays + retries).
- Keep clipboard correct for manual ⌘V, but (optional) **restore clipboard** after auto-insert to avoid clobbering the user’s clipboard (Wispr-like).

## Current Status

### Notch UI (Recent Changes)

We've refactored the overlay to use a **single continuous black island** (matching `boring.notch`'s design), but there are **known issues** that need fixing:

1. **Positioning**: Island appears below the notch (should be at the very top)
2. **Sizing**: Island is ~3× too wide
3. **Text clipping**: Content gets cut off, black areas visible

**Next step**: Audit `boring.notch` source code to understand their exact positioning/sizing approach, then port it to our `OverlayPanelController`.

See:
- `docs/CHANGELOG.md` - Recent changes summary
- `docs/NOTCH_UI_STATUS.md` - Detailed status and next steps

### Auto-insert (Cursor)

Auto-insert is working for most apps (Notion, etc.) but can be finicky in Cursor. Current approach:
- Skip activation if Cursor is already frontmost
- Prefer robust Cmd+V injection (Cmd-down → V-down/up → Cmd-up)
- Skip menu-based paste for Cursor (avoids menu bar flicker)

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


