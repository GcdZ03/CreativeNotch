# `DeviceIsRunningSomewhere` — which scope actually notifies

Run 2026-09-13 on macOS 26.6.2 (25G83), Mac17,3, with an out-of-process
observer holding both listeners simultaneously and a human recording six
seconds of audio in Voice Memos.

## The question, and why it was the dangerous one

`ROADMAP.md` originally called the microphone half the settled one, because the
HUD's `VolumeObserver` already uses CoreAudio and "the project has the
pattern". That pattern is **directional scope** —
`kAudioDevicePropertyScopeOutput` — which is correct for volume and mute,
because those genuinely are per-direction.

Applying it by analogy to `kAudioDevicePropertyDeviceIsRunningSomewhere` was
reported to register with `noErr` and then never fire. That is one unanswered
GitHub issue and one unanswered Apple forum post, which is a lead rather than
evidence, so it was measured.

## Measured

Both listeners registered on the same device, in the same process, at the same
time. Device 78, `MacBook Air Microphone`.

| Listener | Scope | Events |
| --- | --- | --- |
| (a) | `kAudioObjectPropertyScopeGlobal` | **2** |
| (b) | `kAudioObjectPropertyScopeInput` | **0** |

Global scope fired once per edge, cleanly:

```
23:12:00.907   running[global]=1   running[input]=1   ← recording started
23:12:07.549   running[global]=0   running[input]=0   ← recording stopped
```

Registration succeeded for both: `hasProperty=true`, `OSStatus=0 (noErr)`.

## The finding is sharper than "input scope does not work"

**Look at the values.** At the instant the global listener fired,
`running[input]` was already correct — `1` on the start edge, `0` on the stop
edge. The input-scope *property* reads accurately. Only its *notification*
never arrives.

So the failure mode is not a wrong value that testing would expose. It is:

1. register on input scope — succeeds, `noErr`;
2. verify by reading the property — correct, every time;
3. ship an indicator that never updates.

A developer following `VolumeObserver`'s precedent would do exactly that, and
every check short of an end-to-end test with a second application capturing
would pass. **The roadmap's correction was right, and the reason it mattered is
that the project's own precedent leads into the trap.**

## Register on global scope. Read from either.

The observer therefore registers global scope only. The value may be read from
whichever scope is convenient, since both are accurate — but the subscription
must be global.

## Two frameworks, two notification shapes

| Framework | On start | On stop |
| --- | --- | --- |
| CoreAudio | **1 event** | 1 event |
| CoreMediaIO | **3 events** (`0`, `1`, `1` within ~56 ms) | 1 event |

Recorded in `docs/research/2026-09-13-camera-teardown.md` for the camera half.
Neither shape can be relied on, which is why `CaptureDebounce` exists: a
callback is a prompt to **re-read**, and a re-read matching what is already
shown changes nothing.

## Not measured

**Attribution at the moment of the event.** The per-process dump that would
name Voice Memos as the capturing process did not land inside the event window,
so `kAudioHardwarePropertyTranslatePIDToProcessObject` and the
`IsRunningInput` per-process read remain untested against a real second
application. The pure policy over that data is tested; the read that produces
it is not.

**Whether removing a listener actually stops delivery.** There is an
unanswered radar (FB13398940) claiming `CMIOObjectRemovePropertyListenerBlock`
returns `noErr` and keeps delivering. If that reproduces, a registration count
of zero would mean "removal was asked for" rather than "it stopped" — the same
class of failure as the media helper's activity gate. Untested here.
