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
  "AirDrop All" in the shelf's title row, before "Clear", sends every file
  in one picker.

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

## Battery peek drops down (2026-10-17)

The battery peek put its icon in the left ear and its bar and percentage in
the right, with the camera housing between and no words, so it read as two
unrelated pieces. It now hangs below the notch like the music peek, as its
own presentation `.statusPeek`: one compact row (30pt body, 70pt ears, so
narrower than the other peeks; trimmed after seeing the first, larger cut) of icon, the words for
what happened (`PowerLabel.peekTitle`: "Plugged In", "On Battery", "Low
Battery", "Low Power Mode On/Off"), the bar and the percentage. "Plugged In"
rather than "Charging", because a Mac holding at 80% is plugged in without
charging. Low battery stays the one yellow thing. One peek replacing another
still uses the opening spring, even when the new one is smaller.

## Open on hover (2026-10-17)

A Settings switch, **off by default**, under a new "Hover" section. Off,
resting on the notch peeks and a click or a swipe opens the panel, as
before. On, resting for a chosen delay (0.2–1.0s in tenths, default 0.5s)
opens the panel instead of peeking, as Boring Notch and MewNotch offer. The
delay is longer than the peek's 300ms dwell because an accidental panel
costs more than an accidental peek.

- `HoverBehaviour` and `HoverBehaviourStore` (Core) hold and persist it
  (`hover.opensPanel`, `hover.openDelay`), caching nothing, like the
  shortcut's store. `AppState.onSetHoverBehaviour` saves and applies in one
  call; Settings writes only through it.
- `HoverTracker` asks for its dwell each time the pointer arrives, so a new
  delay applies on the next hover with nothing to re-sync.
- A hover-opened panel closes the way any open panel does: leave, and the
  400ms grace runs. A drag in flight is never interrupted, and with no tab
  visible the dwell falls back to the peek.
- The shortcut, a swipe and open-on-hover now share one `openPanel()`, which
  picks the first visible tab if the last one was switched off. The swipe
  used to open on the last tab unchecked.

## One notch while Spaces switch (2026-10-17)

The panel joins every Space and is `.stationary`, yet a desktop swipe still
carried a copy out with the old Space and in with the new one, so two
notches showed mid-swipe. The panel now lives in a Space of its own above
all the others (`NotchSpace`), out of the slide entirely — the approach
Boring Notch ships.

- It uses the window server's private CGS* functions in SkyLight
  (`CGSSpaceCreate`, `CGSSpaceSetAbsoluteLevel`, `CGSShowSpaces`,
  `CGSAddWindowsToSpaces`, and their inverses). They are free — part of
  macOS — but undocumented, like the MediaRemote this app already uses.
- Resolved with `dlsym`, not linked, so a macOS without them falls back to
  the old behaviour instead of failing to launch.
- Created only in `applicationDidFinishLaunching`, after the panel is on
  screen — never in `install`, which the tests use, so a test run creates
  no Spaces. Destroyed in `applicationWillTerminate`.
- **Measured on 2026-10-17:** the Space (569) exists while the app runs and
  is gone after a normal quit, and a relaunched app's Space (570) is gone
  after `kill -9` as well — the window server removes it with the process,
  so a crash leaves nothing behind.
- Still needs checking by eye: the swipe itself, full-screen apps (the
  notch stayed hidden over them before), Mission Control, and a second
  display.

## Follow-ups after v0.11.0 (2026-10-17)

- **Full-screen apps.** The fixed Space put the notch above full-screen apps,
  where it had always hidden. `FullScreenWatcher` now hides it whenever the
  current Space on its display is full-screen (type 4), checked on each Space
  change. See ARCHITECTURE, Fullscreen.
- **The cover moves back to the right.** On screen, the leading ear covered
  the end of app menus ("Help" cut to "Hel"). Cover and bars now share one
  68pt trailing ear — the same menu bar the two 34pt ears took.
  *Reverses* "Cover in a leading ear" above.
- **Wide artwork.** Video thumbnails were cropped to a square. A cover tile
  is now `coverWidth(height:aspect:)`: square for square art, up to 1.5×
  wide for wide art, in the closed notch and the music peek.
- **Render tests compare with a tolerance.** Exact-byte comparison of two
  renders failed about one run in ten: `ImageRenderer` sometimes
  anti-aliases a curve one step (1/255) differently under a parallel run.
  `Render.same` / `Render.differs` allow 2/255 per channel.

## The panel shows progress; open on hover peeks first (2026-10-18)

- **Progress in the panel.** The music column now shows the same
  `PlaybackProgressView` as the peek. Before, the open panel never showed
  where playback was, and with open on hover on, the peek — the bar's only
  home — was skipped entirely.
- **Peek first, then open — tried and reverted.** Open on hover was made to
  peek at 300ms and open the panel after the delay, to keep the peek's
  progress bar and sideways skip. On screen it read as the notch expanding
  twice by itself, without the user asking for the second. Reverted the same
  day: open on hover goes straight to the panel again, one expansion. With
  the progress bar now in the panel, only the peek's sideways skip is lost
  (the panel's skip buttons remain).

## The open panel stopped closing under the user (2026-10-18)

Reported: with open on hover, opening the panel and then scrolling down to
reach the music controls closed it at once. Two causes, both fixed:

- **Swipe up to close was ordinary scrolling.** With natural scrolling,
  scrolling *down* is the fingers moving *up* — the close gesture exactly —
  and the music column is no scroll view to claim it. A push up now closes
  the panel only when it starts on the top strip, level with the notch;
  elsewhere the whole swipe is passed on as a scroll.
- **The pointer area lagged the panel.** A pointer moving into the newly
  drawn panel before the growth delay left the old region and started the
  400ms close, which nothing cancelled. When the region catches up, a
  pointer inside it now cancels the pending close.

## Seeking from the progress bar (2026-10-18)

Clicking or dragging on the progress bar — in the music peek and in the
panel — jumps to that point in the track. The bar and both times follow the
finger while dragging; letting go sends `MRMediaRemoteSetElapsedTime` through
`MediaRemoteBridge.seek`, the same private framework and gate as the
transport buttons. The bar shows the new position at once and yields to the
player's next published reading. No seek function on this macOS, or no
working transport controls, leaves the bar display-only.

On screen, the first cut of seeking sometimes showed the bar **full** right
after a drag, with minutes left on the clock. Two causes: the drag cleared
its "still dragging" flag only after restarting the bar, so the restart
skipped itself; and the bar restarted by setting its start and animating to
the end in the same instant, which SwiftUI merged. The fill is now rebuilt
at its start on every restart (a new identity per restart) and slides on
from there.
