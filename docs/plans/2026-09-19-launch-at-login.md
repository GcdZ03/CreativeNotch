# Launch at Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** One row in Settings that registers the app to open at login,
reading its state from the system every time rather than from a stored
`Bool` — and that refuses to touch the service at all from a copy that is
not installed, because a status read repoints the system's record.

**Architecture:** Two pure functions in `CreativeNotchCore/Startup/`
(path eligibility, raw-status mapping). One controller in
`CreativeNotchUI/Startup/` holding three injected closures over
`SMAppService.mainApp`, defaulted to the real service and replaced by spies
in every test. One section at the top of the Settings form. No `ModuleID`, no
`Preferences` field, no switchboard leg, no lifecycle hook.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, ServiceManagement, Swift Testing,
SwiftPM. macOS 26+. No third-party dependencies.

**Spec:** [`docs/specs/2026-09-19-launch-at-login-design.md`](../specs/2026-09-19-launch-at-login-design.md).
Read it before Task 1, along with the measurements it rests on in
[`docs/research/2026-09-19-launch-at-login-probe.md`](../research/2026-09-19-launch-at-login-probe.md).

## Global Constraints

- **`CreativeNotchCore` imports no UI framework, and no ServiceManagement
  either.** The raw status crosses the boundary as an `Int`. New Core files
  in a subdirectory go into the `expectedInSubdirectories` manifest in
  `CorePurityTests.swift` in the same commit.
- **No test may reach the real `SMAppService`.** A real `register()` writes a
  record into the developer's Background Task Management database, and the
  suite would then pass or fail depending on whether it had been run before.
  Every test injects closures. This is the same rule as "never spawn a real
  helper in a test".
- **An ineligible copy must never call `readStatus`.** Not "must not act on
  the result" — must not call it. That is spec §3, and it is the only
  silent failure in this module.
- **No `ModuleID` case, no `Preferences` field, no `ModuleSwitchboard` leg,
  no `SystemActivity` consumer.** `ModuleID.allCases` stays at ten and
  `PreferencesView.rows` stays a list of modules.
- **Every test must fail when the code it covers is deleted.** Introduce the
  bug, `swift build` green, `swift test` red, revert.
- Conventional commit prefixes. Baseline at the branch point (`fb72af2`):
  1031 tests, all passing. Every task leaves the suite green.

## File Structure

```
Sources/CreativeNotchCore/
  Startup/LaunchAtLoginEligibility.swift   NEW  path rule + raw-status mapping

Sources/CreativeNotchUI/
  Startup/LaunchAtLoginController.swift    NEW  three seams, refresh, setEnabled
  PreferencesWindow.swift                  MOD  the startup section
  AppDelegate.swift                        MOD  build the controller, hand it over

Tests/CreativeNotchCoreTests/
  LaunchAtLoginEligibilityTests.swift      NEW
  CorePurityTests.swift                    MOD  manifest

Tests/CreativeNotchUITests/
  LaunchAtLoginControllerTests.swift       NEW
  PreferencesWindowTests.swift             MOD  the row exists and is not a module
```

## Why the order is what it is

Core first — pure, one-second feedback, and the controller reads both
functions. Then the controller with its seams, which is where the negative
test lives. Then the row, which is presentation over a controller that
already behaves. Then the docs, including removing the last entry from
`ROADMAP.md`.

---

### Task 1: The path rule and the status mapping

**Files:**
- Create: `Sources/CreativeNotchCore/Startup/LaunchAtLoginEligibility.swift`
- Modify: `Tests/CreativeNotchCoreTests/CorePurityTests.swift` (manifest)
- Test: `Tests/CreativeNotchCoreTests/LaunchAtLoginEligibilityTests.swift`

**Interfaces:**
- Produces: `enum LaunchAtLoginEligibility { case eligible, notInstalled; static func resolve(bundlePath: String, installDirectories: [String]) -> Self; static var defaultInstallDirectories: [String] }`
- Produces: `enum LaunchAtLoginState: Equatable, Sendable { case on, off, needsApproval, unavailable(bundlePath: String); static func from(rawStatus: Int) -> LaunchAtLoginState }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// Which copy of the app may touch the login-item service at all.
///
/// A status read repoints the system's record at the copy doing the reading
/// (research §Q3), so this decides *before* the read, from the path alone.
struct LaunchAtLoginEligibilityTests {

    private let dirs = ["/Applications", "/Users/someone/Applications"]

    @Test func anAppInstalledInApplicationsMayAsk() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Applications/CreativeNotch.app",
            installDirectories: dirs) == .eligible)
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Users/someone/Applications/CreativeNotch.app",
            installDirectories: dirs) == .eligible)
    }

    /// The hazard this whole rule exists for: `dev.sh` builds here and
    /// deletes it on the next run.
    @Test func aDevBuildMayNotAsk() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Users/someone/Github/CreativeNotch/dist/CreativeNotch.app",
            installDirectories: dirs) == .notInstalled)
    }

    /// Directly inside, not merely underneath — otherwise a copy in
    /// `/Applications/Utilities` claims the record too.
    @Test func aNestedCopyIsNotInstalled() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Applications/Utilities/CreativeNotch.app",
            installDirectories: dirs) == .notInstalled)
    }

    /// A prefix match would accept this, which is why the rule is not one.
    @Test func aLookalikeDirectoryIsNotInstalled() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Applications.old/CreativeNotch.app",
            installDirectories: dirs) == .notInstalled)
    }

    /// Trailing slashes come off `Bundle.main.bundlePath` on some paths and
    /// not others; neither spelling may change the answer.
    @Test func aTrailingSlashChangesNothing() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Applications/CreativeNotch.app/",
            installDirectories: dirs) == .eligible)
    }

    @Test func theDefaultDirectoriesAreApplicationsAndTheUsersOwn() {
        let defaults = LaunchAtLoginEligibility.defaultInstallDirectories
        #expect(defaults.contains("/Applications"))
        #expect(defaults.contains(NSHomeDirectory() + "/Applications"))
    }
}

/// What the row shows, from the raw `SMAppService.Status` value.
struct LaunchAtLoginStateTests {

    @Test func enabledIsOn() {
        #expect(LaunchAtLoginState.from(rawStatus: 1) == .on)
    }

    /// Both "off" values display the same. They differ in the record —
    /// no record ever, versus a disabled tombstone — and nothing in the UI
    /// acts on that difference, so nothing here pretends to.
    @Test func bothOffValuesAreOff() {
        #expect(LaunchAtLoginState.from(rawStatus: 0) == .off)
        #expect(LaunchAtLoginState.from(rawStatus: 3) == .off)
    }

    @Test func requiresApprovalIsItsOwnState() {
        #expect(LaunchAtLoginState.from(rawStatus: 2) == .needsApproval)
    }

    /// A value Apple adds later must read as off, never as on.
    @Test func anUnknownValueIsOff() {
        #expect(LaunchAtLoginState.from(rawStatus: 99) == .off)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "LaunchAtLoginEligibilityTests|LaunchAtLoginStateTests"`
Expected: compile error, the types do not exist.

- [ ] **Step 3: Implement**

```swift
// Sources/CreativeNotchCore/Startup/LaunchAtLoginEligibility.swift
import Foundation

/// Whether this copy of the app may touch the login-item service at all.
///
/// **A status read is a write.** One record exists per bundle identifier,
/// and its URL follows whichever copy last read `.status` — no registration
/// call needed (`docs/research/2026-09-19-launch-at-login-probe.md`, Q3).
/// So a dev build in `dist/` that merely drew the Settings row would
/// repoint the user's login item at a bundle `dev.sh` deletes on its next
/// run, and the symptom — "it stopped launching at login" — would appear
/// days later with nothing logged.
///
/// This decides from the path, before the read.
public enum LaunchAtLoginEligibility: Equatable, Sendable {
    case eligible
    case notInstalled

    /// `/Applications` and the user's own `~/Applications`.
    public static var defaultInstallDirectories: [String] {
        ["/Applications", NSHomeDirectory() + "/Applications"]
    }

    /// Eligible when the bundle sits **directly inside** an install
    /// directory.
    ///
    /// A whitelist rather than a blacklist of throwaway locations, because
    /// the blacklist cannot be enumerated — `dist/`, DerivedData, a temp
    /// directory, a mounted image, Downloads — and guessing wrong fails
    /// silently. The cost is refusing a copy deliberately kept elsewhere,
    /// and the row names the path so that refusal can be read.
    public static func resolve(
        bundlePath: String,
        installDirectories: [String] = defaultInstallDirectories
    ) -> LaunchAtLoginEligibility {
        // Compared as path components, never as a string prefix: a prefix
        // match accepts `/Applications.old/CreativeNotch.app`, and a bare
        // `contains` accepts `/Applications/Utilities/CreativeNotch.app`.
        let parent = (bundlePath as NSString)
            .standardizingPath
            .deletingLastPathComponent
        for directory in installDirectories
        where (directory as NSString).standardizingPath == parent {
            return .eligible
        }
        return .notInstalled
    }
}

/// What the Settings row shows.
///
/// Derived from the system on every read, never from a stored `Bool`: the
/// user can turn the login item off in System Settings and macOS does not
/// tell us (spec §2).
public enum LaunchAtLoginState: Equatable, Sendable {
    case on
    case off
    /// macOS is holding the registration until the user allows it.
    case needsApproval
    /// This copy is not installed, so it never asked. Carries the path, so
    /// the row can say which copy is running rather than only that
    /// something is wrong.
    case unavailable(bundlePath: String)

    /// From `SMAppService.Status.rawValue`, which Core does not import.
    ///
    /// Anything unrecognised is `off`. A future value read as `on` would be
    /// a switch claiming a registration nobody made, which is the one
    /// direction this module must never fail in.
    public static func from(rawStatus: Int) -> LaunchAtLoginState {
        switch rawStatus {
        case 1:  return .on
        case 2:  return .needsApproval
        default: return .off
        }
    }
}
```

Add `"LaunchAtLoginEligibility.swift"` to `expectedInSubdirectories` in
`CorePurityTests.swift`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter "LaunchAtLogin|CorePurityTests"` — all pass.

- [ ] **Step 5: Mutation.** Replace the component comparison with
  `parent.hasPrefix(directory)`; `aLookalikeDirectoryIsNotInstalled` must
  fail. Then make `from(rawStatus:)` return `.on` in its `default`;
  `anUnknownValueIsOff` and `bothOffValuesAreOff` must fail. Revert both.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchCore/Startup/LaunchAtLoginEligibility.swift Tests/CreativeNotchCoreTests/LaunchAtLoginEligibilityTests.swift Tests/CreativeNotchCoreTests/CorePurityTests.swift
git commit -m "feat: which copy may ask about the login item, and what its answer means"
```

---

### Task 2: The controller, and the read that must not happen

**Files:**
- Create: `Sources/CreativeNotchUI/Startup/LaunchAtLoginController.swift`
- Test: `Tests/CreativeNotchUITests/LaunchAtLoginControllerTests.swift`

**Interfaces:**
- Consumes: `LaunchAtLoginEligibility`, `LaunchAtLoginState` (T1).
- Produces: `@MainActor @Observable final class LaunchAtLoginController` with
  `init(bundlePath:installDirectories:)`, `private(set) var state: LaunchAtLoginState`,
  `var readStatus: () -> Int`, `var register: () throws -> Void`,
  `var unregister: () throws -> Void`, `func refresh()`, `func setEnabled(_:)`,
  and `static func openLoginItemsSettings()`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The login-item toggle.
///
/// **No test here reaches the real `SMAppService`.** A real `register()`
/// writes a record into the developer's Background Task Management database,
/// and the suite would then pass or fail depending on whether it had ever
/// been run before. Every seam is injected, exactly as the media module
/// never spawns a real helper.
@MainActor
struct LaunchAtLoginControllerTests {

    private static let installed = "/Applications/CreativeNotch.app"
    private static let devBuild = "/Users/someone/Github/CreativeNotch/dist/CreativeNotch.app"
    private static let dirs = ["/Applications"]

    private func makeController(
        path: String = installed,
        status: Int = 0
    ) -> LaunchAtLoginController {
        let controller = LaunchAtLoginController(
            bundlePath: path, installDirectories: Self.dirs
        )
        controller.readStatus = { status }
        controller.register = {}
        controller.unregister = {}
        return controller
    }

    // MARK: - The read that must not happen

    /// **The test this module exists to pass.** An ineligible copy must not
    /// *call* the read, not merely discard its answer — the call itself
    /// repoints the system's record at this bundle (research Q3).
    ///
    /// Asserting only that the state is `.unavailable` would pass against a
    /// controller that read the status first and then threw it away, which
    /// is precisely the bug.
    @Test func anUninstalledCopyNeverReadsTheStatus() {
        var reads = 0
        let controller = LaunchAtLoginController(
            bundlePath: Self.devBuild, installDirectories: Self.dirs
        )
        controller.readStatus = { reads += 1; return 1 }

        controller.refresh()

        #expect(reads == 0, "an uninstalled copy touched the service")
        #expect(controller.state == .unavailable(bundlePath: Self.devBuild))
    }

    /// And it must not write either, however the row is driven.
    @Test func anUninstalledCopyNeverRegisters() {
        var registrations = 0
        let controller = LaunchAtLoginController(
            bundlePath: Self.devBuild, installDirectories: Self.dirs
        )
        controller.readStatus = { 1 }
        controller.register = { registrations += 1 }

        controller.setEnabled(true)

        #expect(registrations == 0)
        #expect(controller.state == .unavailable(bundlePath: Self.devBuild))
    }

    // MARK: - An installed copy

    @Test func anInstalledCopyReadsWhatTheSystemSays() {
        #expect(makeController(status: 1).stateAfterRefresh == .on)
        #expect(makeController(status: 0).stateAfterRefresh == .off)
        #expect(makeController(status: 2).stateAfterRefresh == .needsApproval)
    }

    @Test func switchingOnRegistersAndThenRereads() {
        var registrations = 0
        var status = 0
        let controller = makeController()
        controller.readStatus = { status }
        controller.register = { registrations += 1; status = 1 }

        controller.setEnabled(true)

        #expect(registrations == 1)
        #expect(controller.state == .on)
    }

    @Test func switchingOffUnregistersAndThenRereads() {
        var status = 1
        let controller = makeController()
        controller.readStatus = { status }
        controller.unregister = { status = 0 }

        controller.setEnabled(false)

        #expect(controller.state == .off)
    }

    /// **The honesty rule.** A registration that throws leaves the switch
    /// showing what the system says — off — rather than what was asked for.
    /// A stored `Bool` would show `on` over nothing at all.
    @Test func aFailedRegistrationLeavesTheSwitchOff() {
        struct Refused: Error {}
        let controller = makeController(status: 0)
        controller.register = { throw Refused() }

        controller.setEnabled(true)

        #expect(controller.state == .off)
    }

    /// The system is the source of truth, so a change made in System
    /// Settings shows up on the next read without anything telling us.
    @Test func aRegistrationRemovedElsewhereShowsUpOnRefresh() {
        var status = 1
        let controller = makeController()
        controller.readStatus = { status }
        controller.refresh()
        #expect(controller.state == .on)

        status = 0            // the user switched it off in System Settings
        controller.refresh()

        #expect(controller.state == .off)
    }
}

private extension LaunchAtLoginController {
    var stateAfterRefresh: LaunchAtLoginState {
        refresh()
        return state
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile error, no such type.

- [ ] **Step 3: Implement**

```swift
// Sources/CreativeNotchUI/Startup/LaunchAtLoginController.swift
import AppKit
import ServiceManagement
import CreativeNotchCore

/// The login-item toggle: one read, two writes, and a rule about which copy
/// is allowed to make them.
///
/// **Nothing here runs.** A registration is a row in the system's Background
/// Task Management database, not a process, so this module joins no
/// lifecycle hook and no activity gate — there is nothing to start, nothing
/// to stop, and the app is not running when the record matters. It is the
/// first module in this project whose honest answer to "what does the toggle
/// stop?" is *nothing*, and `docs/specs/2026-09-19-launch-at-login-design.md`
/// §2 is why that is stated rather than quietly true.
///
/// The three seams are injected because **a real call changes the machine
/// running the tests**: `register()` writes a record that outlives the
/// process, so a suite that made one would pass or fail depending on whether
/// it had been run before.
@MainActor
@Observable
public final class LaunchAtLoginController {

    /// What the row shows. Written only by `refresh()`, which reads the
    /// system rather than the argument it was just handed.
    public private(set) var state: LaunchAtLoginState

    private let bundlePath: String
    private let eligibility: LaunchAtLoginEligibility

    @ObservationIgnored
    var readStatus: () -> Int = { SMAppService.mainApp.status.rawValue }

    @ObservationIgnored
    var register: () throws -> Void = { try SMAppService.mainApp.register() }

    @ObservationIgnored
    var unregister: () throws -> Void = { try SMAppService.mainApp.unregister() }

    public init(
        bundlePath: String = Bundle.main.bundlePath,
        installDirectories: [String] = LaunchAtLoginEligibility.defaultInstallDirectories
    ) {
        self.bundlePath = bundlePath
        self.eligibility = LaunchAtLoginEligibility.resolve(
            bundlePath: bundlePath, installDirectories: installDirectories
        )
        // Resolved once, at construction, and never read again: the answer
        // is a property of where this bundle is, and a running app does not
        // move.
        self.state = eligibility == .eligible
            ? .off                                       // provisional; `refresh()` decides
            : .unavailable(bundlePath: bundlePath)
    }

    /// The only writer of `state`.
    ///
    /// The guard is the whole mitigation for research Q3 and it guards the
    /// **call**, not the result: reading `.status` from an uninstalled copy
    /// repoints the system's record at it, so discarding the answer
    /// afterwards would be too late.
    public func refresh() {
        guard eligibility == .eligible else {
            state = .unavailable(bundlePath: bundlePath)
            return
        }
        state = LaunchAtLoginState.from(rawStatus: readStatus())
    }

    /// Register or unregister, then read back what actually happened.
    ///
    /// A throw is caught rather than propagated: the row has no way to show
    /// an error that the re-read does not already show better. A refused
    /// registration leaves the switch off, which is true.
    public func setEnabled(_ enabled: Bool) {
        guard eligibility == .eligible else { return }
        do {
            try enabled ? register() : unregister()
        } catch {
            NSLog("CreativeNotch: login item \(enabled ? "registration" : "removal") failed: \(error)")
        }
        refresh()
    }

    /// System Settings → General → Login Items. The manual route, and the
    /// fallback for the one thing no probe in this repo can prove: that
    /// macOS actually starts the app after a logout.
    public static func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 4: Run** `swift test --filter LaunchAtLoginControllerTests` — all pass.

- [ ] **Step 5: Mutation.** Delete the `guard` in `refresh()`;
  `anUninstalledCopyNeverReadsTheStatus` must fail on `reads == 0`. Then make
  `setEnabled` set `state` from its argument instead of calling `refresh()`;
  `aFailedRegistrationLeavesTheSwitchOff` must fail. Revert both.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchUI/Startup/LaunchAtLoginController.swift Tests/CreativeNotchUITests/LaunchAtLoginControllerTests.swift
git commit -m "feat: the login-item toggle, and the read an uninstalled copy must not make"
```

---

### Task 3: The row in Settings

**Files:**
- Modify: `Sources/CreativeNotchUI/PreferencesWindow.swift`
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift`
- Test: `Tests/CreativeNotchUITests/PreferencesWindowTests.swift`

**Interfaces:**
- Consumes: `LaunchAtLoginController` (T2).
- Produces: `PreferencesController.launchAtLogin: LaunchAtLoginController`,
  and `LaunchAtLoginRow` in `PreferencesWindow.swift`.
- Produces on `AppDelegate`: `private(set) var launchAtLogin: LaunchAtLoginController`.

- [ ] **Step 1: Write the failing tests** (append to `PreferencesWindowTests`)

```swift
    // MARK: - Launch at login

    /// It is deliberately **not** a module: the system owns the state, so
    /// there is no stored `Bool` and nothing to stop. `rows` stays a list of
    /// modules, and this keeps `everyModuleHasASwitch` meaningful.
    @Test func launchAtLoginIsNotAModuleRow() {
        #expect(PreferencesView.rows.allSatisfy { $0.title != "Open at login" })
        #expect(ModuleID.allCases.count == 10)
    }

    /// The window reaches a controller, and a dev build's controller reports
    /// itself unavailable rather than touching the service.
    @Test func theWindowCarriesALaunchAtLoginControllerThatRespectsItsPath() {
        let delegate = makeDelegate()
        let controller = makeController(delegate)
        #expect(controller.launchAtLogin === delegate.launchAtLogin)

        // The suite runs from a build directory, never from /Applications,
        // so the real controller must be in the state that touches nothing.
        if case .unavailable = delegate.launchAtLogin.state {} else {
            Issue.record("a test-run bundle was treated as installed: \(delegate.launchAtLogin.state)")
        }
    }
```

- [ ] **Step 2: Run** — compile error, no `launchAtLogin`.

- [ ] **Step 3: Implement**

In `AppDelegate`, beside the other lazily-built controllers:

```swift
    /// Built here rather than in `install(metrics:)` for the same reason the
    /// preferences window is: it is settings-surface wiring, not panel
    /// wiring. It reads nothing until the window asks it to — see
    /// `LaunchAtLoginController.refresh()`.
    private(set) lazy var launchAtLogin = LaunchAtLoginController()
```

In `PreferencesController`, expose it:

```swift
    /// The login-item toggle. Reached through the delegate rather than
    /// rebuilt, so the window and the app agree about one controller.
    let launchAtLogin: LaunchAtLoginController
```

…taking it in both initialisers, and passed from `AppDelegate.showPreferences()`.

In `PreferencesView.body`, before the `ForEach` over `PreferencesSection`:

```swift
            Section {
                LaunchAtLoginRow(controller: controller.launchAtLogin)
            } header: {
                Text("Startup")
            } footer: {
                Text("macOS owns this setting, so it is read back from the system rather than remembered here — turning it off in System Settings turns it off here too.")
            }
```

And the row itself:

```swift
/// The one row in this window that stores nothing.
///
/// Its switch shows `LaunchAtLoginController.state`, which is read from the
/// system, so a registration removed in System Settings shows up here on the
/// next open without anything having told us.
struct LaunchAtLoginRow: View {
    let controller: LaunchAtLoginController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { controller.state == .on },
                set: { controller.setEnabled($0) }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login")
                            .font(.body.weight(.medium))
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.teal)
                        )
                }
            }
            .disabled(isUnavailable)

            // Unconditional, not shown only on failure: no probe in this
            // repo can prove macOS actually starts the app after a logout,
            // and a user for whom it silently does not should not have to
            // deduce that they are in a failure case to find the manual
            // route. (Spec §5.)
            Button("Open Login Items") {
                LaunchAtLoginController.openLoginItemsSettings()
            }
            .padding(.leading, 36)
        }
        // Reads the system when the window appears, never on a timer.
        .onAppear { controller.refresh() }
    }

    private var isUnavailable: Bool {
        if case .unavailable = controller.state { return true }
        return false
    }

    private var detail: String {
        switch controller.state {
        case .on, .off:
            return "Opens CreativeNotch when you log in."
        case .needsApproval:
            return "macOS is holding this until you allow it in System Settings → General → Login Items."
        case .unavailable(let path):
            return "Only an installed copy can do this. This one is running from \(path)."
        }
    }
}
```

- [ ] **Step 4: Run** `swift test` — whole suite green.

- [ ] **Step 5: Mutation.** Make `detail`'s `.unavailable` case return the
  same string as `.on`; no test fails — so instead delete `.disabled(isUnavailable)`
  and confirm nothing fails either, then add the assertion that catches it:
  extend `theWindowCarriesALaunchAtLoginControllerThatRespectsItsPath` to call
  `delegate.launchAtLogin.setEnabled(true)` and assert the state is still
  `.unavailable`. That is the behaviour worth pinning; the string is not.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchUI/PreferencesWindow.swift Sources/CreativeNotchUI/AppDelegate.swift Tests/CreativeNotchUITests/PreferencesWindowTests.swift
git commit -m "feat: an Open at login row that reads the system, not a stored flag"
```

---

### Task 4: The docs, including the last roadmap entry

**Files:**
- Modify: `docs/ROADMAP.md` — remove §1 and the "Suggested order" section that
  exists only for it; move it to the shipped list with its spec and probe.
  The signing-identity table's launch-at-login row is now **measured**: say
  so, and that it came back fine.
- Modify: `README.md` — Status table gains a row; the Roadmap section says
  every planned module has shipped; the documentation table gains the spec,
  the plan and the probe.
- Modify: `docs/ARCHITECTURE.md` — a short section: the module that runs
  nothing, and the repoint-on-read that shapes it.

- [ ] **Step 1:** Make the edits.
- [ ] **Step 2:** `swift test` — green.
- [ ] **Step 3: Commit** `docs: record launch at login, and close the roadmap`

## Definition of done

- `swift test` green; count in the PR.
- Every new test's mutation named in the PR.
- `grep -rn "SMAppService" Tests/` returns nothing.
- `ModuleID.allCases.count == 10` still.
- **Stated in the PR, unresolved:** the logout check is still owed, and the
  toggle should not be trusted until someone runs it.

## Deliberately not built

Spec §8: a LaunchAgent fallback, reading which copy owns the record, and
registering automatically on first launch.
