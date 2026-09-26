# Development

## The three loops

Most work never needs the app running.

### 1. Logic — `swift test` (~1 second)

```bash
swift test                              # all 974
swift test --filter NotchGeometryTests  # one suite
```

The whole suite is headless: no window server, no signing, no bundle. If a
change can be verified here, verify it here.

### 2. See it on screen — `./Scripts/dev.sh` (~6 seconds)

```bash
./Scripts/dev.sh              # debug build, relaunch
./Scripts/dev.sh --release    # release build
./Scripts/dev.sh --fresh      # also clear stored preferences, for first-run behaviour
./Scripts/dev.sh --logs       # stream the app's log output
```

It stops any running instance, rebuilds, signs, and relaunches. You never
need to install to `/Applications` while developing — run it from `dist/`.

### 3. Fresh-install behaviour

`--fresh` clears the `com.gcdz.creativenotch` defaults domain, so every
module returns to its shipped default and the panel forgets its last tab.

## Set up signing first — or lose every TCC grant on each build

Do this once, before working on any module that asks for a permission (the
camera does):

```bash
./Scripts/setup-signing.sh
```

That is the whole setup. `bundle.sh` picks the identity up from your
keychain by name, prints which one it used on every build, and warns
loudly if it ever falls back to ad-hoc. Set `CODESIGN_IDENTITY` only to
override it with a different certificate.

> Earlier versions required you to `export CODESIGN_IDENTITY` yourself,
> and silently signed ad-hoc when you forgot — revoking whatever had been
> granted, with nothing on screen to say so. A build in a fresh shell
> looked completely normal and the permission simply stopped holding.

**Why.** An ad-hoc signature's designated requirement is the hash of the
code itself:

```
# designated => cdhash H"bf2759a7674105c875b1207d4a9389135a30cc74"
```

TCC pins a grant to that requirement. Change one line of Swift, the hash
changes, the requirement stops matching, and macOS silently revokes the
grant. You would re-authorise in System Settings on every build.

Signing with a stable certificate makes the requirement identity-based
instead, so the grant survives rebuilds.

The certificate is free, local, and self-signed. It is **not** an Apple
Developer ID: it cannot notarise, and apps signed with it are still
Gatekeeper-blocked when downloaded through a browser. It exists purely to
give TCC something stable to pin to.

The script will prompt for your login keychain password when it adds the
certificate to your trust settings — that prompt is macOS, not the script.
If it fails, open Keychain Access, find the certificate, and set its trust
for **Code Signing** to **Always Trust**.

Releases are always ad-hoc signed regardless, because a personal
certificate would mean nothing to anyone else.

## The one check that needs a human

Launch at login is the only module whose central claim cannot be tested
headlessly. Everything measurable about it is about the *record* macOS keeps,
never about a launch — and `SMAppService` reporting `enabled` is not evidence,
because a record survives deleting the app entirely. The switch can therefore
read on over nothing, which is the one failure the module exists to prevent.

`Scripts/verify-login-item.sh` captures the state before you log out and
checks it after you log back in, so the comparison is recorded rather than
remembered:

```bash
CODESIGN_IDENTITY=- ./Scripts/bundle.sh release   # ad-hoc, like a release
cp -R dist/CreativeNotch.app /Applications/
open /Applications/CreativeNotch.app              # then flip the switch in Settings

./Scripts/verify-login-item.sh arm                # before logging out
# log out, log back in, TOUCH NOTHING
./Scripts/verify-login-item.sh check              # twice, over two cycles
```

Sign it **ad-hoc**. Releases are, and whether macOS starts an ad-hoc,
non-notarised app at login is the entire question; a pass with the local
certificate would answer a case no user has. The installer cannot stand in
either — it fetches the latest release, which may predate the module.

The script never launches the app, never registers anything, and never calls
`SMAppService`. Any of those would be the thing under test doing itself a
favour.

**Last run 2026-09-19, macOS 26.6.2, Apple Silicon: passed, both cycles.**
Re-run it when the signing identity changes, when the install location
changes, or on a new major macOS — those are the variables it is measuring,
and a pass on one of them is not a pass on the next.

## Debugging in Xcode

Open `Package.swift` directly — there is no `.xcodeproj` to maintain, and
generating one would be a file to keep in sync for no benefit.

Note that `swift run` produces a **bare executable with no bundle**, so it
has no `Info.plist`, no `LSUIElement`, and no stable identity for TCC —
TCC grants will not stick and the app will show a Dock icon. Always go
through `./Scripts/dev.sh` and launch the `.app`.

To debug: launch via `dev.sh`, then **Debug → Attach to Process** in Xcode.

## Project layout

```
Sources/
  CreativeNotchCore/          pure logic. Never imports AppKit or SwiftUI.
  CreativeNotchUI/            AppKit + SwiftUI. Everything with behaviour.
  CreativeNotchMediaBridge/   Objective-C. Loaded into the perl helper, not
                              into this app -- see ARCHITECTURE.md on why a
                              subprocess exists at all.
  CreativeNotch/              18-line executable.
Resources/
  media-helper.pl             what the helper runs. Ships inside the bundle.
Tests/
  CreativeNotchCoreTests/     463 tests
  CreativeNotchUITests/       607 tests
Scripts/
  bundle.sh            build + sign -> dist/CreativeNotch.app
  dev.sh               the loop above
  setup-signing.sh     one-time stable signing identity
  install.sh           the public curl installer
  verify-login-item.sh the one check that needs a human -- see below
```

New code belongs in `CreativeNotchCore` unless it genuinely needs AppKit or
SwiftUI. When something in `CreativeNotchUI` turns out to be worth testing,
the usual answer is to move its logic down into Core rather than reach for a
mock.

Nothing new should accumulate in `Sources/CreativeNotch/` — that target is
not reachable by tests, which is precisely why `AppDelegate` was moved out
of it.

## Writing tests

A test is expected to **fail when its code is broken**, and that gets
verified rather than assumed.

This is not a hypothetical. Three tests shipped during the foundation build
that passed with their implementation deleted. The media metadata module
added **nine more** before they were caught — including one written by the
reviewer who had been insisting everyone else run mutations.

Every single one was found by someone running the mutation and reporting
"this didn't fail", never by reading the test. Reading is not a substitute:
a decorative test reads exactly like a real one.

So, for every test you add:

1. Introduce the bug the test targets, in the real source.
2. Run the suite. Confirm your test **fails**.
3. Revert.
4. Confirm it passes and `git status --short` is clean.

If you cannot make a test fail, it is not protecting anything — either
rewrite it or rename it to describe what it actually checks.

## Never sleep in a test

There is no `Task.sleep` anywhere in the suite, and there should not be.

Timing tests originally slept past a delay and asserted afterwards. They
passed locally every time and **failed seven at once on CI**, because Swift
Testing runs suites in parallel and a loaded runner does not schedule a
pending `Task { @MainActor … }` inside the window the test guessed at.

Await the real work instead:

```swift
delegate.state.transition(to: .open(.shelf))
#expect(delegate.acceptedRect == closedRect)   // not yet
await delegate.growthTask?.value               // deterministic
#expect(delegate.acceptedRect == openRect)
```

`AppDelegate.growthTask`, `AppDelegate.graceTask` and
`HoverTracker.dwellTask` are exposed for exactly this.

Sleeping for *less* than a delay is the same trap in reverse — "wait 150ms,
which is inside the 300ms dwell" overshoots on a slow runner and fires the
thing you were proving had not fired. Hold the task and await it instead.

## Things that will bite you

**Coordinate spaces.** `NSHostingView.isFlipped == true`; `NotchShape`
rectangles are bottom-left origin. This mismatch shipped a Critical bug once
that passed all tests, looked perfect on screen, and passed the manual check
written to catch it. See `ARCHITECTURE.md` for the full account.

**The state funnel.** `AppState.state` is `private(set)`; the only writer is
`transition(to:)`. Keep it that way — the tracking rect is derived from it,
and a direct write desynchronises them silently.

**Register on `AppState.observe`, never replace.** It is a list, and the
delegate's tracking-rect sync and outside-click monitor already live on it.

**`assumeIsolated` requires `queue: .main`.** It is a runtime assertion that
crashes when the assumption is false. If you add a notification observer,
pass `.main` or do not use it.

**Shelf tests write to real temporary directories**, not a fake
`FileManager` — name collisions, extensions and deletion are exactly where a
fake diverges from the real thing, and those are the cases that can lose a
file. `ShelfStore` takes `now` as a parameter, like `PeekArbiter`, so the
7-day purge is testable without waiting a week.

**`MediaCoalescer` compares values rather than reading a clock**, and
`PeekArbiter` takes `now` as a parameter. Between them the whole peek
decision path is testable without hardware or a sleep.

**`removeItem` must never appear in the shelf module.** Removal is
`trashItem`, always.

**Never call a permission-requesting API from a test** — it pops a
real system dialog. `AXIsProcessTrusted()` is a safe read.

**A media helper verified from a terminal proves nothing.** A
terminal-launched process inherits a valid stdin; the packaged `.app` does
not provide one unless the code sets it. That difference shipped a Critical
bug — the helper died in milliseconds in the bundle while every manual check
passed. Verify against `dist/CreativeNotch.app`, and confirm the helper's
fd 0 is a pipe:

```bash
lsof -p "$(pgrep -P "$(pgrep -f 'CreativeNotch.app/Contents/MacOS')")" | head
```

**The same applies to the code-signing gate.** Running a `.swift` file
directly makes it a child of `com.apple.swift-frontend` and it inherits
Apple's identity, so a probe of a `com.apple.*`-gated API will report it
open when it is not. Compile and ad-hoc sign before believing the result.

**`MediaPayload`'s CodingKeys are a wire contract with `bridge.m`.** They
have to match the emitted JSON keys exactly. A mismatch does not throw — the
field decodes as absent and the UI shows empty strings, which looks like "no
music is playing" rather than like a bug.

**Never spawn a real helper in a test, and never `Task.sleep` to wait for
one.** The whole media module is tested against injected pipes and injected
clocks, the same way `PeekArbiter` takes time as a
parameter.

**Do not drive a real media player from a test or a script.** An agent doing
exactly this wedged the author's Spotify badly enough that every programmatic
recovery failed and it needed a manual click.

## Releasing

Releases are cut by tag; CI builds, verifies, packages, and publishes.

```bash
# 1. bump the version -- there is only one place now
#    Sources/CreativeNotchCore/Version.swift   CoreInfo.version
#    (Info.plist carries a __VERSION__ placeholder that bundle.sh fills in)

# 2. commit, tag, push
git commit -am "Release v0.2.0"
git tag v0.2.0
git push origin main --tags
```

The workflow runs the tests, builds, asserts the signature is ad-hoc with no
team identifier, tars the app with a SHA-256 checksum, and attaches both to
a GitHub release with install instructions.

`CoreInfo.version` is the single source; `Scripts/bundle.sh` substitutes it
into the bundled `Info.plist` at build time, and CI fails the release if the
tag disagrees with it.
