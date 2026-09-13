# UI redesign — design

The open panel, its five tabs, the Settings window and the onboarding window,
redrawn. The closed notch, the peeks and the badges are **not** in scope: they
are the part that already works, and the part where the one rule bites.

Reference points: [boring.notch](https://theboring.name/) and
[Notchy](https://notchy.dev/). What is borrowed from each is named in §2; what
is deliberately not borrowed, and why, is §10.

## 1. What is wrong with the panel today

Rendered from `main` with the project's own offscreen renderer:

- The open panel is a 620×260 black rectangle whose bottom 60% is empty. The
  band beside the camera housing — 215pt each side on a 14" — is unused, while
  every *peek* in the app already draws into exactly that band.
- The media header spans the panel with the transport controls floated hard
  right, 400pt from the track they operate on.
- The timer tab uses `.borderedProminent` and `.roundedBorder`: system-blue
  buttons and a white field on a black notch. It is the only place the app
  stops looking like itself, and `NotchPanel.swift:43` already records one bug
  that came from stock controls resolving colours against a black ground.
- The power tab puts a 30pt number top-left and the word "Off" pinned to the
  far right, with nothing in between.
- A drag in flight turns the whole 620×260 black with one 13pt "Drop here".
- The shelf offers no way to remove one item, and neither pane says how many
  things it holds. Clearing either is in the menu bar only.
- Settings is one scrolling column of ten toggles, each followed by a
  paragraph.

## 2. The direction

**The notch opens; it is not replaced.** boring.notch's header puts its tab
switcher in the left ear and its controls in the right ear, with the camera
housing black between them. CreativeNotch already draws every peek into the
ears for the same reason (`HUDView`, `NowPlayingPeekView`, `PowerPeekView`,
`TimerDonePeekView` all take `notchGap`). The open panel's header does the
same: **icon tabs in the left ear, battery and a settings gear in the right
ear, nothing behind the housing.** On a pill Mac the same header spans the
full width, because there is nothing to avoid.

**Music is a column, not a header.** Both reference apps put the artwork on
the left and everything else beside it. Here that has a second benefit: the
module pane keeps one fixed size whether or not a track is playing, which
removes the reason `.open(.camera)` special-cases the media bar today
(`NotchRootView.swift:584-609`). The camera keeps its full-width treatment,
but as a rule of the pane, not an exception to the header.

**Black stays black.** No material, no artwork-tinted background, no shadow
that needs the window to grow (§4). What is borrowed instead: a 20pt bottom
radius when open (14 today), a hairline inner highlight so the panel has an
edge against a dark wallpaper, a one-shot fade on content when the state
changes, and one radial glow behind the album cover whose colour is computed
**once per artwork change**.

**One control vocabulary.** Capsule buttons in white-on-black, one prominent
variant, one field style, one tile style. The tab's *name* leaves the tab bar
and becomes the pane's title row, where it can carry a count and an action.

## 3. Geometry: nothing moves

`NotchGeometry.expandedSize` stays 620×260. `NotchShape.visibleRect` is not
touched: the header lives *inside* the expanded rect, in the band the content
is already padded past (`.padding(.top, app.anchor.rect.height)`), so the
drawn shape, the hit-test region and the hover rect are exactly what they are
today. The whole redesign happens inside the rectangle the app already claims.

One constant changes: `NotchGeometry.panelCornerRadius` 14 → 20.
`NotchCornerRadiiTests` compares against the constant, not the literal, and
`notchCornerRadius` (the closed state) is unchanged.

### 3.1 `PanelLayout` — the one place the split is computed

A new pure type in Core answers every layout question the header and body
ask, from the anchor and the panel frame:

```swift
public struct PanelLayout: Equatable, Sendable {
    public let headerHeight: CGFloat      // anchor.rect.height
    public let leadingEarWidth: CGFloat   // notch: anchor.minX - panel.minX; pill: panel.width / 2
    public let notchGap: CGFloat          // notch: anchor.rect.width; pill: 0
    public let trailingEarWidth: CGFloat  // the rest
    public let mediaColumnWidth: CGFloat  // 212, or 0 when the column is hidden
    public static func resolve(anchor: Anchor, panelFrame: CGRect, showsMedia: Bool) -> PanelLayout
}
```

`leadingEarWidth + notchGap + trailingEarWidth == panelFrame.width` is an
invariant with a test. `notchGap` here is the same number
`NotchRootView.notchGap(for:)` already derives for the peeks; the root view
reads it from the layout so there is still one spelling.

The media column is **212pt when `showsMediaControls` is true, whether or not
a track is playing.** A column that appeared with the first track would
reflow the pane under the user; it shows a placeholder tile and dimmed
controls instead (§5.1). It is 0 when media controls are off, and the pane
takes the width.

## 4. Why there is no drop shadow

The window is exactly the expanded rect, and the expanded shape fills it
(`visibleRect(.expanded)` returns the whole `panelFrame`). A SwiftUI shadow
would be clipped at the window edge on all three open sides. Making room
means growing `panelFrame` by a margin and insetting `visibleRect` by the
same margin, which is the seam ARCHITECTURE.md names as the project's only
Critical bug. A shadow is not worth reopening it.

The edge is drawn instead: a 1pt inner stroke at `white.opacity(0.08)`, on
the **expanded presentation only**. The closed notch must vanish into the
housing and gets no stroke; the peek is a glance and gets none either.

## 5. The panel, part by part

### 5.1 Header (`PanelHeader`)

Height `layout.headerHeight`. Three columns from `PanelLayout`.

- **Leading ear:** `PanelTabBar`, now icon-only. Each tab is a 34×24 button
  with a 13pt SF Symbol; the selected one has a `white.opacity(0.14)`
  rounded-7 fill, unselected glyphs at `white.opacity(0.55)`. The list still
  comes from `PanelTabBar.visible(enabled:hasBattery:)` and therefore from
  `TabVisibility` — the body's `ForEach` line that `PanelTabBarTests` pins by
  source scan is preserved verbatim. Each button carries `.help(tab.title)`
  and an accessibility label, because an icon without a name is a regression
  for anyone using VoiceOver.
- **Symbols** live in Core as `Tab.symbolName`, a pure string map, tested
  non-empty and distinct: `tray.full`, `doc.on.clipboard`, `timer`,
  `battery.100percent`, `camera`. `.hud` gets a symbol too so the switch is
  exhaustive without a `default`.
- **Trailing ear:** the battery level as a small cell glyph plus percentage
  (only when `hasBattery` and a snapshot exists, read from `app.power`), then
  a gear that calls `app.onOpenSettings`. The gear **closes the panel first**:
  Settings is an activating window and the panel should not sit open under
  it.

On a pill Mac `notchGap` is 0 and the two ears are each half the width, so
the header reads as one row.

### 5.2 Media column (`MediaColumn`)

Shown when `layout.mediaColumnWidth > 0`. Vertical: 72pt cover, then
title/artist, then the three transport buttons, left-aligned, with a 1pt
`white.opacity(0.08)` divider on its trailing edge.

- The cover is `NowPlayingView`'s tile grown to 72pt, keeping its hairline
  ring and its blank-tile fallback. When nothing is playing it shows a
  `music.note` glyph on `white.opacity(0.08)`, the title reads "Nothing
  playing" at 50% and the controls sit at 60% opacity — still live, because
  transport works before the helper has reported anything.
- **The glow.** A radial gradient behind the cover, `ArtworkTint.color(for:
  Data)` at 35% opacity, blurred 18pt. The colour is the artwork's average,
  computed in a `.task(id: artwork)` — one computation per artwork change,
  none while the panel is closed (the view does not exist then), and no
  ongoing cost while it is open. Nothing about it animates.
- `MediaControlsView` keeps its buttons and its injected `onCommand`; only
  the sizing changes (32×28 quiet capsules, 40pt for play/pause).

### 5.3 Module pane (`ModulePane`)

Everything right of the column. A **title row** — the tab's name at 13pt
semibold, an optional dimmed count, and an optional trailing action capsule —
then the tab's content. The row is what the tab bar's text labels became.

| Tab | Count | Action |
| --- | --- | --- |
| Shelf | "4 items" / "empty" | Clear (when non-empty) |
| Clipboard | "4 of 50" | Clear (when non-empty) |
| Timer | the set duration while running | — |
| Battery | — | — |

Actions route through new `AppState` closures — `onClearShelf`,
`onRemoveShelfItem(UUID)`, `onClearClipboard`, `onOpenSettings` — wired in
`AppDelegate.install(metrics:)` to the verbs that already exist
(`shelf.clear()`, `shelf.remove(_:)`, `clipboard.store.clear()`,
`showPreferences()`). Same shape as `onPasteClipboard`: the view gets a verb,
never a controller. The menu bar items stay; the pane is a second door to the
same room, and `shelf.clear()` moving real files to the Trash is exactly why
the verb is not duplicated.

### 5.4 Shelf

- Tiles: 64pt thumbnail on a 12pt-radius `white.opacity(0.07)` backing, so a
  white document icon reads against black; 10pt name under it, middle
  truncated. Horizontal scroll as today, centred while it fits.
- Hovering a tile shows a 16pt × in its top-right corner that calls
  `onRemoveShelfItem`. `.onHover` is an `NSTrackingArea` under the hood —
  allowed, and it only exists while the panel is open.
- Empty: a dashed rounded rect (`white.opacity(0.28)`, 1.5pt, radius 14)
  with `arrow.down.doc` and two lines — "Drop files on the notch to stash
  them" and, dimmer, "Kept 7 days · drag them out anywhere". The 7 days is
  `ShelfStore.maxAge`, formatted, not a literal.

### 5.5 Receiving

The same dashed target, brighter (`white.opacity(0.7)`, fill 5%), filling
the content area under an empty header, with `arrow.down.doc` at 28pt and
"Drop to stash on the shelf". The state, the transition and the hit region
are unchanged; only what is drawn is.

### 5.6 Clipboard

Rows of 12pt type with a 22pt leading tile: `text.alignleft` for text,
`link` when the text parses as a URL with a scheme, `chevron.left.forwardslash.chevron.right`
when it contains a newline or a brace (code), and the image itself for
images. A trailing time label: `ClipboardTimeLabel.text(addedAt:now:)` in
Core — `HH:mm` on the same calendar day, `d MMM` otherwise. **A clock time,
not "2m ago":** relative text goes stale while the panel is open, and keeping
it true would need the timer this app does not have. `now` is the single
per-body instant `NotchRootView` already binds.

Hover highlights the row at `white.opacity(0.08)` and swaps the time for
"Paste ↩". Click pastes, as today.

The classifier is `ClipboardKind.classify(_: ClipboardContent) -> ClipboardKind`
in Core, tested.

### 5.7 Timer

- Idle: three preset capsules "5 min" / "10 min" / "25 min", then a row of
  `−` `[15]` `+` and a prominent **Start**. The field is a `TextField` in
  `NotchFieldStyle`; the key-window behaviour in `AppDelegate.syncKeyWindow`
  is unchanged.
- Running: `TimerDisplay.text` at 44pt tabular with the unit small beside
  it, a 220×4 progress track filled to `TimerProgress.fraction(countdown, at:
  now)`, and Pause/Resume + Cancel capsules. The track redraws only when the
  digits do — it is a function of the same `now` — so the redraw cadence
  `TimerSchedule` fixes is untouched. Paused dims to 45%, as today.
- Every stock style in `TimerTabView` is replaced. A source-scan test pins
  that `.borderedProminent`, `.bordered` and `.roundedBorder` no longer appear
  under `Sources/CreativeNotchUI/`.

### 5.8 Battery

An 88×44 gauge — rounded rect outline, terminal nub, fill proportional to
level — beside a 34pt percentage, the `PowerLabel.state` string at 14pt, and
a "Low Power Mode" row whose value is a pill. Fill colour from
`PowerGaugeTone.tone(level:isCharging:)` in Core: `.charging` (green) when
charging, `.low` (yellow) at or below `LowBatteryArming.thresholds.max()`
(20), `.normal` (white) otherwise. Yellow is the one colour the power module
already uses (`PowerPeekView.tint`), and green for charging is what the menu
bar item does.

### 5.9 Camera

`.open(.camera)` renders the header and then `CameraTabView` across the
**whole** content area — no media column — so the preview gets the width it
wants and a fixed height regardless of playback. The tab bar is present, so
the close button `CameraTabView` grew when the bar was hidden becomes
redundant; it stays for one release because removing a way out is the bug
that put it there.

### 5.10 Controls (`NotchControls.swift`)

- `NotchButtonStyle(.quiet)`: capsule, `white.opacity(0.10)` fill, white
  12pt semibold label, 0.16 on hover, 0.22 pressed.
- `NotchButtonStyle(.prominent)`: white fill, black label.
- `NotchFieldStyle`: 8pt radius, `white.opacity(0.08)` fill, 1pt
  `white.opacity(0.12)` ring, centred tabular digits.

Pressed/hover states change on input only. Nothing pulses.

### 5.11 Motion

The shape keeps its spring. Content inside the expanded shape gets
`.transition(.opacity.combined(with: .scale(scale: 0.96)))` keyed on
`app.state`, so switching tabs or opening the panel fades the pane in once.
No repeating animation is added anywhere.

## 6. Settings

A `Form` in `.grouped` style, 520×620, sections in this order:

1. **In the notch** — File shelf, Clipboard history, Timer, Battery and power.
2. **Music** — Now playing, Media controls.
3. **Camera and privacy** — Camera, Camera and microphone indicator.
4. **System** — System HUD.
5. **Shortcut** — Global shortcut with the existing `HotKeyRow` beneath it.

Each row: a 26pt coloured symbol tile, the module name, and **one line** of
detail. The paragraphs from today's `PreferencesView.rows` do not disappear:
the sentence that says what switching off actually stops moves to the row's
one line, and anything longer becomes the section footer. The conditional
warnings (`PreferencesView.warning(for:controller:)`) stay inline in orange,
unchanged. `PreferencesView.rows` remains the single list a test compares
against `ModuleID.allCases`; it gains `section` and `symbolName` fields.

The mock on the proposal page showed a sidebar with a "General" pane. It is
not built: General would hold one line about Accessibility and nothing else,
and structure that encodes nothing is decoration. When Launch at login ships
it gets a section.

## 7. Onboarding

Same window, same buttons, same `onDone`. The wall of text becomes a title
and three short rows, each with a symbol: what it needs (Accessibility, for
the volume and brightness keys), why (to stay quiet when macOS already shows
its own overlay), and what happens without it (both indicators at once). The
granted/not-granted `Label` stays and stays event-driven.

## 8. What is pure, and where it lives

New in `CreativeNotchCore`, each added to the `CorePurityTests` manifest in
the commit that creates it:

| File | Answers |
| --- | --- |
| `PanelLayout.swift` | header height, ear widths, notch gap, media column width |
| `TabSymbols.swift` | `Tab.symbolName` |
| `Clipboard/ClipboardKind.swift` | text / link / code / image for a row's tile |
| `Clipboard/ClipboardTimeLabel.swift` | the time string, from `addedAt` and `now` |
| `Timer/TimerProgress.swift` | filled fraction of the track |
| `Power/PowerGaugeTone.swift` | normal / low / charging |

Everything else is presentation and lives in `CreativeNotchUI`. Rendering
tests follow `PowerPanelRenderingTests`: build an `AppState`, set geometry,
render `NotchRootView` through `ImageRenderer`, and compare pixels between
two states that must differ. `ImageRenderer` does not run `ScrollView`
content, so list contents are asserted through their pure functions, not
their pixels.

## 9. How this could betray the one rule, and what catches it

- **A relative time label.** "2m ago" is wrong within a minute of being drawn
  unless something redraws it. §5.6 uses a clock time; the Core function's
  signature takes `now` and returns nothing relative.
- **A glow that animates.** `ArtworkTint` runs in `.task(id:)`; a test pins
  that no `TimelineView`, `.repeatForever` or `Timer` appears in the UI
  sources touched by this spec, by source scan, the way `PanelTabBarTests`
  pins its body.
- **A progress track on its own clock.** `TimerProgress.fraction` takes the
  same `now` as `TimerDisplay.text`; the view never reads `Date()`.
- **Hover tracking areas.** `.onHover` on shelf tiles and clipboard rows
  creates `NSTrackingArea`s inside the panel — allowed by ARCHITECTURE.md,
  and gone when the view is, which is the moment the panel closes.

## 10. Deliberately not borrowed

| Seen in | Idea | Why not |
| --- | --- | --- |
| boring.notch | Audio visualiser in the closed notch | An FFT on a live tap; the README names it as the reason the app exists. |
| boring.notch | Hover opens the full panel | Hover peeks, click opens. It keeps the notch out of the way on the path to the menu bar. |
| boring.notch | Flared top corners into the menu bar | Paints black over menu bar pixels on a light menu bar. |
| Notchy | Liquid-glass material | Composited by the window server for as long as the panel is open; black is the identity. |
| Notchy | Per-tab panel sizes | The window is fixed so it never resizes; the hit test derives from one function. |
| Both | Scrubber and elapsed time | A once-a-second redraw for as long as music plays. |
| Both | A fake black notch on notchless Macs | The pill stays. |

## 11. Deliberately not in v1

- Keyboard navigation between tabs (⌘1–5). Wants the panel to be key on every
  tab, which today it is only on the timer's.
- Drag-reordering shelf items.
- A per-item "reveal in Finder" on the shelf. One hover affordance per tile.
- Pinning the settings gear's tooltip to the shortcut. There is no default
  shortcut to show.
