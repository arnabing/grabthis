# Notch UI Status & Next Steps

## Current State

We've implemented a **single continuous black island** UI (matching `boring.notch`'s design principle), but there are **three critical issues** that need to be fixed:

1. **Positioning**: Island appears below the notch instead of at the top
2. **Sizing**: Island is ~3× too wide
3. **Text clipping**: Content gets cut off, black areas visible in the middle

## What We Need to Learn from `boring.notch`

### Key Questions

1. **How do they position the window?**
   - Do they use `safeAreaInsets.top` or simpler math?
   - What's their exact `y` calculation?
   - Do they use `.statusBar` level or something else?

2. **How do they size the island?**
   - What are their default widths for idle/listening states?
   - How do they handle built-in vs external displays?
   - Do they clamp to screen width differently?

3. **How do they handle the center gap?**
   - Built-in displays: What's the exact reserved width?
   - External displays: Do they reserve any center space, or is it fully continuous?
   - How do they ensure content doesn't get clipped?

4. **Window configuration**
   - `NSPanel` vs `NSWindow`?
   - Exact `styleMask` and `level` settings?
   - How do they handle multiple screens?

## Recommended Approach

1. **Clone `boring.notch` locally**:
   ```bash
   cd /Users/arnab/Development
   git clone https://github.com/TheBoredTeam/boring.notch.git
   ```

2. **Find the window/panel creation code**:
   - Look for files like `NotchWindow.swift`, `NotchPanel.swift`, `WindowController.swift`
   - Search for `NSPanel`, `NSWindow`, `.statusBar`, `setFrame`

3. **Find the positioning logic**:
   - Search for `safeAreaInsets`, `frame.maxY`, `setFrameOrigin`
   - Look for screen detection (built-in vs external)

4. **Find the sizing logic**:
   - Search for width calculations, `setContentSize`, screen width clamping

5. **Port the exact approach** to our `OverlayPanelController.positionPanel()` and `NotchIsland` component

## Files to Update

Once we understand `boring.notch`'s approach:

1. **`Sources/GrabThisApp/UI/OverlayPanel.swift`**
   - `positionPanel(size:)` - Fix Y calculation
   - `centerReserveWidth(for:)` - Fix external display logic (should return 0)
   - `presentIdleChip()` / `presentListening(...)` - Reduce default widths
   - `NotchIsland` - Fix layout to prevent text clipping

2. **Potentially `Sources/GrabThisApp/UI/OverlayPanel.swift`**
   - Window level/configuration if needed
   - Screen detection logic if current heuristic is wrong

## Testing Checklist

After fixes:

- [ ] Island appears at the very top (aligned with notch on built-in displays)
- [ ] Island width is reasonable (~200-300pt for idle, ~300-400pt for listening)
- [ ] Built-in display: Center gap is visible, content left/right of notch
- [ ] External display: No center gap, content can span across
- [ ] Transcript text doesn't get cut off or show black areas
- [ ] Works on both built-in and external displays

