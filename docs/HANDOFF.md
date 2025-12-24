# Handoff: Notch UI Fixes Needed

## Context

We've built a macOS app (`grabthis`) that shows a floating overlay UI when the user holds `fn` to capture screenshots + dictation. The overlay uses a "notch island" design inspired by `boring.notch` (single continuous black bar that integrates with the MacBook's notch).

## What We Just Changed

**Commit `8dbccbc`**: Refactored from a two-pill split layout to a single continuous black island.

**Files changed**:
- `Sources/GrabThisApp/UI/OverlayPanel.swift` - Main overlay controller and UI components
- `Sources/GrabThisApp/AppState.swift` - Removed `notchGapWidth` setting
- `Sources/GrabThisApp/SettingsView.swift` - Removed notch gap slider

## Current Problems

The user reported three issues:

1. **Island is in the wrong place**: It appears **below the notch** instead of at the very top
2. **Island is too wide**: It's approximately **3× the size it should be**
3. **Text is cut off**: Content gets clipped, and there are visible black areas within the text region

## What We Need

**Audit `boring.notch` source code** and port their exact positioning/sizing approach to fix these issues.

### Key Questions

1. **Positioning**: How do they calculate the Y position? (We're currently using `y = full.maxY - topInset + 6 - height` which is wrong)
2. **Sizing**: What are their default widths? (We're using 560pt which is too large)
3. **Center gap**: 
   - Built-in displays: What's the exact reserved width for the notch?
   - External displays: Should there be NO center gap? (We're currently reserving 120pt which causes clipping)

## Files to Inspect

**In `boring.notch` repo**:
- Look for window/panel creation code (likely `NotchWindow.swift`, `NotchPanel.swift`, or similar)
- Find positioning logic (search for `setFrame`, `safeAreaInsets`, `frame.maxY`)
- Find sizing logic (search for width calculations, screen clamping)
- Find screen detection (built-in vs external)

**In our codebase**:
- `Sources/GrabThisApp/UI/OverlayPanel.swift`:
  - `positionPanel(size:)` - Lines 155-174 (needs Y fix)
  - `centerReserveWidth(for:)` - Lines 176-182 (external should return 0)
  - `presentIdleChip()` - Line 57 (width: 560, should be smaller)
  - `presentListening(...)` - Line 66 (width: 560, should be smaller)
  - `NotchIsland` - Lines 311-363 (layout needs text clipping fix)

## Expected Outcome

After fixes:
- Island appears at the very top of the screen (aligned with notch on built-in displays)
- Island width is reasonable (~200-300pt idle, ~300-400pt listening)
- Built-in display: Center gap visible, content left/right of notch
- External display: No center gap, content spans across
- Transcript text doesn't get cut off

## How to Proceed

1. Clone `boring.notch` locally (or ask user if they've already done this)
2. Find their window positioning/sizing code
3. Compare to our `OverlayPanelController.positionPanel()` and `NotchIsland`
4. Port the exact approach
5. Test on both built-in and external displays

## Additional Context

- We're using `NSPanel` with `.statusBar` level for idle/listening states
- We're using SwiftUI for the UI (`NotchIsland` is a SwiftUI view)
- The island should be "always on" (idle chip visible when not in use)
- Pure black background (`Color.black`) to match `boring.notch`'s illusion

