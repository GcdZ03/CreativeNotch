# Roadmap

Four modules are planned. **None of them is implemented.** Nothing in this
document describes code that exists — it records what each module would have
to do, and the specific problem each one has to solve before it can be
written.

Two of the original six have shipped, both on 2026-08-30, and their entries
have been removed:

- **Battery and power state** — `docs/plans/2026-08-30-battery.md`,
  `docs/research/2026-08-30-battery-estimate-noise.md`.
- **Timer** — `docs/specs/2026-08-30-timer-design.md`,
  `docs/plans/2026-08-30-timer.md`.

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

## 1. Screen recording, microphone and camera in use

**What it is.** An ambient indicator when something is capturing — the
privacy tell, in the notch, next to the hardware it is about.

**This is the one with a genuine feasibility question, and the three parts
are not equally solvable.**

- **Microphone.** CoreAudio exposes
  `kAudioDevicePropertyDeviceIsRunningSomewhere` as a listenable property.
  Property listeners are notification-driven, so this fits the one rule
  cleanly. This is the same framework the HUD's `VolumeObserver` already
  uses, so the project has the pattern.
- **Camera.** CoreMediaIO exposes the analogous
  `kCMIODevicePropertyDeviceIsRunningSomewhere`. Less travelled than the
  CoreAudio equivalent and worth proving before committing to it.
- **Screen recording.** No public API reports that another application is
  capturing the screen. macOS shows its own indicator and does not expose
  the underlying state. Assume this part is **not feasible** until a spike
  proves otherwise, and be prepared to ship the module with two of its three
  parts.

**The trap this project has already hit twice.** The HUD's brightness
callback signature circulated online is wrong, and the media metadata
module's first probe reported the API ungated because the test binary
inherited Apple's signing identity. Both looked like working code. For any
`IsRunningSomewhere` property: verify it changes when a *different*
application starts capturing, not only when this one does.

**Needs a spike:** yes — and the spike's first job is to decide whether
screen recording is in scope at all.

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

**Needs a spike:** small one — enough to confirm registration survives the
install script's path and the ad-hoc signature.

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

**The thing to get right.** Conflict handling. Registration fails when
another app already holds the combination, and the failure is silent unless
checked. A hotkey that does nothing, with a preferences pane insisting it is
set, is the same failure mode as the login item above.

**Needs a spike:** no.

---

## 4. Preferences

**What it is.** A settings surface: enable or disable individual modules,
and adjust the values currently compiled in — dwell delay, clipboard
retention and poll interval, HUD peek duration, which peeks are allowed to
interrupt.

**This is the module the others depend on.** Launch-at-login and the
global hotkey both need somewhere to live, and every module above adds
another thing worth turning off.

**The architectural requirement, and it is the whole point.** Disabling a
module must **stop its subsystem**, not hide its UI. Turning off clipboard
history has to stop the poller; turning off media metadata has to terminate
the helper subprocess. A preference that leaves the cost running while
removing the feature is strictly worse than no preference — the user pays
for something they explicitly declined. That means module toggles belong
next to the `SystemActivity` gate, in the same place that already knows how
to start and stop these subsystems, rather than in the views.

**What exists to build on.** `UserDefaults` is already used in two places,
and `OnboardingWindow` establishes the pattern worth copying: it takes an
injectable `UserDefaults` suite so its logic is testable against an isolated
store instead of the real one. Every preference should be readable and
writable through `CreativeNotchCore` so the defaults logic stays headlessly
testable.

**The thing to get right.** Defaults are a compatibility surface. Once a key
ships, its absence, its type, and its out-of-range values all have to mean
something forever. Decide what an unset key means before the first release
that reads it.

**Needs a spike:** no, but it needs a spec more than any of the others —
it is the only one of the five that changes how existing modules are wired.

---

## Suggested order

**Battery and the timer both shipped ahead of this order**, which was
originally Preferences-first on the grounds that four of the six then-planned
modules wanted a home in a preferences surface.

That reasoning still holds for what remains, and it did not hold for either
of the two that shipped. Battery's tunables are four documented `static let`s
in Core; the timer's are its 99-minute cap and its badge width. Preferences
can read all of them whenever it arrives. The cost the ordering warns about
is retrofitting module *enable/disable* wiring, which is a different thing
from retrofitting a constant — and neither module made that harder.

1. **Preferences**, because the remaining three want a home in it, and
   because retrofitting module enable/disable is more expensive than
   building for it.
2. **Launch at login** and **global hotkey** — small, self-contained, and
   they validate the preferences surface with real settings.
3. **Capture indicators**, last, because it is the only one that might come
   back from its spike smaller than planned.

## Still deliberately not planned

- **An audio visualiser.** Named in this category as a top CPU cost; it
  contradicts the one rule directly.
- **iCloud sync.** Requires the paid Developer Program.
- **A synthetic black notch** on notchless Macs. The pill is the answer.
- **The Mac App Store.** Private framework use rules it out regardless.
