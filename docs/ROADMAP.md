# Roadmap

Two modules are planned. **Neither is implemented.** Nothing in this
document describes code that exists — it records what each module would have
to do, and the specific problem each one has to solve before it can be
written.

Three have shipped, and their entries have been removed:

- **Battery and power state** (2026-08-30) — `docs/plans/2026-08-30-battery.md`,
  `docs/research/2026-08-30-battery-estimate-noise.md`.
- **Timer** (2026-08-30) — `docs/specs/2026-08-30-timer-design.md`,
  `docs/plans/2026-08-30-timer.md`.
- **The camera in the notch** (2026-09-13) —
  `docs/specs/2026-09-13-camera-design.md`. The module whose admission rested
  on a single undocumented question -- does `stopRunning()` release the
  hardware -- now answered by measurement rather than by argument: 10ms after
  the call is made, and still released 120 seconds later with the process
  alive. It also turned out this document's geometry arithmetic was wrong; the
  preview fits.
- **Global shortcut** (2026-09-13) — `docs/specs/2026-09-13-global-hotkey-design.md`,
  `docs/research/2026-09-13-hotkey-probe.md`. Three of this document's claims
  about it were wrong, and the probe that found that out is recorded beside the
  spec: `OSStatus` cannot detect a conflict, `RegisterEventHotKey` is not
  deprecated, and the macOS 15 shift/option restriction does not survive into
  macOS 26. What the module does about the undecidable part — asking the user
  to press the combination once — is the only honest proof available.
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

## The constraint both have to answer

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
- **Microphone.** CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere`,
  **registered on global scope**. Measured: global fires once per edge;
  the directional-scope listener `VolumeObserver`'s pattern would have used
  fires **never** — while its property value reads correctly throughout, so
  polling to check it would pass. See
  `docs/research/2026-09-13-capture-listener-scope.md`.

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
first proposed.** Module 3 puts a camera preview in the notch, making
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

**The microphone spike is done**, and it confirmed this entry's correction:
global scope notifies, input scope does not, and input scope's *value* is
accurate the whole time — so the trap survives every check short of an
end-to-end test with a second application capturing.

**Needs a spike:** only the listener-removal question below.

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

## Suggested order

**Preferences has shipped**, which removes the argument that used to lead this
section: the remaining four wanted somewhere to live, and now they have one.
Every module is switchable, and switching one off stops what it runs.

1. **Microphone and camera indicators.** The camera module has shipped, which
   settles the dependency this order was really about: CreativeNotch is now a
   known, instrumentable capture client to test the indicator against, and —
   because clips are silent — it is **not** something the microphone half has
   to exclude.
2. **Launch at login**, *last*, and conditional. It is the only module that
   might not exist, and pairing it with the shortcut — as this document used
   to — would have risked the safe one slipping behind the blocked one. The
   shortcut has since shipped on its own, which is the argument settled.

**What Preferences leaves for whoever builds the next module.** Adding a
module now means adding a `ModuleID` case, a row in `PreferencesView.rows`, and
a leg to `ModuleSwitchboard.setEnabled` — and the leg has to *stop something*,
because every one of them is mutation-verified against its own subsystem rather
than against a stored boolean. That is the enable/disable retrofit this
document kept warning about, paid once.

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
