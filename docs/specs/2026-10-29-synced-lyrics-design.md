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

- `GET /api/get?track_name&artist_name&duration` matches the duration within
  about 2s. **The album is not sent.** With it, a wrong album is a 404; and on
  the afternoon of 2026-10-29 every request carrying the right album answered
  `503`, three tries running, while the same request without it answered
  `200` every time. The length already tells a radio edit from an album cut.
  So one request per track. *Changed while building:* the first cut asked with
  the album and then without it, and was caught by this on the real app.
- `/api/get-cached` needs an exact album and second; not used.
- The service answers `503 ServerOverloaded` under load, sometimes several
  times in a row. A 503 or a network failure is retried **once**, after a
  few seconds, and then the track is left without lyrics until it is played
  again — never a retry loop.
- Requests carry a `User-Agent` naming the app and its repository, as the
  service asks of clients.

What is sent: title, artist and duration in seconds. Nothing else —
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
   current line sits in it, swapped for the next with no fade: on the real
   app a 0.3s cross-fade per line cost 1.42% of a core against 0.19% for the
   plain swap (see "Measured"). An empty LRC line (an
   instrumental break) shows a note glyph rather than collapsing the strip:
   a strip that shrank and grew on every break would be the shape moving
   by itself, which the open-on-hover revert (2026-10-18) already showed
   reads as a bug. Paused, the strip goes with the badge. **Notch only:** a
   pill sits inside the menu bar, and one rect grown down by a line would be
   that wide at the menu bar's height too, over the app menus.
2. **In the music peek** — the same line under the progress bar; the body
   grows by the row. On a pill too.
3. **In the panel's music column** — the current line in the artist's place,
   shown paused too. *Changed while building:* the first cut put the current
   and next lines under the progress bar, and the text-size render check
   caught the transport controls running off the bottom of the panel at every
   size. The artist is still in the peek.

There is no separate switch for the strip: the module's switch is the one
decision. A "lyrics in the panel only" option is a possible follow-up.

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

## Measured (2026-10-29, real app)

A release build on a 14" MacBook Pro (macOS 26), with a silent stand-in
player publishing Now Playing for a track LRCLIB has, so nothing played out
loud. App CPU time over 100s of playback, the app warm:

| | App CPU | Wakeups / 3s |
| --- | --- | --- |
| Lyrics off | 0.04% | 0 |
| Lyrics on, 0.3s cross-fade per line | 1.42% | ~180 |
| Lyrics on, line swapped (shipped) | 0.19% | 8 |

The strip showed the note glyph before the first line and each line on its
timestamp (screenshots checked at 14s, 20s, 24s and 33s into the song).

