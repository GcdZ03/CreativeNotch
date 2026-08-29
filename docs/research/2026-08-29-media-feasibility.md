# Media module — feasibility findings

**Date:** 2026-08-29 · **Verified on:** macOS 26.6.2 (build 25G83)

Findings from a throwaway spike before building the media module. The
probes were deleted; this is the record.

Spec section 5.4 carried an explicit risk — *"the adapter does not
explicitly claim macOS 26 testing. The mechanism is confirmed present, but
this needs one runtime test before anything depends on it."* This spike
closes it.

## Summary

Both halves of spec 5.4 are confirmed, and they land on opposite sides of
the project's no-dependencies rule:

- **Transport controls are not gated.** `MRMediaRemoteSendCommand` works
  from an ad-hoc-signed binary. No helper, no subprocess, no third-party
  code. Buildable immediately.
- **Metadata is gated**, exactly as the spec assumed. It is unreachable
  without routing the read through a `com.apple.*` process.

That split is why the module was scoped to transport controls only, with
metadata deferred to its own spike, spec, and plan.

## The gate is on the calling process, not the framework

`mediaremoted` decides what to return by inspecting the **code-signing
identifier of the process asking**. Every MediaRemote symbol resolves for
anyone; what differs is what the daemon answers.

All nine probed symbols resolved under `dlopen`/`dlsym` regardless of
signing: `MRMediaRemoteSendCommand`,
`MRMediaRemoteGetNowPlayingInfo`,
`MRMediaRemoteGetNowPlayingApplicationIsPlaying`,
`MRMediaRemoteGetNowPlayingApplicationPID`,
`MRMediaRemoteRegisterForNowPlayingNotifications`,
`MRMediaRemoteGetNowPlayingClient`, and the
`kMRMediaRemoteNowPlayingInfo{Title,Artist,ArtworkData}` constants.

**Symbol resolution therefore proves nothing about access.** Any future
probe that stops there has measured the wrong thing.

## ⚠️ The trap: `swift file.swift` inherits an Apple identity

The first probe reported metadata as *ungated* — full track data, artwork
and all. That was false, and the reason is worth recording because the
next person will hit it.

Running a script with `swift file.swift` executes it inside the Swift
interpreter's process:

```
codesign -dv $(xcrun -f swift-frontend)
  Identifier=com.apple.swift-frontend
```

That is the **same loophole the perl helper relies on** — an Apple-signed
host process. The probe inherited the exemption it was written to detect.

**Any probe of this gate must be compiled and ad-hoc signed**, matching
what `Scripts/bundle.sh` ships:

```bash
swiftc main.swift -o probe && codesign -s - -f probe && ./probe
```

## Metadata — gated

Identical binary, same machine, seconds apart. The only variable is the
signature.

| Read | Ad-hoc signed | Via `com.apple.swift-frontend` |
|---|---|---|
| `MRMediaRemoteGetNowPlayingInfo` | 0 keys | **14 keys**, incl. `ArtworkData` |
| `MRMediaRemoteGetNowPlayingApplicationPID` | `0` | **`1287`** (the real pid) |

The now-playing *client identity* is gated too, not just the track fields.
An ad-hoc process cannot even learn which application is playing.

**Conclusion:** metadata requires the `com.apple.*` helper route. There is
no way around this from inside the app's own process, because the app
cannot be signed `com.apple.*` — those identifiers need Apple's private
keys.

## Transport controls — not gated

`MRMediaRemoteSendCommand` sent from an **ad-hoc-signed** binary, with
Spotify's AppleScript interface as independent ground truth:

| Command | Sent | Ground truth |
|---|---|---|
| `1` (pause), while playing | `true` | `playing` → **`paused`** |
| `2` (togglePlayPause), while paused | `true` | `paused` → **`playing`** |
| `2` (togglePlayPause), while playing | `true` | `playing` → **`paused`** |

**Not verified:** `4` (nextTrack) and `5` (previousTrack). Same function,
different constant, so they are expected to behave identically — but they
were not sent, because doing so moves the user's queue position. Treat
them as inferred rather than proven.

## ⚠️ `SendCommand`'s return value means "dispatched", not "obeyed"

It returned `true` in every case, **including several where nothing
happened**. It returned `true` when the command was routed to an
application that ignored it, and `true` for a nonsense command id (`99`).

Do not use the return value as a success signal. There is no reliable
in-process confirmation that a command took effect.

## ⚠️ The now-playing client is often not the app you expect

A long detour in this spike came from sending commands and checking
Spotify's state, while the actual now-playing client was **Google Chrome**
— a browser tab holding the media session. Commands were being routed
correctly; the ground truth was being read from the wrong application.

`MRMediaRemoteGetNowPlayingApplicationPID` (via a `com.apple.*` route)
identifies the real target. Any future manual test of this module should
confirm the target first, and be aware that a browser tab can silently
hold the media session.

## Environment premise for the deferred metadata module

Still true on this machine, and the foundation the helper route rests on:

```
codesign -dv /usr/bin/perl
  Identifier=com.apple.perl
  Platform identifier=26
```

⚠️ **Not verified by this spike:** that a compiled dylib *loaded into* the
perl process inherits the exemption. The whole helper approach assumes the
check is on the main executable's identity rather than on loaded code.
That assumption is the first thing the metadata spike must test — before
any decision about vendoring
[`ungive/mediaremote-adapter`](https://github.com/ungive/mediaremote-adapter)
versus writing an equivalent bridge.

## Recommendation

Build transport controls now: verified, ~50 lines, no dependency question
to answer. Give metadata its own spike, spec, and plan, starting from the
dylib-inheritance question above and then the third-party decision — the
only part of this application that needs a subprocess, and the only part
that puts the no-dependencies rule in play.
