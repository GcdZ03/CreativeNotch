# Camera teardown — what was measured

The camera module is admitted where the audio visualiser is refused, on the
grounds that one runs ambiently and the other only while the user is watching
it — **provided the session actually stops.** Apple's documentation does not
reach that far: `stopRunning` is documented to stop the session *object* and
the *flow of data*, never to say when the device is released, and
`AVCaptureVideoPreviewLayer.isPreviewing` is `API_UNAVAILABLE(macos)`.

So it was measured, twice: once against a throwaway subject, and once against
the real app.

Both used an out-of-process observer holding CoreMediaIO
`kCMIODevicePropertyDeviceIsRunningSomewhere` listeners on every device. **The
instrument never constructs a capture session**, which is the point: a probe
that shares identity, process or fate with its subject measures itself.

Host: macOS 26.6.2 (25G83), Mac17,3.

## Why the obvious test proves nothing

The natural experiment — open the camera, close it, watch the light — passes
for the wrong reason every time. A process that exits releases the camera
whatever its teardown code does, so **the subject must stay alive and idle
afterwards.** Every figure below was taken with the capturing process still
running.

## Measurement 1 — the throwaway subject

Two ad-hoc-signed variants, differing only in teardown depth, each holding for
120 seconds after stopping.

| Variant | Device released |
| --- | --- |
| `stopRunning()` alone | **10 ms after the call was made** — 40 ms before it returned |
| `stopRunning()` + remove inputs/outputs + drop the session | 52 ms before the call returned |

Both stayed released for the full 120-second hold.

**So `stopRunning()` alone is sufficient**, and the deeper teardown — which is
what the most popular open-source notch app does — buys nothing for device
release. The preview layer's session must still be nilled, but that is a retain
cycle rather than a device claim, and a different fix.

## Measurement 2 — the shipped app

The same observer, pointed at CreativeNotch running from `dist/`, while a human
opened and closed the camera tab twice.

| | Claimed | Released | Held |
| --- | --- | --- | --- |
| Cycle 1 | 22:57:49.108 | 22:57:57.892 | 8.78 s |
| Cycle 2 | 22:58:03.224 | 22:58:07.439 | 4.22 s |

**The app was still running throughout, and after.** Every reading between the
cycles and after the second release was `0`, and CreativeNotch appeared in the
process list as `in=0 out=0 running=0` — present, claiming nothing.

This is the weaker measurement in one respect and the stronger in another. It
cannot give a call-to-release latency, because the moment the user clicked is
not recorded and the app does not log when it calls `stopRunning`. But it is
production code, with the real preview layer, the real controller, and the real
`CameraRunReason` gating — none of which the throwaway subject had.

**What both establish:** the claim in the spec is a measurement, not a hope.

## An incidental finding, for the indicator module

CMIO fires **three events on start** — values `0`, `1`, `1` within ~56 ms — and
**one on stop**.

An indicator that toggles its own state on every callback would therefore
flicker every time any application opens a camera. It must read the property's
value and dedupe, not react to the notification. Recorded here because it was
free: the instrument built for this module is a strict subset of what the
indicator module needs.

## What was not measured

**The call-to-release latency in production**, as above.

**Whether the green LED and the CMIO property agree.** The LED reports the
hardware; the property reports the device claim. They need not change at the
same instant, and only the property was logged.
