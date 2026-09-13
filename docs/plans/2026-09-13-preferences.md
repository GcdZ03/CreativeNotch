# Preferences Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Seven switches in a window that **stop seven subsystems** — a
CoreAudio listener, a DisplayServices registration, a `CGEventTap`, a `perl`
subprocess, the project's only repeating `Timer`, a run-loop source, and a drop
target — applied the instant they change, and enforced in one place rather than
trusted to seven modules.

**Architecture:** The values and every decision about them are pure and live in
`CreativeNotchCore/Preferences/`: what an absent or mistyped key means, which
tabs exist, which tab to fall back to. `CreativeNotchUI` holds one new type,
`ModuleSwitchboard`, which is the only thing that calls a controller's
`start()`/`stop()`, and one window. The four lifecycle callers —  launch,
terminate, the `SystemActivity` fan-out, and a toggle — route through it, so
"off at launch" and "turned off at runtime" are the same code.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, Observation, Swift Testing, SwiftPM.
macOS 26+. No third-party dependencies.

**Spec:** [`docs/specs/2026-09-13-preferences-design.md`](../specs/2026-09-13-preferences-design.md).
Read it before Task 1. This plan executes it and does not re-argue it; where a
step's reasoning is one line here, the spec section named beside it is the
argument.

## Global Constraints

- **`CreativeNotchCore` imports no UI framework.** `CorePurityTests` enforces
  this, recursively, from a manifest of filenames — which is why every new Core
  file is added to that manifest in the same commit that creates it. Foundation
  is allowed, and that is what makes `UserDefaults` in Core legal (spec §5).
- **Every test asserts against the subsystem, never against the stored
  `Bool`.** `poller.scheduledInterval == nil`, `stops == 1` on the supervisor's
  injected counter, `isObserving == false`, `hud.keys.isRunning == false`. A
  test that reads back the preference it just wrote is a test of `UserDefaults`.
- **Every disable test pre-asserts that the subsystem was running, in the same
  test function.** Most of these assertions are vacuous at rest, because
  `install(metrics:)` starts nothing: no `scheduledInterval`, `isObserving`
  false, `state.nowPlaying` nil. The discipline is stated verbatim at
  `SystemActivityFanOutTests.swift:115` — *"not suspended is indistinguishable
  from resumed."* Suite order is always **install → inject fakes → apply**.
- **Every test must fail when the code it covers is deleted.** For each: apply
  the mutation, `swift build`, **confirm the build is green**, `swift test`,
  confirm your test fails, revert. A mutation that breaks the build looks
  identical to a caught bug. Nine tests shipped decorative on the media module
  despite review; `CONTRIBUTING.md:32-48` calls this the one non-negotiable
  process demand.
- **No test writes into the real defaults domain.** Every suite that builds an
  `AppDelegate` sets `preferencesDefaults` to a UUID-suffixed suite cleared with
  `removePersistentDomain`, as `OnboardingControllerTests.swift:23-28` does.
  Without it a developer who disabled media in the real app makes
  `lockingStopsTheMediaHelper` fail.
- **No `Task.sleep` in tests, no real `perl` helper, no real `CGEventTap`
  required for a test to pass.** The tap needs Accessibility; anything asserting
  on it goes through `expectOrKnownHardwareIssue`.
- **No new app-lifetime registration.** Not on `SystemActivityObserver`, not on
  the `AppState` funnel, and **not on `UserDefaults`** — there is no KVO and no
  `didChangeNotification` anywhere in `Sources/`, and this module does not
  introduce the first (spec §5).
- **`install(metrics:)` starts nothing.** Fourteen suites reach it and *then*
  inject their fakes. An `apply()` inside `install` puts a real repeating
  `Timer` in every suite in the repo and spawns a real subprocess.
- **Toggles take effect immediately.** `HUDController.swift:103` —
  `let diagnostics = HUDDiagnostics.enabledFromDefaults()` — is the in-repo
  pattern that must **not** be copied (R8).
- Conventional commit prefixes (`feat:`, `fix:`, `test:`, `refactor:`, `docs:`).
- **Baseline at the branch point (`ed6de77`): 752 tests in 85 suites, all
  passing.** Every task leaves
  the suite green.

## The decisions this plan is executing

Settled in the spec, recorded here so no step re-opens one.

| Decision | Choice | Why not the alternative |
|---|---|---|
| Surface | A separate window, on the `OnboardingWindow` pattern | The panel is a `.nonactivatingPanel` with a 400ms dismiss grace that takes key focus for one tab. A form that closes when your cursor strays is the wrong container. |
| Timer disabled mid-countdown | The tab goes, the countdown finishes and chimes | A deadline the user set is already the project's one deliberate exemption from the central gate. A preference is not a better reason to drop it than a locked screen was. |
| Disabled controllers | Kept, idle. **Not torn down** | A stopped controller's idle cost is provably zero, and `install(metrics:)` is not safely re-entrant. Teardown is a large refactor for no measurable saving. |
| Effect timing | Immediate, never next launch | Every `start()` in the repo is idempotent. "Restart for this to take effect" is a menu-bar utility admitting its settings do not work. |
| Disabling and data | Disabling is not deleting | `clear()` already exists on the menu bar for both stores, and `ShelfStore.clear()` trashes real user files. |
| `isDegraded` / `attempt` on re-enable | Reset, and **only** on the explicit re-enable | Flipping a switch back on is the one thing a person can do to say "try again". The activity gate's resume is not a user request. |
| Media metadata vs transport | **Two** toggles | Only the header costs a subprocess. One switch cannot answer "buttons but no `perl`". |
| Media's enabled latch | Latch **and** switchboard | The latch makes each controller safe to call; the switchboard makes the policy readable in one place. Neither alone. |
| The shelf | Toggleable, with the honesty note beside the switch | Its idle cost genuinely is zero. It ships because the shelf is the most intrusive module on screen, not to save power. |
| Tunables in v1 | **Zero** | Every key is a permanent obligation, and two of ROADMAP's five named tunables have prerequisites (spec §11). |

## Work already in the tree

**Tasks 1 to 3 are done and committed** (`05effc4`), after this plan was
drafted and describing them as an unverified sketch. They are not a sketch:
the five `Sources/CreativeNotchCore/Preferences/` files, the three Core test
files and the `CorePurityTests` manifest entry are in, and the suite is at
**776 tests in 86 suites**.

The distinction that section originally drew was the right one — a spike is
separated from finished work by mutation verification, not by reading well —
so here is the evidence, seven mutations, each confirmed to fail the suite:

| Mutation | Killed by |
| --- | --- |
| absent key resolves OFF (R9) | `anAbsentValueMeansTheModuleIsOn`, `anEmptyDomainResolvesEveryModuleOn` |
| a wrong-typed value is parsed rather than defaulted | `aValueOfTheWrongTypeMeansTheShippedDefault`, `aHandWrittenStringDoesNotDisableTheModule` |
| the power tab ignores `hasBattery` | `thePowerTabNeedsBothABatteryAndThePreference` |
| tab order scrambled | `relativeOrderIsPreservedUnderAnyRemoval` |
| a `ModuleID` raw value renamed | `theModuleRawValuesAreUnchanged`, `theStoreWritesUnderTheDocumentedKey` |
| `fallback` never re-targets | `aTabThatHasJustVanishedFallsBackToTheFirstOneLeft`, `nothingLeftToShowMeansNoTab` |
| the subscript setter writes the wrong field | `theSubscriptReachesEveryModuleIndependently` |

Tasks 1 to 3 below are kept as the record of what was built and why. **Start
at Task 4.**

## File Structure

**Created — `CreativeNotchCore/Preferences/`, pure and headlessly testable**

| File | Responsibility |
|---|---|
| `ModuleID.swift` | The seven cases. Raw values are the defaults keys' middle segment, so they are a live compatibility surface |
| `Preferences.swift` | The value — one field per module, with a `ModuleID` subscript |
| `PreferenceKeys.swift` | The key strings **and** the pure resolution function: what absent, mistyped and out-of-range mean |
| `PreferencesStore.swift` | `UserDefaults` read/write, injectable suite, caches nothing |
| `TabVisibility.swift` | `visible(enabled:hasBattery:)` and `fallback(from:enabled:hasBattery:)`, moved down from the view |

**Created — `CreativeNotchUI/`**

| File | Responsibility |
|---|---|
| `ModuleSwitchboard.swift` | The four verbs, the effective-state table, and the only caller of a controller's `start()`/`stop()` |
| `PreferencesWindow.swift` | The form and its window, on the `OnboardingWindow` pattern |

**Modified:** `AppDelegate.swift` (the three lists collapse into one; `hud`
becomes reachable; `startSubsystems()`, `modulesDidChange()`,
`preferencesDefaults`, `mediaRemoteAvailable`; the shelf drop guards),
`NotchRootView.swift` (`AppState.preferences`, `retarget(lastOpenTab:)`),
`PanelTabBar.swift` (delegates to `TabVisibility`), `MediaController.swift`
(`reset()`, the enabled latch), `MediaHelperSupervisor.swift` (retry-budget
reset, `helperIsRunning`), `PowerObserver.swift` / `PowerController.swift`
(`stop()` clears the snapshot; `reset()`), `PeekArbiter.swift` (`clearHUD()`,
`clearPower()`), `MenuBarController.swift` (a Preferences item, and its own doc
comment is false), `CorePurityTests.swift`, `NotchedDelegate.swift` and every
per-suite `makeDelegate()`, `PanelTabBarTests.swift`,
`SystemActivityFanOutTests.swift`, `README.md`, `docs/ROADMAP.md`,
`docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md`.

## Why the order is what it is

Tasks 1 to 11 are **prerequisite work on modules that already shipped**. Eight
of the spec's ten forced changes land there, each as its own commit, each
standing on its own merit — and three of them are **pre-existing bugs fixed in
passing**, marked ⚠ below:

| Task | Forced change | Standing merit |
|---|---|---|
| 4 | `hud` reachable | ⚠ `AppDelegate.swift:47-49` documents `hud` as internal. It is `private`. The comment has been false since it was written |
| 5 | Power stop/reset pair | ⚠ `state.hasBattery = power.hasBattery` at `:380` is **dead**: it always reads `false`. Two doc comments claim otherwise |
| 5 | `PowerObserver.stop()` clears `snapshot` | ⚠ Restarting the observer today republishes nothing, because `read()` returns early on `guard next != snapshot` |
| 6 | Supervisor retry budget | A degraded-then-restarted supervisor has crash-restart handling permanently dead |
| 7 | `MediaController.reset()` + latch | R1 is live in the tree today: `setActivity(.active)` calls `supervisor.start()` unconditionally |
| 8 | `clearHUD()` / `clearPower()` | A peek must be withdrawable, not merely expirable |
| 9 | `mediaRemoteAvailable` probe | Operand order in a lazy `&&` is otherwise unprovable |
| 10 | Shelf drop refusal | — needs Task 3's read surface, has none today |
| 11 | `retarget(lastOpenTab:)` | The funnel has exactly one writer by design; this adds the second and last |

Nothing is half-migrated at a commit boundary. `AppState.preferences` arrives in
Task 3 defaulting to all-on, so every later guard reads a real field and changes
no behaviour until Task 14 writes to it.

---

### Task 1: `ModuleID`, `Preferences`, and what an absent key means

**Files:**
- Create: `Sources/CreativeNotchCore/Preferences/ModuleID.swift`
- Create: `Sources/CreativeNotchCore/Preferences/Preferences.swift`
- Create: `Sources/CreativeNotchCore/Preferences/PreferenceKeys.swift`
- Modify: `Tests/CreativeNotchCoreTests/CorePurityTests.swift` (the manifest)
- Test: `Tests/CreativeNotchCoreTests/PreferencesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ModuleID`, `Preferences`, `PreferenceKeys.enabled(_:)`,
  `PreferenceKeys.resolveEnabled(_:shippedDefault:)`. Every later task uses all
  four.

**`resolveEnabled` is the entire compatibility surface of this module**, and it
is a pure function of `Any?` so it can be pinned with `#expect` and tested with
no `UserDefaults` instance in sight. `defaults.bool(forKey:)` returns `false`
for an absent key — **the wrong polarity for a set of enable-flags**, whose
failure mode is the whole app going dark on a fresh install with the window
truthfully reporting that the user turned everything off. `Scripts/dev.sh:34`
deletes the whole domain under `--fresh` and `README.md:206` tells users to
delete it on uninstall, so "every key absent" is a routine state, exercised
daily, and it is designed for first.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

struct PreferencesTests {

    // MARK: the compatibility surface

    /// The raw values are the defaults keys' middle segment. Renaming a case
    /// does not migrate the preference behind it — it abandons it, and
    /// because absent resolves to *on*, the symptom is "the module I turned
    /// off is back" with nothing failing. Pinned by literal for the same
    /// reason `TimerTabTests` pins `Tab`'s.
    @Test func theModuleIdentifiersAreACompatibilitySurface() {
        #expect(ModuleID.shelf.rawValue == "shelf")
        #expect(ModuleID.hud.rawValue == "hud")
        #expect(ModuleID.clipboard.rawValue == "clipboard")
        #expect(ModuleID.mediaMetadata.rawValue == "media-metadata")
        #expect(ModuleID.mediaControls.rawValue == "media-controls")
        #expect(ModuleID.power.rawValue == "power")
        #expect(ModuleID.timer.rawValue == "timer")
        #expect(ModuleID.allCases.count == 7)
    }

    @Test func everyModuleHasItsOwnKey() {
        #expect(PreferenceKeys.enabled(.clipboard) == "module.clipboard.enabled")
        #expect(PreferenceKeys.enabled(.mediaMetadata)
                == "module.media-metadata.enabled")
        let keys = ModuleID.allCases.map(PreferenceKeys.enabled)
        #expect(Set(keys).count == keys.count)
    }

    /// The key that decides whether the app works on a fresh install. An
    /// absent key means the shipped default, and for a module toggle the
    /// shipped default is ON.
    @Test func anAbsentValueMeansTheShippedDefault() {
        #expect(PreferenceKeys.resolveEnabled(nil) == true)
        #expect(PreferenceKeys.resolveEnabled(nil, shippedDefault: false) == false)
    }

    /// And the other half, or the test above passes against a `resolve` that
    /// hard-codes `true`.
    @Test func aStoredBooleanIsHonoured() {
        #expect(PreferenceKeys.resolveEnabled(NSNumber(value: false)) == false)
        #expect(PreferenceKeys.resolveEnabled(NSNumber(value: true)) == true)
    }

    /// `defaults write … -string yes` gets working software, and the typo
    /// stays visible in the domain rather than being silently corrected.
    @Test func aValueOfTheWrongTypeIsTreatedAsAbsent() {
        #expect(PreferenceKeys.resolveEnabled("yes") == true)
        #expect(PreferenceKeys.resolveEnabled("no") == true)
        #expect(PreferenceKeys.resolveEnabled([1, 2, 3]) == true)
        #expect(PreferenceKeys.resolveEnabled("no", shippedDefault: false) == false)
    }

    // MARK: the value

    @Test func aFreshPreferencesValueHasEveryModuleOn() {
        let prefs = Preferences()
        for module in ModuleID.allCases {
            #expect(prefs[module], "\(module.rawValue) shipped off")
        }
    }

    /// The cross-check that catches a case wired to the wrong field. A
    /// subscript with two cases transposed passes every single-module
    /// assertion and fails this one.
    @Test func switchingOneModuleOffLeavesEveryOtherOn() {
        for module in ModuleID.allCases {
            var prefs = Preferences()
            prefs[module] = false
            #expect(prefs[module] == false)
            for other in ModuleID.allCases where other != module {
                #expect(prefs[other], "\(module.rawValue) off also cleared \(other.rawValue)")
            }
        }
    }

    @Test func preferencesCompareByValue() {
        var changed = Preferences()
        changed.clipboard = false
        #expect(Preferences() == Preferences.allEnabled)
        #expect(changed != Preferences.allEnabled)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PreferencesTests`
Expected: FAIL — `cannot find 'ModuleID' in scope`.

- [ ] **Step 3: Implement**

Three files. `ModuleID` is `public enum … : String, CaseIterable, Equatable,
Sendable` with the seven cases and the two hyphenated raw values.
`Preferences` is a `public struct … : Equatable, Sendable` with one `Bool` per
module, an all-defaulted `init`, `static let allEnabled`, and a
`subscript(module: ModuleID) -> Bool` with get and set — one field per module
rather than a dictionary, because a dictionary makes "missing" a runtime
question, and the whole point of this task is that missing is decided once, at
the boundary.

`PreferenceKeys` carries the doc comment that matters:

```swift
    /// What a raw defaults value means.
    ///
    /// **Absent means the shipped default, and for a module toggle that is
    /// on.** `UserDefaults.bool(forKey:)` returns `false` for an absent key,
    /// which is the wrong polarity for a set of enable-flags: the failure
    /// mode is the entire app going dark on a fresh install, with the
    /// preferences window truthfully reporting that the user turned
    /// everything off.
    ///
    /// **A value of the wrong type is treated as absent, and is not
    /// rewritten.** Someone who ran `defaults write … -string yes` gets
    /// working software *and* keeps the evidence of what they typed;
    /// silently correcting the key would make the next `defaults read` lie
    /// to them.
    public static func resolveEnabled(
        _ raw: Any?, shippedDefault: Bool = true
    ) -> Bool {
        guard let raw else { return shippedDefault }
        // `object(forKey:)` hands back `NSNumber` for a boolean written
        // through either `set(_:forKey:)` or `defaults write -bool`, so the
        // bridge to `Bool` is the honest check. A `String` — what `defaults
        // write` produces without `-bool` — deliberately falls through to
        // the shipped default rather than being parsed: "yes" parsing true
        // and "yep" parsing false is a worse surprise than neither.
        guard let number = raw as? NSNumber else { return shippedDefault }
        return number.boolValue
    }
```

**`UserDefaults.register(defaults:)` is refused.** It appears nowhere in the
repo, it is invisible to `defaults read`, it is per-process, and it makes "what
does absent mean" depend on registration order at launch — a fact living in a
side effect rather than in a function.

- [ ] **Step 4: Add the three filenames to the purity manifest**

In `CorePurityTests.swift`'s `expectedInSubdirectories` (`:69-86`), append
`"ModuleID.swift"`, `"Preferences.swift"`, `"PreferenceKeys.swift"`. That list
exists because a non-recursive scan once silently stopped covering `HUD/` and
`Shelf/` — the purity test passed by checking nothing.

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter PreferencesTests`, then `swift test`.

- [ ] **Step 6: Mutation-verify**

| Mutation | Must fail |
|---|---|
| `resolveEnabled` drops the `guard let raw` and calls `bool(forKey:)`'s equivalent (`raw as? Bool ?? false`) | `anAbsentValueMeansTheShippedDefault` |
| `resolveEnabled` returns `shippedDefault` unconditionally | `aStoredBooleanIsHonoured` |
| `resolveEnabled` parses strings (`"yes" → true`, else `false`) | `aValueOfTheWrongTypeIsTreatedAsAbsent` |
| `mediaMetadata` raw value → `"mediaMetadata"` | `theModuleIdentifiersAreACompatibilitySurface`, `everyModuleHasItsOwnKey` |
| `enabled(_:)` returns `"module.enabled"` | `everyModuleHasItsOwnKey` |
| the subscript's `.mediaControls` setter writes `mediaMetadata` | `switchingOneModuleOffLeavesEveryOtherOn` |
| `Preferences.init` defaults one field to `false` | `aFreshPreferencesValueHasEveryModuleOn` |
| remove a filename from the purity manifest | `theRecursiveScanFindsEveryCoreFile` (it should — confirm, and say so) |

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchCore/Preferences Tests/CreativeNotchCoreTests/PreferencesTests.swift Tests/CreativeNotchCoreTests/CorePurityTests.swift
git commit -m "feat: add the preference values and the one function that resolves them"
```

---

### Task 2: `PreferencesStore`, and a fresh domain that leaves everything on

**Files:**
- Create: `Sources/CreativeNotchCore/Preferences/PreferencesStore.swift`
- Modify: `Tests/CreativeNotchCoreTests/CorePurityTests.swift` (the manifest)
- Test: `Tests/CreativeNotchCoreTests/PreferencesStoreTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces: `PreferencesStore(defaults:)`, `.load()`, `.setEnabled(_:for:)`.

Task 1 pinned the resolution function. **This task pins that the real read path
actually calls it** — R9 is not a bug in `resolveEnabled`, it is a bug in
somebody reaching for `defaults.bool(forKey:)` two files away, and only a test
that drives a real `UserDefaults` catches that.

**The store caches nothing.** A cached `Preferences` is a second source of truth
to invalidate, and the pattern it would copy is `HUDController.swift:103` — the
one this module exists not to repeat.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

struct PreferencesStoreTests {

    /// UUID-suffixed and cleared before use, exactly as
    /// `OnboardingControllerTests` does it: a suite name reused across runs
    /// carries yesterday's values into today's assertions.
    private func freshSuite() -> UserDefaults {
        let name = "CreativeNotchPrefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// R9. `dev.sh --fresh` deletes the whole domain and the README tells
    /// users to do the same on uninstall, so this is the state the app is
    /// launched in most often — and `bool(forKey:)` would report every
    /// module as switched off.
    @Test func anEmptyDomainLeavesEveryModuleOn() {
        let store = PreferencesStore(defaults: freshSuite())
        let prefs = store.load()
        for module in ModuleID.allCases {
            #expect(prefs[module], "\(module.rawValue) was off on a fresh domain")
        }
    }

    /// The other half. Without it, a `load()` returning `.allEnabled`
    /// unconditionally passes the test above.
    @Test func aModuleWrittenOffReadsBackOff() {
        let store = PreferencesStore(defaults: freshSuite())
        store.setEnabled(false, for: .clipboard)
        #expect(store.load().clipboard == false)
    }

    /// One key per module, written and read through the real path. A store
    /// that wrote every module to one key passes both tests above.
    @Test func eachModuleIsStoredUnderItsOwnKey() {
        let store = PreferencesStore(defaults: freshSuite())
        for module in ModuleID.allCases {
            store.setEnabled(false, for: module)
            let prefs = store.load()
            #expect(prefs[module] == false)
            for other in ModuleID.allCases where other != module {
                #expect(prefs[other], "writing \(module.rawValue) also cleared \(other.rawValue)")
            }
            store.setEnabled(true, for: module)
        }
    }

    /// The key the store writes is the key `defaults read` shows, so a user
    /// can see and edit what they set.
    @Test func theStoredKeyIsTheDocumentedOne() {
        let defaults = freshSuite()
        PreferencesStore(defaults: defaults).setEnabled(false, for: .hud)
        #expect(defaults.object(forKey: "module.hud.enabled") as? NSNumber == 0)
    }

    /// A hand-typed string resolves to the shipped default AND survives in
    /// the domain. A read that normalised the key would be silent.
    @Test func aHandTypedStringIsNotRewritten() {
        let defaults = freshSuite()
        defaults.set("yes", forKey: PreferenceKeys.enabled(.power))
        let store = PreferencesStore(defaults: defaults)

        #expect(store.load().power)
        #expect(defaults.object(forKey: PreferenceKeys.enabled(.power)) as? String == "yes")
    }

    /// No cached value: a write behind the store's back is visible on the
    /// next `load()`. This is R8 at the storage layer.
    @Test func theStoreHoldsNoCachedCopy() {
        let defaults = freshSuite()
        let store = PreferencesStore(defaults: defaults)
        #expect(store.load().timer)

        defaults.set(false, forKey: PreferenceKeys.enabled(.timer))

        #expect(store.load().timer == false)
    }
}
```

- [ ] **Step 2: Run to verify it fails**, then implement

`public final class PreferencesStore` with
`public init(defaults: UserDefaults = .standard)`, copying
`OnboardingController` (`OnboardingWindow.swift:26`) exactly. `load()` walks
`ModuleID.allCases`, reading `defaults.object(forKey:)` — **never
`bool(forKey:)`** — through `PreferenceKeys.resolveEnabled`.
`setEnabled(_:for:)` writes. Nothing else; no observation in either direction.

- [ ] **Step 3: Add `PreferencesStore.swift` to the purity manifest**

- [ ] **Step 4: Run, then mutation-verify**

| Mutation | Must fail |
|---|---|
| `load()` uses `defaults.bool(forKey:)` | `anEmptyDomainLeavesEveryModuleOn` |
| `load()` returns `.allEnabled` | `aModuleWrittenOffReadsBackOff`, `eachModuleIsStoredUnderItsOwnKey` |
| `setEnabled` writes to a single shared key | `eachModuleIsStoredUnderItsOwnKey` |
| `setEnabled` writes `"module.\(module).enabled"` (the case name, not the raw value) | `theStoredKeyIsTheDocumentedOne` |
| the store caches `Preferences` at init | `theStoreHoldsNoCachedCopy` |
| `load()` rewrites a mistyped key to the default | `aHandTypedStringIsNotRewritten` |

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: read and write module toggles against an injectable defaults suite"
```

---

### Task 3: The tab list moves to Core and learns about preferences

**Files:**
- Create: `Sources/CreativeNotchCore/Preferences/TabVisibility.swift`
- Modify: `Sources/CreativeNotchUI/PanelTabBar.swift`
- Modify: `Sources/CreativeNotchUI/NotchRootView.swift` (`AppState.preferences`,
  and the two `PanelTabBar` call sites)
- Modify: `Tests/CreativeNotchUITests/PanelTabBarTests.swift`
- Modify: `Tests/CreativeNotchCoreTests/CorePurityTests.swift`
- Test: `Tests/CreativeNotchCoreTests/TabVisibilityTests.swift`

**Interfaces:**
- Consumes: `Preferences` (Task 1).
- Produces: `TabVisibility.visible(enabled:hasBattery:)`,
  `TabVisibility.fallback(from:enabled:hasBattery:)`, and
  `AppState.preferences`. Tasks 10, 13 and 14 all read `AppState.preferences`;
  Task 14 uses `fallback`.

**This task changes no behaviour.** `AppState.preferences` defaults to
`.allEnabled` and nothing writes it until Task 14, so `visible` returns exactly
what it returns today. That is the point: the read surface has to exist before
seven guards can read it, and a guard added against a field nobody writes is
inert rather than half-migrated.

**Hardware availability and user preference stay two arguments.** `hasBattery`
answers "can this machine do it"; the preference answers "does the user want
it". AND them at the point of use. `hasBattery` is written at runtime on power
notifications, so a conflated field would be clobbered by the hardware and the
preference would silently revert.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import CreativeNotchCore

struct TabVisibilityTests {

    private func prefs(_ mutate: (inout Preferences) -> Void = { _ in }) -> Preferences {
        var p = Preferences()
        mutate(&p)
        return p
    }

    /// Literal, not derived. The suite's existing doc comment says the
    /// arrays were chosen to be literals so the test cannot re-derive the
    /// thing it is checking.
    @Test func everythingOnAMacBookShowsFourTabs() {
        #expect(TabVisibility.visible(enabled: prefs(), hasBattery: true)
                == [.shelf, .clipboard, .timer, .power])
    }

    @Test func noBatteryStillHidesThePowerTab() {
        #expect(TabVisibility.visible(enabled: prefs(), hasBattery: false)
                == [.shelf, .clipboard, .timer])
    }

    /// The first thing in this app's history that removes a tab from the
    /// middle of the list.
    @Test func aDisabledModuleLosesItsTabAndTheRestKeepTheirOrder() {
        #expect(TabVisibility.visible(enabled: prefs { $0.clipboard = false },
                                      hasBattery: true)
                == [.shelf, .timer, .power])
        #expect(TabVisibility.visible(enabled: prefs { $0.shelf = false },
                                      hasBattery: true)
                == [.clipboard, .timer, .power])
        #expect(TabVisibility.visible(enabled: prefs { $0.timer = false },
                                      hasBattery: true)
                == [.shelf, .clipboard, .power])
    }

    /// An empty list is a legal state, not a trap: the window is reached
    /// from the menu bar, so there is always a way back.
    @Test func everythingOffShowsNoTabsAtAll() {
        var off = Preferences()
        for module in ModuleID.allCases { off[module] = false }
        #expect(TabVisibility.visible(enabled: off, hasBattery: true) == [])
    }

    /// A preference must not resurrect a tab the hardware has no use for.
    @Test func thePowerTabNeedsBothTheBatteryAndThePreference() {
        #expect(TabVisibility.visible(enabled: prefs { $0.power = false },
                                      hasBattery: true).contains(.power) == false)
        #expect(TabVisibility.visible(enabled: prefs(),
                                      hasBattery: false).contains(.power) == false)
    }

    /// `.hud` owns no panel content: a tab that opens onto a placeholder is
    /// worse than no tab, and switching the HUD *on* must not offer one.
    @Test func theHudNeverGetsATabHoweverItIsConfigured() {
        #expect(TabVisibility.visible(enabled: prefs { $0.hud = true },
                                      hasBattery: true).contains(.hud) == false)
    }

    /// Every one of the sixteen combinations of the four tab-bearing
    /// modules, so an eighth module cannot be added without wiring it in
    /// here. Zero `arguments:` traits exist in `Tests/`, so this is a loop
    /// inside one bare `@Test`.
    @Test func everyCombinationShowsExactlyTheModulesThatAreOn() {
        for mask in 0..<16 {
            var p = Preferences()
            p.shelf     = mask & 1 != 0
            p.clipboard = mask & 2 != 0
            p.timer     = mask & 4 != 0
            p.power     = mask & 8 != 0
            let tabs = TabVisibility.visible(enabled: p, hasBattery: true)
            #expect(tabs.count == [p.shelf, p.clipboard, p.timer, p.power]
                                    .filter { $0 }.count, "mask \(mask)")
            #expect(tabs.contains(.shelf) == p.shelf, "mask \(mask)")
            #expect(tabs.contains(.clipboard) == p.clipboard, "mask \(mask)")
            #expect(tabs.contains(.timer) == p.timer, "mask \(mask)")
            #expect(tabs.contains(.power) == p.power, "mask \(mask)")
        }
    }

    // MARK: fallback

    @Test func aStillVisibleTabIsLeftAlone() {
        #expect(TabVisibility.fallback(from: .timer, enabled: prefs(),
                                       hasBattery: true) == .timer)
    }

    @Test func aVanishedTabFallsBackToTheFirstOneLeft() {
        #expect(TabVisibility.fallback(from: .clipboard,
                                       enabled: prefs { $0.clipboard = false },
                                       hasBattery: true) == .shelf)
        #expect(TabVisibility.fallback(from: .shelf,
                                       enabled: prefs { $0.shelf = false },
                                       hasBattery: true) == .clipboard)
    }

    /// `nil` means close the panel. There is nothing to fall back *to*, and
    /// inventing a tab would reopen the module the user just switched off.
    @Test func nothingLeftMeansNoTab() {
        var off = Preferences()
        for module in ModuleID.allCases { off[module] = false }
        #expect(TabVisibility.fallback(from: .shelf, enabled: off,
                                       hasBattery: true) == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails, then implement `TabVisibility`**

`.power` is still **appended** rather than inserted, so hiding it never reorders
the tabs that were already there — the rule `PanelTabBar.swift:48-49` records.
`fallback` returns `selected` if it is still in the list, else `tabs.first`,
else `nil`. Add `TabVisibility.swift` to the purity manifest.

- [ ] **Step 3: `AppState` gains the read surface**

In `NotchRootView.swift`, beside `hasBattery`:

```swift
    /// Which modules are switched on.
    ///
    /// **The only read surface for a preference in the whole app.** Nothing
    /// reads `PreferencesStore` or the switchboard directly: the drop
    /// closures, `PanelTabBar` and `timerDidFinish` all read this field, and
    /// that is what makes R8 — a preference snapshotted into a `let` at
    /// construction — structurally unavailable to the app-lifetime closures
    /// built in `install(metrics:)`.
    ///
    /// Not `@ObservationIgnored`: like `hasBattery`, it is a plain value
    /// `body` reads directly and needs Observation's tracking when a toggle
    /// writes it.
    ///
    /// Defaults to everything on, so anything constructing a bare
    /// `AppState` — every test that does not care about preferences — gets
    /// the shipped shape.
    public var preferences: Preferences = .allEnabled
```

- [ ] **Step 4: `PanelTabBar` delegates rather than deciding**

Replace `PanelTabBar.visible(hasBattery:)` with a call through to
`TabVisibility.visible(enabled:hasBattery:)`, add an `enabled: Preferences`
property beside `hasBattery`, and pass `app.preferences` from the two call
sites in `NotchRootView`. **Delete the local list.** Leaving it as a second
spelling is the two-derivations defect class that produced this project's only
Critical bug.

While you are in the file, correct the doc comment at `:26-27`: `.hud` does not
stay in the enum "because `PeekArbiter` and `AppDelegate` reference it" — no
`Tab.hud` reference exists outside the enum, the `title` switch, `openContent`
and one test (`AppDelegate.swift:725, :768` are `PeekContent.hud`). It stays
because two exhaustive switches need it. The same false claim is in
`PanelTabBarTests.swift:9-11`.

- [ ] **Step 5: Restate the broken invariant in `PanelTabBarTests`**

`hidingThePowerTabLeavesTheOthersInPlace` (`:33-38`) asserts
`Array(with.prefix(without.count)) == without`, which assumes **only trailing
tabs are conditional**. That is no longer true. Restate it as "relative order is
preserved under removal" — and note in the test's comment that **the
restatement is mutation-blind on its own**, because the full list is a
subsequence of itself and the assertion holds even when `visible` ignores
`enabled` entirely. The literal-pinned arrays in `TabVisibilityTests` are what
actually bite; this one documents the property.

- [ ] **Step 6: Run the full suite** — `swift test`. Nothing about today's
behaviour may change. If an existing assertion needs adjusting beyond the
renamed argument, the move has changed behaviour and that is a defect; report
it rather than editing the assertion.

- [ ] **Step 7: Mutation-verify**

| Mutation | Must fail |
|---|---|
| `visible` ignores `enabled` | `aDisabledModuleLosesItsTabAndTheRestKeepTheirOrder`, `everyCombinationShowsExactlyTheModulesThatAreOn` |
| `.power` appended without `hasBattery` | `thePowerTabNeedsBothTheBatteryAndThePreference`, `noBatteryStillHidesThePowerTab` |
| `.power` inserted before `.timer` | `everythingOnAMacBookShowsFourTabs` |
| `.hud` appended when `enabled.hud` | `theHudNeverGetsATabHoweverItIsConfigured` |
| `fallback` returns `tabs.first` unconditionally | `aStillVisibleTabIsLeftAlone` |
| `fallback` returns `selected` unconditionally | `aVanishedTabFallsBackToTheFirstOneLeft` |
| `fallback` force-unwraps / returns `.shelf` on empty | `nothingLeftMeansNoTab` |
| `PanelTabBar` keeps its own list | `TabVisibility` tests stay green — **so also assert in `PanelTabBarTests` that the view's list equals `TabVisibility.visible(...)` for one disabled module**, or this mutation is uncaught |

- [ ] **Step 8: Commit**

```bash
git commit -m "refactor: move tab visibility into Core and give it a preferences axis"
```

---

### Task 4: The HUD controller becomes reachable ⚠

**Files:**
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift:46-49`, `:220-222`, `install(metrics:)`
- Test: `Tests/CreativeNotchUITests/AppDelegateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppDelegate.hud` as `private(set) var`, constructed in
  `install(metrics:)`. Tasks 13 and 14 cannot start or stop what they cannot
  see.

**The blocker, and a doc comment that has been false since it was written.**
`private var hud: HUDController?` (`:46`) is private and constructed inline in
`applicationDidFinishLaunching` (`:220-222`), unlike every other controller —
while `:47-49` cites *"the same reason `hud`, `clipboard` and `activity` are
internal"* as the precedent for `arbiter` being internal. The precedent list has
a wrong entry. This task makes the comment true rather than deleting it.

**Construction only.** `hud.start()` stays where it is, in
`applicationDidFinishLaunching`, until Task 12 moves the whole launch block into
`startSubsystems()`. `install(metrics:)` must continue to start nothing.

**Guard the construction with `if hud == nil`.** `install(metrics:)` is not
safely re-entrant and `AppDelegateTests.swift:185-186` calls it twice in a row.
The HUD is the only module whose orphaned instance holds a **system-global**
resource — a `CGEventTap`, its `CFRunLoopSource`, and a retained `TapContext`
(`MediaKeyMonitor.swift:151-154`), reachable for teardown only through a live
`MediaKeyMonitor`. Every other orphan on the spec's §11 list is at least idle.

- [ ] **Step 1: Write the failing tests**

Add to `AppDelegateTests`:

```swift
    /// The switchboard cannot start or stop a controller it cannot see, and
    /// nor can a test. Until this, `hud` was the one controller built
    /// outside `install` and unreachable from outside the file.
    @Test func installingBuildsTheHudController() {
        let delegate = makeDelegate()
        #expect(delegate.hud != nil)
    }

    /// And building it must not start it. Fourteen suites reach
    /// `install(metrics:)` and then inject their fakes; a tap created here
    /// would be a real global event monitor in every one of them.
    @Test func installingDoesNotStartTheHud() throws {
        let delegate = makeDelegate()
        let hud = try #require(delegate.hud)
        #expect(hud.keys.isRunning == false)
        #expect(hud.volume.isRunning == false)
        #expect(hud.brightness.isRunning == false)
    }

    /// `install` twice must not leave an orphaned controller holding a
    /// second event tap that nothing can reach to tear down.
    @Test func installingTwiceKeepsOneHudController() {
        let delegate = makeDelegate()
        let first = delegate.hud
        delegate.install(metrics: Self.notched)
        #expect(delegate.hud === first)
    }
```

- [ ] **Step 2: Run to verify it fails, then implement**

`private var hud` → `private(set) var hud: HUDController?`, with the doc
comment rewritten to say what is now true. Move the construction into
`install(metrics:)` beside the other controllers:

```swift
        // Constructed here like every other controller, so the switchboard
        // and the tests can reach it; started in `startSubsystems()`,
        // because building a panel must not install a global event tap.
        //
        // Guarded: `install(metrics:)` is not safely re-entrant, and an
        // orphaned `HUDController` is the only one that would keep a
        // system-global resource — the tap, its run-loop source and a
        // retained `TapContext` — with nothing left able to remove it.
        if hud == nil {
            hud = HUDController { [weak self] kind in self?.showHUD(kind) }
        }
```

`applicationDidFinishLaunching` keeps `hud?.start()` where the three inline
lines were.

- [ ] **Step 3: Run the full suite**, then mutation-verify

| Mutation | Must fail |
|---|---|
| construction left in `applicationDidFinishLaunching` | `installingBuildsTheHudController` |
| `hud.start()` called from `install` | `installingDoesNotStartTheHud` |
| drop the `if hud == nil` guard | `installingTwiceKeepsOneHudController` |

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor: build the HUD controller in install so its lifecycle is reachable"
```

---

### Task 5: Power can be stopped and started again ⚠

**Files:**
- Modify: `Sources/CreativeNotchUI/Power/PowerObserver.swift` (`stop()`)
- Modify: `Sources/CreativeNotchUI/Power/PowerController.swift` (`reset()`)
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift:378-380`,
  and the doc comments at `:654` and `NotchRootView.swift:111`
- Test: `Tests/CreativeNotchUITests/PowerObserverTests.swift`,
  `Tests/CreativeNotchUITests/PowerControllerTests.swift`,
  `Tests/CreativeNotchUITests/PowerWiringTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PowerController.reset()`. Task 14's power stop verb is the **pair**
  `stop()` + `reset()`.

**Two live defects, both only visible once something restarts the observer —
which nothing has ever done.**

1. `PowerObserver.start()` performs an immediate `read()` (`:101`), but `read()`
   returns early on `guard next != snapshot` (`:129`) and `stop()` never clears
   `snapshot`. **The immediate read republishes nothing**, so a re-enabled Power
   tab stays empty until the next genuine level, source or Low Power Mode change
   — on a desk machine on wall power, possibly hours. That is the placeholder
   tab `PanelTabBar.swift:28` forbids, produced by a toggle.
2. `PowerController.previous` (`:27`) is never cleared either, so the first
   snapshot after a restart is compared against a baseline from *before* the
   stop and can fire a `.pluggedIn` / `.unplugged` / `.lowPowerMode` peek for a
   transition that happened while the module was off — breaking what `:79-80`
   states outright: *"The first snapshot is a baseline, not an event."*

**And one dead line.** `state.hasBattery = power.hasBattery` (`:380`) always
reads `false`: `PowerObserver.hasBattery` is `false` at init (`:38`) and
assigned only inside `start()` (`:102`), which runs at `:227` — after
`install(metrics:)` at `:195`. The Power tab appears **solely** because of
`powerDidChange` (`:658`). `NotchRootView.swift:111` and `AppDelegate.swift:654`
both document the opposite. Delete the assignment and correct both comments:
one writer for that flag, and it is the first snapshot. Do **not** clear
`hasBattery` when the power module is disabled — it is a capability, not a
preference (spec §7).

- [ ] **Step 1: Write the failing tests**

```swift
    // PowerObserverTests

    /// Stopping must forget what was last seen, or the `read()` inside
    /// `start()` finds nothing new and publishes nothing — and a re-enabled
    /// Power tab sits empty until the hardware happens to move.
    @Test func stoppingForgetsTheLastSnapshotSoARestartRepublishes() {
        let observer = PowerObserver()
        observer.snapshot = PowerSnapshot(level: 50, source: .battery,
                                          isCharging: false, estimateMinutes: nil,
                                          isLowPowerMode: false)
        observer.stop()
        #expect(observer.snapshot == nil)
    }
```

```swift
    // PowerControllerTests

    /// The first snapshot is a baseline, not an event — and after a
    /// disable/re-enable cycle, "first" means the first one since the
    /// re-enable. Without `reset()`, unplugging while the module is off
    /// fires an `.unplugged` peek the moment it comes back.
    @Test func resettingMakesTheNextSnapshotABaselineAgain() {
        let controller = PowerController()
        var events: [PowerEvent] = []
        controller.onEvent = { events.append($0) }

        controller.apply(snapshot(source: .wall))
        #expect(events.isEmpty, "the first snapshot must be a baseline")

        controller.stop()
        controller.reset()
        controller.apply(snapshot(source: .battery))

        #expect(events.isEmpty, "the first snapshot after a reset is a baseline too")
    }

    /// And the control: without the reset, that same second snapshot is an
    /// event. If this one does not pass, `reset()` is being called from
    /// somewhere it should not be.
    @Test func aSourceChangeWithinOneRunStillPeeks() {
        let controller = PowerController()
        var events: [PowerEvent] = []
        controller.onEvent = { events.append($0) }

        controller.apply(snapshot(source: .wall))
        controller.apply(snapshot(source: .battery))

        #expect(events.count == 1)
    }

    /// Low-battery arming is re-seeded too, or a battery that was below the
    /// threshold when the module was switched off never speaks again.
    @Test func resettingClearsTheLowBatteryArming() {
        let controller = PowerController()
        var events: [PowerEvent] = []
        controller.onEvent = { events.append($0) }

        controller.apply(snapshot(source: .battery, level: 50))
        controller.apply(snapshot(source: .battery, level: 19))
        #expect(events.count == 1)

        controller.stop()
        controller.reset()

        controller.apply(snapshot(source: .battery, level: 50))
        controller.apply(snapshot(source: .battery, level: 19))
        #expect(events.count == 2)
    }
```

```swift
    // PowerWiringTests

    /// The install-time assignment always read `false`, and two doc comments
    /// claimed otherwise. `hasBattery` is established by the first snapshot,
    /// which is what actually happens today.
    @Test func installDoesNotClaimToKnowWhetherThereIsABattery() {
        let delegate = makeDelegate()
        #expect(delegate.state.hasBattery == false)

        delegate.powerDidChange(snapshot())

        #expect(delegate.state.hasBattery)
    }
```

- [ ] **Step 2: Run to verify they fail, then implement**

`PowerObserver.stop()` sets `snapshot = nil` after removing the source and the
token, with a comment saying why — it is not tidiness, it is what makes the
`read()` in `start()` publish. `PowerController.reset()` sets `previous = nil`
and `arming = LowBatteryArming()`, documented as **the other half of `stop()`,
never called on its own**. Delete `AppDelegate.swift:380` and correct the two
doc comments.

`observer.snapshot` may need to become `internal private(set)` with an internal
setter for the test above; if exposing a setter is the wrong trade, drive it
through `read()` on a machine with a battery and guard with
`expectOrKnownHardwareIssue`. **Prefer the seam** — `registrationCount`,
`runLoopSource` and `readCount` are all exposed for exactly this reason.

- [ ] **Step 3: Run the full suite**, then mutation-verify

| Mutation | Must fail |
|---|---|
| `stop()` leaves `snapshot` | `stoppingForgetsTheLastSnapshotSoARestartRepublishes` |
| `reset()` leaves `previous` | `resettingMakesTheNextSnapshotABaselineAgain` |
| `reset()` leaves `arming` | `resettingClearsTheLowBatteryArming` |
| `reset()` is called from `apply()` | `aSourceChangeWithinOneRunStillPeeks` |
| restore `state.hasBattery = power.hasBattery` at install | none today — **note it**; the line is dead either way, which is why it is being deleted rather than fixed |

- [ ] **Step 4: Commit**

```bash
git commit -m "fix: make a stopped power observer restartable, and delete the dead hasBattery read"
```

---

### Task 6: The media supervisor gets its retry budget back

**Files:**
- Modify: `Sources/CreativeNotchUI/Media/MediaHelperSupervisor.swift`
- Test: `Tests/CreativeNotchUITests/MediaHelperSupervisorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `MediaHelperSupervisor.resetRetryBudget()` and
  `var helperIsRunning: Bool`. Task 7 calls the first from
  `MediaController.start()`; Tasks 13 and 14 assert on the second.

`start()` (`:105-109`) resets only `stoppedDeliberately` and `startedAt`.
`isDegraded` (`:51`) and `attempt` (`:50`) are **never** reset, and
`helperExited` short-circuits on `guard !isDegraded else { return }` (`:163`).
**A module that degraded, was disabled, then re-enabled spawns a helper with
crash-restart handling permanently dead** — working until the first crash, then
silently gone for the session.

Reset both, and **only on the explicit re-enable path**. The activity gate's
resume is not a user request; an unlock must not hand back a budget the helper
spent crashing. That is why this is a separate verb rather than a line inside
`start()`.

`helperIsRunning` exists for the same reason `PowerObserver.registrationCount`
does: `helperProcess` is a `private let` (`:88`), so no headless test can today
assert the subprocess **stopped** rather than that a stop was *asked for*.

- [ ] **Step 1: Write the failing tests**

```swift
    /// Flipping a switch back on is the one thing a person can do to say
    /// "try again". Leaving the flag latched means a module that is on,
    /// running, and permanently unable to recover from a crash.
    @Test func resettingTheBudgetClearsDegradationAndTheAttemptCount() {
        let supervisor = MediaHelperSupervisor()
        supervisor.startHelper = {}
        supervisor.stopHelper = {}
        supervisor.scheduleRetry = { _, _ in }

        for _ in 0...HelperBackoff.maxAttempts {
            supervisor.helperExited(status: 1)
        }
        #expect(supervisor.isDegraded)
        #expect(supervisor.attempt > 0)

        supervisor.resetRetryBudget()

        #expect(supervisor.isDegraded == false)
        #expect(supervisor.attempt == 0)
    }

    /// And the budget is genuinely usable again — `helperExited` is what
    /// `guard !isDegraded` short-circuits, so clearing the flag without
    /// clearing the attempt count is a one-crash budget.
    @Test func aResetBudgetSchedulesRetriesAgain() {
        let supervisor = MediaHelperSupervisor()
        supervisor.startHelper = {}
        supervisor.stopHelper = {}
        var retries = 0
        supervisor.scheduleRetry = { _, _ in retries += 1 }

        for _ in 0...HelperBackoff.maxAttempts {
            supervisor.helperExited(status: 1)
        }
        let afterDegrade = retries

        supervisor.resetRetryBudget()
        supervisor.helperExited(status: 1)

        #expect(retries == afterDegrade + 1)
    }

    /// The activity gate must not hand the budget back. An unlock is not a
    /// user saying "try again".
    @Test func stoppingAndStartingDoesNotRefreshTheBudget() {
        let supervisor = MediaHelperSupervisor()
        supervisor.startHelper = {}
        supervisor.stopHelper = {}
        supervisor.scheduleRetry = { _, _ in }

        for _ in 0...HelperBackoff.maxAttempts {
            supervisor.helperExited(status: 1)
        }
        #expect(supervisor.isDegraded)

        supervisor.stop()
        supervisor.start()

        #expect(supervisor.isDegraded, "start() must not forgive a degraded helper")
    }
```

Plus one for `helperIsRunning`, asserting it is `false` after `stop()` and that
it reads the process rather than a flag the supervisor sets itself.

- [ ] **Step 2: Run to verify it fails, then implement**

```swift
    /// Hands the helper a fresh retry budget.
    ///
    /// **Only ever called from the explicit re-enable path**, never from
    /// `start()` and never from the activity gate's resume. `start()` runs
    /// on every screen unlock; forgiving a degraded helper there would mean
    /// a crash loop that resets itself every time the lid opens. A person
    /// flipping the switch back on is a different thing: it is the one
    /// gesture available for saying "try again".
    func resetRetryBudget() {
        attempt = 0
        isDegraded = false
    }

    /// Whether the subprocess is actually up.
    ///
    /// Internal, for the lifecycle proof — the same reason
    /// `PowerObserver.registrationCount` is internal. `helperProcess` is
    /// private, so without this a test can only assert that a stop was
    /// *asked for*, which is exactly the assertion R2 is about.
    var helperIsRunning: Bool { helperProcess?.isRunning ?? false }
```

- [ ] **Step 3: Run the full suite**, then mutation-verify

| Mutation | Must fail |
|---|---|
| `resetRetryBudget` clears only `isDegraded` | `aResetBudgetSchedulesRetriesAgain` |
| `resetRetryBudget` clears only `attempt` | `resettingTheBudgetClearsDegradationAndTheAttemptCount` |
| `start()` calls `resetRetryBudget()` | `stoppingAndStartingDoesNotRefreshTheBudget` |
| `helperIsRunning` returns a stored `Bool` the supervisor sets | its own test, once `stopHelper` is a no-op closure that never touches the process |

- [ ] **Step 4: Commit**

```bash
git commit -m "fix: give the media helper a fresh retry budget on an explicit restart"
```

---

### Task 7: `MediaController` can be switched off and stay off

**Files:**
- Modify: `Sources/CreativeNotchUI/Media/MediaController.swift`
- Test: `Tests/CreativeNotchUITests/MediaControllerTests.swift`

**Interfaces:**
- Consumes: Task 6's `resetRetryBudget()`.
- Produces: `MediaController.setEnabled(_:)` and `reset()`. Task 14's media
  stop verb calls `setEnabled(false)` then `stop()`.

**The headline bug, live in the tree today.** `setActivity(.active)` calls
`supervisor.start()` unconditionally (`:126`). A user disables media metadata,
walks away, unlocks — and the `perl` subprocess they explicitly declined is
running again, with nothing on screen to reveal it.

The fix is a **transplant, not a design**: `ClipboardPoller` already holds two
independent latches, `isRunning` (lifecycle, `:51`) and `activity` (the gate,
`:50`), and reschedules only `if isRunning` (`:101`). That shape is why the
clipboard module needs no new code at all for this feature. Copy it.

The second half is `reset()`. Stopping the helper does not clear
`state.nowPlaying`, `nowPlayingArtwork` or `arbiter.setNowPlaying(nil)`, and a
stale badge keeps widening the closed notch's hit-test region **forever** — the
failure `AppDelegate.swift:512-517` warns about. And the coalescer must be reset
at the same time, or the **re-enable** silently fails: the first snapshot from
the fresh helper is deduped against the dead one's last and the header never
repopulates (`MediaController.swift:102-107` documents exactly this trap).
`degrade()` (`:108-114`) already does the right work — but it *means* "failed
past the retry cap". Extract `reset()` and have `degrade()` call it, so a
deliberate disable does not masquerade as a failure.

- [ ] **Step 1: Write the failing tests**

```swift
    /// R1. Disabling then unlocking must not respawn the helper. The
    /// pre-assert is not optional: `starts == 0` after an unlock is also
    /// what a controller that was never started looks like.
    @Test func anUnlockDoesNotResurrectADisabledHelper() {
        let controller = MediaController()
        var starts = 0
        var stops = 0
        controller.supervisor.startHelper = { starts += 1 }
        controller.supervisor.stopHelper = { stops += 1 }

        controller.start()
        #expect(starts == 1, "not started is indistinguishable from not resurrected")

        controller.setEnabled(false)
        controller.stop()
        let baseline = starts

        controller.setActivity(.locked)
        controller.setActivity(.active)

        #expect(starts == baseline)
        #expect(controller.helperIsRunning == false)
    }

    /// And the gate still works when the module is on, or the test above
    /// passes against a `setActivity` that does nothing at all.
    @Test func anUnlockStillResumesAnEnabledHelper() {
        let controller = MediaController()
        var starts = 0
        controller.supervisor.startHelper = { starts += 1 }
        controller.supervisor.stopHelper = {}

        controller.start()
        controller.setActivity(.locked)
        controller.setActivity(.active)

        #expect(starts == 2)
    }

    /// A stale now-playing badge widens the closed notch's hit-test region
    /// for the rest of the session. Stopping the helper has to publish the
    /// absence, not just stop producing presence.
    @Test func disablingPublishesNothingPlaying() {
        let controller = MediaController()
        controller.supervisor.startHelper = {}
        controller.supervisor.stopHelper = {}
        var published: [TrackSnapshot?] = []
        controller.onChange = { published.append($0) }

        controller.start()
        controller.handle(line: /* a real now-playing line */ "")
        #expect(controller.snapshot != nil)

        controller.reset()

        #expect(controller.snapshot == nil)
        #expect(published.last ?? nil == nil)
    }

    /// R4(a). The coalescer dedupes against the dead helper's last snapshot,
    /// so an identical line after a re-enable publishes nothing and the
    /// header stays empty. Note there is no `degrade()` anywhere in this
    /// test: `degrade()` resets the coalescer on its first line and would
    /// mask the bug.
    @Test func reEnablingRepublishesEvenTheIdenticalTrack() {
        let controller = MediaController()
        controller.supervisor.startHelper = {}
        controller.supervisor.stopHelper = {}
        let line = /* a real now-playing line */ ""
        var published = 0
        controller.onChange = { _ in published += 1 }

        controller.start()
        controller.handle(line: line)
        let afterFirst = published

        controller.setEnabled(false)
        controller.reset()
        controller.stop()

        controller.setEnabled(true)
        controller.start()
        controller.handle(line: line)

        #expect(published > afterFirst + 1, "the re-enable published nothing new")
    }

    /// An explicit re-enable hands back the retry budget; the activity
    /// gate's resume does not.
    @Test func reEnablingForgivesADegradedHelper() {
        let controller = MediaController()
        controller.supervisor.startHelper = {}
        controller.supervisor.stopHelper = {}
        controller.supervisor.scheduleRetry = { _, _ in }

        for _ in 0...HelperBackoff.maxAttempts {
            controller.supervisor.helperExited(status: 1)
        }
        #expect(controller.supervisor.isDegraded)

        controller.setEnabled(true)
        controller.start()

        #expect(controller.supervisor.isDegraded == false)
    }
```

Fill the two `/* a real now-playing line */` placeholders from
`MediaControllerTests`' existing fixture rather than inventing a format — read
the suite first; the payload grammar is pinned in `MediaPayloadTests`.

- [ ] **Step 2: Run to verify it fails, then implement**

```swift
    /// The lifecycle latch, separate from the activity gate.
    ///
    /// Two latches rather than one, copied from `ClipboardPoller`'s
    /// `isRunning` / `activity` split — which is why the clipboard module
    /// needs no new code for preferences at all. A single flag cannot
    /// distinguish "the user switched this off" from "the screen is
    /// locked", and conflating them is what lets an unlock resurrect a
    /// helper nobody asked for.
    private(set) var isEnabled = true

    /// Only ever called by `ModuleSwitchboard`. The latch exists as well as
    /// the switchboard, not instead of it: the switchboard keeps the policy
    /// in one readable place, and this makes the controller safe to call by
    /// somebody who has not read it.
    func setEnabled(_ enabled: Bool) { isEnabled = enabled }

    public func setActivity(_ activity: SystemActivity) {
        switch activity {
        case .active:
            guard isEnabled else { return }
            supervisor.start()
        case .locked, .asleep:
            supervisor.stop()
        }
    }
```

`start()` gains `supervisor.resetRetryBudget()` before `supervisor.start()`, and
`reset()` is `degrade()`'s body with `degrade()` reduced to calling it plus
whatever it needs to say about having failed.

Note the asymmetry deliberately: **`.locked` still stops a disabled
controller.** Stopping something already stopped is free; guarding it would only
add a way to be wrong.

- [ ] **Step 3: Run the full suite.** `SystemActivityFanOutTests`'
`unlockingStartsTheMediaHelperAgain` must still pass — the latch defaults to
`true`, so nothing that does not toggle sees a change. If it fails, the default
is wrong.

- [ ] **Step 4: Mutation-verify**

| Mutation | Must fail |
|---|---|
| drop the `guard isEnabled` from `setActivity` | `anUnlockDoesNotResurrectADisabledHelper` |
| `setActivity` returns early always | `anUnlockStillResumesAnEnabledHelper` |
| `reset()` does not nil `snapshot` | `disablingPublishesNothingPlaying` |
| `reset()` does not rebuild the coalescer | `reEnablingRepublishesEvenTheIdenticalTrack` |
| `start()` drops `resetRetryBudget()` | `reEnablingForgivesADegradedHelper` |
| `degrade()` stops calling `reset()` | the existing degrade tests |

- [ ] **Step 5: Commit**

```bash
git commit -m "fix: stop a screen unlock resurrecting a disabled media helper"
```

---

### Task 8: `PeekArbiter` learns to withdraw a peek

**Files:**
- Modify: `Sources/CreativeNotchCore/PeekArbiter.swift`
- Test: `Tests/CreativeNotchCoreTests/PeekArbiterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PeekArbiter.clearHUD()`, `PeekArbiter.clearPower()`. Task 14's
  disable verbs call them.

Because toggles take effect immediately, a peek already in the slot has to be
**withdrawn**, not waited out. A 3s power peek surviving its own module's
disable is small, visible, and exactly the kind of thing that makes a preference
feel unreliable. Three of the five contents already have a withdrawal verb:

| `PeekContent` | Module | Withdrawal verb |
|---|---|---|
| `.dragTarget` | shelf | `setDragActive(false)` — exists (`:53`) |
| `.timerDone` | timer | `dismissTimerDone()` — exists (`:72`) |
| `.hud` | HUD | `clearHUD()` — **new** |
| `.power` | power | `clearPower()` — **new** |
| `.nowPlaying` | media metadata | `setNowPlaying(nil)` — exists (`:57`) |

- [ ] **Step 1: Write the failing tests**, modelled on
`dismissingClearsItImmediately` in `TimerPeekArbitrationTests`

Assert, for each: the peek is returned before the clear and `nil` after; that
clearing one does **not** clear the other; and that clearing reveals whatever
was queued behind it rather than blanking the slot — a HUD peek cleared while
media is playing must return `.nowPlaying`, which is the whole reason the
arbiter is a priority list and not a single slot.

- [ ] **Step 2: Implement, run, and mutation-verify**

| Mutation | Must fail |
|---|---|
| `clearHUD()` does nothing | `clearingTheHudWithdrawsItsPeek` |
| `clearPower()` does nothing | `clearingPowerWithdrawsItsPeek` |
| `clearHUD()` also clears power | `clearingOneModulesPeekLeavesTheOthers` |
| `clearHUD()` clears `nowPlaying` too | `clearingTheHudRevealsWhatWasBehindIt` |

- [ ] **Step 3: Commit**

```bash
git commit -m "feat: let the arbiter withdraw a HUD or power peek on demand"
```

---

### Task 9: The MediaRemote probe becomes injectable

**Files:**
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift:70`-ish (the seam),
  `:387`
- Test: `Tests/CreativeNotchUITests/MediaControlsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppDelegate.mediaRemoteAvailable: () -> Bool`. Task 14 writes
  `state.showsMediaControls = prefs.mediaControls && mediaRemoteAvailable()`.

`MediaRemoteBridge` has a lazily `dlopen`'d `private static let handle`
(`:26`), and the `dlopen` fires on the **first read of `isAvailable`** (`:38`).
There is no `dlclose`, because `static let` is immutable. For the transport
toggle to mean "not loaded", the disabled path must not touch it — which makes
the operand order of a lazy `&&` load-bearing. Written the other way round it
compiles, behaves identically in every visible respect, and loads a private
framework the user just declined: **exactly the line a later tidy-up reverses
with nothing failing.**

Without a seam that order is unprovable. `handle` is already forced open by
`MediaRemoteBridgeTests` (`:22-27`) in the same process, so no test can
distinguish the two spellings by observing the bridge.

This task installs the seam only. The `&&` arrives in Task 14, where there is a
preference to put on its left.

- [ ] **Step 1: Write the failing test**

```swift
    /// The seam exists so the operand order in Task 14's `&&` can be
    /// asserted. Here it pins only that the delegate goes through it.
    @Test func installReadsAvailabilityThroughTheProbe() {
        let delegate = AppDelegate()
        var probes = 0
        delegate.mediaRemoteAvailable = { probes += 1; return true }
        delegate.shelfDirectory = /* a fresh temporary directory */ .init(fileURLWithPath: "")
        delegate.install(metrics: Self.notched)

        #expect(probes == 1)
        #expect(delegate.state.showsMediaControls)
    }
```

- [ ] **Step 2: Implement**

```swift
    /// Whether MediaRemote is loadable, behind a seam.
    ///
    /// In the shape of `playChime` and `now`, and for a sharper reason than
    /// either: reading `MediaRemoteBridge.isAvailable` is what performs the
    /// `dlopen`, and there is no `dlclose`. Once the transport toggle exists
    /// the read has to sit on the right of a lazy `&&` with the preference
    /// on the left, and a test can only prove that by counting calls to
    /// this.
    var mediaRemoteAvailable: () -> Bool = { MediaRemoteBridge.isAvailable }
```

- [ ] **Step 3: Run, mutation-verify** (delegate reads `MediaRemoteBridge`
directly → the probe count is `0` and the test fails), **commit**

```bash
git commit -m "refactor: read MediaRemote availability through an injectable probe"
```

---

### Task 10: The shelf refuses drops when it is off

**Files:**
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift:390-432`
- Test: `Tests/CreativeNotchUITests/ShelfDropTests.swift`

**Interfaces:**
- Consumes: `AppState.preferences` (Task 3).
- Produces: nothing new. The guards are read by Task 14's shelf verb.

All three container closures are unconditional today. `onDragEntered`
(`:390-393`) transitions to `.receiving` **and** sets
`arbiter.setDragActive(true)`; `onDragExited` (`:394-397`) undoes both; `onDrop`
(`:398-432`) stores. **A disabled shelf that opens a drop target on a drag-over
is worse than no toggle**, because it advertises a feature and then refuses the
drop.

**Only the first two gain a guard.** The exit leg stays unconditional, so a
disabled shelf that somehow reached `.receiving` — a drag in flight when the
toggle flipped — can still leave it. A symmetric guard there is how the notch
gets stuck open.

- [ ] **Step 1: Write the failing tests**

```swift
    /// A drop target that appears and then refuses the file is worse than
    /// no drop target.
    @Test func aDisabledShelfOpensNoDropTarget() {
        let delegate = makeDelegate()
        delegate.state.preferences.shelf = false

        delegate.container?.onDragEntered?()

        #expect(delegate.state.state == .closed)
        #expect(delegate.arbiter.content(now: delegate.now()) == nil)
    }

    /// And the enabled half, or the above passes against a closure that was
    /// never wired.
    @Test func anEnabledShelfStillOpensItsDropTarget() {
        let delegate = makeDelegate()

        delegate.container?.onDragEntered?()

        #expect(delegate.state.state == .receiving)
    }

    @Test func aDisabledShelfStoresNothingEvenIfADropArrives() throws {
        let delegate = makeDelegate()
        let shelf = try #require(delegate.shelf)
        delegate.state.preferences.shelf = false

        delegate.container?.onDrop?([/* one real payload */])

        #expect(shelf.items.isEmpty)
    }

    /// The exit leg is deliberately NOT guarded: a drag already in flight
    /// when the toggle flipped must still be able to put the notch back.
    @Test func aDisabledShelfCanStillLeaveAReceivingState() {
        let delegate = makeDelegate()
        delegate.container?.onDragEntered?()
        #expect(delegate.state.state == .receiving)

        delegate.state.preferences.shelf = false
        delegate.container?.onDragExited?()

        #expect(delegate.state.state == .closed)
    }
```

If `container` is not reachable from a test, expose it `private(set)` for the
same reason every other controller is reachable — and say so in its doc comment.
`DropRegionTests` and `ShelfDropTests` already drive this area; read how they
reach the closures before adding a seam that duplicates one.

- [ ] **Step 2: Implement, run, mutation-verify**

| Mutation | Must fail |
|---|---|
| `onDragEntered` drops its guard | `aDisabledShelfOpensNoDropTarget` |
| `onDragEntered` always returns early | `anEnabledShelfStillOpensItsDropTarget` |
| `onDrop` drops its guard | `aDisabledShelfStoresNothingEvenIfADropArrives` |
| `onDragExited` gains a guard | `aDisabledShelfCanStillLeaveAReceivingState` |

- [ ] **Step 3: Commit**

```bash
git commit -m "feat: refuse drags and drops while the shelf is switched off"
```

---

### Task 11: `AppState.retarget(lastOpenTab:)`, the second and last writer

**Files:**
- Modify: `Sources/CreativeNotchUI/NotchRootView.swift:217-222` (beside the
  funnel)
- Test: `Tests/CreativeNotchUITests/AppStateFunnelTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppState.retarget(lastOpenTab:)`. Task 14 calls it.

`state` and `lastOpenTab` are `public private(set)` and `transition(to:)` is the
only writer — **by design, so a view cannot fix this itself**. But `lastOpenTab`
is assigned only on the `.open` branch (`:219`). With the panel **closed** and
`lastOpenTab == .clipboard`, the only way to correct it through the existing
funnel is to open the panel — so changing a setting would visibly open a window
on screen.

Hence exactly one further writer, documented beside the funnel comment as the
only other one there will be. **Correcting `lastOpenTab` is not optional:** fix
only the live state and the notch-tap reopen (`NotchRootView.swift:589`) fires
later from `.open(app.lastOpenTab)`, long after the toggle — the hardest version
of this bug to reproduce and the easiest to dismiss as a glitch.

- [ ] **Step 1: Write the failing tests**

Assert: `retarget` changes `lastOpenTab`; it does **not** change `state`; it
does not fire the funnel's `.state` notification (it is not a state change, and
an observer told the panel moved when it did not is a redraw for nothing); and a
subsequent notch tap opens the retargeted tab. Then extend whichever existing
test pins "transition is the only writer" to say "the only *state* writer",
honestly.

- [ ] **Step 2: Implement, run, mutation-verify, commit**

| Mutation | Must fail |
|---|---|
| `retarget` also assigns `state` | `retargetingDoesNotMoveThePanel` |
| `retarget` does nothing | `retargetingChangesWhereTheNotchTapWillOpen` |
| `retarget` notifies the funnel | `retargetingIsNotAStateChange` |

```bash
git commit -m "feat: let the last open tab be corrected without opening the panel"
```

---

### Task 12: `startSubsystems()`, so the launch path can be tested at all

**Files:**
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift:193-228`
- Test: `Tests/CreativeNotchUITests/AppDelegateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppDelegate.startSubsystems()`. Task 13 replaces its body with
  `activity.start(); switchboard.apply()`.

**`applicationDidFinishLaunching` is not drivable from a test and never has
been.** It reads `NSScreen.main`, installs a real `MenuBarController`, calls
`showIfNeeded()` on a non-injectable `OnboardingController`
(`AppDelegate.swift:42`) that pops a real window on a fresh domain, and calls
`orderFrontRegardless()`. `grep applicationDidFinishLaunching Tests/` returns
zero call sites. R5 — "the toggle applies on change but not at launch" — is
therefore untestable until the five start lines move somewhere reachable.

This task is a pure refactor: same lines, same order, one method call.

- [ ] **Step 1: Write the failing tests**

```swift
    /// Everything that starts a subsystem, in one method a test can call.
    @Test func startingSubsystemsStartsThem() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        let media = try #require(delegate.media)
        var starts = 0
        media.supervisor.startHelper = { starts += 1 }
        media.supervisor.stopHelper = {}

        delegate.startSubsystems()

        #expect(clipboard.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
        #expect(starts == 1)
        #expect(delegate.power?.isObserving == true)
        delegate.activity.stop()
    }

    /// The call site is pinned the only way this repo can pin it, in the
    /// shape of `ClipboardStoreTests.theStoreNeverTouchesTheFileSystem`:
    /// `applicationDidFinishLaunching` is unreachable from a test, so the
    /// thing that stops a start line drifting back into it is a source
    /// scan. **This scan, not a behavioural test, is what covers the launch
    /// call site.**
    @Test func theLaunchPathStartsSubsystemsOnlyThroughTheOneMethod() throws {
        let source = try String(contentsOf: /* AppDelegate.swift */, encoding: .utf8)
        let body = /* the text between `applicationDidFinishLaunching` and the
                      next `public func` */
        #expect(body.contains("startSubsystems()"))
        for banned in ["hud?.start()", "clipboard?.start()", "media?.start()",
                       "power?.start()", "activity.start()"] {
            #expect(body.contains(banned) == false, "\(banned) is back in the launch path")
        }
    }
```

Locate the source file the way `ClipboardStoreTests` does — read that suite
first and copy its path derivation rather than inventing a second one.

- [ ] **Step 2: Implement**

```swift
    /// Everything that starts a subsystem, in one place.
    ///
    /// Split out of `applicationDidFinishLaunching` because that method is
    /// not drivable from a test — it reads `NSScreen.main`, installs a real
    /// status item, and pops a real onboarding window on a fresh defaults
    /// domain. Behaviour that only ever ran there was behaviour nothing
    /// could assert, which is precisely where a preference that applies on
    /// change but not at launch would hide.
    func startSubsystems() {
        activity.start()
        hud?.start()
        clipboard?.start()
        media?.start()
        power?.start()
    }
```

`applicationDidFinishLaunching` calls it and contains nothing else
module-related.

- [ ] **Step 3: Run the full suite, mutation-verify, commit**

| Mutation | Must fail |
|---|---|
| `startSubsystems()` omits `media?.start()` | `startingSubsystemsStartsThem` |
| a start line moved back inline into the launch method | `theLaunchPathStartsSubsystemsOnlyThroughTheOneMethod` |

```bash
git commit -m "refactor: gather every subsystem start into one testable method"
```

---

### Task 13: `ModuleSwitchboard` takes over the three lists

**Files:**
- Create: `Sources/CreativeNotchUI/ModuleSwitchboard.swift`
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift` (`preferencesDefaults`,
  `install`, `startSubsystems`, `applicationWillTerminate`, `activity.onChange`)
- Modify: `Tests/CreativeNotchUITests/NotchedDelegate.swift` and **every**
  per-suite `makeDelegate()`
- Test: `Tests/CreativeNotchUITests/ModuleSwitchboardTests.swift` (new)
- Test: `Tests/CreativeNotchUITests/SystemActivityFanOutTests.swift`

**Interfaces:**
- Consumes: Tasks 1 to 12.
- Produces: `ModuleSwitchboard` with `apply()`, `stopAll()`, `setActivity(_:)`;
  `AppDelegate.preferencesDefaults`. Task 14 adds `setEnabled(_:for:)`.

**Three straight-line lists exist today and none contains every module:**

| List | Location | Contents |
|---|---|---|
| Start | `AppDelegate.swift:220-227` (now `startSubsystems()`) | `hud`, `activity`, `clipboard`, `media`, `power` |
| Stop | `:230-237` | screen observers, `hud`, `clipboard`, `media`, `power`, `activity` |
| Activity fan-out | `:288-314` | `clipboard`, `media`, `timer`, `power` |

`hud` is in the first two and not the third; `timer` is in the third and not the
first two; the shelf and the transport controls are in none. A seven-way
preference across three disagreeing lists is twenty-one chances for one to be
missed, silently.

**The effective-state table, because one formula is wrong.** "Enabled AND
activity" is right for the lifecycle verbs and wrong applied uniformly:

| Module | Activity axis | Under preferences |
|---|---|---|
| Clipboard | stop on inactive | unchanged; the poller's own latch composes |
| Media metadata | stop on inactive | unchanged; Task 7's latch |
| Timer | reschedule only | **fanned out unconditionally while `countdown != nil`** |
| Power | suppress peeks only | unchanged |
| HUD / transport / shelf | none | none. Preference only |

**The HUD has no activity axis and must not gain one.** A uniform formula would
newly stop it on every screen lock, tearing down and recreating a `CGEventTap`
per lock/unlock cycle — and `MediaKeyMonitor.start()` records success as
`isRunning = token != nil` (`:51`) with **no retry**, so one `CGEventTapCreate`
failure in an unlock window leaves the HUD silently dead for the session. That
window does not exist today. Do not create it.

**`setActive` reaches the timer even while the timer is disabled**, for as long
as `timer.countdown != nil`. It is a scheduling-rate verb, not a lifecycle verb:
freezing `isActive` at `true` on a disabled-but-running countdown costs a
25-minute timer on a locked machine ~84 wakes where `TimerSchedule` promises
one.

**`install(metrics:)` constructs and wires the switchboard and starts
nothing.** `apply()` runs only from `startSubsystems()`.

- [ ] **Step 1: Add the defaults seam and fix the test helpers first**

`AppDelegate` gains `var preferencesDefaults: UserDefaults = .standard`, set
before `install(metrics:)` exactly as `shelfDirectory` (`:120`) and
`growthDelay` (`:171`) are; `install` builds
`PreferencesStore(defaults: preferencesDefaults)`.

**Then update every helper that builds an `AppDelegate`, in the same commit:**
`NotchedDelegate.make` plus the private `makeDelegate()` in
`AppDelegateTests`, `ClipboardWiringTests`, `DismissBehaviourTests`,
`DropRegionTests`, `GrowthLagTests`, `MediaWiringTests`, `NowPlayingTests`,
`PanelPassthroughTests`, `PowerWiringTests`, `ShelfDropTests` and
`SystemActivityFanOutTests`. Each sets a UUID-suffixed suite cleared with
`removePersistentDomain`. **This is required editing, not optional:** without
it every wiring suite reads the developer's real `com.gcdz.creativenotch`
domain, and a developer who disabled media in the real app makes
`lockingStopsTheMediaHelper` fail on their machine and nowhere else.

- [ ] **Step 2: Write the failing tests**

`ModuleSwitchboardTests`, and additions to `SystemActivityFanOutTests`:

```swift
    /// R5. The launch path and a live toggle are the same code, so "off at
    /// launch" cannot drift from "turned off at runtime" — and the one that
    /// drifts is always the launch path, because a developer's machine has
    /// every module on.
    @Test func aModuleDisabledBeforeLaunchNeverStarts() throws {
        let delegate = makeDelegate()              // preferencesDefaults injected
        delegate.preferencesStore.setEnabled(false, for: .clipboard)
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }

        delegate.startSubsystems()

        #expect(clipboard.poller.scheduledInterval == nil)
        delegate.activity.stop()
    }

    /// The ON case is what makes the OFF case mean anything: `nil` is also
    /// what a poller that was never started looks like.
    @Test func aModuleEnabledBeforeLaunchStarts() throws { /* the mirror */ }

    /// R11. Quit stops five things today while the switchboard owns seven.
    /// This is the one lifecycle call site that is drivable.
    @Test func terminatingStopsEverythingThatWasRunning() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        let media = try #require(delegate.media)
        var stops = 0
        media.supervisor.startHelper = {}
        media.supervisor.stopHelper = { stops += 1 }

        delegate.startSubsystems()
        #expect(clipboard.poller.scheduledInterval != nil)
        #expect(delegate.power?.isObserving == true)

        delegate.applicationWillTerminate(Notification(name: .init("t")))

        #expect(clipboard.poller.scheduledInterval == nil)
        #expect(stops == 1)
        #expect(delegate.power?.isObserving == false)
    }

    /// R6. The switchboard is the one-line addition the fan-out comment
    /// promised, wearing a name. It registers nothing.
    @Test func theSwitchboardRegistersNoSecondObserver() {
        let delegate = makeDelegate()
        let observers = delegate.stateObserverCount
        delegate.activity.start()

        #expect(delegate.activity.tokenCount == 4)
        #expect(delegate.stateObserverCount == observers)
        delegate.activity.stop()
    }
```

Every existing test in `SystemActivityFanOutTests` must still pass unchanged.
They drive `activity.handle(...)` and never call `apply()`, so the switchboard's
preferences are still `.allEnabled` in those suites — **which is exactly why the
switchboard's initial value must be `.allEnabled` rather than a load from the
store.** State that in the type's doc comment.

- [ ] **Step 3: Implement the switchboard**

```swift
/// The one place that knows how to start and stop every module.
///
/// ROADMAP asks for module toggles "next to the `SystemActivity` gate, in
/// the same place that already knows how to start and stop these
/// subsystems". That place was `AppDelegate` — and it was three
/// straight-line lists that did not agree: `hud` in two of them, `timer` in
/// the third, the shelf and the transport controls in none.
///
/// Holds the resolved `Preferences` and the current `SystemActivity` and
/// composes them per module. **Not one formula:** the HUD has no activity
/// axis and must not gain one, and the timer's `setActive` is a
/// scheduling-rate verb that keeps firing while a disabled countdown runs.
/// See the spec's effective-state table.
///
/// Starts at `.allEnabled` rather than loading from the store, so
/// constructing a delegate is not a defaults read: `apply()` is the only
/// thing that consults storage, and it runs from `startSubsystems()`.
@MainActor
final class ModuleSwitchboard { … }
```

`apply()` runs the full table from the current preferences. `stopAll()` stops
all seven regardless of preference — a module already stopped stops for free,
and a quit path that consults a preference is a quit path that can be wrong.
`setActivity(_:)` fans out per the table.

`AppDelegate` wires it: `install` constructs it, `startSubsystems()` becomes
`activity.start(); switchboard.apply()`, `applicationWillTerminate` becomes
`removeScreenObservers(); switchboard.stopAll(); activity.stop()`, and
`activity.onChange` becomes a single `self.switchboard.setActivity(state)` —
carrying forward the four comments at `:286-313` that explain why the timer's
leg is different, because that reasoning does not survive the move on its own.

- [ ] **Step 4: Run the full suite, mutation-verify**

| Mutation | Must fail |
|---|---|
| `apply()` ignores preferences and starts everything | `aModuleDisabledBeforeLaunchNeverStarts` |
| `apply()` starts nothing | `aModuleEnabledBeforeLaunchStarts` |
| `stopAll()` omits the media leg | `terminatingStopsEverythingThatWasRunning` |
| `setActivity` omits the clipboard leg | `lockingStillSuspendsTheClipboardPoller` |
| `setActivity` omits the media leg | `lockingStopsTheMediaHelper` |
| `setActivity` omits the power leg | `lockingSilencesThePowerPeek` |
| the switchboard registers its own `activity.onChange` | `theSwitchboardRegistersNoSecondObserver` |
| `apply()` called from `install(metrics:)` | the whole UI suite — a real timer and a real `perl` in fourteen suites. **Confirm it is loud, and say so** |

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor: route every module's lifecycle through one switchboard"
```

---

### Task 14: `setEnabled` — the toggle that stops the subsystem

**Files:**
- Modify: `Sources/CreativeNotchUI/ModuleSwitchboard.swift`
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift` (`modulesDidChange()`,
  `timerDidFinish`, the transport `&&`)
- Test: `Tests/CreativeNotchUITests/ModuleToggleTests.swift` (new)
- Test: `Tests/CreativeNotchUITests/TimerWiringTests.swift` (R10)

**Interfaces:**
- Consumes: everything above.
- Produces: `ModuleSwitchboard.setEnabled(_:for:)`. Task 15's window calls it
  and nothing else.

**This is the task the whole plan exists for**, and the one where a green suite
is least reassuring: the preference will be stored correctly and the UI will
update correctly whether or not the subsystem stops.

Each stop verb is followed by **one** `AppDelegate.modulesDidChange()`, which
calls `syncTrackingRect()` (`:570`) and `reevaluatePeek()` (`:756`) — the pair
`nowPlayingDidChange` (`:518-524`) already uses, which is why that one method is
the only disable path in the tree that works. Without it, these verbs stop the
subsystem and leave its output on screen.

| Module | Disable does | Enable does |
|---|---|---|
| `hud` | `hud.stop()`, `arbiter.clearHUD()` | `hud.start()` |
| `media-metadata` | `media.setEnabled(false)`, `media.reset()`, `nowPlayingDidChange(nil)`, `media.stop()` | `media.setEnabled(true)`, `media.start()` |
| `clipboard` | `clipboard.stop()` | `clipboard.start()` |
| `power` | `power.stop()`, `power.reset()`, `state.power = nil`, `arbiter.clearPower()` | `power.start()` |
| `timer` | nil the four `state.on*Timer` closures, `arbiter.dismissTimerDone()` | restore the four closures |
| `media-controls` | `state.showsMediaControls = false`, `state.onMediaCommand = nil` | restore both, through the `&&` |
| `shelf` | `state.shelf = nil` | `state.shelf = shelf` |

Then, for every module: write `state.preferences`, recompute the visible tab
list, correct `state.state` and `lastOpenTab` if either names a tab that has
gone, persist through the store, and call `modulesDidChange()`.

**Three things that are not symmetric, and are not mistakes:**

- **The timer's countdown is not cancelled.** The tab goes immediately and the
  four closures are nilled so no new countdown can start, but a running one
  completes and chimes. `timer.onChange` and `timer.onFinished` are **not**
  among the four — they are the publish and finish paths, and nilling them for
  symmetry is the failure mode. The badge stays, because a chime with no prior
  warning is worse than a badge with no tab behind it.
- **A countdown that finishes after the disable chimes but does not peek.**
  `timerDidFinish` still calls `playChime()` — the interruption is what the user
  asked for — but skips `recordTimerFinished` when `state.preferences.timer` is
  false. `timerDoneTTL` is 600s and outranks `.hud` and `.power`, so recording
  would hold the shared peek slot for ten minutes on behalf of a switched-off
  module, swallowing volume feedback — and it would be **unclearable**, because
  `dismissTimerDone()`'s sole caller (`:863`) is behind a transition to `.open`
  and there is no tab left to reach.
- **`hasBattery` is never cleared.** Capability and preference stay two values.

**Operand order is load-bearing**: `prefs.mediaControls && mediaRemoteAvailable()`,
never the reverse. `&&` is lazy, and the reverse loads a private framework the
user just declined.

- [ ] **Step 1: Write the failing tests — one function per module, three steps
each**

The shape, repeated seven times. **Start it, assert it is running, toggle off,
assert it stopped.** The middle assertion is not decoration: at rest,
`scheduledInterval` is `nil`, `isObserving` is `false` and `state.nowPlaying` is
`nil`, so without it every one of these passes with the toggle deleted.

```swift
    /// R2, clipboard leg. Deleting one `setActivity` line once left all 471
    /// tests green while the helper ran on through lock and sleep; this is
    /// the same assertion for a preference.
    @Test func disablingClipboardStopsTheOnlyRepeatingTimerInTheProject() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        delegate.startSubsystems()
        #expect(clipboard.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)

        delegate.switchboard.setEnabled(false, for: .clipboard)

        #expect(clipboard.poller.scheduledInterval == nil)
        delegate.activity.stop()
    }

    /// R8. Twice, in both directions: a preference snapshotted at
    /// construction works exactly once.
    @Test func aModuleFollowsTheToggleEveryTimeItMoves() throws { /* off, on, off */ }

    /// The HUD's running half needs Accessibility, so the flag is captured
    /// once and the hard consequence asserted only inside `if keysStarted`
    /// — the shape `HUDControllerTests.stopStopsAllThreeOwnedSources` uses.
    @Test func disablingTheHudReleasesTheEventTap() throws { … }

    /// Media transport asserts the injected probe, not the resolved
    /// boolean, which is `false` on a host with no MediaRemote — and the
    /// count is what proves the lazy `&&` is the right way round.
    @Test func disablingTransportControlsDoesNotLoadMediaRemote() {
        let delegate = AppDelegate()
        var probes = 0
        delegate.mediaRemoteAvailable = { probes += 1; return true }
        delegate.preferencesDefaults = /* a fresh suite */
        delegate.preferencesStore.setEnabled(false, for: .mediaControls)
        delegate.install(metrics: Self.notched)
        delegate.startSubsystems()

        #expect(probes == 0, "the preference must be the left operand of the &&")
        #expect(delegate.state.showsMediaControls == false)
        delegate.activity.stop()
    }

    /// R3, at the visible layer. An arbiter assertion alone proves nothing:
    /// the arbiter is queried rather than pushed, so a peek withdrawn from
    /// it is still on screen until something re-asks.
    @Test func disablingPowerTakesItsPeekOffTheScreen() {
        let delegate = makeDelegate()
        delegate.showPowerPeek(.unplugged(level: 66))
        #expect(delegate.state.state == .peek(.power(.unplugged(level: 66))))

        delegate.switchboard.setEnabled(false, for: .power)

        #expect(delegate.state.state == .closed)
        #expect(delegate.state.power == nil)
    }

    /// The stale now-playing badge widens the closed notch's hit-test
    /// region forever. Measured against `NotchedDelegate.metrics`, not a
    /// fourth private copy of the numbers.
    @Test func disablingMediaNarrowsTheClosedNotchBackToItsBareWidth() { … }

    /// R7. Both selection paths, because fixing only the live state leaves
    /// the notch tap to reopen a dead tab minutes later.
    @Test func disablingTheOpenTabMovesToAVisibleOne() { … }
    @Test func disablingAClosedPanelsLastTabRetargetsItWithoutOpening() { … }
    @Test func theTimerTabStopsTakingKeyFocusWhenTheTimerIsOff() {
        #expect(AppDelegate.shouldTakeKey(for: .open(.timer)))
        // with the timer off, `.open(.timer)` is unreachable — assert the
        // state that results from disabling, not the static function alone.
    }

    /// R1 as a gesture, through the delegate rather than the controller.
    @Test func disablingMediaAndThenUnlockingLeavesTheHelperStopped() { … }
```

And R10, in `TimerWiringTests`, with an injected clock and `playChime` counting:

```swift
    /// The timer's asymmetry is deliberate and nothing pins it today. A
    /// later implementer nilling `onFinished` for symmetry, or routing
    /// `setActive` through the enabled check, would break nothing.
    @Test func aRunningCountdownSurvivesTheTimerBeingSwitchedOff() throws {
        // start a countdown; disable the timer
        // #expect(timer.countdown != nil) and scheduledWake != nil
        // advance the clock past the deadline, drive the wake
        // #expect(chimes == 1)
        // #expect(delegate.state.state != .peek(.timerDone(…)))
        // #expect(timer.pending == nil && timer.scheduledWake == nil)
        // #expect(delegate.acceptedRect.width == 230)
    }

    /// Through the surviving API, so the test proves the effect rather than
    /// the implementation: the tab is gone, but the closure it called is
    /// what must be dead.
    @Test func noNewCountdownCanBeStartedWhileTheTimerIsOff() throws {
        // disable, then state.onStartTimer?(1500)
        // #expect(delegate.timer?.countdown == nil)
    }

    /// The scheduling-rate verb keeps firing on a disabled-but-running
    /// countdown, or a locked machine pays ~84 wakes for one deadline.
    @Test func aDisabledCountdownStillSchedulesOnTheDeadlineWhenTheScreenLocks() throws { … }
```

- [ ] **Step 2: Run to verify they fail, then implement `setEnabled`**

One method, a `switch` over `ModuleID`, each case the row from the table above,
followed unconditionally by: `state.preferences[module] = enabled`; the tab
recomputation through `TabVisibility.fallback`; `store.setEnabled(_:for:)`;
`delegate.modulesDidChange()`.

`modulesDidChange()` is new and internal on `AppDelegate`:

```swift
    /// Puts the screen back in step after a module's lifecycle changed.
    ///
    /// The pair `nowPlayingDidChange` already uses, and the reason that is
    /// the only disable path in the tree that works today: `syncTrackingRect`
    /// because the closed notch's width is derived from what the modules are
    /// publishing, and `reevaluatePeek` because withdrawing something from
    /// the arbiter changes nothing on screen until something re-asks it.
    ///
    /// **The switchboard reaches AppKit through the module verbs and this
    /// method, and nothing else.**
    func modulesDidChange() {
        syncTrackingRect()
        reevaluatePeek()
    }
```

- [ ] **Step 3: Run the full suite, then mutation-verify**

| Mutation | Must fail |
|---|---|
| `setEnabled` writes the preference and calls no verb | every per-module test |
| the clipboard case omits `poller.stop()` | `disablingClipboardStopsTheOnlyRepeatingTimerInTheProject` |
| the media case omits `setEnabled(false)` on the controller | `disablingMediaAndThenUnlockingLeavesTheHelperStopped` |
| the media case omits `nowPlayingDidChange(nil)` | `disablingMediaNarrowsTheClosedNotchBackToItsBareWidth` |
| the power case omits `clearPower()` | `disablingPowerTakesItsPeekOffTheScreen` |
| `modulesDidChange()` drops `reevaluatePeek()` | `disablingPowerTakesItsPeekOffTheScreen` |
| `modulesDidChange()` drops `syncTrackingRect()` | `disablingMediaNarrowsTheClosedNotchBackToItsBareWidth` |
| the `&&` operands swapped | `disablingTransportControlsDoesNotLoadMediaRemote` |
| `lastOpenTab` left uncorrected | `disablingAClosedPanelsLastTabRetargetsItWithoutOpening` |
| the timer case calls `timer.cancel()` | `aRunningCountdownSurvivesTheTimerBeingSwitchedOff` |
| the timer case nils `onFinished` | same |
| `timerDidFinish` records a peek regardless of the preference | same |
| `setActivity` routed through the enabled check for the timer | `aDisabledCountdownStillSchedulesOnTheDeadlineWhenTheScreenLocks` |
| the preference re-read at each use rather than written to `AppState` | none — **note it**; the seam that makes R8 structurally unavailable is architectural, and only `aModuleFollowsTheToggleEveryTimeItMoves` bites at all |

- [ ] **Step 4: Commit**

```bash
git commit -m "feat: make a module toggle stop the module's subsystem"
```

---

### Task 15: The preferences window

**Files:**
- Create: `Sources/CreativeNotchUI/PreferencesWindow.swift`
- Modify: `Sources/CreativeNotchUI/MenuBarController.swift`
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift` (the menu bar callback)
- Test: `Tests/CreativeNotchUITests/PreferencesWindowTests.swift` (new)
- Test: `Tests/CreativeNotchUITests/MenuBarControllerTests.swift`

**Interfaces:**
- Consumes: `ModuleSwitchboard.setEnabled(_:for:)`.
- Produces: the surface. **It calls `setEnabled` and nothing else** — it does not
  touch `PreferencesStore`, a controller, or `AppState`.

**A window, following `OnboardingWindow`.** The panel disqualifies itself on its
own construction: a `.nonactivatingPanel` dismissed on a 400ms grace when the
cursor leaves, taking key focus for exactly one tab. A form that closes 400ms
after your cursor strays and does not hold the keyboard is the wrong container.
A menu of seven checkboxes was considered and declined — it does not scale past
the toggles and has nowhere to put the honesty notes.

**It is reachable from the menu bar, not the panel.** With every tab-bearing
module disabled the visible list is empty, the panel has nowhere to open, and
the notch tap is a deliberate no-op. The menu bar is the escape hatch, and the
reason an empty tab list is a legal state rather than a trap.

Follow `OnboardingController`'s split exactly: a controller holding the window
with an injectable presenter, so a test can drive `show()` without a window
server.

**Three pieces of copy are required, not decorative** (spec §2.6, §2.7, §10):

- Beside the shelf switch: its idle cost is genuinely zero, so this toggle is
  about surface, not battery. Say it rather than implying a saving.
- Beside the transport switch: **only disabled-at-launch means not loaded.**
  Toggling transport off mid-session leaves MediaRemote mapped for the session.
- Beside the timer switch, **when a countdown is running**: turning the timer
  off removes the tab you would cancel it from. The countdown will finish and
  chime.

And one honesty rule with teeth: **the window must not report the HUD as on when
the tap failed.** `CGEventTapCreate` genuinely fails without Accessibility and
`MediaKeyMonitor.start()` records that as `isRunning = token != nil` with no
retry. A switch reading "on" over a dead subsystem is the exact inversion of the
failure this module exists to prevent.

- [ ] **Step 1: Write the failing tests**

```swift
    /// The window writes through the switchboard and nowhere else: one
    /// direction, one source of truth, and no second path that could apply
    /// a change without persisting it or persist one without applying it.
    @Test func flippingASwitchStopsTheSubsystem() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        delegate.startSubsystems()
        #expect(clipboard.poller.scheduledInterval != nil)

        let controller = PreferencesController(switchboard: delegate.switchboard,
                                               state: delegate.state)
        controller.setEnabled(false, for: .clipboard)

        #expect(clipboard.poller.scheduledInterval == nil)
        delegate.activity.stop()
    }

    /// Every module gets a switch, or one ships unreachable — the failure
    /// `PanelTabBar` was built to stop repeating.
    @Test func everyModuleHasASwitch() {
        #expect(Set(PreferencesView.rows.map(\.module)) == Set(ModuleID.allCases))
    }

    /// The HUD row cannot claim the subsystem is up when the tap is down.
    @Test func theHudRowReportsThePermissionNotThePreference() { … }

    /// The warning is conditional on a live countdown: showing it always
    /// trains people to ignore it.
    @Test func theTimerRowWarnsOnlyWhileACountdownIsRunning() { … }

    /// A window-opening item in the menu, and the reason an empty tab list
    /// is survivable.
    @Test func theMenuOffersPreferences() { … }
```

- [ ] **Step 2: Implement, run, mutation-verify**

| Mutation | Must fail |
|---|---|
| the view writes `PreferencesStore` directly | `flippingASwitchStopsTheSubsystem` |
| a row dropped from `rows` | `everyModuleHasASwitch` |
| the HUD row reads the preference | `theHudRowReportsThePermissionNotThePreference` |
| the timer warning shown unconditionally | `theTimerRowWarnsOnlyWhileACountdownIsRunning` |
| the menu item removed | `theMenuOffersPreferences` |

- [ ] **Step 3: Rewrite `MenuBarController`'s own doc comment**

`:3-4` reads *"The only settings surface. A four-module personal tool does not
need a preferences window."* Both halves are now false. Replace it with what the
menu bar is: the app's escape hatch — the one surface that is reachable when
every tab-bearing module is switched off.

- [ ] **Step 4: Manual verification — part of done, not polish**

```bash
./Scripts/dev.sh --release
```

The transport module shipped a layout bug to `main` because its manual step was
skipped, and the metadata module's helper was dead in the packaged app while
every terminal check passed. Confirm and **record the result of each**:

1. **The event tap is genuinely released.** Disable the HUD; volume keys no
   longer produce a notch pill, and the app goes quiet in Accessibility.
2. **The `perl` process is genuinely gone.** Disable media metadata and confirm
   with `pgrep -f` against the **packaged `.app`**, not a `swift run` binary.
3. **Lock and unlock with media disabled**, and confirm no helper appears. R1
   as a gesture.
4. **`defaults delete com.gcdz.creativenotch`, relaunch.** Every module is on.
   This is R9, and it is caught instantly here and by nothing else.
5. **Disable the timer with a countdown running.** The tab goes, the badge
   stays, the chime fires, no peek appears, and the badge clears afterwards.
6. **Disable every tab-bearing module.** The notch tap does nothing, and the
   menu bar still opens the window.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: add the preferences window and reach it from the menu bar"
```

---

### Task 16: The docs, which are part of shipping

**Files:** `README.md`, `docs/ROADMAP.md`, `docs/ARCHITECTURE.md`,
`docs/DEVELOPMENT.md`.

- [ ] **Step 1: `ARCHITECTURE.md` — a Preferences section**

After the Timer section. It must cover, because none of it is guessable from the
code:

- **`ModuleSwitchboard` and why it exists**: three start lists that did not
  agree, and the rule that effective state is computed in one place — with the
  effective-state table, because "enabled AND activity" is wrong applied
  uniformly and the next reader will otherwise simplify it.
- **The two deliberate asymmetries**: the HUD has no activity axis and must not
  gain one; the timer's `setActive` fires while the timer is disabled.
- **Defaults as a compatibility surface**: `ModuleID`'s raw values are the keys;
  absent means ON and why `bool(forKey:)` is the wrong polarity; wrong type is
  treated as unset and not rewritten; nothing observes the domain in either
  direction, so a `defaults write` needs a relaunch.
- **Disabled controllers are kept, idle**, with the reason teardown was declined.

- [ ] **Step 2: `ARCHITECTURE.md` — the stale claims**

Each is wrong **now**, before this module changed anything:

| Location | Claim | Correction |
|---|---|---|
| `:32-33` | *"the media helper subprocess, which is the gate's second consumer. Those two are the whole list."* | Four consumers — clipboard, media, timer, power |
| `:655-659` | *"now gates three subsystems"* | Four; it omits the timer and contradicts its own exemption section at `:594-602` |
| `:17-21` | the "not allowed" list | The event tap is on it and ships anyway — now under a switch. Record that, since it is the one toggle that turns off something the architecture forbids |

- [ ] **Step 3: `docs/ROADMAP.md`**

Move Preferences out of the planned list and mark it shipped, keeping its
analysis. **Four modules remain planned.** Renumber the rest and update the
"Suggested order" section, which listed Preferences first: record that the
remaining four now have the home it was built to give them. Correct `:152` —
*"clipboard retention"* names no constant that exists; `ClipboardStore` has
`capacity` and `maxTotalBytes` and no age-based expiry of any kind, and the
7-day `maxAge` is the shelf's.

- [ ] **Step 4: `README.md`**

- Status table `:315`: Preferences from `Planned` to **Shipped**, and check the
  surrounding prose for a count of what is planned.
- A usage row: where the window is, what each switch stops, and the three
  honesty notes in one line each.
- The uninstall instructions at `:206` now delete seven more keys — say that
  deleting the domain resets every module to on, which is the shipped state.

- [ ] **Step 5: The hardcoded test counts — measure, never copy**

`docs/DEVELOPMENT.md` hardcodes counts in three places (`:10` `all 752`, `:105`
`322`, `:106` `430`), and `README.md` in four (`:17` the badge, `:265`, and
`:291-292` per target). CI checks none of them.

```bash
swift test 2>&1 | tail -1        # "Test run with N tests in M suites passed"
swift test --filter CreativeNotchCoreTests 2>&1 | tail -1
swift test --filter CreativeNotchUITests 2>&1 | tail -1
grep -n '752\|322\|430' README.md docs/DEVELOPMENT.md
```

**Take the numbers from the first three commands and from nowhere else.** The
baseline in this plan is 752 and it was already stale once. The `grep` is there
because the brief said two sites in `README.md` and there are four — run it and
fix every hit rather than trusting either count.

- [ ] **Step 6: Commit**

```bash
git commit -m "docs: record preferences as shipped and correct what it made false"
```

---

## Definition of done

- [ ] `swift test` passes, and the measured count is in `README.md` and
  `docs/DEVELOPMENT.md` at all seven sites.
- [ ] Every new test has been proven to fail against a deliberately introduced
  bug, with `swift build` confirmed green first, and the evidence is in the PR
  body as `CONTRIBUTING.md` requires.
- [ ] `CorePurityTests` passes with all five Preferences filenames in its
  manifest.
- [ ] **No new app-lifetime registration.** `delegate.activity.tokenCount == 4`
  and `delegate.stateObserverCount` unchanged after a toggle; `grep -rn
  "didChangeNotification\|addObserver(self, forKeyPath" Sources/` finds nothing
  new.
- [ ] **No new `Timer`, no new global event monitor.** The clipboard poller and
  the HUD's tap remain the only ones — and both are now switchable off.
- [ ] `grep -rn "UserDefaults" Sources/CreativeNotchUI/` finds only the
  injection points, never a read: every resolution goes through
  `PreferenceKeys`.
- [ ] The six manual checks in Task 15 Step 4 have been performed on real
  hardware against the **packaged app**, and what was seen is written down.
- [ ] `README`, `ROADMAP`, `ARCHITECTURE` and `DEVELOPMENT` updated, including
  every stale claim in the spec's §12 table.

## Deliberately not built

- **Every tunable.** Seven keys, no sliders. Dwell delay and the clipboard poll
  interval are ready and still deferred, to hold the first release's
  compatibility surface at seven. HUD peek duration is two values that must move
  together and needs the arbiter's TTLs injected first; "clipboard retention"
  names no constant that exists; capacity values are non-retroactive and, for
  the shelf, destructive — lowering a shelf limit sends real user files to the
  Trash at the next drop.
- **Tearing down a disabled controller.** Idle cost is provably zero and
  `install(metrics:)` is not safely re-entrant. Revisit only if a future
  module's idle-but-constructed cost turns out not to be zero.
- **Deleting data on disable.** Disabling is not deleting; `clear()` already
  exists on the menu bar for both stores.
- **Observing the defaults domain.** A `defaults write` needs a relaunch,
  deliberately. The window is the supported way to change a preference, and the
  domain is a persistence format rather than an API.
- **Launch at login and the global hotkey.** Both are roadmap modules in their
  own right. This module builds the somewhere they will live and does not
  pre-empt what goes in it.
- **Persisting `lastOpenTab`.** `TimerTabTests.swift:10-11` says `Tab`'s raw
  values are *"persisted as a raw string via `lastOpenTab`"*. No such
  persistence exists, and v1 does not add it — but `ModuleID`'s raw values **are**
  persisted, so the argument that comment makes is now true of a different type.
- **Import, export, profiles, or sync.** iCloud needs the paid Developer
  Program, and the rest are features of a much larger app.
