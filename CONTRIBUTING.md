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

## Strings and translations

Every word the app shows or speaks — panel text, Settings, the menu bar,
VoiceOver labels and announcements — comes from one String Catalog,
[`Sources/CreativeNotchCore/Localizable.xcstrings`](Sources/CreativeNotchCore/Localizable.xcstrings).
The camera permission prompt, which macOS reads from the app itself, has its
own: [`Resources/InfoPlist.xcstrings`](Resources/InfoPlist.xcstrings).

**Writing a string.** In Core or the UI alike:

```swift
String(localized: "Close camera", bundle: .creativeNotch)
Text("Nothing copied yet", bundle: .creativeNotch)
```

The bundle is not optional. Without it the lookup goes to the main bundle,
which has no strings, and the English still shows — so nothing looks wrong
until a translation fails to appear. `LocalizationTests` fails on prose in a
literal that skips the catalog, and on a localized literal the catalog does
not have. Interpolate rather than concatenate (`"Remove \(name)"`, not
`"Remove " + name`), so a translator can move the name; and never build a
plural with `n == 1 ? "" : "s"` — write `"\(n) items"` and give it plural
variations.

**After adding, changing or removing a string**, run:

```bash
./Scripts/sync-strings.sh
```

It extracts every localized literal with the compiler, merges them into the
catalog (new keys added, unused ones removed, translations untouched) and
fills in the English. A new plural then needs its English `one` and `other`
forms; Xcode's catalog editor does this with **Vary by Plural**, or edit the
JSON beside an existing one such as `"%lld items"`.

**Adding a language** is adding entries — no code changes:

1. Open `Localizable.xcstrings` in Xcode (open `Package.swift`, then the file)
   and add the language with **+**, or add a `"<code>"` entry beside `"en"`
   under each string's `"localizations"` in the JSON.
2. Translate every string, including each plural's forms for that language
   (Xcode lists the categories the language needs — Russian has four).
3. Add the same language to `Resources/InfoPlist.xcstrings` (at least the
   camera prompt). This is what switches the app's language, not a side
   step: macOS chooses a nested bundle's language — and the strings live in
   one — only from the languages the main app bundle has `.lproj` folders
   for, and the main bundle's folders are compiled from this catalog. A
   language in `Localizable.xcstrings` alone ships and is never shown.
   `LocalizationTests` and `bundle.sh` both fail if you skip this.
4. Run `swift test`, then `./Scripts/bundle.sh` and check
   `dist/CreativeNotch.app/Contents/Resources/CreativeNotch_CreativeNotchCore.bundle/<code>.lproj`
   exists. The `StringCatalogCompiler` plugin finds the language in the
   catalog by itself.
5. Try it without changing your Mac's language:
   `open dist/CreativeNotch.app --args -AppleLanguages '(<code>)'`.

Translations need a native speaker's review. Machine translations are not
accepted: a confident wrong label is worse than an English one.

## Commits

Conventional prefixes: `feat:`, `fix:`, `test:`, `refactor:`, `chore:`,
`docs:`. Explain *why* in the body when it is not obvious; the code already
says what.

## Licence

Contributions are licensed under [GPL-3.0](LICENSE), same as the project.
