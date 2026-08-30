# Calibrating the battery time-remaining estimate

> **The estimate is no longer displayed.** It was built on these
> measurements, shipped, and then removed — see "Built, then removed" in
> `docs/plans/2026-08-30-battery.md`. This note is kept because its
> findings are about IOKit's behaviour, not about this app's UI, and they
> are what anyone reconsidering the feature would otherwise have to
> rediscover. Findings 1, 6 and 7 still describe live code.

**Date:** 2026-08-30
**Machine:** M-series MacBook, macOS 26.5, internal battery, discharging from 68% to 57%.
**Duration:** 55 minutes, 653 samples, including one plug/unplug pair.
**Probe:** `2026-08-30-battery-probe.swift`, beside this file. Probes in
this project are normally throwaway and only their findings are kept; this
one is committed because the measurement below is *incomplete* and the
instructions for finishing it need something to point at. It is not built,
linted, or shipped.

It registers the real
`IOPSNotificationCreateRunLoopSource` callback and
`NSProcessInfoPowerStateDidChange`, plus a 5-second timer so the estimate
could be characterised *between* notifications. The timer is polling, which
the shipped module does not do; it exists here because notifications cannot
tell you what happens between them.

This is **not a feasibility spike**. `docs/ROADMAP.md` was right that the
APIs are public and documented and that no spike was needed. This measures
one thing the documentation does not state: how much IOKit's estimate moves
when nothing is happening, so `BatteryEstimateGate` can be calibrated
against evidence rather than taste.

## What was measured

### 1. The notification fires on drift, not only on transitions

**43 notifications in 39 minutes — roughly one a minute — with the charger
untouched the entire time.** The roadmap describes
`IOPSNotificationCreateRunLoopSource` as firing "when the power source
changes", which is true in the sense that the *published information*
changed; it is not once-per-plug-event.

Consequences, both built:

- `PowerObserver.read()` drops callbacks whose snapshot is identical to the
  last one, so a consumer is not rebuilt for an event carrying nothing.
- `PowerController` decides transitions by comparing `source` between
  consecutive snapshots. A design that treated "notification fired" as
  "the charger moved" would have fired a peek about once a minute, forever.

### 2. The estimate is quantised, in 5- and 10-minute steps

36 distinct values were reported. The gaps between adjacent distinct values:

| Gap (minutes) | Count |
|---|---|
| 10 | 19 |
| 5 | 8 |
| 1–7 (other) | 8 |

**This is the finding that changed the design.** A relative-only tolerance
is *too strict* at the bottom of the range, which is the opposite of the
usual concern. One 10-minute step is 4% of four hours and 50% of twenty
minutes:

| Estimate | One 10-min step | Accepted by a 10% relative rule? |
|---|---|---|
| 240 min | 4.0% | yes |
| 120 min | 7.7% | yes |
| 60 min | 14.3% | **no** |
| 30 min | 25.0% | **no** |
| 10 min | 50.0% | **no** |

A purely relative rule would therefore have left the panel reading
"Estimating…" continuously from about an hour of battery down to empty —
silent in precisely the part of the range where the number changes what
somebody does. Hence `BatteryEstimateGate.quantisationFloor`: a
disagreement of one step is always forgiven, because one step is the
smallest thing the estimator can express and so is not evidence of
anything.

### 3. Consecutive readings are stable, even under load

Between consecutive **notifications** (mean gap 53 s, n = 44):

| Percentile | Relative change |
|---|---|
| p50 | 3.14% |
| p75 | 4.03% |
| p90 | 4.48% |
| p95 | 4.59% |
| max | **4.69%** |

The session included a full debug build and app launch, which drove the
estimate from 457 minutes down to 203 — a 55% drift over the run. It got
there in small steps: no single consecutive pair disagreed by more than
4.7%.

**Chosen: `agreementTolerance = 0.10`.** A little over double the observed
worst case, so ordinary drift is never rejected, while the swing the
roadmap complains about — 1:20 to 4:55, a 73% disagreement — is rejected by
a wide margin. For reference, a 2% tolerance would have accepted only 11%
of the observed consecutive pairs, which is a panel that says nothing.

### 4. The `-1` sentinel never appeared

Zero "Still Calculating" readings in 512 samples of steady discharge. This
confirms the sentinel is a *transition* phenomenon, and confirms that
filtering it alone would have left the estimate completely ungated in the
steady state — where the estimate nonetheless moved 55%.

### 5. A transition, captured late in the session

The session eventually caught one plug/unplug pair, four seconds apart:

```
2828.4s  Battery Power -> AC Power    toEmpty=0   toFull=0  charging=false
2832.4s  AC Power -> Battery Power    toEmpty=-1
2945.0s  last -1
2948.8s  first usable reading: 219 minutes
```

- **The `-1` sentinel lasted 113 seconds**, and the first usable reading
  arrived **116 seconds** after the cable moved. `settlingWindow` is set to
  **120 s** on that basis. This is **n = 1** — one transition, on one
  machine, at 55% charge — so it is the weakest number in the module, and
  erring long is the deliberate direction.
- On that occasion IOKit's own `-1` covered the entire unreliable period,
  so the settling window added nothing. It remains insurance against the
  case the roadmap actually describes: *confident* nonsense rather than an
  admitted unknown, which no sentinel check can catch.

### 6. `Time to Full Charge` has a second not-applicable convention — and it is not negative

The two AC-power samples are the whole finding:

```
state=AC Power  charging=false  toEmpty=0  toFull=0
```

Plugged in, at 55%, with nothing charging, IOKit reports **`Time to Full
Charge = 0`**. That means "not applicable", not "zero minutes away".

The first implementation filtered only *negative* values as unknown, so the
0 was accepted as a real estimate and the panel read **"Until full: 0
min"**. This was a shipped bug, found by the user running the app, not by
the test suite.

Zero cannot simply be rejected everywhere: zero minutes *to empty* is a
legitimate reading and the most urgent one the module can carry. The guard
therefore sits on the state rather than on the value — `PowerObserver` does
not read the charging key at all unless `Is Charging` is true — and
`PowerLabel.timeRemainingValue` says **"Not charging"** rather than
"Estimating…", because nothing is being estimated and no amount of waiting
will produce a number.

### 7. "Plugged in and not charging" is a normal state, and the first wording of it was wrong

Observed live: adapter attached, **52%**, `Is Charging = 0`, and
`Current = -383` — the battery genuinely draining while plugged in.
`pmset` agrees ("AC attached; not charging") and so does `ioreg`
(`IsCharging = No`, `ExternalConnected = Yes`).

`IOPSKeys.h` documents this as legitimate rather than exceptional:

> Note that a battery may validly be plugged in, not charging, and <100% charge.
> e.g. A battery with capacity >= 95% and not charging, is defined as charged.

Two things were wrong in the shipped panel, and both were presentation
rather than data:

- The state line read **"Plugged in"**, which tells the user the cable is
  connected — something they can already see — and hides the part worth
  knowing. macOS calls this "Not charging"; so does the panel now.
- The time row was **titled "Until full" with the value "Not charging"** —
  a title promising a filling time, answered by a state. The title now
  falls back to "Time remaining" whenever nothing is filling, and the value
  is an em dash rather than a second copy of the state.

`Is Charged` is read separately from `Is Charging` because of the second
line of that quote: they are not negations of each other, and a machine
that has simply finished must not be reported with the same words as one
that is failing to charge. The key is absent from the dictionary entirely
while on battery, so "absent means not charged" matches Apple's convention.

## What is still weak

`settlingWindow` rests on a single transition.

The **"Fully charged"** path is unverified on real hardware: the machine
never reached the ≥95%-and-not-charging state during testing, and
`Is Charged` is not published while on battery. It is covered by unit
tests against a constructed dictionary, not by observation. **To strengthen it:** run the
probe again — `swift docs/research/2026-08-30-battery-probe.swift` — then
plug and unplug the charger several times with a couple of minutes either side, and look for how long `-1`
persists and how long the post-transition readings take to come within
`agreementTolerance` of each other. Then set `settlingWindow` from that and
update this section.
