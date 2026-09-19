# Launch at login — design

The last module on the roadmap, and the first one with **nothing to run**.

Roadmap entry: [`docs/ROADMAP.md`](../ROADMAP.md) §1. This spec supersedes it.
The measurements it rests on are in
[`docs/research/2026-09-19-launch-at-login-probe.md`](../research/2026-09-19-launch-at-login-probe.md);
this document does not re-argue them.

## 1. It ships as a toggle, because the blocking question came back yes

The roadmap said this module might not exist at all: if
`SMAppService.mainApp.register()` refused an ad-hoc signature, it would ship
"as an explanation rather than a toggle". It does not refuse. An ad-hoc
bundle registers cleanly and the status moves to `enabled`, and a rebuild
under a different code hash at the same path leaves the record untouched.

So the two things that made this module doubtful are gone, and what is left
is unremarkable: one row, one system call each way.

**Everything hard about it is now the third finding** — that a bundle
identifier has exactly one record, and reading `.status` from any copy
repoints that record's URL at the copy doing the reading. §3 is that.

## 2. It is not a `ModuleID`, and that is the central decision

Every other switch in this app persists a `Bool` in `UserDefaults` and calls
a `start()` or a `stop()`. This one must not.

> **The system owns this state, not us.** A user can turn the login item off
> in System Settings → General → Login Items, and macOS will not tell us.

A stored `Bool` would then read `on` over a registration that no longer
exists — the exact inversion the Preferences spec exists to prevent, arrived
at from the opposite direction. There, the lie was a switch reading `on` over
a subsystem we had stopped; here it would be a switch reading `on` over a
registration the *user* removed somewhere else.

So:

- **No `ModuleID` case, no `Preferences` field, no `PreferenceKeys` entry.**
  `ModuleID.allCases` stays at ten, and `PreferencesView.rows` stays a list
  of modules — the test comparing the two keeps its meaning.
- **No `ModuleSwitchboard` leg.** The switchboard's contract is that every
  leg stops something; this has nothing to stop. A leg that did nothing
  would be the first one that lies about that.
- **No lifecycle hook.** Nothing at launch, nothing at terminate, nothing on
  the `SystemActivity` gate. A registration is a row in a database, not a
  process, and the app is not running when it matters.
- **The row reads the system every time it is shown.** That read is the
  whole feature.

This is the first module whose honest answer to *"what does the toggle
stop?"* is **nothing**, and the shape above is what stops that from being a
quiet exception to the Preferences rule rather than a stated one.

## 3. A status read is a write, so this copy has to earn the right to ask

Measured, and documented nowhere: one record per bundle identifier, and its
URL follows whichever copy last called `.status`. No `register()` needed.

That is a hazard created by how this project is developed. `./Scripts/dev.sh`
builds to `dist/CreativeNotch.app` and starts by deleting it. A user with the
released app in `/Applications` and the toggle on would have their login item
repointed at `dist/` the moment a dev build's Settings window drew this row —
and at the next login macOS would start the dev build, or, after the next
`dev.sh`, nothing. No error, no log line, and a symptom that shows up days
later.

**So eligibility is decided before the read, from the bundle's own path, and
an ineligible copy never touches `SMAppService` at all.**

```swift
public enum LaunchAtLoginEligibility: Equatable, Sendable {
    case eligible
    case notInstalled
    public static func resolve(bundlePath: String, installDirectories: [String]) -> Self
}
```

Eligible means the bundle sits **directly inside** an install directory:
`/Applications`, or `~/Applications`. A whitelist rather than a blacklist of
throwaway locations, because the blacklist cannot be enumerated — `dist/`,
DerivedData, a temp dir, a disk image, a Downloads folder — and the failure
mode of guessing wrong is silent. The cost is that an app deliberately kept
somewhere else is refused; the message names the path, so that is a refusal
the user can read rather than a mystery.

`"directly inside"` is load-bearing: `/Applications/Utilities/X.app` is not
`/Applications/X.app`, and a prefix match would also accept
`/Applications.old/X.app`.

**The ineligible row still says something true.** It is not hidden — a row
that vanishes teaches nothing. It is shown, switched off, not operable, with
the path it is running from and the manual route (§5).

## 4. What the controller does, and the seam that keeps tests off the real service

`LaunchAtLoginController` (UI target) owns three injected closures, defaulted
to the real service:

```swift
var readStatus: () -> Int        // SMAppService.mainApp.status.rawValue
var register:   () throws -> Void
var unregister: () throws -> Void
```

Closures rather than a protocol, for the same reason `AppState.onMediaCommand`
is one: **a real call changes the machine running the tests.** Registering a
login item from the suite would put a real record in the developer's BTM
database, and the suite would then pass or fail depending on whether it had
ever been run before. Nothing in `Tests/` may reach the real service, and the
injection is what makes that structural rather than a rule people remember.

Two operations, and both end the same way:

```
setEnabled(true)   → register()   → refresh()
setEnabled(false)  → unregister() → refresh()
refresh()          → eligible ? map(readStatus()) : .unavailable
```

**`refresh()` is the only writer of the published state, and it reads the
system rather than the argument it was just given.** A `register()` that
throws is caught, logged, and followed by a `refresh()` anyway — so a failed
attempt shows the switch falling back to off, which is what happened, instead
of staying on, which is what was asked for.

Raw status maps in Core, so the mapping is testable headlessly and
`CreativeNotchCore` never imports ServiceManagement:

| raw | `LaunchAtLoginState` |
|---|---|
| `1` enabled | `.on` |
| `0` notRegistered | `.off` |
| `3` notFound | `.off` |
| `2` requiresApproval | `.needsApproval` |

`notFound` and `notRegistered` both display as off. They are kept distinct in
the probe's notes because the difference is real — no record ever, versus a
disabled tombstone — but nothing in the UI acts on it, so nothing here
pretends to.

`requiresApproval` is the state the probe could **not** produce, because it
needs the user to deny the item in System Settings. It is handled rather than
measured, and the row says what it means: macOS is holding the registration
until it is approved.

## 5. The row

In Settings, its own section, **first** — it is about the app rather than
about a module, and the module sections read as a group below it. The section
is added to the `Form` directly rather than to `PreferencesSection`, whose
cases are module groups and whose "every section has rows" test is worth
keeping honest.

| State | Switch | What it says |
|---|---|---|
| `.on` | on, live | Opens CreativeNotch when you log in. |
| `.off` | off, live | Opens CreativeNotch when you log in. |
| `.needsApproval` | off, live | macOS is holding this until you allow it in System Settings → General → Login Items. |
| `.unavailable` | off, **not operable** | Only an installed copy can do this. This one is running from `<path>`. |

Every state carries a button to **Open Login Items**, which is the manual
route and the fallback the roadmap asked for. It is unconditional rather than
shown only on failure: the probe cannot prove the app actually *launches*
after a logout (§7), and a user for whom it silently does not needs the
manual route visible without having to deduce that they are in a failure
case.

## 6. What is pure, and what cannot be tested at all

`Sources/CreativeNotchCore/Startup/LaunchAtLoginEligibility.swift`
— path eligibility, and the raw-status mapping. Both pure, both fully tested,
added to the `CorePurityTests` manifest in the commit that creates them.

`Sources/CreativeNotchUI/Startup/LaunchAtLoginController.swift`
— the three closures, `refresh()`, `setEnabled(_:)`. Tested with fakes.

**The test that matters most is a negative one.** With an ineligible path and
a spy on `readStatus`, the spy must never be called: that is §3's whole
mitigation, and it is the only part of this module whose failure is silent.
A test that merely asserts the published state is `.unavailable` would pass
against a controller that read the status first and then discarded it — which
is precisely the bug.

**Not testable at all:** that macOS honours the record at login. See §7.

## 7. How this could betray the user, and what catches it

- **The repoint.** Caught by the eligibility gate and the spy test above.
  Re-measure on a new macOS release — a repoint-on-read is far likelier to be
  a bug than a contract, and if it is fixed, the gate becomes unnecessary
  rather than wrong.
- **A switch that lies.** Caught by `refresh()` being the only writer and by
  its reading the system rather than the argument.
- **A registration that exists but never launches.** **Not caught by
  anything in this repo.** The probe measured the record, never a login. The
  manual route is unconditional (§5) for exactly this reason, and the
  roadmap's demand stands: a real logout and a `pgrep` before believing the
  toggle.
- **Quarantine.** An app downloaded through a browser carries
  `com.apple.quarantine` and Gatekeeper refuses to open it; whether that also
  blocks a login launch is unmeasured. `install.sh` uses `curl`, which never
  sets the flag, so the supported install path is unaffected.

## 8. Deliberately not in v1

- **A LaunchAgent plist fallback.** Path-based, signature-blind, and it would
  work — but it is a second mechanism with its own enable/disable state, and
  two sources of truth for one switch is the thing §2 is about. It is the
  answer only if the logout check shows the public API's record is ignored.
- **Detecting which copy currently owns the record.** No public API exposes
  the URL; `sfltool dumpbtm` needs `sudo`. The eligibility gate makes the
  question moot rather than answering it.
- **Registering automatically on first launch.** Nothing in this app turns
  itself on.
