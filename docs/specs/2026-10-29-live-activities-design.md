# Activities side by side — design

Status: built 2026-10-29, from a mock-up the owner sent ("Music keeps the
bar; every activity gets its own capsule beside it") and four decisions they
made from options:

| Question | Decision |
| --- | --- |
| Where, on a notch? | All right of the notch. The left ear is app menus; the cover was moved off it on 2026-10-17 for covering "Help". |
| How do they look? | One bar out of the notch with a tinted segment per activity, not floating capsules with gaps — so the drawn rect, the hit test and the hover rect stay one rectangle. |
| Hover and click? | Each segment its own: hover shows that activity's peek, a click opens its tab. |
| Which activities? | Music, the timer and stopwatch, downloads, and the camera/microphone/recording dot. |

## Before

One badge slot, by priority: recording, then another app's capture, then a
running countdown, then downloads, then playing music. A timer starting took
the album cover's place.

## Now

`NotchShape.badgeSlots` returns every active one, ordered from the notch out:

1. **Music** — nearest the notch, as before.
2. **Timer** — the soonest countdown.
3. **Stopwatch** — new: shown once started, until reset; a live
   `Text(timerInterval:)`, so nothing is scheduled for it.
4. **Downloads.**
5. **The privacy dot** — this app's recording, or another app's camera or
   microphone — at the far end, where macOS keeps its own.

The closed shape grows by their total width (`totalWidth`), so the three
rects still come from one `visibleRect`. `NotchShape.badgeSegments` says where
each one is; `segment(at:in:)` finds the one under a point.

**Look.** Alone, a badge draws exactly as before. Beside others, each sits on
its own rounded tint inside the black — the artwork's colour for music,
orange for timing, teal for downloads, none for the privacy dot — with its
content centred.

**Room.** The panel window is centred on the notch and never resizes, so the
segments can reach only half its width past the notch (`badgeRoom`; 215pt on
a 14" Mac at the default width). Past that a segment would be cut off and its
clicks would land nowhere. When they do not all fit, the least important go
first — the stopwatch, then downloads, music, the timer — and the privacy dot
never: it is the one thing here the user cannot see any other way.

**Hover.** The hover dwell reads the segment under the pointer before
anything moves. Music shows the player; the timer and the stopwatch show a new
one-row peek (`PeekContent.timer` / `.stopwatch`, `TimingPeekView`) with their
live time; downloads shows its row. Over the housing or the privacy dot, the
old order. Unasked peeks — a finished timer, power, Bluetooth, a finished
download — still come first wherever the pointer is. With open on hover, the
segment's tab opens instead.

**Click.** On the timer's segment, the Timer tab in timer mode; on the
stopwatch's, the Timer tab in stopwatch mode; on a recording's, the Camera
tab. Music, downloads and the capture dot open the panel as before.

## What it costs

Nothing new at rest. Every segment was already static or already ticking —
the countdown once a second as before, the stopwatch in the system's own
timer text. A stopwatch running with the panel closed is one more ticking
text than before.

## Trade-offs

- **Notchless displays.** "Keep clear of app menus" now reserves room for
  every activity at once (`pillClosedMaxWidth`, 248pt), so the idle pill sits
  further right than before when it is clearing long menus, up to the limit
  that leaves the open panel on screen.
- **A crowded menu bar.** Five segments reach about 200pt right of the notch;
  status items that far left would be covered while they show.
- **The stopwatch gives way first** when all five are active on a 14" Mac at
  the default panel width. Settings → Layout → Width → Wide gives the room
  back.
