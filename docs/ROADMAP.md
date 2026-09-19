# Roadmap

**Nothing is planned. Every module this document ever described has shipped.**

It is kept because what it recorded was never a feature list — it was the
specific problem each module had to solve before it could be written, and the
entries that turned out to be *wrong about that problem* are the useful part.
Three of them were, and each is noted below.

Their entries have been removed as they shipped:

- **Battery and power state** (2026-08-30) — `docs/plans/2026-08-30-battery.md`,
  `docs/research/2026-08-30-battery-estimate-noise.md`.
- **Timer** (2026-08-30) — `docs/specs/2026-08-30-timer-design.md`,
  `docs/plans/2026-08-30-timer.md`.
- **Microphone and camera indicator** (2026-09-13) —
  `docs/research/2026-09-13-capture-listener-scope.md`. The spike this entry
  called for settled the dangerous half: the listener must be registered on
  **global** scope, because the directional scope this project's own
  `VolumeObserver` uses registers with `noErr` and never fires — while its
  property value reads correctly throughout, so polling to check it would pass.
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

- **Launch at login** (2026-09-19) —
  `docs/specs/2026-09-19-launch-at-login-design.md`,
  `docs/research/2026-09-19-launch-at-login-probe.md`. **This document was
  wrong about it twice.** It said the module might not exist as a toggle at
  all, because an ad-hoc signature might be refused: it is not, and the record
  also survives a new code hash, so the entry's central worry — that the
  signing identity was the variable — was the one row of its own table that
  did not hold. What it never thought to ask is the thing that actually shapes
  the module: reading `.status` repoints the system's record at the copy doing
  the reading, so a dev build drawing the Settings row would silently steal a
  user's login item. Measurement found that; no amount of argument would have.

Every module in this project so far has gone spec → plan → implementation,
and the two that touched private or undocumented API (the system HUD, media
metadata) got a feasibility spike before the spec. The notes below say which
of these need one, and why.

## The constraint it has to answer

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

## There is no order left to suggest

Every module has shipped. Everything this document warned about ordering —
retrofitting enable/disable wiring, modules wanting somewhere to live — was
paid once, by Preferences.

**What that leaves for whoever builds an eleventh.** Adding a module means
adding a `ModuleID` case, a row in `PreferencesView.rows`, and a leg to
`ModuleSwitchboard.setEnabled` — and the leg has to *stop something*, because
every one of them is mutation-verified against its own subsystem rather than
against a stored boolean.

Unless it stops nothing, in which case it is not a `ModuleID` at all. Launch
at login is the precedent: the system owns its state, so it has no stored
flag, no switchboard leg and no lifecycle hook, and it reads the truth back
on every appearance instead. See its spec, §2.

### The decision that sits above all of this: a signing identity

Three separate findings are the same finding. CreativeNotch is **ad-hoc
signed**, so its designated requirement is the code hash and its identity
changes on every build. Measured consequences:

| | |
| --- | --- |
| Accessibility grant dies on every rebuild | already documented; `Scripts/setup-signing.sh` exists for it |
| Camera grant re-prompts on every update | **measured** — module 5 |
| ~~Launch at login may be refused outright~~ | **measured, and it is not** — an ad-hoc bundle registers cleanly, and the record survives a new code hash |
| Downloads carry quarantine | why install instructions need `xattr -dr` |

A Developer ID would remove the rest. That is a **distribution decision**, it
costs money rather than time, and it no longer gates any module: launch at
login turned out not to need it, and the camera ships with a re-prompt on
every update rather than waiting for one.

What it would still buy: an Accessibility grant that survives rebuilds
without a local certificate, no camera re-prompt, and downloads that are not
quarantined.

## Still deliberately not planned

- **An audio visualiser.** Named in this category as a top CPU cost; it
  contradicts the one rule directly.
- **A screen-recording indicator.** Cut from module 1 above. No public API
  reports that another application is capturing the screen, and macOS
  already shows its own indicator for it.
- **iCloud sync.** Requires the paid Developer Program.
- **A synthetic black notch** on notchless Macs. The pill is the answer.
- **The Mac App Store.** Private framework use rules it out regardless.
