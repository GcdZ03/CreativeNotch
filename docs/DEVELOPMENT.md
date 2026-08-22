# Development

## The three loops

Most work never needs the app running.

### 1. Logic — `swift test` (~1 second)

```bash
swift test                              # all 70
swift test --filter NotchGeometryTests  # one suite
```

The whole suite is headless: no window server, no signing, no bundle. If a
change can be verified here, verify it here.

### 2. See it on screen — `./Scripts/dev.sh` (~6 seconds)

```bash
./Scripts/dev.sh              # debug build, relaunch
./Scripts/dev.sh --release    # release build
./Scripts/dev.sh --fresh      # also reset onboarding, replaying first-run UI
./Scripts/dev.sh --logs       # stream the app's log output
```

It stops any running instance, rebuilds, signs, and relaunches. You never
need to install to `/Applications` while developing — run it from `dist/`.

### 3. Fresh-install behaviour

`--fresh` clears the `com.gcdz.creativenotch` defaults domain, so onboarding
and the Accessibility prompt replay from scratch.

## Set up signing first — or lose Accessibility on every build

Do this once, before working on any module that needs Accessibility (the
HUD and the file shelf both will):

```bash
./Scripts/setup-signing.sh
export CODESIGN_IDENTITY="CreativeNotch Dev"   # add to your shell profile
```

**Why.** An ad-hoc signature's designated requirement is the hash of the
code itself:

```
# designated => cdhash H"bf2759a7674105c875b1207d4a9389135a30cc74"
```

TCC pins your Accessibility grant to that requirement. Change one line of
Swift, the hash changes, the requirement stops matching, and macOS silently
revokes the grant. You would re-authorise in System Settings on every build.

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

## Debugging in Xcode

Open `Package.swift` directly — there is no `.xcodeproj` to maintain, and
generating one would be a file to keep in sync for no benefit.

Note that `swift run` produces a **bare executable with no bundle**, so it
has no `Info.plist`, no `LSUIElement`, and no stable identity for TCC —
Accessibility will not stick and the app will show a Dock icon. Always go
through `./Scripts/dev.sh` and launch the `.app`.

To debug: launch via `dev.sh`, then **Debug → Attach to Process** in Xcode.

## Project layout

```
Sources/
  CreativeNotchCore/   pure logic. Never imports AppKit or SwiftUI.
  CreativeNotchUI/     AppKit + SwiftUI. Everything with behaviour.
  CreativeNotch/       18-line executable.
Tests/
  CreativeNotchCoreTests/   35 tests
  CreativeNotchUITests/     35 tests
Scripts/
  bundle.sh            build + sign -> dist/CreativeNotch.app
  dev.sh               the loop above
  setup-signing.sh     one-time stable signing identity
  install.sh           the public curl installer
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

During the foundation build, three tests shipped that passed with their
implementation deleted. Every one was caught by a reviewer mutating the
source, not by reading it. Two more were only shown adequate after a
reviewer proved they covered half of the bug they claimed to cover.

So, for every test you add:

1. Introduce the bug the test targets, in the real source.
2. Run the suite. Confirm your test **fails**.
3. Revert.
4. Confirm it passes and `git status --short` is clean.

If you cannot make a test fail, it is not protecting anything — either
rewrite it or rename it to describe what it actually checks.

## Things that will bite you

**Coordinate spaces.** `NSHostingView.isFlipped == true`; `NotchShape`
rectangles are bottom-left origin. This mismatch shipped a Critical bug once
that passed all tests, looked perfect on screen, and passed the manual check
written to catch it. See `ARCHITECTURE.md` for the full account.

**The state funnel.** `AppState.state` is `private(set)`; the only writer is
`transition(to:)`. Keep it that way — the tracking rect is derived from it,
and a direct write desynchronises them silently.

**`onTransition` is a single closure.** The first module to assign its own
observer clobbers the delegate's tracking-rect sync. Make it an observer
list before that happens — follow-up **F2**.

**`assumeIsolated` requires `queue: .main`.** It is a runtime assertion that
crashes when the assumption is false. If you add a notification observer,
pass `.main` or do not use it.

**Never call `Permissions.requestAccessibility()` from a test** — it pops a
real system dialog. `AXIsProcessTrusted()` is a safe read.

## Releasing

Releases are cut by tag; CI builds, verifies, packages, and publishes.

```bash
# 1. bump BOTH version strings — CI fails the release if they disagree
#    Resources/Info.plist          CFBundleShortVersionString
#    Sources/CreativeNotchCore/Version.swift   CoreInfo.version

# 2. commit, tag, push
git commit -am "Release v0.2.0"
git tag v0.2.0
git push origin main --tags
```

The workflow runs the tests, builds, asserts the signature is ad-hoc with no
team identifier, tars the app with a SHA-256 checksum, and attaches both to
a GitHub release with install instructions.

Keeping two version strings in sync by hand is a wart (follow-up **F9**);
the CI check exists so it fails loudly rather than drifting quietly.
