# Rich music peek and notch motion — design

Status: approved 2026-10-15. Chosen from three variants in a throwaway
SwiftUI prototype (branch `prototype/music-states`, variant C).

## Why

The music states read as three unrelated designs. The closed notch shows a
cover on the right only, the peek is a wide one-line bar with the title far
left and the artist far right, and the open panel's cover appears from
nowhere. Nothing moves between them: every state change is one spring, and
content arrives at full opacity while the shape is still small.

## What changes

### Closed, while music plays

- Cover in a **leading** ear, still equalizer bars in the **trailing** ear.
  Both ears are `NotchGeometry.nowPlayingBadgeWidth` (34pt).
- The bars are **static** when closed. They animate only in the peek. The
  closed badge is on screen for as long as music plays, and the app exists
  to not redraw continuously for that long. That rule from the original
  badge design still holds; only the bars' *shape* is new.
- Bars take their colour from the artwork (`ArtworkTint`), lifted so a dark
  cover still gives bars that show on black.

**Reversed after the fact.** The original badge was trailing-only so the
left ear stayed clear for app menus. That is given up while music plays:
34pt on the left, chosen for the symmetric look (2026-10-15). Timer,
recording and capture badges are unchanged and stay trailing-only.

### The music peek (hover while something is playing or paused)

A new presentation, `.mediaPeek`, distinct from the one-line `.peek` that
power and timer peeks keep. It grows **down** from the notch: the top band
keeps animated bars in the trailing ear, and the body below holds a 48pt
cover, title over artist, and a play/pause button whose icon follows the
snapshot's `isPlaying`.

Width matches the other peeks (`peekEarWidth` either side of the anchor).
The body is `NotchGeometry.mediaPeekBodyHeight` tall. On a pill Mac it is
the same rect, centred and hanging from the pill's top edge.

**Progress bar (follow-up, same day).** Below the player row: a thin bar and
elapsed / remaining times. The body grew to 100pt to hold it, and keeps that
height without a position, centring the row instead.

- **Source.** The bridge sends `elapsed`, `duration` and `elapsedAt`
  (MediaRemote's `ElapsedTime`, `Duration` and `Timestamp`). MediaRemote
  does not tick `elapsed`: it republishes it with a fresh timestamp on play,
  pause and seek. Measured against Spotify on 2026-10-15: elapsed + (now −
  timestamp) matched `player position` to within the gap between reads, and
  duration matched exactly. Whether time is passing comes from the queried
  `isPlaying`, never the playback rate.
- **Model.** `PlaybackPosition` stores the reading and its anchor, and every
  question takes `now`. It rides on `TrackSnapshot`, so a seek republishes
  through the existing coalescer. No duration (live streams) means no bar.
- **No clock in the view.** The bar is set to now and given one linear
  animation to the end of the track, restarted only when the position or
  play state changes. The times are `Text(timerInterval:)`. Paused, both are
  plain values. Shown in the peek only; the panel is unchanged.

### Motion

- **One cover.** The closed badge's cover, the peek's cover and the panel's
  cover share a `matchedGeometryEffect`, so the cover slides between states
  instead of popping.
- **Direction-aware springs.** Growing uses a slightly bouncy spring,
  shrinking a quicker critically-damped one (`NotchMotion`). The growth lag
  follows the opening spring's response.
- **Content arrives after the shape.** Inserted state content blurs in;
  removed content fades out fast.
- **Hover reacts at once.** The closed notch grows a few points the moment
  the cursor enters, before the 300ms dwell. This is drawn only: the
  accepted hit/hover region does not grow, which keeps the invariant that
  the accepted region is never larger than what is drawn.
- Track changes cross-fade the title and artist text.

**Reversed after the fact.** The UI redesign spec (§5.11, §9) allowed no
repeating animation anywhere, enforced by
`noStockControlStyleOrRepeatingAnimationSurvivesInTheUI`. The peek's
moving bars are the one exception, chosen on 2026-10-15: they loop only
while the peek is on screen, which is only while the cursor is over it.
The guard exempts `EqualizerBarsView.swift` by name and nothing else, and
`TimelineView` stays banned there too.

## Invariants kept

- The drawn rect, the hit-test region and the hover tracking rect still all
  come from `NotchShape.visibleRect`. The leading badge width goes through
  that function the same way the trailing one does.
- The badge slot is still one decision (`NotchShape.badgeSlot`); the
  leading width is a property of the slot, not a second rule.

## Polish (2026-10-17)

From the second competitor round: things Boring Notch, NotchNook and
Alcove have that fit this project's rules.

- **Reduce Motion.** With the system setting on, both springs become one
  0.2s ease, content fades rather than blurs in, the cover cross-fades
  rather than slides, hover does not grow the notch, and the peek's bars
  stand still. The progress bar keeps running: its movement is the
  information.
- **Rolling digits.** The timer (badge and tab) and the battery percentage
  (header, tab and peek) roll to each new value with `numericText`, scoped
  to the value so it runs only when the number changes. A fade under
  Reduce Motion.
- **Haptics.** One light tap (`.levelChange`, at `.drawCompleted`) as the
  panel opens; none for tab switches, peeks or closing. Felt only on a
  Force Touch trackpad, and macOS drops it if haptics are off.
- **AirDrop from the shelf.** A button on each tile, on hover, through
  `NSSharingService(named: .sendViaAirDrop)`: no permission, nothing
  running until it is asked. Files no longer on disk are left out.

## Trackpad swipes (2026-10-17)

Two-finger swipes on the notch, as Alcove and Boring Notch offer:

- **Down** on the closed notch or a peek: the shape follows the fingers,
  growing a quarter of the way toward the panel at the threshold (36pt of
  finger travel) and rubber-banding past it. Let go past the threshold and
  it springs open on the last tab; short of it, it springs back.
- **Up** on the open panel: it shrinks a little with the fingers, and
  closes past the threshold.
- **Sideways** on the music peek only (60pt): left is the next track, right
  the previous, through the same media-command route as the buttons and
  only when those controls are available. Not on the open panel, whose
  shelf scrolls sideways.

`NotchSwipe` (Core) holds every rule, in finger space so the scroll
direction setting does not matter, and locks to one axis per swipe. Scroll
events already reach the hosting view while the cursor is over the drawn
shape, so there is **no global monitor**; an event the swipe does not use
goes on as an ordinary scroll, so lists in the panel still scroll. Mouse
wheels and momentum are ignored. The pull is drawn only, like the hover
growth. One haptic at the threshold; the panel it opens does not tap again.
