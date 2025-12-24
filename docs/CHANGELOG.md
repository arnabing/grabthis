# Changelog

## Recent Changes: Notch UI Refactor (Single Continuous Black Island)

### What Changed

**Commit: `8dbccbc` - "Notch: single continuous black island"**

We refactored the notch UI to match `boring.notch`'s core design principle: **one continuous black island** that visually integrates with the MacBook's notch, instead of two separate pills.

### Files Modified

1. **`Sources/GrabThisApp/UI/OverlayPanel.swift`**
   - **Removed**: `SplitNotchIsland` component (two-pill layout with visible gap)
   - **Added**: `NotchIsland` component (single continuous black capsule)
   - **Changed**: Layout now uses a single `RoundedRectangle` with pure black fill (`Color.black`)
   - **Changed**: Content is split left/right of a reserved center zone (for notch cutout on built-in displays)
   - **Changed**: `centerReserveWidth` is now computed per-screen (built-in vs external heuristic)
   - **Kept**: Glow animations, audio visualizer, hover effects, auto-dismiss behavior

2. **`Sources/GrabThisApp/AppState.swift`**
   - **Removed**: `notchGapWidth` property and `Keys.notchGapWidth` (no longer needed)
   - **Removed**: UserDefaults persistence for notch gap width

3. **`Sources/GrabThisApp/SettingsView.swift`**
   - **Removed**: Entire "Notch UI" section with notch gap width slider
   - **Kept**: General, History, Privacy sections

### Design Intent

- **Built-in displays (with notch)**: Single black island wider than the notch, with content left/right of the center cutout
- **External displays (no notch)**: Smaller centered bar with no empty center gap (content can span across)
- **Always-on idle state**: Island remains visible as a small chip when not in use
- **Pure black background**: Matches `boring.notch`'s visual illusion

### Known Issues (Current State)

**These issues were reported after the refactor and need to be fixed:**

1. **Positioning is wrong**
   - Island appears **below the notch** instead of at the top
   - Current code: `y = full.maxY - topInset + 6 - height`
   - Problem: `safeAreaInsets.top` is too large on notched displays, pushing the island down
   - **Fix needed**: Use simpler positioning (e.g., `y = full.maxY - height` with minimal offset) like `boring.notch` does

2. **Island is too wide (3× expected size)**
   - Current hardcoded widths: 560pt for idle/listening
   - Problem: Should be much smaller to match notch proportions
   - **Fix needed**: Reduce default widths and make them responsive to screen size

3. **Text is cut off / black areas visible in content**
   - Problem: On external displays, we're still reserving center space (120pt), which shrinks left/right columns
   - Problem: Transcript text gets truncated and looks like "black is covering text"
   - **Fix needed**: 
     - External displays: `centerReserveWidth = 0` (no gap, content can span)
     - Built-in displays: Keep reserved center, but ensure left/right columns have enough space for content
     - Improve text truncation handling (maybe `.lineLimit(2)` or scrollable)

### Next Steps

1. **Audit `boring.notch` source code** to understand their exact positioning/sizing approach
2. **Fix positioning**: Remove `safeAreaInsets.top` subtraction, use simpler top-anchored math
3. **Fix sizing**: Reduce default widths, make external displays smaller with no center gap
4. **Fix text layout**: Ensure transcript has enough space, handle truncation gracefully

### Technical Details

**Current positioning logic** (`OverlayPanelController.positionPanel`):
```swift
let topInset = screen.safeAreaInsets.top
let y = full.maxY - topInset + 6 - clampedSize.height
```

**Current center reserve logic** (`centerReserveWidth(for:)`):
```swift
let isBuiltIn = name.contains("built") || name.contains("color lcd") || name.contains("retina")
return isBuiltIn ? 240 : 120  // Should be 0 for external!
```

**Current sizing**:
- Idle: 560×54
- Listening: 560×70
- Review: 520×260
- Processing: 360×110
- Response/Error: 520×320 / 420×140

