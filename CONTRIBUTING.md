# Contributing

This is a personal tool that happens to be open source. Issues and pull
requests are welcome, but the bar is set by one rule rather than by taste.

## The rule

> No subsystem runs when it isn't needed, and that rule is enforced
> centrally rather than trusted to each module.

Existing apps in this category are notorious for idle battery drain — global
mouse monitors running continuously, system stats on timers, audio
visualisers running FFT on a live tap. Users report up to 5%/hour.

**A change that introduces an unconditional `Timer`, an always-installed
global event monitor, or cursor polling will be declined**, however useful
the feature is. If you think you need one, you probably need a notification
you have not found yet. The one genuine exception — clipboard history, since
`NSPasteboard` has no change notification — is gated centrally on
`SystemActivity`. A looping animation counts too: the one allowed, the music
peek's equalizer, runs only while that peek is open, and a test bans the rest.

## Before you open a PR

Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). It documents the traps,
not just the design — the flipped `NSHostingView` coordinate space, the
compiler-enforced state funnel, why omitting `.fullScreenAuxiliary` is
load-bearing. Most PR feedback would otherwise be about things written down
there.

Then [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) for the dev loops and the
one-time signing setup.

## Tests are expected to fail when the code is broken

This is the one process demand, and it is not negotiable.

During the foundation build, three tests shipped that passed with their
implementation deleted. Every one was caught by a reviewer mutating the
source, not by reading it. Two more were only shown adequate after a
reviewer proved they covered half the bug they claimed to.

So for every test you add:

1. Introduce the bug it targets, in the real source.
2. Run the suite. Confirm your test **fails**.
3. Revert. Confirm it passes.

Say in the PR that you did, and what failed. A test you cannot make fail is
not protecting anything.

## Structure

- New code belongs in `CreativeNotchCore` unless it genuinely needs AppKit or
  SwiftUI. **`CreativeNotchCore` importing either is a mistake, not a
  tradeoff** — its independence is what lets the logic run headlessly in CI.
- Nothing new should accumulate in `Sources/CreativeNotch/`; that target is
  unreachable by tests.
- When something in `CreativeNotchUI` turns out to be worth testing, move its
  logic down into Core rather than reaching for a mock.

## Scope

Every module on the roadmap has shipped. New work lands the same way the
modules did: one change at a time, with its design written down before any
code — see `docs/specs/`.

Before starting anything substantial, **open an issue first.** This project
is opinionated and narrow by design; it is better to find out early that
something is out of scope than after you have written it.

## Merging

`main` is protected: a change goes in through a pull request, and CI must
pass. CI fails on **any** compiler warning, tests included.

## Commits

Conventional prefixes: `feat:`, `fix:`, `test:`, `refactor:`, `chore:`,
`docs:`. Explain *why* in the body when it is not obvious; the code already
says what.

## Licence

Contributions are licensed under [GPL-3.0](LICENSE), same as the project.
