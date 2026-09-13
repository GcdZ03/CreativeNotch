# Roadmap

Four modules are planned. **None of them is implemented.** Nothing in this
document describes code that exists — it records what each module would have
to do, and the specific problem each one has to solve before it can be
written.

Three have shipped, and their entries have been removed:

- **Battery and power state** (2026-08-30) — `docs/plans/2026-08-30-battery.md`,
  `docs/research/2026-08-30-battery-estimate-noise.md`.
- **Timer** (2026-08-30) — `docs/specs/2026-08-30-timer-design.md`,
  `docs/plans/2026-08-30-timer.md`.
- **Preferences** (2026-09-13) — `docs/specs/2026-09-13-preferences-design.md`,
  `docs/plans/2026-09-13-preferences.md`. It answered the question this
  document asks of every module, for all seven at once: **what does a toggle
  actually call to stop this subsystem?** Four had a stop verb already; three
  had nothing to stop, and the spec says so rather than inventing symmetry.
  Specifying it surfaced two live defects — an unlock would have resurrected a
  disabled media helper, and the power module could not be restarted at all —
  plus a dead `state.hasBattery` read that two doc comments described as the
  mechanism.

Every module in this project so far has gone spec → plan → implementation,
and the two that touched private or undocumented API (the system HUD, media
metadata) got a feasibility spike before the spec. The notes below say which
of these need one, and why.

## The constraint all four have to answer

> No subsystem runs when it isn't needed, and that rule is enforced
> centrally rather than trusted to each module.

That rule is the reason this project exists — see the battery-drain figures
in the README — and it is what makes several of these harder than they look.
A feature is not blocked by being expensive; it is blocked by being expensive
*while nobody is looking at it*. The question for each module below is
therefore always the same: what wakes it, and what does it cost when idle?

`SystemActivity` is the central gate, and it now has four consumers that
join it in three different ways:

- **Clipboard poller** and **media helper** are *suspended* outside
  `.active`. Their output is only worth producing while somebody can see it.
- **The power module** is not suspended. It is entirely notification-driven,
  so it costs nothing idle, and suspending it would only mean missing the
  charger moving while the lid was shut. What the gate suppresses there is
  the peek, not the observer.
- **The timer** is the third shape, and the sharpest: its *redraws* are
  gated and its *deadline* never is. A countdown's whole purpose is to fire
  while nobody is watching, which is the one thing the gate exists to
  suppress. Outside `.active` it schedules the deadline itself and nothing
  before it.

The useful precedent those two leave behind: joining the gate does not have
to mean being switched off. Ask what the subsystem *costs* when idle and what
it *draws* when nobody is looking, and gate those separately.

---

## 1. Microphone and camera in use

**What it is.** An ambient indicator when something is capturing — the
privacy tell, in the notch, next to the hardware it is about.

**Scope is the microphone and the camera. Screen recording is out**, and
that is now a decision rather than an open question the spike has to settle.
No public API reports that another application is capturing the screen;
macOS shows its own indicator and does not expose the underlying state. It
is listed under *Still deliberately not planned* below, with the rest of
what this project has ruled out.

Both properties are documented in word-for-word identical terms — *"a UInt32
where 1 means that the device is running in at least one process on the
system"* — so **cross-process reporting is documented, not inferred**. And
**CoreMediaIO is a public framework**, with public headers and a module map.
That is settled: this is not a second private-framework decision.

- **Camera.** CoreMediaIO's `kCMIODevicePropertyDeviceIsRunningSomewhere`.
  **Measured working**: it fired correctly, on both edges, from a probe
  process holding *no camera permission at all*. That matters more than it
  sounds — an indicator that had to request camera access in order to report
  camera use would be self-defeating.
- **Microphone.** CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere`.

**This roadmap previously had the risk on the wrong half, in the dangerous
direction.** It said the microphone was the settled one because the HUD's
`VolumeObserver` already uses CoreAudio. But `VolumeObserver`'s pattern is
*directional scope* (`kAudioDevicePropertyScopeOutput`) — correct for volume
and mute, which really are scoped — and applying it by analogy to
`DeviceIsRunningSomewhere` is reported to register with `noErr` and then
**never fire, ever**. The microphone half needs the probe *more* than the
camera half, precisely because this project's own precedent leads into the
trap.

**The trap this project has already hit twice.** The HUD's brightness
callback signature circulated online is wrong, and the media metadata
module's first probe reported the API ungated because the test binary
inherited Apple's signing identity. Both looked like working code. For any
`IsRunningSomewhere` property: verify it changes when a *different*
application starts capturing, not only when this one does.

**It must not point at itself, and the answer is not the one this document
first proposed.** Module 4 puts a camera preview in the notch, making
CreativeNotch one of the applications this indicator watches for.
`IsRunningSomewhere` reports *that* something is capturing, not *who* — so it
cannot answer this alone.

The obvious fix was `AVCaptureDevice.inUseByAnotherApplication`, which is
public and documented as meaning exactly what its name says. **It did not
work in the probe**: it read `false` throughout, while a genuinely separate
application captured on that exact device. That measurement is confounded —
the observing process had never requested camera access, so it cannot
distinguish "the property does not work" from "it needs an authorisation we
did not ask for" — and *either* answer disqualifies it here, because a
privacy indicator that must hold camera permission to function is the wrong
shape.

**Use `kAudioHardwarePropertyTranslatePIDToProcessObject` instead.** It maps
a PID directly to its audio process object, so "is that me?" is a cheap
lookup rather than an enumeration, and it needs no permission at all.

**Needs a spike:** yes — and it is now the *microphone* half, plus the
listener-removal question below.

**One thing to measure before trusting `stop()`.** There is an unresolved
report that `CMIOObjectRemovePropertyListenerBlock` returns `noErr` and keeps
delivering. If that reproduces on macOS 26, a registration count of zero
proves only that removal was *asked for*, and the observer needs its own
stopped flag as a backstop. That is the same class of failure as the media
helper's activity gate: a stop that is asserted rather than observed.

---

## 2. Launch at login

**What it is.** A toggle that registers the app to start with the session.

**How.** `SMAppService.mainApp.register()`. macOS 13+, public, and it costs
nothing at runtime — the registration is state, not a process.

**The thing to get right, and it is specific to this app.**
CreativeNotch is **ad-hoc signed, not notarised**, and installed by a shell
script rather than dragged from a disk image. `SMAppService` cares about
where the bundle lives and about its signature, and a login item whose
registration silently fails is worse than no toggle at all — the user
believes it is on. The toggle must read back the service's actual `status`
and show that, rather than showing whatever the user last clicked.

The same applies to a dev build: an ad-hoc signature's designated
requirement is the code hash, so a registration made by one build may not
survive the next. See `docs/DEVELOPMENT.md` on why local signing exists.

**The variable is the identity, not the path.** This entry used to say the
spike had to confirm registration survives "the install script's path". The
path is almost certainly irrelevant. An ad-hoc signature's designated
requirement is the **code hash**, so every build is a different identity —
which is already why this project loses its Accessibility grant on every
rebuild, and, now measured, its camera grant too. Whether Background Task
Management tracks a `mainApp` login item by that identity is stated nowhere
in Apple's documentation.

**Two questions, neither answerable from documentation:**

1. Does `mainApp.register()` accept an ad-hoc signature at all? Apple says
   apps using these APIs "must be code signed" and never defines *properly*
   signed. If the answer is `kSMErrorInvalidSignature`, **this ships as an
   explanation rather than a toggle**.
2. Does a registration survive replacement by a different cdhash at the same
   path?

**A warning about researching this one.** A web search returns, as flat fact,
*"Ad hoc signing is not sufficient for SMAppService operations."* Apple has
never written that; it is a generalisation of one reply about an **embedded
helper**, whose identity must match its container — a code path `mainApp`
does not use. It is the brightness-callback failure again, and it is now in
the search index. Design against Apple's own text, and measure the rest.

**Needs a spike:** yes, and it is the one that needs a human: a throwaway
ad-hoc bundle, installed the real way, and **two logout/login cycles**.
`status == .enabled` is not evidence — a BTM record survives deleting the app
entirely. Only a `pgrep` after a real logout proves anything.

---

## 3. Global hotkey

**What it is.** A key combination that opens the panel from anywhere.

**The obvious implementation is the wrong one.** An
`NSEvent.addGlobalMonitorForEvents` monitor runs on every keystroke you
type, forever, which is precisely the cost this project exists to avoid, and
`ARCHITECTURE.md` names permanently-installed global monitors as not
allowed.

`RegisterEventHotKey` is the answer. It registers the specific combination
with the window server, which delivers an event only when that combination
is pressed. Nothing runs in between. It is old Carbon-era API and still
supported, and unlike a monitor it needs no Accessibility permission,
because it never sees any key but the one it registered.

**Worth knowing.** `MediaKeyMonitor` is currently the project's *one*
admitted always-installed monitor, and it earns that by firing only on
physical media keys. A second one would need the same justification;
`RegisterEventHotKey` avoids needing it at all.

**The conflict model in this document was wrong, and the correction changes
what the preferences pane may honestly say.** It used to claim registration
fails when another app holds the combination, and that checking `OSStatus`
catches it. Apple's header says the opposite — *"The same hot key can be
registered by multiple applications"* — so an ordinary conflict returns
`noErr` and **both** handlers fire. Checking the status detects nothing.

Apple's header then contradicts itself about whether the `kEventHotKeyExclusive`
option gives honest detection. **Measured, with two separate bundle
identities:**

| Incumbent | Challenger | Result |
|---|---|---|
| non-exclusive | non-exclusive | `noErr` |
| non-exclusive | **exclusive** | `noErr` |
| **exclusive** | **exclusive** | **−9878 `eventHotKeyExistsErr`** |
| **exclusive** | non-exclusive | `noErr` |

The narrow reading holds: exclusive registration detects only other
*exclusive* registrants, and virtually nothing ships with that option. The
third row is what makes this a real result rather than an inert option.

**So the pane must not claim "that combination is taken."** What it can
honestly do: detect duplicates *within this app* (same-process
re-registration does return −9878), and enumerate `CopySymbolicHotKeys()` for
system conflicts. A system hotkey like ⌘Space registers with `noErr` and then
never delivers, because the system consumes it first.

**Also measured:** `RegisterEventHotKey` is **not deprecated** — the
"deprecated since 10.8" claim that dominates search results is false — and
the macOS 15 shift/option-only restriction **does not survive into macOS 26**:
all sixteen modifier subsets register cleanly, zero modifiers included.

**The real trap is Swift 6, not Carbon.** Calling a `@MainActor` method
straight from the C callback is *only a warning* under strict concurrency. It
compiles and works by luck. That is why CI now fails on any warning.

**Needs a spike:** no. This is the only remaining module with no unresolved
feasibility question, which is why it goes first.

---

---

## 4. The camera in the notch

**What it is.** Click the notch, choose the camera tab, and the FaceTime
camera's feed appears in the panel — a mirror for checking framing before a
call, a shutter for a still, and a record button for a clip. What gets
captured lands in the file shelf.

**The pleasing part is geometric rather than technical.** The camera sits
physically behind the notch, so a preview drawn in the open panel is
directly beneath the lens feeding it. Looking at yourself means very nearly
looking at the camera.

### Why this is allowed when the audio visualiser is not

This is the most expensive thing the app would ever do, and a few lines
below, the visualiser is refused as a top CPU cost that contradicts the one
rule. A live capture session costs more than an FFT. So the distinction
cannot be cost, and pretending it is would be dishonest:

> The visualiser runs **ambiently**. It would draw whenever audio played,
> whether or not anybody had the notch open, and whether or not anybody was
> looking. The camera runs **only because the user opened it**, and only
> while they are watching the thing it produces.

The rule is *no subsystem runs when it isn't needed*, not *nothing expensive
is allowed*. A preview the user explicitly asked for, while they are looking
at it, is the definition of needed. The visualiser fails the rule; this
passes it — **provided the session actually stops.**

### Where this module can silently betray the rule

An `AVCaptureSession` left running behind a closed panel is exactly the idle
drain this project exists to avoid, and it is invisible everywhere except
the battery graph. **Hiding the view is not stopping the session.** It has
to stop on:

- the panel dismissing by any route — click-out, Escape, the menu bar item
- the tab changing away from the camera
- screen lock and display sleep, which `SystemActivity` already reports
- app termination

This is the first module where the gate is not a power optimisation but a
privacy guarantee. The green light beside the lens is the user's only
evidence of what the app is doing, and it has to go out when they close the
panel.

### Permissions, and the trap specific to this app

`NSCameraUsageDescription` in the bundle plist, and
`AVCaptureDevice.requestAccess(for: .video)`. TCC keys the grant to the code
signature, and CreativeNotch is **ad-hoc signed** — an ad-hoc signature's
designated requirement is the hash of the code, so the camera grant is
revoked on every rebuild. This is the same failure `DEVELOPMENT.md` already
documents for Accessibility, and `Scripts/setup-signing.sh` is the same
answer. Expect it while developing rather than discovering it as a bug.

**The green light is not suppressible.** It is wired to the camera hardware
below the level of any API. Document it, so "the light comes on" is not
filed as a defect.

### The geometry fits — this document got the arithmetic wrong

**Correction.** This section used to read *"the geometry does not fit"*, on
the basis that a 16:9 preview 620 points wide wants 349 points of height
against a 260-point panel. That is only true fitting to **width**. Fit to
**height** and 16:9 at 260 tall is **462 × 260**, which sits inside 620 with
158 points to spare for controls.

The real constraint is not `expandedSize` at all — it is the **tab content
area** left after the notch inset, the media header when a track is playing,
and the tab bar. That leaves roughly 130 points with music playing and ~195
without, and **a preview whose height changes when a track starts is not
acceptable.**

So the option this document missed is the likely answer: a camera tab that
**suppresses the media header and tab chrome and takes the full 260**,
leaving `expandedFrame` untouched and every other tab unaffected. Measure the
three heights on a real screen before the spec commits.

### Recording needs what a preview does not

A clip needs somewhere to go while it is being written, a size that is not
unbounded, and an unambiguous tell that recording is happening. The shelf is
the natural destination and already knows how to hold files and drag them
back out. What `ShelfStore` does *not* have is any notion of a file still
being written — so a clip should land in the shelf **on stop, not on
start.**

### The teardown question is answered, and the module is admissible

This module's admission rests entirely on "provided the session actually
stops", and Apple's documentation does not reach that far: `stopRunning` is
documented to stop the session *object* and the flow of data, never to say
when the **device** is released. `AVCaptureVideoPreviewLayer.isPreviewing` —
the only in-process cross-check — is unavailable on macOS, and the preview
layer **retains the session**, so the obvious teardown leaves it running with
no symptom anywhere inside the app.

**Measured, twice, with an out-of-process observer and a control:**

| Variant | Observer saw the device released |
| --- | --- |
| `stopRunning()` alone | **10 ms after the call was made** — 40 ms before it returned |
| `stopRunning()` + remove inputs/outputs + drop the session | 52 ms before the call returned |

Both held at released for the full 120-second idle hold **with the process
still alive**, which is what rules out the obvious false pass: a probe that
exits measures the kernel reclaiming a dead process's handle, not
`stopRunning`.

So **`stopRunning()` alone is sufficient**, the deeper teardown buys nothing
for device release, and the justification above holds as written. Still nil
the preview layer's session — that is a retain cycle, not a device claim.

**One cost to write into the spec.** TCC keys the camera grant to the code
hash, and this app is ad-hoc signed. Confirmed in the same probe: a rebuild
with an unchanged bundle identifier and a changed cdhash **re-prompted for
camera access**. Every shipped update makes every user approve the camera
again. Unlike Accessibility, which fails silently, this is noisy and
self-healing — but it is a real cost, and it is one of several that a stable
signing identity would remove at a stroke.

**Needs a spike:** the hard one is done. What remains is the preview inside
an `LSUIElement` agent that owns no ordinary window — only an `NSPanel` whose
hosting view already declines clicks in three layers.

## Suggested order

**Preferences has shipped**, which removes the argument that used to lead this
section: the remaining four wanted somewhere to live, and now they have one.
Every module is switchable, and switching one off stops what it runs.

1. **Global hotkey**, *alone*. The only remaining module with **no unresolved
   feasibility question**, no signing coupling, and mostly pure combinatorics —
   the best Core-to-UI test ratio of the four. The right first real consumer of
   the preferences surface.
2. **The camera in the notch**, de-risked by the teardown measurement above.
3. **Microphone and camera indicators.**
4. **Launch at login**, *last*, and conditional. It is the only module that
   might not exist, and pairing it with the hotkey — as this document used to —
   risks the safe one slipping behind the blocked one.

**What Preferences leaves for whoever builds the next module.** Adding a
module now means adding a `ModuleID` case, a row in `PreferencesView.rows`, and
a leg to `ModuleSwitchboard.setEnabled` — and the leg has to *stop something*,
because every one of them is mutation-verified against its own subsystem rather
than against a stored boolean. That is the enable/disable retrofit this
document kept warning about, paid once.

**Why 2 before 3, restated.** This document used to justify it by
self-exclusion: build the camera first so the indicator is designed not to
point at it. That reason is weaker than it looked, and the measurement above
weakened it further. The stronger reasons: the camera module can **delete** the
indicator module's hardest requirement outright if it is ever cut, and whether
clips carry sound is a camera scope decision that determines whether
CreativeNotch is something the *microphone* indicator must exclude.

### The decision that sits above all of this: a signing identity

Three separate findings are the same finding. CreativeNotch is **ad-hoc
signed**, so its designated requirement is the code hash and its identity
changes on every build. Measured consequences:

| | |
| --- | --- |
| Accessibility grant dies on every rebuild | already documented; `Scripts/setup-signing.sh` exists for it |
| Camera grant re-prompts on every update | **measured** — module 5 |
| Launch at login may be refused outright | unmeasured — module 2 |
| Downloads carry quarantine | why install instructions need `xattr -dr` |

A Developer ID would remove all four. That is a **distribution decision, not
a launch-at-login decision**, it costs money rather than time, and it gates
how modules 2 and 5 are specified. It should be settled before either is
built, and it is the reason module 2 sits last rather than second.

## Still deliberately not planned

- **An audio visualiser.** Named in this category as a top CPU cost; it
  contradicts the one rule directly.
- **A screen-recording indicator.** Cut from module 1 above. No public API
  reports that another application is capturing the screen, and macOS
  already shows its own indicator for it.
- **iCloud sync.** Requires the paid Developer Program.
- **A synthetic black notch** on notchless Macs. The pill is the answer.
- **The Mac App Store.** Private framework use rules it out regardless.
