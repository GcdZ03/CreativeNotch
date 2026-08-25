# System HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Volume and brightness feedback in the notch, **alongside** Apple's HUD rather than replacing it — filling the gap where macOS gives no feedback at all: Control Center, Siri, the menu bar slider, other applications.

**Architecture:** Both levels are observed as *values* (CoreAudio, DisplayServices), which needs no permission and catches every change whatever caused it. A global media-key monitor attributes changes to keypresses so the notch can stay silent in the one case Apple already covers. The pure halves — attribution timing and duplicate coalescing — live in `CreativeNotchCore` and run headlessly; the observers are thin AppKit wrappers.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, CoreAudio, DisplayServices (private, via `dlopen`), Swift Testing, SwiftPM. No third-party dependencies.

**Spec:** `docs/specs/2026-08-25-system-hud-design.md`
**Research:** `docs/research/2026-08-22-hud-feasibility.md`

## Global Constraints

- Minimum platform **macOS 26.0**.
- **No third-party dependencies.**
- **`CreativeNotchCore` must never `import AppKit` or `import SwiftUI`.** `CorePurityTests` enforces this mechanically. CoreAudio and DisplayServices are AppKit-free but belong in `CreativeNotchUI` anyway — Core holds only pure logic here.
- **No polling.** No `Timer`, no mouse monitors. The one admitted exception is the always-installed `.systemDefined` media-key monitor, justified in spec §3.2: the rule exists to stop monitors firing continuously, and this one fires a few dozen times a day. **No other monitor may be added.**
- **`FileManager.removeItem` remains banned** in the shelf module; this module touches no files.
- **Never mutate `AppState.state` directly.** It is `private(set)`; go through `transition(to:)`. Register observers with `observe`, never replace them.
- `now` is passed as a parameter, never read from a clock inside pure logic.
- All new types in `CreativeNotchCore` are `public`, `Equatable`, and `Sendable`.
- **No `Task.sleep` in tests.** Seven tests once failed on CI while passing locally because they slept past a delay. Await the real work — `growthTask`, `graceTask`, `dwellTask` are exposed for exactly this.
- **Every new test must be proven to fail against the bug it targets** — introduce it, watch it fail, revert. Verify the build succeeds before interpreting a mutation result: an invalid mutation breaks the build, produces no test failures, and looks identical to an uncaught bug.
- Conventional commit prefixes (`feat:`, `fix:`, `test:`, `chore:`, `docs:`).

---

### Task 1: `HUDAttribution` — was this change caused by a keypress?

The pure decision at the heart of the module. A value change and the keypress that caused it are separate events; this correlates them.

**Files:**
- Create: `Sources/CreativeNotchCore/HUD/HUDAttribution.swift`
- Create: `Tests/CreativeNotchCoreTests/HUDAttributionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `HUDAttribution.window: TimeInterval` = `0.25`
  - `HUDAttribution.isKeyDriven(changeAt: TimeInterval, lastKeyAt: TimeInterval?) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/HUDAttributionTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// The notch stays silent when Apple's HUD is already showing, which means
/// knowing a change came from a keypress. Nothing exposes whether Apple's
/// HUD is on screen, so the keypress is what gets detected — and a keypress
/// and the value change it causes are separate events that have to be
/// correlated.
struct HUDAttributionTests {

    @Test func theWindowIsWhatTheSpecSays() {
        #expect(HUDAttribution.window == 0.25)
    }

    @Test func noKeyEverSeenMeansTheChangeCameFromElsewhere() {
        #expect(HUDAttribution.isKeyDriven(changeAt: 100, lastKeyAt: nil) == false)
    }

    @Test func aKeyJustBeforeTheChangeClaimsIt() {
        #expect(HUDAttribution.isKeyDriven(changeAt: 100.1, lastKeyAt: 100.0))
    }

    @Test func aKeyLongBeforeTheChangeDoesNot() {
        #expect(HUDAttribution.isKeyDriven(changeAt: 105, lastKeyAt: 100) == false)
    }

    /// Exactly at the window the key still claims it; a moment past and it
    /// does not. Without this, `<` and `<=` are indistinguishable.
    @Test func theBoundaryIsInclusive() {
        #expect(HUDAttribution.isKeyDriven(changeAt: 100 + HUDAttribution.window, lastKeyAt: 100))
        #expect(HUDAttribution.isKeyDriven(changeAt: 100 + HUDAttribution.window + 0.001, lastKeyAt: 100) == false)
    }

    /// Clocks are not guaranteed monotonic across sources. A key stamped
    /// after the change it supposedly caused is nonsense, not a match.
    @Test func aKeyAfterTheChangeIsNotACause() {
        #expect(HUDAttribution.isKeyDriven(changeAt: 100, lastKeyAt: 100.1) == false)
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter HUDAttributionTests`
Expected: FAIL — `cannot find 'HUDAttribution' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchCore/HUD/HUDAttribution.swift`:

```swift
import Foundation

/// Decides whether a level change was caused by the volume or brightness
/// keys.
///
/// The notch stays silent for keypresses because Apple's own HUD already
/// covers them; it speaks for every other source, where macOS gives no
/// feedback at all. Nothing exposes whether Apple's HUD is on screen, so
/// the keypress is detected instead and correlated with the change it
/// caused.
///
/// Pure and time-injected, so the whole decision is testable without a
/// keyboard.
public enum HUDAttribution {

    /// How long after a keypress a level change is still attributed to it.
    public static let window: TimeInterval = 0.25

    /// - Parameters:
    ///   - changeAt: when the level actually changed.
    ///   - lastKeyAt: when a media key was last seen, or nil if never.
    public static func isKeyDriven(changeAt: TimeInterval, lastKeyAt: TimeInterval?) -> Bool {
        guard let lastKeyAt else { return false }
        let delta = changeAt - lastKeyAt
        // Negative means the key is stamped *after* the change it would
        // have caused — clocks from different sources are not guaranteed
        // to agree, and that ordering is nonsense rather than a match.
        return delta >= 0 && delta <= window
    }
}
```

- [ ] **Step 4: Run them**

Run: `swift test --filter HUDAttributionTests`
Expected: PASS — 6 tests.

- [ ] **Step 5: Prove the tests have teeth**

Apply each, confirm the build succeeds, confirm the named test FAILS, revert:

| Mutation | Must be caught by |
|---|---|
| `delta <= window` → `delta < window` | `theBoundaryIsInclusive` |
| `delta >= 0 &&` removed | `aKeyAfterTheChangeIsNotACause` |
| `guard let lastKeyAt else { return false }` → `return true` | `noKeyEverSeenMeansTheChangeCameFromElsewhere` |

Report the real output for each. If any is NOT caught, say so plainly.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchCore/HUD Tests/CreativeNotchCoreTests/HUDAttributionTests.swift
git commit -m "feat: attribute level changes to media keypresses"
```

---

### Task 2: `HUDCoalescer` — collapse CoreAudio's duplicate callbacks

The spike measured **8 listener callbacks for 4 volume changes**. Without collapsing them the pill flickers, and the arbiter's TTL restarts twice per change.

**Files:**
- Create: `Sources/CreativeNotchCore/HUD/HUDCoalescer.swift`
- Create: `Tests/CreativeNotchCoreTests/HUDCoalescerTests.swift`

**Interfaces:**
- Consumes: `HUDKind` from `Sources/CreativeNotchCore/NotchState.swift` — `.volume(Double)`, `.brightness(Double)`, `.mute(Bool)`.
- Produces:
  - `HUDCoalescer()` — `public`, a struct, mutating API
  - `HUDCoalescer.minimumInterval: TimeInterval` = `0.05`
  - `mutating func accept(_ kind: HUDKind, at: TimeInterval) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/HUDCoalescerTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// CoreAudio fires its volume listener **twice** for a single change — the
/// spike measured 8 callbacks for 4 changes, roughly a millisecond apart.
/// Passing both through would flicker the pill and restart the arbiter's
/// TTL twice per change.
struct HUDCoalescerTests {

    @Test func theFirstEventIsAlwaysAccepted() {
        var c = HUDCoalescer()
        #expect(c.accept(.volume(0.3), at: 100))
    }

    @Test func anIdenticalEventAMillisecondLaterIsDropped() {
        var c = HUDCoalescer()
        #expect(c.accept(.volume(0.3), at: 100))
        #expect(c.accept(.volume(0.3), at: 100.001) == false)
    }

    @Test func aDifferentLevelIsAcceptedEvenImmediately() {
        // Dragging a slider produces a genuine stream of distinct values.
        // Only exact repeats are duplicates.
        var c = HUDCoalescer()
        #expect(c.accept(.volume(0.3), at: 100))
        #expect(c.accept(.volume(0.35), at: 100.001))
    }

    @Test func theSameLevelAgainLaterIsAccepted() {
        // Nudge down then back up: the level repeats, but it is a real
        // second event, not a duplicate callback.
        var c = HUDCoalescer()
        #expect(c.accept(.volume(0.3), at: 100))
        #expect(c.accept(.volume(0.3), at: 100 + HUDCoalescer.minimumInterval + 0.001))
    }

    @Test func theBoundaryIsExclusive() {
        var c = HUDCoalescer()
        #expect(c.accept(.volume(0.3), at: 100))
        // Exactly at the interval is still within the duplicate window.
        #expect(c.accept(.volume(0.3), at: 100 + HUDCoalescer.minimumInterval) == false)
    }

    @Test func differentKindsDoNotSuppressEachOther() {
        // Brightness and volume can legitimately change together.
        var c = HUDCoalescer()
        #expect(c.accept(.volume(0.3), at: 100))
        #expect(c.accept(.brightness(0.3), at: 100.001))
    }

    @Test func muteIsCoalescedLikeAnyOtherKind() {
        var c = HUDCoalescer()
        #expect(c.accept(.mute(true), at: 100))
        #expect(c.accept(.mute(true), at: 100.001) == false)
        #expect(c.accept(.mute(false), at: 100.002))
    }

    @Test func theIntervalIsWhatTheSpecSays() {
        #expect(HUDCoalescer.minimumInterval == 0.05)
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter HUDCoalescerTests`
Expected: FAIL — `cannot find 'HUDCoalescer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchCore/HUD/HUDCoalescer.swift`:

```swift
import Foundation

/// Drops the duplicate callbacks CoreAudio emits for a single change.
///
/// The feasibility spike measured **8 listener callbacks for 4 volume
/// changes** — pairs about a millisecond apart carrying identical values.
/// Letting both through flickers the pill and restarts the peek TTL twice.
///
/// Only an *exact repeat* within `minimumInterval` is dropped. Dragging a
/// slider produces a genuine stream of distinct values, and those must all
/// pass or the level would appear to lag behind the cursor.
public struct HUDCoalescer: Equatable, Sendable {

    /// Duplicates arrive about a millisecond apart; a twentieth of a second
    /// is comfortably wider than that and far below what a human notices.
    public static let minimumInterval: TimeInterval = 0.05

    private var last: (kind: HUDKind, at: TimeInterval)?

    public init() {}

    /// Returns whether this event should be shown.
    public mutating func accept(_ kind: HUDKind, at time: TimeInterval) -> Bool {
        if let last, last.kind == kind, time - last.at <= Self.minimumInterval {
            return false
        }
        last = (kind, time)
        return true
    }

    public static func == (lhs: HUDCoalescer, rhs: HUDCoalescer) -> Bool {
        lhs.last?.kind == rhs.last?.kind && lhs.last?.at == rhs.last?.at
    }
}
```

- [ ] **Step 4: Run them**

Run: `swift test --filter HUDCoalescerTests`
Expected: PASS — 8 tests.

- [ ] **Step 5: Prove the tests have teeth**

| Mutation | Must be caught by |
|---|---|
| `last.kind == kind` removed from the condition | `aDifferentLevelIsAcceptedEvenImmediately` |
| `time - last.at <= Self.minimumInterval` → `< ` | `theBoundaryIsExclusive` |
| `return false` → `return true` in the duplicate branch | `anIdenticalEventAMillisecondLaterIsDropped` |
| `last = (kind, time)` moved above the `if` | `theSameLevelAgainLaterIsAccepted` |

Report the real output for each.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchCore/HUD Tests/CreativeNotchCoreTests/HUDCoalescerTests.swift
git commit -m "feat: coalesce CoreAudio's duplicate volume callbacks"
```

---

### Task 3: `VolumeObserver` — CoreAudio

**Files:**
- Create: `Sources/CreativeNotchUI/HUD/VolumeObserver.swift`
- Create: `Tests/CreativeNotchUITests/VolumeObserverTests.swift`

**Interfaces:**
- Consumes: `HUDKind` from `CreativeNotchCore`.
- Produces:
  - `VolumeObserver()` — `@MainActor`, `final class`
  - `VolumeObserver.onChange: (HUDKind) -> Void`
  - `VolumeObserver.start()` / `.stop()`
  - `VolumeObserver.currentLevel() -> Double?`
  - `VolumeObserver.isMuted() -> Bool?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/VolumeObserverTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// CoreAudio is public API and not TCC-gated — the spike confirmed a
/// listener installs and fires with no permission prompt. These tests read
/// the machine's real audio device, so they assert shape rather than exact
/// values.
@MainActor
struct VolumeObserverTests {

    @Test func aFreshObserverIsNotRunning() {
        let observer = VolumeObserver()
        #expect(observer.isRunning == false)
    }

    @Test func startingAndStoppingIsIdempotent() {
        let observer = VolumeObserver()
        observer.start()
        observer.start()          // must not install a second listener
        #expect(observer.isRunning)
        observer.stop()
        observer.stop()           // must not fail on an absent listener
        #expect(observer.isRunning == false)
    }

    @Test func theCurrentLevelIsAUnitValueOrUnavailable() {
        let observer = VolumeObserver()
        if let level = observer.currentLevel() {
            #expect(level >= 0 && level <= 1)
        }
        // A machine with no output device is legitimate; nil is a valid
        // answer, and asserting a level exists would fail on such a host.
    }

    @Test func muteReadsAsABooleanOrUnavailable() {
        let observer = VolumeObserver()
        if let muted = observer.isMuted() {
            #expect(muted == true || muted == false)
        }
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter VolumeObserverTests`
Expected: FAIL — `cannot find 'VolumeObserver' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchUI/HUD/VolumeObserver.swift`:

```swift
import AppKit
import CoreAudio
import AudioToolbox
import CreativeNotchCore

/// Watches the default output device's volume and mute state.
///
/// Observes the **value**, not the keypress. That needs no permission —
/// CoreAudio is public API and not TCC-gated — and it catches every change
/// whatever caused it: Control Center, Siri, another application, or the
/// keys. Apple's own HUD only appears for the keys, so this is what fills
/// the gap.
@MainActor
public final class VolumeObserver {

    public var onChange: (HUDKind) -> Void = { _ in }

    private(set) var isRunning = false
    private var device = AudioDeviceID(0)
    private var listeners: [AudioObjectPropertyAddress] = []

    public init() {}

    public func start() {
        guard !isRunning else { return }
        device = Self.defaultOutputDevice()
        guard device != 0 else { return }

        subscribe(to: kAudioHardwareServiceDeviceProperty_VirtualMainVolume) { [weak self] in
            guard let self, let level = self.currentLevel() else { return }
            self.onChange(.volume(level))
        }
        subscribe(to: kAudioDevicePropertyMute) { [weak self] in
            guard let self, let muted = self.isMuted() else { return }
            self.onChange(.mute(muted))
        }

        // The default output device changes when headphones are plugged in
        // or a display is connected. Without re-subscribing, the volume
        // half silently stops working.
        subscribeToSystem(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            guard let self else { return }
            self.stop()
            self.start()
        }

        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        for var address in listeners {
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main) { _, _ in }
        }
        listeners.removeAll()
        isRunning = false
    }

    public func currentLevel() -> Double? {
        read(Float32.self, kAudioHardwareServiceDeviceProperty_VirtualMainVolume).map(Double.init)
    }

    public func isMuted() -> Bool? {
        read(UInt32.self, kAudioDevicePropertyMute).map { $0 != 0 }
    }

    // MARK: - CoreAudio plumbing

    private static func defaultOutputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr else { return 0 }
        return id
    }

    private func read<T>(_ type: T.Type, _ selector: AudioObjectPropertySelector) -> T? {
        guard device != 0 else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, value) == noErr
        else { return nil }
        return value.pointee
    }

    private func subscribe(
        to selector: AudioObjectPropertySelector,
        handler: @escaping @MainActor () -> Void
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main) { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        if status == noErr { listeners.append(address) }
    }

    private func subscribeToSystem(
        _ selector: AudioObjectPropertySelector,
        handler: @escaping @MainActor () -> Void
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { _, _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
```

- [ ] **Step 4: Run them**

Run: `swift test --filter VolumeObserverTests`
Expected: PASS — 4 tests.

- [ ] **Step 5: Check the reading agrees with the system**

A unit test cannot prove a CoreAudio *listener* fires — that needs a real
change and is verified by hand in Task 7. What can be checked now is that
the observer reads the same level macOS reports:

```bash
swift test --filter VolumeObserverTests 2>&1 | tail -3
osascript -e 'output volume of (get volume settings)'
```

The second command prints 0–100. Confirm the suite passes and report the
number. If `currentLevel()` returned nil on a machine that clearly has
audio, the device lookup is wrong — say so rather than moving on.

**Do not claim the listener fires.** Nothing here demonstrates that.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchUI/HUD Tests/CreativeNotchUITests/VolumeObserverTests.swift
git commit -m "feat: observe volume and mute through CoreAudio"
```

---

### Task 4: `BrightnessObserver` — DisplayServices

The private half. The spike found the callback's signature is **not** what is documented online, and getting it wrong fails silently.

**Files:**
- Create: `Sources/CreativeNotchUI/HUD/BrightnessObserver.swift`
- Create: `Tests/CreativeNotchUITests/BrightnessObserverTests.swift`

**Interfaces:**
- Consumes: `HUDKind` from `CreativeNotchCore`.
- Produces:
  - `BrightnessObserver()` — `@MainActor`, `final class`
  - `.onChange: (HUDKind) -> Void`, `.start()`, `.stop()`, `.isRunning`
  - `.currentLevel() -> Double?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/BrightnessObserverTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// DisplayServices is private but not permission-gated. The spike confirmed
/// registration succeeds and the notification fires once per change — but
/// also that the callback's display-ID argument is **0**, so reading with
/// it returns status 1000 and writes nothing. `CGMainDisplayID()` is what
/// works.
@MainActor
struct BrightnessObserverTests {

    @Test func aFreshObserverIsNotRunning() {
        #expect(BrightnessObserver().isRunning == false)
    }

    @Test func startingAndStoppingIsIdempotent() {
        let observer = BrightnessObserver()
        observer.start()
        observer.start()
        #expect(observer.isRunning)
        observer.stop()
        observer.stop()
        #expect(observer.isRunning == false)
    }

    @Test func theCurrentLevelIsAUnitValueOrUnavailable() {
        if let level = BrightnessObserver().currentLevel() {
            #expect(level >= 0 && level <= 1)
        }
        // An external-display-only machine legitimately has no readable
        // built-in brightness; nil is a valid answer.
    }

    /// The framework has to load and the symbols resolve, or the whole
    /// module is inert. Cheap to assert, and it fails loudly if a future
    /// macOS drops them.
    @Test func theDisplayServicesSymbolsResolve() {
        #expect(BrightnessObserver.symbolsAvailable)
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter BrightnessObserverTests`
Expected: FAIL — `cannot find 'BrightnessObserver' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchUI/HUD/BrightnessObserver.swift`:

```swift
import AppKit
import CoreGraphics
import CreativeNotchCore

/// Watches display brightness through the private DisplayServices
/// framework.
///
/// There is no public API for reading brightness. DisplayServices is not
/// permission-gated, and the spike confirmed its change notification fires
/// exactly once per change — unlike CoreAudio's, which fires twice.
///
/// ⚠️ **The callback's `CGDirectDisplayID` argument is `0`**, not a valid
/// display. The signature circulated online is wrong: reading brightness
/// with the passed ID returns status 1000 and writes nothing.
/// `CGMainDisplayID()` is what works. ⚠️ The callback also runs **off the
/// main thread**.
@MainActor
public final class BrightnessObserver {

    public var onChange: (HUDKind) -> Void = { _ in }
    private(set) var isRunning = false

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Callback = @convention(c) (
        UnsafeMutableRawPointer?, CGDirectDisplayID,
        UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?
    ) -> Void
    private typealias Register = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?, Callback) -> Int32
    private typealias Unregister = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?, Callback) -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_NOW
    )

    public static var symbolsAvailable: Bool {
        guard let handle else { return false }
        return dlsym(handle, "DisplayServicesGetBrightness") != nil
            && dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications") != nil
    }

    /// Set while running so the C callback — which carries no context we
    /// can trust — can reach the live observer.
    private nonisolated(unsafe) static weak var active: BrightnessObserver?

    public init() {}

    public func start() {
        guard !isRunning, let handle = Self.handle,
              let registerSym = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications")
        else { return }

        Self.active = self
        let register = unsafeBitCast(registerSym, to: Register.self)

        let callback: Callback = { _, _, _, _, _ in
            // The passed display ID is 0 and unusable, and this runs off
            // the main thread — hop before touching anything.
            Task { @MainActor in
                guard let observer = BrightnessObserver.active,
                      let level = observer.currentLevel() else { return }
                observer.onChange(.brightness(level))
            }
        }

        if register(CGMainDisplayID(), nil, callback) == 0 {
            isRunning = true
        }
    }

    public func stop() {
        guard isRunning, let handle = Self.handle,
              let unregisterSym = dlsym(handle, "DisplayServicesUnregisterForBrightnessChangeNotifications")
        else { isRunning = false; return }

        let unregister = unsafeBitCast(unregisterSym, to: Unregister.self)
        let callback: Callback = { _, _, _, _, _ in }
        _ = unregister(CGMainDisplayID(), nil, callback)
        Self.active = nil
        isRunning = false
    }

    public func currentLevel() -> Double? {
        guard let handle = Self.handle,
              let sym = dlsym(handle, "DisplayServicesGetBrightness")
        else { return nil }
        let get = unsafeBitCast(sym, to: GetBrightness.self)
        var level: Float = 0
        // CGMainDisplayID(), never the ID handed to the callback.
        guard get(CGMainDisplayID(), &level) == 0 else { return nil }
        return Double(level)
    }
}
```

- [ ] **Step 4: Run them**

Run: `swift test --filter BrightnessObserverTests`
Expected: PASS — 4 tests.

- [ ] **Step 5: Prove one test has teeth**

Change `currentLevel()` to read with a hardcoded `0` instead of
`CGMainDisplayID()` — the exact bug the spike found. Run
`swift test --filter BrightnessObserverTests`;
`theCurrentLevelIsAUnitValueOrUnavailable` should still pass (nil is
allowed), so **report that this mutation is NOT caught** and explain why:
the observer degrades to nil rather than to a wrong value, which is by
design, and no headless test can distinguish that from a machine with no
readable brightness. Verified by hand in Task 6 instead.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchUI/HUD Tests/CreativeNotchUITests/BrightnessObserverTests.swift
git commit -m "feat: observe display brightness through DisplayServices"
```

---

### Task 5: `MediaKeyMonitor` — the one admitted global monitor

**Files:**
- Create: `Sources/CreativeNotchUI/HUD/MediaKeyMonitor.swift`
- Create: `Tests/CreativeNotchUITests/MediaKeyMonitorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `MediaKeyMonitor()` — `@MainActor`, `final class`
  - `.onKey: () -> Void`, `.start()`, `.stop()`, `.isRunning`
  - `static func isMediaKey(subtype: Int, data1: Int) -> Bool`
  - `var installMonitor: (@escaping (NSEvent) -> Void) -> Any?` — injectable for tests
  - `var removeMonitor: (Any) -> Void`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/MediaKeyMonitorTests.swift`:

```swift
import AppKit
import Testing
@testable import CreativeNotchUI

/// The only always-installed global monitor in the project, admitted
/// against the letter of the no-polling rule because the rule exists to
/// stop monitors that fire continuously and this one fires a few dozen
/// times a day. See spec section 3.2.
///
/// The decoding is pure and tested directly; the monitor's lifecycle is
/// tested through an injected installer, since a real global monitor needs
/// Accessibility and a keyboard.
@MainActor
struct MediaKeyMonitorTests {

    // NX_KEYTYPE values, shifted into place as data1 carries them.
    private func data1(keyCode: Int) -> Int { (keyCode << 16) }

    @Test func volumeAndBrightnessKeysAreRecognised() {
        for code in [0, 1, 2, 3, 7] {   // SOUND_UP, SOUND_DOWN, BRIGHT_UP, BRIGHT_DOWN, MUTE
            #expect(MediaKeyMonitor.isMediaKey(subtype: 8, data1: data1(keyCode: code)))
        }
    }

    @Test func otherSystemKeysAreIgnored() {
        // Keyboard illumination and eject are system-defined too, and must
        // not be mistaken for a level change.
        for code in [4, 6, 21, 22] {
            #expect(MediaKeyMonitor.isMediaKey(subtype: 8, data1: data1(keyCode: code)) == false)
        }
    }

    @Test func onlySubtypeEightCounts() {
        #expect(MediaKeyMonitor.isMediaKey(subtype: 7, data1: data1(keyCode: 0)) == false)
        #expect(MediaKeyMonitor.isMediaKey(subtype: 0, data1: data1(keyCode: 0)) == false)
    }

    @Test func startingInstallsExactlyOneMonitor() {
        let monitor = MediaKeyMonitor()
        var installs = 0
        monitor.installMonitor = { _ in installs += 1; return installs as NSNumber }
        monitor.removeMonitor = { _ in }

        monitor.start()
        monitor.start()

        #expect(installs == 1)
        #expect(monitor.isRunning)
    }

    @Test func stoppingRemovesIt() {
        let monitor = MediaKeyMonitor()
        var removals = 0
        monitor.installMonitor = { _ in 1 as NSNumber }
        monitor.removeMonitor = { _ in removals += 1 }

        monitor.start()
        monitor.stop()
        monitor.stop()

        #expect(removals == 1)
        #expect(monitor.isRunning == false)
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter MediaKeyMonitorTests`
Expected: FAIL — `cannot find 'MediaKeyMonitor' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchUI/HUD/MediaKeyMonitor.swift`:

```swift
import AppKit

/// Detects presses of the volume, mute and brightness keys.
///
/// This exists so the notch can stay **silent** when Apple's own HUD is
/// already showing — the one case where the two would genuinely overlap.
/// Nothing exposes whether Apple's HUD is on screen, so the keypress is
/// detected instead.
///
/// It requires Accessibility permission, and it is the only
/// always-installed global monitor in the project. Spec section 3.2 admits
/// it deliberately: the no-polling rule exists to stop monitors that fire
/// continuously, and this one fires a few dozen times a day. If
/// Accessibility is not granted the monitor simply never fires, and
/// attribution fails open — the notch shows every change, including
/// keypresses. Doubled feedback, not silence, because silence is
/// indistinguishable from broken.
@MainActor
public final class MediaKeyMonitor {

    public var onKey: () -> Void = {}

    /// Injectable so the lifecycle is testable without Accessibility or a
    /// keyboard.
    var installMonitor: (@escaping (NSEvent) -> Void) -> Any? = { handler in
        NSEvent.addGlobalMonitorForEvents(matching: [.systemDefined]) { handler($0) }
    }

    var removeMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }

    private(set) var isRunning = false
    private var token: Any?

    public init() {}

    public func start() {
        guard !isRunning else { return }
        token = installMonitor { [weak self] event in
            guard let self,
                  Self.isMediaKey(subtype: Int(event.subtype.rawValue), data1: event.data1)
            else { return }
            self.onKey()
        }
        isRunning = token != nil
    }

    public func stop() {
        guard isRunning, let token else { isRunning = false; return }
        removeMonitor(token)
        self.token = nil
        isRunning = false
    }

    /// `data1` packs the key code into its high 16 bits.
    ///
    /// Only the level keys count. Keyboard illumination and eject are
    /// system-defined events too, and must not be read as a level change.
    public static func isMediaKey(subtype: Int, data1: Int) -> Bool {
        guard subtype == 8 else { return false }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        switch keyCode {
        case 0, 1, 7:   return true   // SOUND_UP, SOUND_DOWN, MUTE
        case 2, 3:      return true   // BRIGHTNESS_UP, BRIGHTNESS_DOWN
        default:        return false
        }
    }
}
```

- [ ] **Step 4: Run them**

Run: `swift test --filter MediaKeyMonitorTests`
Expected: PASS — 5 tests.

- [ ] **Step 5: Prove the tests have teeth**

| Mutation | Must be caught by |
|---|---|
| `guard subtype == 8` removed | `onlySubtypeEightCounts` |
| `default: return false` → `default: return true` | `otherSystemKeysAreIgnored` |
| `guard !isRunning else { return }` removed from `start()` | `startingInstallsExactlyOneMonitor` |
| `removeMonitor(token)` removed | `stoppingRemovesIt` |

Report the real output for each.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchUI/HUD Tests/CreativeNotchUITests/MediaKeyMonitorTests.swift
git commit -m "feat: detect media keypresses so the notch can stay silent for them"
```

---

### Task 6: Wire it together — and give `PeekArbiter` its first consumer

**Files:**
- Create: `Sources/CreativeNotchUI/HUD/HUDController.swift`
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift`
- Create: `Tests/CreativeNotchUITests/HUDControllerTests.swift`

**Interfaces:**
- Consumes: `HUDAttribution`, `HUDCoalescer`, `PeekArbiter`, `HUDEvent`, `HUDKind`, `VolumeObserver`, `BrightnessObserver`, `MediaKeyMonitor`.
- Produces:
  - `HUDController(onPeek: @escaping (HUDKind) -> Void)` — `@MainActor`
  - `.handle(_ kind: HUDKind, at: TimeInterval)` — the whole decision path
  - `.noteKeyPress(at: TimeInterval)`
  - `.start()` / `.stop()`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/HUDControllerTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The decision path, driven directly rather than through real hardware:
/// coalesce duplicates, attribute to a keypress, and only then peek.
@MainActor
struct HUDControllerTests {

    private func makeController() -> (HUDController, Box<[HUDKind]>) {
        let peeked = Box<[HUDKind]>([])
        let controller = HUDController(onPeek: { peeked.value.append($0) })
        return (controller, peeked)
    }

    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    @Test func aChangeFromElsewherePeeks() {
        let (controller, peeked) = makeController()
        controller.handle(.volume(0.4), at: 100)
        #expect(peeked.value == [.volume(0.4)])
    }

    @Test func aChangeRightAfterAKeypressStaysSilent() {
        let (controller, peeked) = makeController()
        controller.noteKeyPress(at: 100)
        controller.handle(.volume(0.4), at: 100.1)
        #expect(peeked.value.isEmpty)
    }

    @Test func aChangeLongAfterAKeypressPeeksAgain() {
        let (controller, peeked) = makeController()
        controller.noteKeyPress(at: 100)
        controller.handle(.volume(0.4), at: 105)
        #expect(peeked.value == [.volume(0.4)])
    }

    /// CoreAudio fires twice per change; only one peek should result.
    @Test func duplicateCallbacksProduceOnePeek() {
        let (controller, peeked) = makeController()
        controller.handle(.volume(0.4), at: 100)
        controller.handle(.volume(0.4), at: 100.001)
        #expect(peeked.value == [.volume(0.4)])
    }

    @Test func aGenuineStreamOfValuesAllPeek() {
        // Dragging a slider: distinct values, all real.
        let (controller, peeked) = makeController()
        controller.handle(.volume(0.40), at: 100)
        controller.handle(.volume(0.45), at: 100.01)
        controller.handle(.volume(0.50), at: 100.02)
        #expect(peeked.value.count == 3)
    }

    @Test func brightnessAndMuteBothPeek() {
        let (controller, peeked) = makeController()
        controller.handle(.brightness(0.6), at: 100)
        controller.handle(.mute(true), at: 101)
        #expect(peeked.value == [.brightness(0.6), .mute(true)])
    }

    /// A keypress suppresses one change, not everything after it.
    @Test func aKeypressDoesNotSuppressTheNextUnrelatedChange() {
        let (controller, peeked) = makeController()
        controller.noteKeyPress(at: 100)
        controller.handle(.volume(0.4), at: 100.1)     // suppressed
        controller.handle(.volume(0.5), at: 100.6)     // beyond the window
        #expect(peeked.value == [.volume(0.5)])
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter HUDControllerTests`
Expected: FAIL — `cannot find 'HUDController' in scope`.

- [ ] **Step 3: Write the controller**

Create `Sources/CreativeNotchUI/HUD/HUDController.swift`:

```swift
import AppKit
import CreativeNotchCore

/// Owns the HUD's decision path: coalesce, attribute, then peek.
///
/// The observers and the key monitor are dumb sources; every judgement
/// happens here, against pure logic from `CreativeNotchCore`, so it is
/// testable without hardware.
@MainActor
public final class HUDController {

    private var coalescer = HUDCoalescer()
    private var lastKeyAt: TimeInterval?

    private let onPeek: (HUDKind) -> Void

    private let volume = VolumeObserver()
    private let brightness = BrightnessObserver()
    private let keys = MediaKeyMonitor()

    public init(onPeek: @escaping (HUDKind) -> Void) {
        self.onPeek = onPeek
    }

    public func start() {
        volume.onChange = { [weak self] kind in
            self?.handle(kind, at: Date().timeIntervalSince1970)
        }
        brightness.onChange = { [weak self] kind in
            self?.handle(kind, at: Date().timeIntervalSince1970)
        }
        keys.onKey = { [weak self] in
            self?.noteKeyPress(at: Date().timeIntervalSince1970)
        }
        volume.start()
        brightness.start()
        keys.start()
    }

    public func stop() {
        volume.stop()
        brightness.stop()
        keys.stop()
    }

    public func noteKeyPress(at time: TimeInterval) {
        lastKeyAt = time
    }

    /// Time is a parameter, not a clock read, so the whole path is testable.
    public func handle(_ kind: HUDKind, at time: TimeInterval) {
        // Duplicates first: CoreAudio fires twice per change, and letting
        // both through flickers the pill and restarts the peek TTL twice.
        guard coalescer.accept(kind, at: time) else { return }

        // Apple's HUD already covers keypresses. Everywhere else, macOS
        // gives no feedback at all — that is the gap this fills.
        guard !HUDAttribution.isKeyDriven(changeAt: time, lastKeyAt: lastKeyAt) else { return }

        onPeek(kind)
    }
}
```

- [ ] **Step 4: Run them**

Run: `swift test --filter HUDControllerTests`
Expected: PASS — 7 tests.

- [ ] **Step 5: Wire it into the delegate, replacing the placeholder**

In `Sources/CreativeNotchUI/AppDelegate.swift`, add a stored property:

```swift
    private var hud: HUDController?
    private var arbiter = PeekArbiter()
```

Replace the placeholder `peek()` — which currently fabricates a
`TrackSnapshot` — with the arbiter deciding:

```swift
    /// The dwell opened the notch. What it shows is the arbiter's call.
    private func peek() {
        guard state.state == .closed else { return }
        guard let content = arbiter.content(now: Date().timeIntervalSince1970) else { return }
        state.transition(to: .peek(content))
    }

    /// A level changed and the HUD decided it is worth showing.
    private func showHUD(_ kind: HUDKind) {
        let now = Date().timeIntervalSince1970
        arbiter.recordHUD(HUDEvent(kind: kind), now: now)
        guard let content = arbiter.content(now: now) else { return }
        state.transition(to: .peek(content))
    }
```

And at the end of `applicationDidFinishLaunching(_:)`:

```swift
        let hud = HUDController { [weak self] kind in self?.showHUD(kind) }
        hud.start()
        self.hud = hud
```

Add to `applicationWillTerminate(_:)`:

```swift
        hud?.stop()
```

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: PASS.

Note that `AppDelegateTests.theDwellPeeksThroughTheFunnel` asserts the
placeholder peek. It will now fail, because an empty arbiter has nothing to
show. Update it to record a HUD event first:

```swift
    /// The dwell shows whatever the arbiter has. An empty arbiter has
    /// nothing, so record a HUD event first — which is also the real
    /// sequence: a level changes, then the notch shows it.
    @Test func theDwellPeeksThroughTheFunnel() {
        let delegate = makeDelegate()
        delegate.showHUD(.volume(0.5))
        #expect(delegate.state.state.presentation == .peek)
        #expect(delegate.hoverView?.trackingRect == CGRect(x: 150, y: 216, width: 320, height: 44))
    }
```

For that to compile, `showHUD(_:)` must be **internal, not private** — the
test target reaches it through `@testable import`. Declare it as
`func showHUD(_ kind: HUDKind)` with no access modifier. Do not add a
separate test-only shim.

- [ ] **Step 7: Prove the tests have teeth**

| Mutation | Must be caught by |
|---|---|
| the coalescer guard removed | `duplicateCallbacksProduceOnePeek` |
| the attribution guard removed | `aChangeRightAfterAKeypressStaysSilent` |
| `noteKeyPress` does not store the time | `aChangeRightAfterAKeypressStaysSilent` |

Report the real output for each.

- [ ] **Step 8: Commit**

```bash
git add Sources/CreativeNotchUI Tests/CreativeNotchUITests
git commit -m "feat: wire the HUD through the peek arbiter (closes F8)"
```

---

### Task 7: `HUDView` — what you actually see

**Files:**
- Create: `Sources/CreativeNotchUI/HUD/HUDView.swift`
- Modify: `Sources/CreativeNotchUI/NotchRootView.swift`

**Interfaces:**
- Consumes: `HUDKind`, `PeekContent`.
- Produces: `HUDView(kind:)`

- [ ] **Step 1: Write the view**

Create `Sources/CreativeNotchUI/HUD/HUDView.swift`:

```swift
import SwiftUI
import CreativeNotchCore

/// An icon and a level bar — the same information Apple's HUD conveys, in
/// the place your eyes already go.
///
/// Deliberately no percentage and no device name: matching what Apple
/// conveys makes the notch read as familiar rather than as a second,
/// different indicator.
struct HUDView: View {
    let kind: HUDKind

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 18)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: geometry.size.width * level)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 22)
    }

    private var level: Double {
        switch kind {
        case .volume(let value):     return max(0, min(1, value))
        case .brightness(let value): return max(0, min(1, value))
        case .mute(let muted):       return muted ? 0 : 1
        }
    }

    private var symbol: String {
        switch kind {
        case .mute(let muted):
            return muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .brightness:
            return "sun.max.fill"
        case .volume(let value):
            if value <= 0    { return "speaker.fill" }
            if value < 0.34  { return "speaker.wave.1.fill" }
            if value < 0.67  { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }
}
```

- [ ] **Step 2: Show it in the panel**

In `Sources/CreativeNotchUI/NotchRootView.swift`, extend the overlay's
switch so a HUD peek renders the view rather than the generic label:

```swift
                case .peek(.hud(let event)):
                    HUDView(kind: event.kind)
```

Place it above the existing `default:` case.

- [ ] **Step 3: Build and run the suite**

Run: `swift build && swift test`
Expected: build clean, whole suite green.

- [ ] **Step 4: Verify by hand — this needs a human**

```bash
pkill -f CreativeNotch; ./Scripts/bundle.sh && open dist/CreativeNotch.app
```

Grant Accessibility when prompted, then check and report **what actually
happened**, not what should:

1. Change the volume from **Control Center** → the notch shows a speaker
   icon and a bar. Apple's HUD does **not** appear.
2. Press the **volume keys** → Apple's HUD appears, the notch stays silent.
3. Change **brightness** from Control Center → sun icon and bar.
4. Press the **brightness keys** → Apple's HUD only.
5. **Mute** from Control Center → the slashed speaker icon.
6. Drag the Control Center volume slider → the bar tracks smoothly without
   flickering.
7. Revoke Accessibility in System Settings → the notch now reacts to
   keypresses too (attribution fails open). Doubled feedback, not silence.

**You cannot see the screen. Do not claim any of these were verified.** List
them for the human and say plainly which were not checked.

- [ ] **Step 5: Commit**

```bash
git add Sources/CreativeNotchUI
git commit -m "feat: render volume and brightness in the notch"
```

---

### Task 8: Onboarding, and documentation

Accessibility now has a second consumer, and the onboarding copy predates
both.

**Files:**
- Modify: `Sources/CreativeNotchUI/OnboardingWindow.swift`
- Modify: `README.md`, `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md`
- Modify: `docs/plans/2026-08-22-foundation-followups.md`

- [ ] **Step 1: Update the onboarding copy**

In `Sources/CreativeNotchUI/OnboardingWindow.swift`, the explanatory text
currently names the HUD and the file shelf as the two consumers. The shelf
no longer needs it. Replace the body text with:

```swift
            Text("""
                 CreativeNotch needs Accessibility access for one thing: to \
                 notice when you press the volume or brightness keys.

                 It uses that to stay *quiet*. macOS already shows its own \
                 overlay for those keys, so the notch stands aside — and \
                 speaks up only when you change the volume somewhere macOS \
                 gives you no feedback at all, like Control Center or Siri.

                 Without it, everything still works; you will just see both \
                 indicators at once when using the keys.
                 """)
```

- [ ] **Step 2: Update the documentation**

- `README.md`: move the HUD from the roadmap into the built column; update
  the usage table with what the notch reacts to; update the test count.
- `docs/ARCHITECTURE.md`: a section covering value-observation rather than
  key interception, the two gotchas (CoreAudio fires twice, the brightness
  callback's display ID is 0), the admitted always-installed monitor with
  its justification, and that attribution fails open without Accessibility.
- `docs/DEVELOPMENT.md`: note that `HUDAttribution` and `HUDCoalescer` take
  time as a parameter, like `PeekArbiter`.
- `docs/plans/2026-08-22-foundation-followups.md`: mark **F8 closed** —
  `PeekArbiter` finally has a consumer, and `AppDelegate.peek()` no longer
  fabricates a placeholder `TrackSnapshot`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: record the HUD module and close F8"
```

---

## Definition of done

- `swift test` green; CI green.
- Changing volume from Control Center shows the notch HUD; pressing the keys does not.
- Brightness behaves the same way.
- Dragging a slider tracks smoothly without flicker.
- Without Accessibility, the notch reacts to everything rather than nothing.
- `PeekArbiter` is wired; no placeholder `TrackSnapshot` remains.
- No `Timer`, no mouse monitor, no second global monitor.
- `CorePurityTests` still passes.

## Deliberately not built

Suppressing Apple's HUD. Percentage or device-name display. Keyboard
backlight. Reacting in fullscreen — the panel is hidden there by design and
Apple's HUD covers that case.
