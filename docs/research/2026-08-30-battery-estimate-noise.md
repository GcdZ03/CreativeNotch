# Calibrating the battery time-remaining estimate

**Date:** 2026-08-30
**Machine:** M-series MacBook, macOS 26.5, internal battery, discharging from 68% to 57%.
**Duration:** 39.2 minutes, 512 samples.
**Probe:** a throwaway Swift script registering the real
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

## What was NOT measured, and what that means

**No plug/unplug transition was captured.** The machine ran on battery for
the whole session, so the settling window — how long after a transition
IOKit's estimate is worthless — has no measurement behind it.

`BatteryEstimateGate.settlingWindow` is therefore set to **90 seconds by
reasoning, not by evidence**, and is the one number in this module that
should be treated as provisional. Two things limit the damage:

- The agreement rule is independent of it and is measured. A wrong settling
  window changes *how long* the panel stays quiet after a transition; it
  cannot make the panel show a number that two consecutive readings
  disagree about.
- Erring long is the safe direction. Too long means a few extra seconds of
  "Estimating…"; too short means showing a number during recalibration,
  which is the failure the whole gate exists to prevent.

**To finish this measurement:** run the probe again
(`scratchpad/battery-probe.swift`), plug and unplug the charger a few
times with a couple of minutes either side, and look for how long `-1`
persists and how long the post-transition readings take to come within
`agreementTolerance` of each other. Then set `settlingWindow` from that and
update this section.
