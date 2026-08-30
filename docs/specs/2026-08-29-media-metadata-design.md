# Media metadata — Design

**Date:** 2026-08-29
**Status:** Approved design, pre-implementation
**Supersedes:** the metadata half of
[`2026-08-22-creativenotch-design.md`](2026-08-22-creativenotch-design.md)
section 5.4. The transport half of that section shipped unchanged.
**Research:** [`2026-08-29-media-metadata-feasibility.md`](../research/2026-08-29-media-metadata-feasibility.md)

## 1. Purpose

Show **what is playing** in the notch: title, artist, and artwork — in the
open panel's header, and as an ambient peek when the panel is closed.

Transport controls already shipped. They needed no helper, because sending
commands is not gated. Reading metadata is, which is why this is a separate
module with its own subprocess, and the only part of CreativeNotch that
runs a child process at all.

## 2. Why a helper process exists

`mediaremoted` decides whether to return now-playing data by inspecting the
**code-signing identifier of the calling process**, and allows only
`com.apple.*`. CreativeNotch is signed `com.gcdz.creativenotch` and gets
nothing — not the track fields, not even which application is playing.

The app cannot be signed `com.apple.*`; those identifiers require Apple's
private keys. So the read has to happen inside a process that already has
the exemption. `/usr/bin/perl` ships with macOS signed `com.apple.perl`.

The spike proved the mechanism completely: a dylib **loaded into** perl
inherits perl's exemption. Identical ad-hoc-signed dylib, same machine,
seconds apart — `0` keys in an ordinary host, **17 keys and 138 KB of
artwork** inside perl.

**We write the bridge ourselves.** No third-party code, so the project's
no-dependencies rule stands. The technique is the borrowed part, not the
implementation.

## 3. Architecture

```
/usr/bin/perl  (com.apple.perl — the exemption)
  └─ media-helper.pl  → dl_load_file → libCreativeNotchMediaBridge.dylib
       └─ MediaRemote push notifications
            └─ newline-delimited JSON on stdout
                 └─ Process readabilityHandler      [UI]
                      └─ LineBuffer                  [Core, pure]
                           └─ MediaPayload           [Core, pure]
                                └─ MediaCoalescer    [Core, pure]
                                     └─ TrackSnapshot + MediaArtworkCache
                                          └─ panel header + PeekArbiter
```

One direction only, like every other module. Everything carrying judgement
is pure and runs headlessly in CI; `CreativeNotchUI` owns the subprocess
and the views and nothing else.

## 4. Lifecycle

**The helper runs while `SystemActivity == .active`**, suspended on lock
and sleep. It is `SystemActivity`'s second consumer, after the clipboard
poller.

This deliberately departs from the original section 5.4, which spawned the
helper on panel open and killed it 30s after close. That rule cannot
support an ambient peek: the app would have to already know media had
started in order to decide to start listening. A peek that can never fire
is not a feature.

**Measured cost: 2.8 MB resident, 0.0% CPU** — against the app's own 75 MB.
The helper blocks on a runloop; it is a small resident footprint rather
than ongoing work, which is what makes this compatible with the project's
one architectural rule.

The supervisor guarantees no helper outlives the app, on quit or on crash.

## 5. Failure, and what degrades

Failure is ordinary here in a way it is not elsewhere — a subprocess
talking to a private framework.

| Failure | Behaviour |
|---|---|
| Helper exits unexpectedly | Restart with backoff: 1s → 2s → 4s → 8s → 16s, capped at 30s, 5 attempts |
| Five consecutive failures | **Degrade to controls-only.** Transport still works; the panel shows no header |
| Bundle paths missing (`swift run`, tests) | Module reports unavailable and never spawns |
| Malformed JSON line | Dropped and counted; never crashes the reader |
| No now-playing client | Empty state, not an error |

Degradation is silent-but-honest: the header is absent rather than showing
a spinner or a lie. Transport controls are unaffected by any of this,
because they need none of it.

## 6. Rules the spike forced

These are not preferences. Each comes from an observed behaviour, and
getting any of them wrong produces a visible bug.

**Artwork is cached by track identity and never cleared because a payload
omits it.** For a single unchanged song, consecutive emissions reported
artwork sizes of `138061 → 0 → 0 → 138061 → 138061 → 0 → 138061`. Clearing
on omission flickers the album art several times per play/pause. A one-shot
read cannot reveal this.

**One user action emits about six notifications.** Pressing play produced
six lines. They must be coalesced, following `HUDCoalescer`, which exists
for the identical problem in CoreAudio.

**Playing state comes from a direct query, not from `playbackRate`.**
`bridge.m` calls `MRMediaRemoteGetNowPlayingApplicationIsPlaying` and
publishes its answer as `playing`.

> ~~`playbackRate` is the source of truth for playing state, not
> notification arrival or ordering — the spike saw `playing` lag the real
> state in the first notifications after a change.~~
>
> **Superseded during task 6.** The half that still holds is *why* the rule
> existed: notification arrival and ordering are not trustworthy, so
> playing state must be read, never inferred. What did not survive is
> *what* to read. Task 6's by-hand verification found
> `kMRMediaRemoteNowPlayingInfoPlaybackRate` inverted for Spotify on macOS
> 26.6.2 — published as `1` while PAUSED and absent while PLAYING, and
> correct in only 1 of 5 samples. A rate that lies is worse than no rate:
> it would show a pause button over paused music.
>
> ⚠️ **Observed, not proven. Pending live confirmation.** This is one
> player, on one machine, on one OS build, measured in a single session,
> and the inversion has no explanation — it may be a Spotify bug, a macOS
> 26 change, or an artefact of how the spike sampled. The shipped code
> takes the safer of two unproven readings; it does not claim the rate
> field is universally wrong. Confirm against a live player (and at least
> one non-Spotify client) before treating this as settled, and record the
> result here.

**Track identity is title + artist + album, and never `contentID`.**
`TrackIdentity` is what the artwork cache is keyed by, so it must be stable
for as long as one song is one song. `contentID` looked like the obvious
key — it is an identifier, supplied by the player — but task 6 measured it
*changing on every play/pause of an unchanged track*. Keyed by that, the
cache would miss on every pause and the album art would vanish and reappear
with the transport, which is the very flicker the never-clear rule above
exists to prevent. The text triple is duller and stable. Its known
weakness — two different recordings sharing all three fields collide — is a
far rarer and far quieter failure than one that fires on every pause.

**Artwork does not belong in `TrackSnapshot`.** That type is `Equatable`
and lives inside `PeekArbiter`; carrying 138 KB of `Data` would make every
equality check compare image bytes. Identity and playback state live in
`TrackSnapshot`; artwork lives in a cache keyed by identity. Coalescing
then reduces to a cheap equality check.

## 7. Packaging

Verified end to end by the spike.

- `Package.swift` gains a **dynamic library product** over a C target.
  Nothing links it; the helper loads it at runtime.
- The dylib ships in **`Contents/Frameworks/`**, not `Resources/`.
  `codesign` seals `Frameworks/` as nested *code*; a dylib in `Resources/`
  is sealed as an opaque resource and loading it breaks validation.
- **Signing is inside out** — the dylib before the bundle, or the outer
  signature seals unsigned code.
- The helper is passed an **absolute** dylib path. `/usr/bin/perl` is a
  hardened program and rejects relative ones outright.

⚠️ `bundle.sh` therefore becomes load-bearing for *correctness*, not just
packaging: a wrong path or signing order breaks the module at runtime,
with a clean build.

## 8. Security

- **Never log payload contents.** Track titles are user data; the same rule
  the clipboard module follows. Counts and error kinds only.
- Artwork is held in memory, bounded by the cache's capacity, and dies with
  the process. Nothing this module reads is written to disk.
- The helper receives no user input; its arguments are paths the app
  computes from its own bundle.

## 9. Testing, and its limits

Every layer above the subprocess is pure and headless: payload decoding
against captured fixtures, line reassembly fed deliberately mid-line
chunks, the artwork cache including the never-clear rule, coalescing a real
captured six-notification burst down to one, and the backoff schedule.

**No test spawns the helper**, and the line source is injected.

⚠️ Two things consequently have **no automated coverage**: the ObjC bridge,
which the Swift suite cannot reach at all, and the real spawn path through
the signed bundle. Both are verified by a manual integration step that is
part of the definition of done — not optional polish. The media transport
module shipped a layout bug to `main` precisely because its manual step was
skipped.

## 10. Deliberately not built

- **Scrubbing, a position bar, volume, per-app routing.** All need write
  access or continuous position polling.
- **Reading the now-playing client's bundle identity** to show an app icon.
  Available through the helper, but not worth the surface in v1.
- **`contentID` as track identity.** Present in every payload and still
  decoded into `MediaPayload`, but deliberately not part of `TrackIdentity`
  — it was measured changing on every play/pause. See section 6.

### Reversed after the fact

- **Artwork on the peek** — listed here until 2026-08-30 as *"The peek is
  small, and the cache may legitimately be empty when it fires."*

  **Reversed on the user's direct request**, made after they saw the shipped
  panel; that request post-dates this spec. Recorded rather than deleted,
  because the reasoning that stood here was not wrong so much as answered:
  an empty cache draws **nothing** on the peek — `NowPlayingPeekView.cover`
  omits the tile entirely rather than reserving a placeholder — so "the
  cache may legitimately be empty" costs a peek nothing at all.

  What remains true is the second-order effect: artwork that lands *after*
  a peek is already on screen shifts its title sideways. That is accepted,
  not fixed — see the comment on `NowPlayingPeekView.cover`, which records
  the trade-off so the next reader does not "fix" it back.
