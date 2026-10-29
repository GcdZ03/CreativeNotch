# Synced lyrics — design

Status: built 2026-10-29. The roadmap's "ideas considered" entry, after the
second competitor round and a GitHub-issue survey of Boring Notch and Atoll
(six separate lyrics requests in Boring Notch alone).

## Why

The playback position already exists (spec 2026-10-15), so the hard half of
syncing is done. What stopped the roadmap was not cost but privacy: lyrics
come from a service, and asking it means sending the track's title and
artist off the machine.

## The one rule, applied

Lyrics are the timer's shape, not the visualiser's:

- **One request per track**, never a stream. Nothing is fetched while the
  module is off, while the screen is locked or asleep, or for a track that
  is paused and not being looked at.
- **One one-shot per line.** A line's start time is a known instant
  (`PlaybackPosition` extrapolates from the last reading), so the controller
  sleeps until the next line and redraws once. A typical song changes line
  every 3–5 seconds: about fifteen redraws a minute, fewer than the timer
  badge's one a second. No `TimelineView`, no polling, no clock in the view.
- **Nothing scheduled while nobody can see it.** The one-shot exists only
  while the music is playing, the system is `.active`, and a surface showing
  lyrics is on screen. A seek or a pause republishes the position, and the
  one-shot is rescheduled from it.

Boring Notch re-renders its lyrics every 0.25s in a `TimelineView`; Atoll
moved from 300ms polling to sleeping until the next timestamp. This is
Atoll's shape.

## The service

[LRCLIB](https://lrclib.net): free, no key, community-maintained, returns
LRC timestamps. Measured 2026-10-29:

- `GET /api/get?track_name&artist_name&album_name&duration` matches the
  duration within about 2s and **requires the album to match** — a wrong
  album is a 404, an empty one is ignored. So the lookup asks with the album,
  and on a 404 asks once more without it. At most two requests per track.
- `/api/get-cached` needs an exact album and second; not used.
- The service answers `503 ServerOverloaded` under load, sometimes several
  times in a row. A 503 or a network failure is retried **once**, after a
  few seconds, and then the track is left without lyrics until it is played
  again — never a retry loop.
- Requests carry a `User-Agent` naming the app and its repository, as the
  service asks of clients.

What is sent: title, artist, album and duration in seconds. Nothing else —
no identifier, no cookie (an ephemeral session), and the response is not
written to disk.

## What is kept

An in-memory cache of the last 50 lookups, including "no lyrics" answers, so
replaying a track or skipping back never asks again. Gone on quit, like the
clipboard. Not on disk: a lyrics file per track played would be a listening
history, and this app keeps none.

## Where lyrics show

1. **Under the closed notch** — a strip, while something is playing and has
   synced lyrics. The closed shape grows down by one line (22pt) and the
   current line sits in it, cross-fading to the next. An empty LRC line (an
   instrumental break) shows a note glyph rather than collapsing the strip:
   a strip that shrank and grew on every break would be the shape moving
   by itself, which the open-on-hover revert (2026-10-18) already showed
   reads as a bug. A setting, on by default once lyrics are on.
2. **In the music peek** — the same line under the progress bar.
3. **In the panel's music column** — the current line and the next, dimmer.

The strip is part of the closed shape, so the drawn rect, the hit test and
the hover tracking rect all grow by it through `NotchShape.visibleRect`, as a
badge does. Hovering it peeks, like the rest of the notch.

## The module

`ModuleID.lyrics`, **off until switched on**, for the same reason the
calendar is: switching it on is what starts talking to a third party, so it
belongs to a click with the reason beside it. The Settings row names the
service and says what is sent.

Switching it off cancels any request in flight, drops the one-shot, clears
the cache and withdraws the strip.

## Accepted trade-offs

- **Matching is by name.** A live cut, a radio edit or a remaster with a
  different length gets no lyrics or the studio cut's timing. Duration
  within 2s is the guard.
- **Browser video** (YouTube) usually reports the channel as the artist and
  a title like "Song (Official Video)", so it rarely matches. Not cleaned up:
  guessing would show wrong lyrics, which is worse than none.
- **Line-level, not word-level.** LRCLIB has some word timing; a sweep
  across the line would be an animation for the whole song.
- **Sync is as good as the position.** MediaRemote republishes on play,
  pause and seek only; a player that buffers without saying so drifts until
  the next event.
