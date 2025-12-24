## Permissions that keep “resetting” after rebuilds (TCC persistence)

macOS privacy permissions (TCC) for **Microphone**, **Speech Recognition**, **Screen Recording**, **Input Monitoring**, and **Accessibility** are tied to an app’s **bundle identifier + code signing requirement**.

If you rebuild an app and its **signing identity changes** (or it becomes **unsigned**), macOS can treat it as a different app and you’ll be prompted again.

This is the main reason apps built as a normal Xcode project tend to “just work” here: Xcode signs with a consistent Apple Development identity by default (similar to how [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) is set up).

### Recommended grabthis dev loop (stable permissions)

1. **Run only the bundled `.app`** (not a raw SwiftPM executable from DerivedData).
2. Make sure you do not have multiple copies (e.g. one in `/Applications` and one in `build/`). If you do, macOS permissions may be toggled for one copy while you’re launching the other.
2. Ensure you have an **Apple Development** certificate installed (Xcode → Settings → Accounts → Manage Certificates).
3. Set a stable signing identity once:

```bash
export GRABTHIS_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

4. Build & package:

```bash
scripts/build_app_bundle.sh
open "/Users/arnab/Development/grabthis/build/GrabThisApp.app"
```

5. Grant permissions in System Settings when prompted.

### How to confirm it’s stable

On launch, grabthis logs code signing info (team id, signing id). If it logs **unsigned**, your permissions will not persist across rebuilds.

### If Screen Recording was enabled but screenshots still fail
macOS often requires **quit & relaunch** after toggling Screen Recording.


