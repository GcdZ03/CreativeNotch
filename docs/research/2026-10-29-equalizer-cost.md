# What moving bars cost — measured

2026-10-29, 14" MacBook Pro (Apple silicon, ProMotion XDR display), macOS 26,
on AC power, with the machine in ordinary use. Probe:
`docs/research/2026-10-29-equalizer-probe.swift`.

## The question

The closed notch's equalizer bars have stood still since 2026-10-15 because
they are on screen for as long as music plays. The second competitor round
asked for them to move. Is there a way to move four 3pt bars that costs
nothing while it runs, and if not, what does it cost?

## 1. Four ways of moving the bars, in a probe

One small borderless panel near the bottom-right corner of the screen, the
bars drawn one of six ways, 30s per run with a 2s settle, the runs
interleaved round-robin. The app's own CPU and energy come from
`proc_pid_rusage` (`ri_user_time + ri_system_time`, `ri_energy_nj`);
WindowServer's CPU from `ps -o time=` around the same 30s.

| Mode | Runs | App CPU | App energy / 30s | WindowServer CPU, mean (median, sd) |
| --- | --- | --- | --- | --- |
| no probe window | 9 | — | — | 34.5% (37.0, 6.1) |
| static SwiftUI capsules | 15 | 0.008% | 2.9 mJ | 38.8% (40.0, 11.4) |
| SwiftUI `.repeatForever`, frame height | 3 | **6.27%** | **572 mJ** | 47.8% (46.7, 1.6) |
| SwiftUI `.repeatForever`, scaleEffect | 3 | **5.22%** | **682 mJ** | 50.0% (46.7, 4.7) |
| `CABasicAnimation`, uncapped | 9 | 0.009% | 2.5 mJ | 50.4% (50.0, 4.6) |
| `CABasicAnimation`, 30 fps | 3 | 0.005% | 1.0 mJ | 50.0% (50.0, 5.4) |
| `CABasicAnimation`, 20 fps | 15 | 0.010% | 3.4 mJ | 39.6% (46.7, 13.8) |

**What this settles.**

- **A SwiftUI loop is expensive in the app itself:** 5–6% of a core,
  ~200× a static view, because SwiftUI re-evaluates and re-lays-out the view
  every frame in-process. That is what the music peek's bars cost while the
  cursor rested on them, until this change.
- **A Core Animation loop costs the app nothing measurable:** 0.01%, the
  same as not animating. The animation is committed to the render server
  once and the app never runs again for it.

**What it does not settle.** The window server still composites whatever
is animating, every frame. Its CPU is dominated by everything else on a
machine in use (a 34–40% baseline here, with run-to-run spread of 5–14
points), so the difference between modes is near the noise:

- Uncapped (and 30 fps) Core Animation sits about **10 points above static**
  on the mean and the median alike, consistent across runs. That is real
  enough to act on: an always-on animation is not free, wherever it runs.
- Capped at **20 fps** it lands between static and uncapped (median 46.7,
  mean 39.6) with the widest spread of all. It is cheaper than uncapped;
  how much cheaper, this machine cannot say.

`powermetrics` (root) on an idle machine would answer the window server's
share properly; it was not run.

## 2. The real app

The shipped bars (`EqualizerBarsView`, Core Animation, 20 fps) in a release
build, closed notch, with a silent stand-in player publishing Now Playing.
Each run relaunched the app with Moving bars on or off, let it settle 25s,
then measured 60s. Three rounds, interleaved:

| Round | Moving: app CPU | Moving: WindowServer | Still: app CPU | Still: WindowServer |
| --- | --- | --- | --- | --- |
| 1 | 0.03% | 41.7% | 0.03% | 16.7% |
| 2 | 0.12% | 35.0% | 1.10%\* | 25.0% |
| 3 | 0.03% | 26.7% | 0.03% | 15.0% |
| mean | 0.06% | **34.4%** | — | **18.9%** |

\* One outlier with the bars still; nothing in the app runs per frame then,
so it is something else the app did in that minute.

- **The app's share is nothing**, moving or still, as the probe predicted.
- **The window server ran about 15 points higher with the bars moving, in
  every round.** The noise is large, but every pair points the same way and
  the gap is bigger than in the probe — a real notch window over the menu bar
  is composited with more around it than a probe window in a corner.

That is a cost a battery should not carry for the length of an album.

## What was decided

- **Every loop is Core Animation now**, capped at 20 fps
  (`EqualizerBarsView.framesPerSecond`). The music peek's bars keep their
  look and lose 5–6% of a core of app CPU while the peek is open.
- **Moving bars in the closed notch ship off** (Settings → Layout → Moving
  bars). The app's share is nothing; the window server's is not, and it
  would be paid for as long as music plays. Off by default is the one rule;
  on is the user's informed choice, and the Settings caption says what it
  costs.
- **Even switched on, they move only on the charger**, and stand still on
  battery, in Low Power Mode and under Reduce Motion.
- **No real audio visualiser.** Bars that follow the music need a Core Audio
  process tap and an FFT for as long as music plays — app CPU every frame,
  on top of the compositing above — and a "system audio recording"
  permission. One competitor that shipped it broke the AirPods
  pause gesture on Bluetooth output. Still refused (ROADMAP).
