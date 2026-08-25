# HUD module — feasibility findings

**Date:** 2026-08-22 · **Verified on:** macOS 26.6.2, MacBook Air M5

Findings from a throwaway spike before writing the HUD spec. The probes
were deleted; this is the record.

## Summary

The **observation half is solved and better than the spec assumed**. The
**suppression half has no known solution on macOS 26** — which is why the
HUD was deferred and the file shelf built first.

## Volume — solved, public API, no permission

`AudioObjectAddPropertyListenerBlock` on the default output device's
`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`.

```
AudioObjectAddPropertyListenerBlock status: 0 (OK)
  [+ 547ms] volume listener fired -> 0.300
  [+1080ms] volume listener fired -> 0.450
```

- **No permission prompt.** CoreAudio is not TCC-gated.
- `VirtualMainVolume` and `kAudioDevicePropertyVolumeScalar` both read
  correctly; `kAudioDevicePropertyMute` is separate.
- ⚠️ **Fires twice per change** — 8 callbacks for 4 changes. Needs
  coalescing, or the HUD will flicker.
- ⚠️ Must re-subscribe when the default output device changes.
- ⚠️ `AudioObjectRemovePropertyListenerBlock` is reported unreliable; the
  `AudioObjectPropertyListenerProc` form is the documented workaround.

## Brightness — works, private API, no permission

`DisplayServicesRegisterForBrightnessChangeNotifications`, with the value
read via `DisplayServicesGetBrightness`.

```
register status: 0 (OK)
3 notifications for 3 changes — no double-firing
```

- **No permission prompt.** Fires exactly once per change.
- ⚠️ **The callback's `CGDirectDisplayID` argument is `0`**, not a valid
  display. The signature commonly assumed online is wrong. Reading with the
  passed ID returns `status=1000` and writes nothing; reading with
  `CGMainDisplayID()` returns the correct level. This cost three probes to
  find.
- ⚠️ The callback runs **off the main thread**.
- `CoreDisplay_Display_GetUserBrightness` returned `1.0` regardless of the
  real level — wrong semantics, do not use it.

## Why this beats the spec's plan

The spec assumed intercepting `.systemDefined` key events (subtype 8).
Observation is better on every axis:

| | Key interception | Value observation |
|---|---|---|
| Permission | Accessibility required | **None** |
| Coverage | Physical keys only | Keys, Control Center, menu bar, Siri, external keyboards, other apps |
| Mechanism | Global event monitor | Push callbacks |

The practical consequence: **the HUD needs no Accessibility permission at
all.** Onboarding only has to ask for it when the file shelf's drag
detection arrives.

## Suppression — no known solution

The spec's plan was to stop `OSDUIHelper`. That is obsolete.

- **`OSDUIHelper` never launches on macOS 26.** Confirmed across two
  separate rounds of pressing volume and brightness keys: `active count = 0`,
  `state = not running` throughout. The binary and its LaunchAgent still
  exist, but nothing starts them.
- **Apple's HUD still appears** — confirmed visually by the user.
- **Control Center is not drawing it.** Neither `ControlCenter` nor
  `DisplayControls.appex` accrued any CPU while keys were pressed.
- **`WindowServer` moved 3.49s**, the top legitimate mover. Suggestive but
  **not conclusive**: pressing brightness keys physically changes the
  display, which would spin WindowServer regardless.
- **No suppression API found.** `SLSSetOSDVisibility`, `CGSSetOSDVisibility`,
  `SLSOSDSetVisibility`, `SLSSetDisplayOSDEnabled`,
  `CGSSetDisplayOSDVisibility`, `SLSHideOSD`, `SLSShowOSD`,
  `SLSSetSystemUIVisibility` — none resolve in SkyLight.
  `OSDSetVisibility`, `OSDManagerSetVisibility`, `_OSDDisable` — none
  resolve in `OSD.framework`, though the framework does load.

If suppression is revisited, the unexplored leads are: enumerating
`OSD.framework`'s actual exports from the dyld shared cache, and examining
how a currently-shipping HUD replacement does it on macOS 26.

## Recommendation — superseded 2026-08-25

The original conclusion was to wait until suppression was understood. **The
goal changed instead: the two HUDs coexist**, and suppression left scope
entirely. See [`../specs/2026-08-25-system-hud-design.md`](../specs/2026-08-25-system-hud-design.md).

The reframing holds up better than a concession would suggest. Apple's HUD
appears **only for the physical keys** — confirmed here: a programmatic
volume change never spawned it. Value-based observation sees every change
whatever caused it. So the notch covers Control Center, Siri, the menu bar
slider and other applications, where macOS currently gives no feedback at
all, and the only genuine overlap is the keypress case — which the module
deliberately stays silent for.

The findings above stand unchanged; only the conclusion drawn from them
moved.
