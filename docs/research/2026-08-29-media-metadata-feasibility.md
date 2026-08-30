# Media metadata module — feasibility findings

**Date:** 2026-08-29 · **Verified on:** macOS 26.6.2 (build 25G83), perl 5.34.1

Findings from a throwaway spike before building the now-playing metadata
module. The probes were deleted; this is the record.

The transport-controls spike
([`2026-08-29-media-feasibility.md`](2026-08-29-media-feasibility.md)) left
one premise untested and named it as the first thing this spike must
answer:

> ⚠️ **Not verified by this spike:** that a compiled dylib *loaded into*
> the perl process inherits the exemption. The whole helper approach
> assumes the check is on the main executable's identity rather than on
> loaded code.

**It does. The approach works, end to end.**

## Summary

Every link in the chain is verified: SwiftPM builds the dylib, `bundle.sh`
ships it, the signature survives, the helper runs from inside the bundle,
and the app's own process can spawn it and read the stream.

The module is buildable with **no third-party code**.

## 1. A dylib loaded into perl inherits the exemption

The decisive differential. Identical ad-hoc-signed dylib, identical
exported function, same machine, seconds apart — only the host process
differs:

| Host process | now-playing pid | keys | artwork | title |
|---|---|---|---|---|
| ad-hoc-signed binary | `0` | `0` | — | — |
| `/usr/bin/perl` (`com.apple.perl`) | `31616` | **17** | **138 061 bytes** | "Beauty And A Beat" |

`mediaremoted` inspects the **host process's** identity, not the loaded
code. That is what makes the helper possible.

## 2. Library validation does not block it

A real risk that did not bite: `/usr/bin/perl` is a **hardened program**,
and hardened runtimes often refuse foreign code. An **ad-hoc-signed** dylib
loaded into it without complaint. No entitlement, no special signing, no
SIP change.

## 3. ⚠️ Three traps that each produce a wrong conclusion

**Relative dylib paths are rejected.** perl being hardened means
`dl_load_file("./lib.dylib")` fails with *"relative path not allowed in
hardened program"*. The helper must be passed an **absolute** path. Worth
an explicit check in the script, so this surfaces as an obvious error
rather than a confusing dyld one.

**Never do the work in a `__attribute__((constructor))`.** The first probe
did, and the MediaRemote callback **timed out** — a constructor runs during
`dlopen` while dyld holds the loader lock, and the XPC round-trip cannot
complete there. That result looks exactly like "the gate blocked us" and
would have killed the module wrongly. Export a function and call it *after*
load.

**perl is built threaded** (`usethreads=define`), so an installed XSUB is
called with `(pTHX_ CV*)`. A C function declared `void f(void *, void *)`
matches that convention and ignores both. Because it never touches perl's
stack, **no perl headers are needed to build the dylib** — which is what
keeps this a plain SwiftPM C target.

The loading sequence that works:

```perl
require DynaLoader;
my $lib = DynaLoader::dl_load_file($absolute_path, 0);
my $sym = DynaLoader::dl_find_symbol($lib, "mrstream");
DynaLoader::dl_install_xsub("main::mrstream", $sym);
mrstream();
```

## 4. Push notifications work — no polling required

`MRMediaRemoteRegisterForNowPlayingNotifications` plus an
`NSRunLoop` inside the perl host delivers callbacks. Observing
`kMRMediaRemoteNowPlayingInfoDidChangeNotification` and
`…ApplicationIsPlayingDidChangeNotification` was enough. The module
therefore respects the project's no-polling rule.

## 5. ⚠️ One user action produces about six notifications

Pressing play emitted six lines. Same shape as CoreAudio's duplicate
callbacks in the HUD module, and it needs the same answer: **coalesce**,
following `HUDCoalescer`.

## 6. ⚠️ Artwork flaps present/absent for the *same track*

Consecutive emissions for one unchanged song reported `artworkBytes` as:

```
138061 → 0 → 0 → 138061 → 138061 → 0 → 138061
```

This is the design's sharpest constraint, and it is invisible from a
one-shot read. **Artwork must be cached by track identity and never
cleared because a payload omits it.** A naïve implementation flickers the
album art several times per play/pause.

Related: `playing` lagged the real state in the first notifications after
a change, so playing state must be *read*, not inferred from notification
ordering or arrival time.

> **Correction, from task 6's implementation (2026-08-29).** This section
> originally named `kMRMediaRemoteNowPlayingInfoPlaybackRate` as that
> source of truth. It is not what shipped. Re-measured by hand against
> Spotify on macOS 26.6.2, the rate field was *inverted*: published as `1`
> while PAUSED and absent while PLAYING, agreeing with reality in 1 of 5
> samples. `bridge.m` therefore calls
> `MRMediaRemoteGetNowPlayingApplicationIsPlaying` and publishes its
> answer instead.
>
> ⚠️ **Observed, not proven.** One player, one machine, one OS build, one
> session, and no explanation for the inversion — it could be a Spotify
> bug, a macOS 26 change, or an artefact of how it was sampled. It has not
> been independently confirmed, and this document should not be read as
> establishing that the rate field is wrong in general. **Pending a live
> check** against a running player, ideally including a non-Spotify
> client. The original finding above (arrival order is untrustworthy)
> stands regardless; only the choice of field changed.

**`contentID` is not a stable track identity.** Also measured during task
6: it changed on *every play/pause of an unchanged track*. Anything keyed
by it — the artwork cache in particular — would miss on every pause. The
shipped `TrackIdentity` is title + artist + album.

## 7. Packaging — verified end to end

**SwiftPM builds the dylib.** A plain C target plus a dynamic library
product; `Foundation` via `linkerSettings`. Nothing links it — the helper
loads it at runtime.

```swift
.library(name: "CreativeNotchMediaBridge", type: .dynamic,
         targets: ["CreativeNotchMediaBridge"]),
.target(name: "CreativeNotchMediaBridge",
        linkerSettings: [.linkedFramework("Foundation")]),
```

**The dylib belongs in `Contents/Frameworks/`, not `Contents/Resources/`.**
`codesign` seals `Frameworks/` as nested *code*; a dylib in `Resources/` is
sealed as an opaque resource and loading it breaks validation.

**Sign inside out.** The nested dylib must be signed *before* the bundle
that contains it, or the outer signature seals unsigned code:

```bash
codesign -s "$IDENTITY" ... "$APP/Contents/Frameworks/libCreativeNotchMediaBridge.dylib"
codesign -s "$IDENTITY" ... "$APP"
```

`codesign --verify --deep --strict` then passes, with the dylib explicitly
`--validated`. (`spctl` still rejects the bundle — it is not notarised.
That is pre-existing and documented in the README, not a regression.)

**The app can spawn it.** A host signed as the app is
(`com.gcdz.creativenotch`) ran `/usr/bin/perl` with the bundled script and
dylib, and received the JSON line on `stdout` through a
`readabilityHandler` — the exact plumbing the real helper will use.

## Recommendation

Build it. Both the mechanism and the packaging are proven, and no
third-party code is required — the spike's own bridge is close to what the
real one needs.

The remaining work is engineering rather than discovery: a bridge with
real JSON escaping and clean shutdown (the spike's had a hardcoded
12-second runloop), subprocess supervision with backoff, coalescing,
artwork caching by identity, and the lifecycle that keeps the helper alive
only while media is actually on screen.
