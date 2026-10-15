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

A progress bar is **out of scope** and comes in a follow-up PR: it needs elapsed
time and duration from the media bridge, and MediaRemote's playback rate
has already proved unreliable for Spotify, so those fields need checking
against real playback first.

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
