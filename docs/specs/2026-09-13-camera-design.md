# The camera in the notch — design

Click the notch, choose the camera tab, and the FaceTime camera's feed appears
in the panel: a mirror for checking framing, a shutter for a still, and a
record button for a clip. Captures land in the file shelf.

The pleasing part is geometric rather than technical. The camera sits
physically behind the notch, so a preview drawn in the open panel is directly
beneath the lens feeding it.

---

## 1. Why this is allowed where the audio visualiser is not

`ROADMAP.md` refuses an audio visualiser as a top CPU cost that contradicts the
one rule. A live capture session costs more than an FFT, so the distinction
cannot be cost, and pretending otherwise would be dishonest:

> The visualiser would run **ambiently** — whenever audio played, whether or
> not anybody had the notch open or was looking at it. The camera runs **only
> because the user opened it**, and only while they are watching what it
> produces or recording what it captures.

The rule is *no subsystem runs when it isn't needed*, not *nothing expensive is
allowed*. That argument holds only if the session genuinely stops, which was
the module's one unresolved question.

### It is answered, and it was measured twice

`stopRunning` is documented to stop the session *object* and the *flow of
data*. Nothing in AVFoundation says when the **device** is released, and
`AVCaptureVideoPreviewLayer.isPreviewing` — the only in-process cross-check —
is unavailable on macOS.

Measured out-of-process, with the subject held alive afterwards:

| Teardown | Device released |
| --- | --- |
| `stopRunning()` alone | **10 ms after the call was made** — 40 ms before it returned |
| `stopRunning()` + remove inputs/outputs + drop session | 52 ms before the call returned |

Both stayed released for a full 120-second idle hold **with the process still
alive**, which is what rules out the obvious false pass: a probe that exits
measures the kernel reclaiming a dead process's handle, not `stopRunning`.

So `stopRunning()` alone is sufficient. The deeper teardown buys nothing for
device release — but the preview layer must still be released, for a different
reason (§4).

---

## 2. Two reasons to run, and the second is an exemption

The obvious design gates the session on the panel being open. That is wrong,
and the case that makes it wrong is the one a user hits first: **press record,
then click away.**

The roadmap says the session stops when the panel dismisses "by any route".
Applied literally, a stray cursor ends your take. Pressing record is a
deliberate act; the panel closing is often not.

So the session runs while **either** is true:

| Reason | What runs |
| --- | --- |
| The camera tab is visible | preview + session |
| A recording is in progress | session, no preview |

**This is the project's second documented exemption from the activity gate**,
and it is the same shape as the timer's: a countdown's whole purpose is to fire
while nobody is watching, and a recording's whole purpose is to capture while
you are doing something else. In both cases the *drawing* is gated and the
*work* is not.

And it is honest about itself. While a recording outlives the panel, the ear
shows a recording indicator — the same slot the countdown uses. **The green
camera light stays on, and so does something in the notch that explains why.**
A capture running with nothing on screen to account for it is precisely what
this project exists to prevent.

### What stops it

- The tab changing away, **unless recording**
- The panel dismissing, **unless recording**
- Screen lock and display sleep — `SystemActivity`, **unless recording**
- The recording finishing, if the panel is already closed
- The module being switched off in Settings, which stops it **including**
  mid-recording: the switch is a stronger statement than the cursor moving, and
  the partial clip is saved rather than discarded

`pkill` is not on that list and cannot be: `Scripts/dev.sh` and
`Scripts/install.sh` both use SIGTERM, which runs no AppKit termination
handler. The session dies with the process, which is the only guarantee
available and is sufficient.

---

## 3. The geometry fits — the roadmap had the arithmetic wrong

`ROADMAP.md` said a 16:9 preview 620 points wide wants 349 points of height
against a 260-point panel, and offered crop, letterbox, or a taller panel.

That is only true fitting to **width**. Fit to **height** and 16:9 at 260 tall
is **462 × 260**, inside 620 with 158 points to spare for controls.

The real constraint was never `expandedSize`. It is the **tab content area**
after the notch inset, the media header when a track is playing, and the tab
bar — roughly 130 points with music playing and 195 without. **A preview whose
height changes when a track starts is not acceptable.**

So the camera tab suppresses **the media header only**, and keeps the tab bar.
`expandedFrame` is untouched, no other tab is affected, and the preview never
resizes under the user, because the thing that was resizing it was the media
header appearing and disappearing with playback.

**This corrects the first version of this spec**, which suppressed the tab bar
as well and claimed "the camera view owns a close control, and Escape still
dismisses". The second half of that was simply false — **there is no Escape
handling anywhere in the panel** — so removing the tab bar left one close
button as the only discoverable way out, and using it for a minute was enough
to find that out.

The lesson is worth keeping rather than quietly fixing: the reasoning about
which chrome to suppress was sound, and the claim about what would replace it
was never checked. 27 points of preview is a smaller cost than a tab the user
cannot obviously leave.

---

## 4. The preview layer retains the session

`AVCaptureVideoPreviewLayer.h` states it twice: *"The session is retained by
the preview layer."*

So removing the SwiftUI view — switching tabs, closing the panel — does **not**
release the session. The layer's `session` must be nilled explicitly. This is
the roadmap's "hiding the view is not stopping the session", made mechanical,
and it is a retain cycle rather than a device claim: the measurement in §1 says
the device is released by `stopRunning` regardless.

Both are needed. `stopRunning()` releases the hardware; nilling the layer
releases the graph.

---

## 5. Mirroring is a property of the connection, not the view

A selfie preview is mirrored. `.scaleEffect(x: -1)` on the SwiftUI view mirrors
the preview correctly and mirrors **nothing else** — the still and the clip
come out unmirrored, because mirroring lives on `AVCaptureConnection` and there
is a separate connection per output.

**The preview is mirrored; the saved file is not.** You see yourself as in a
mirror, and the file shows what the camera actually saw — so text in shot reads
correctly and the file matches what anyone else would see. Photo Booth saves
mirrored and makes un-mirroring an explicit action; FaceTime and most video
tools do not. Apple's own answers disagree, so this is a choice rather than a
convention, and it is recorded as one.

---

## 6. Clips are silent, deliberately

Adding an `AVCaptureDeviceInput` for the microphone compiles, works, and
silently adds: a second usage-description key, a second TCC prompt, the orange
recording indicator, an entry in Control Center's microphone list — and **a
self-exclusion problem for the planned microphone indicator that does not
otherwise exist.**

A framing mirror and a short self-recording do not need sound. If they ever
do, the cost above is what it costs, and module 1's spec has to change with it.

---

## 7. Permissions, and what the user actually sees

`NSCameraUsageDescription` in the bundle plist, and
`AVCaptureDevice.requestAccess(for: .video)`.

**A denied grant does not produce an error.** `AVCaptureDevice.h`: *"Until
access has been granted, any AVCaptureDevices for the media type will vend
silent audio samples or black video frames."* A denied camera is
indistinguishable from a bug unless `authorizationStatus` is read **before**
building the graph, so it is.

**Every shipped update re-prompts.** TCC keys the grant to the code hash, and
this app is ad-hoc signed — measured: a rebuild with an unchanged bundle
identifier and a changed cdhash produced a fresh permission dialog. Unlike
Accessibility, which fails silently, this is noisy and self-healing, but it is
a real cost and it is one of several that a stable signing identity would
remove at a stroke.

---

## 8. Which camera, and what macOS adds to it

**The built-in camera only.** `AVCaptureDevice.default(for: .video)` and
`systemPreferredCamera` can both return a Continuity Camera — an iPhone on a
desk across the room — which breaks the module's entire premise that the lens
is above the preview. `isContinuityCamera` is the documented filter and the
discovery session excludes them.

**Reaction Effects are suppressed.** `AVCaptureDevice.h`: *"On macOS, Reaction
Effects are enabled by default for all applications"*, with gesture detection
on. A hand gesture producing confetti is right for FaceTime and wrong for a
framing mirror. The opt-out is **not a guarantee** — the key sets the default
*"until such time that the user makes their own selection in Control Center"* —
so the spec says so rather than promising no fireworks.

---

## 9. What is pure, and what cannot be tested at all

This is the module with the **worst headless coverage ratio in the project**,
and that is a property of the subject rather than a gap to close. A capture
session cannot be constructed in `swift test`: the test bundle has no
Info.plist with a usage description, and Apple's documented response to that is
termination.

| Core — provable headlessly | UI — not |
| --- | --- |
| `CameraPreviewFit` — the aspect arithmetic the roadmap got wrong | `CameraSession` — the graph, on its own queue |
| `ClipLimits` — duration and size ceilings | `CameraPreviewView` — the layer, and the fourth thing to decline a click |
| `CaptureFileNaming` — collision-free names | `CameraController` — lifecycle and gating |
| `CameraRunReason` — the two-reasons rule of §2 | the photo and movie delegates |

`CameraRunReason` is the interesting one: **the decision of whether the session
should be running is pure**, a function of (tab visible, recording, activity,
enabled) to a Bool. That is the part §2 is about, it is where the exemption
lives, and it is testable exhaustively over sixteen combinations without a
camera.

---

## 10. How this could silently betray the one rule

**R1 — The session outlives the panel with nothing recording.** The exemption
in §2 is narrow, and a bug that widens it leaves the camera claimed. *Test:*
`CameraRunReason` over all sixteen inputs.

**R2 — The preview layer keeps the session alive.** *Test:* the teardown nils
the layer's session, asserted on a fake.

**R3 — A recording outlives the panel with nothing on screen to say so.** The
exemption is only honest while the ear shows it. *Test:* recording with the
panel closed produces the badge.

**R4 — `stopRunning` on the main actor.** Both calls are documented as
blocking. *Test:* the session's queue is not the main queue, asserted directly.

**R5 — A denied grant reads as a bug.** Black frames, no error. *Test:*
`authorizationStatus` is read before the graph is built, pinned by a source
scan the way the launch path is.

**R6 — A clip overwrites or fails silently.** `AVCaptureFileOutput` fails
*asynchronously* if the file exists. *Test:* `CaptureFileNaming` never returns a
name twice.

---

## 11. Deliberately not in v1

- **Audio.** §6.
- **Choosing a camera.** §8 — the premise is the built-in lens.
- **Editing anything.** The shelf holds files; it does not open them.
- **A countdown before the shutter.** Photo Booth has one; this is a notch.
