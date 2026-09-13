# Hotkey probe — what was measured

Run 2026-09-13 on macOS 26.6.2 (25G83), Mac17,3, Swift 6.3.3, against the
macOS 26 SDK.

The probe was a throwaway `.app` — bundle id `com.gcdz.notchprobe`,
`LSUIElement`, **ad-hoc signed with `codesign -s -` forced**, launched with
`open -n` so it inherited no Terminal context. It is not in this repo; it was
built in a scratch directory and deleted.

## The gate that came first

```
codesign -dvvv --requirements - NotchProbe.app
  flags=0x2(adhoc)
  TeamIdentifier=not set
  designated => cdhash H"625497e0534fa43b68cd09d2093e8e70508c67a9"
```

No `Authority=` line. This matters more than it looks: `security find-identity`
confirms a **"CreativeNotch Dev" certificate is in this machine's keychain**,
and `Scripts/bundle.sh` silently prefers it whenever it is present. A probe
built the ordinary way would have measured a stable identity-based designated
requirement rather than the ad-hoc one releases actually ship with.

Run context from the log header: `AXIsProcessTrusted=false`, `parentPID=1`.

## Modifier policy — all sixteen subsets register

macOS 15.0 rejected shift-only and option-only combinations with `-9868`, as an
anti-keylogger measure, and relaxed it in 15.2 beta 2. Whether that relaxation
survived was unknown.

All 16 subsets of {⌘, ⇧, ⌥, ⌃}, on two keys — `kVK_ANSI_N` and `kVK_F13`,
register then immediately unregister:

**32/32 `noErr`.** Every ref non-nil, every unregister `noErr`.

So the restriction does **not** survive into 26.6.2. ⇧-only, ⌥-only and ⇧⌥ all
register cleanly for an untrusted, ad-hoc-signed, non-hardened agent, and zero
modifiers is still allowed as the parameter documentation has said since 10.3.
`kVK_F13` was added on the theory that a keylogging-motivated policy would
discriminate against text-producing keys. It does not.

**What this does not license.** It removes only the *registration-time*
refusal. `noErr` says nothing about delivery, so this table cannot justify a
default combination. A zero-modifier hotkey in particular would fire on every
press of that letter system-wide, and `noErr` gives no warning whatsoever.

## Exclusive registration — Apple's header contradicts itself, and the narrow reading wins

`CarbonEvents.h` says two incompatible things about `eventHotKeyExistsErr`:

- the `HotKeyOptions` enum doc: returned when *"another hot key"* is already
  registered for that combination — i.e. any incumbent;
- the `RegisterEventHotKey` Result doc: returned only when another process
  registered the same hotkey **with `kEventHotKeyExclusive`**.

Measured with a holder and a challenger in **two processes with two different
bundle identities**, so "a second process" could not be confounded with "the
same app twice". Combination ⌥⌘N throughout:

| Incumbent | Challenger | Challenger `OSStatus` |
| --- | --- | --- |
| non-exclusive | non-exclusive | `0` `noErr` |
| non-exclusive | **exclusive** | `0` `noErr` |
| **exclusive** | **exclusive** | **`−9878` `eventHotKeyExistsErr`** |
| **exclusive** | non-exclusive | `0` `noErr` |

**The narrow reading holds.** The Result doc is right; the enum sentence is
wrong as written.

Rows one, three and four were added beyond the single case the probe plan
called for, because that case is ambiguous alone: `noErr` in row two could
equally have meant `kEventHotKeyExclusive` is simply **inert** on macOS 26 — a
third outcome that reads as a pass for the narrow reading and is not one. Row
three is the guard. The same call *does* return −9878 when the incumbent is
exclusive, so row two is a real discrimination between kinds of incumbent. Row
three also returned a nil `EventHotKeyRef`, so nothing leaked.

A third header passage settles the tie the same way, at
`CarbonEventsCore.h:144-151`: returned when a hotkey is already registered
*"in the current process"*, **and** when registering exclusively against
another process's exclusive registration. The headers are 2-to-1 for the narrow
reading and the measurement agrees with the majority.

## What this leaves undecidable

An ordinary conflict — another app holding the same combination
non-exclusively, which is what virtually every app does — returns `noErr` and
**both handlers fire**. There is no API that reports it.

So a preferences pane cannot truthfully say *"that combination is taken"*. It
can say *"you already used that shortcut in CreativeNotch"*, because
same-process re-registration genuinely returns −9878, and it can enumerate
`CopySymbolicHotKeys()` to say *"macOS already uses this"*. Anything stronger
is a claim the system does not support.

## Not measured

**Delivery.** Every result above is about registration. Whether the
combination actually reaches the handler — with Secure Keyboard Entry on, in a
password field, over a fullscreen app — needs keypresses and a human, and was
deliberately left out of the automated half. It is also why the module asks the
user to press the combination once rather than trusting any API.

**The Accessibility claim.** The roadmap says `RegisterEventHotKey` needs no
Accessibility permission. `AXIsProcessTrusted=false` throughout is consistent
with that but does not prove it: the differential — an `NSEvent` global monitor
installed alongside, logging zero keydowns while the Carbon handler fires — was
not run, because it needs a human typing.
