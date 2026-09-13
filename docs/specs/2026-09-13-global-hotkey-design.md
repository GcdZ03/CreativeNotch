# Global hotkey — design

A key combination that opens the panel from anywhere.

Four things about this module were measured rather than assumed, and three of
them contradict what `ROADMAP.md` said before the probe ran. The measurements
are in `docs/research/2026-09-13-hotkey-probe.md`; what follows is what they
mean for the design.

---

## 1. The obvious implementation is the one this project exists to avoid

`NSEvent.addGlobalMonitorForEvents` runs a closure on **every keystroke you
type, forever**. `ARCHITECTURE.md` names permanently-installed global monitors
as not allowed, and this is the case it had in mind.

`RegisterEventHotKey` registers the specific combination with the window
server, which delivers an event only when that combination is pressed. Nothing
runs in between, and it needs **no Accessibility permission**, because it never
sees any key but the one it registered.

`MediaKeyMonitor` is the project's one admitted always-installed monitor, and
it earns that by firing only on physical media keys. A second one would need
the same justification. This module needs none.

**Measured:** `RegisterEventHotKey` is **not deprecated**. It carries no
deprecation macro in `CarbonEvents.h` and sits deliberately outside the
`!__LP64__` guard that removed the rest of Carbon. The "deprecated since 10.8"
claim dominating search results is false.

---

## 2. `OSStatus` cannot detect a conflict, and the roadmap said it could

This is the correction that shapes the whole user-facing half.

`ROADMAP.md` used to say registration fails when another app already holds the
combination, and that checking the status catches it. Apple's header says the
opposite:

> The same hot key can, however, be registered by multiple applications.

So an ordinary conflict returns **`noErr` and both handlers fire**. Checking
the status detects nothing at all.

Apple's header then contradicts itself about whether `kEventHotKeyExclusive`
gives honest detection — one passage says it fails against *any* incumbent,
another says only against another *exclusive* one. **Measured, two processes,
two bundle identities:**

| Incumbent | Challenger | `OSStatus` |
| --- | --- | --- |
| non-exclusive | non-exclusive | `noErr` |
| non-exclusive | **exclusive** | `noErr` |
| **exclusive** | **exclusive** | **−9878 `eventHotKeyExistsErr`** |
| **exclusive** | non-exclusive | `noErr` |

The narrow reading holds. The third row is what makes this a result rather
than an inert option: the same call *does* return −9878 when the incumbent is
exclusive, so row two's `noErr` is a real discrimination between kinds of
incumbent rather than the option being unimplemented.

### We register exclusively anyway

Not for the conflict detection — virtually nothing ships with the option, so
−9878 will almost never fire. For the **delivery**: exclusive registration
stops other registrants' handlers firing for that combination, so a hotkey the
user chose does one thing rather than two.

### So the pane must never say "that combination is taken"

It cannot know. What it can honestly claim:

| Claim | How |
| --- | --- |
| "You already used that shortcut in CreativeNotch" | same-process re-registration genuinely returns −9878 |
| "macOS already uses this" | `CopySymbolicHotKeys()`, enumerated once at the moment of choosing |
| "Another app may also respond" | never claimed, because it cannot be known |

---

## 3. Neither API proves the hotkey *delivers*, so the user does

A system symbolic hotkey like ⌘Space registers with `noErr` and then never
fires, because the system consumes it first. `CopySymbolicHotKeys` catches
most of those, but it is enumerable state rather than a guarantee, and it
cannot name which feature owns a combination.

**Registration success and delivery are independent, and only delivery is the
feature.** So after recording a combination, the row arms and waits:

```
Recorded ⌘⌥N
┌──────────────────────┐
│ Press it now to      │
│ confirm…             │
└──────────────────────┘
        ↓
┌──────────────────────┐
│ ✓ ⌘⌥N confirmed      │
└──────────────────────┘
```

This is the only honest proof available, and it costs one keystroke. A
combination that never confirms is one the user can change while looking at
the evidence, rather than discovering months later that the feature was never
working.

**The confirmation is state, not ceremony.** It is persisted, so a combination
proven once is not re-interrogated on every launch; and it is cleared whenever
the combination changes, because the proof was about that combination.

---

## 4. The real trap is Swift 6, not Carbon

Three traps, all measured, all of which produce code that looks correct:

**A capturing closure type-checks clean.** `swiftc -typecheck` exits 0 on a
closure that captures context and is passed to `InstallEventHandler`; only
`swiftc -c` reports it, because the diagnostic comes from SILGen rather than
the type checker. An editor or LSP will show nothing.

**Calling a `@MainActor` method straight from the C callback is only a
warning** under strict concurrency. It compiles, it works by luck, and — until
CI gained a warning gate three commits ago — it would have shipped.

**Passing context through `userData` as `Unmanaged.passUnretained(self)` is the
canonical blog pattern and is a use-after-free** waiting for the owner to
deallocate.

The answer to all three is the same: **the callback captures nothing.** Context
travels as the `EventHotKeyID` carried by the event itself, so there is no
lifetime to get wrong, and `MainActor.assumeIsolated` makes the main-run-loop
assumption an assertion that traps loudly rather than an inference that
corrupts quietly.

The handler is installed on `GetApplicationEventTarget()` and sees **every**
`kEventHotKeyPressed` in the process, including any a dependency registers, so
it checks our four-character signature and returns `eventNotHandledErr` for
anything else. Returning `noErr` unconditionally would tell the Carbon
dispatcher we consumed someone else's event.

---

## 5. What is stored, and what is only ever rendered

**A keycode, never a character.** `RegisterEventHotKey` takes a virtual
keycode identifying a *physical* key. The letter printed on that key is a
rendering concern that changes with the keyboard layout. Store the character
and every load has to reverse-map it against whatever layout is current, which
is wrong the moment the user switches layouts.

```
stored:    { keyCode: 45, carbonModifiers: cmdKey | optionKey }
rendered:  ⌘⌥N   (US)        ⌘⌥N   (UK)        ⌘⌥‹  (Dvorak)
```

Resolution happens at display time, using the **ASCII-capable** input source
rather than the current one: with a Japanese or Pinyin IME selected, the
current source has no Unicode layout data at all and the pane would render
blank.

### Two keys that are the same keycode

`kVK_ANSI_N` and the `N` on a different layout are one keycode. So are ⌘ and
the Command key on an external keyboard. The value type is two `UInt32`s and
`Equatable`, which is all the comparison any of this needs.

---

## 6. Ships unset

No default combination. Any default risks colliding with Raycast, Alfred,
Spotlight or whatever launcher the user already runs — and a colliding hotkey
either double-fires or is silently eaten, both of which read as CreativeNotch
being broken.

Unset is also the only state that cannot be wrong. `UserDefaults` resolution
follows the module-toggle rule established by Preferences: **absent means
absent**, and for this key that is genuinely "no hotkey", not a shipped
default — which is why it is stored as an optional rather than defaulted.

---

## 7. Where the seam falls

`Carbon.HIToolbox` is neither AppKit nor SwiftUI, so `HotKeyCenter` could
technically satisfy `CorePurityTests`. It does not belong there: registration
cannot be exercised headlessly in CI, and Core is the part that must be
provable without a window server.

| Core | UI |
| --- | --- |
| `HotKeyCombo` — two `UInt32`s, `Codable`, `Equatable` | `HotKeyCenter` — registration, the one C handler |
| `HotKeyValidation` — modifier policy, intra-app duplicates | `SymbolicHotKeys` — the `CopySymbolicHotKeys` read |
| `HotKeyGlyphs` — modifier ordering and assembly | `KeyCodeDisplay` — `UCKeyTranslate` against the ASCII layout |
| `HotKeyStore` — the defaults key and its resolution | the recorder row in the settings window |

The Core half is pure combinatorics and is the bulk of the testable surface:
modifier ordering is a fixed sequence (⌃⌥⇧⌘, the order macOS itself uses), and
validation is a set of rules over two integers.

---

## 8. It joins Preferences like every other module

The hotkey is a module, so it gets a `ModuleID` case, a row, and a leg in
`ModuleSwitchboard.setEnabled`. **The leg has to stop something**, per the rule
that shipped with Preferences — and for this module stopping means
*unregistering*, not ignoring the callback. A registration left alive while the
switch reads off is exactly the failure that module exists to prevent.

Not needed at termination: Apple's header is explicit that the system reclaims
registrations when the process exits. Writing teardown for that would be
defending against something that cannot happen.

---

## 9. How this could silently betray the one rule

**R1 — A registration outlives the toggle.** The switch reads off, the key
still opens the panel. *Test:* register, assert the center holds one entry,
disable, assert zero.

**R2 — The handler outlives its last hotkey.** Cheap to leave installed, but it
is a process-wide event handler and the module's own rule says disabling stops
the subsystem. *Test:* register then unregister, assert the handler ref is nil.

**R3 — A stale registration survives a change of combination.** Recording a new
key without dropping the old one leaves both live, and the old one keeps
working. *Test:* register A, re-record as B, assert A no longer fires and the
entry count is still one.

**R4 — Confirmation survives a combination it was not about.** A proof carried
over to a different key is worse than no proof. *Test:* confirm A, change to B,
assert unconfirmed.

**R5 — The pane claims a conflict it cannot know about.** *Test:* the copy is
pinned by literal, the way the Preferences honesty notes are.

**R6 — The callback fires for someone else's hotkey.** *Test:* the signature
check is a pure function over an `EventHotKeyID` and is tested directly.

---

## 10. Deliberately not in v1

- **Per-tab hotkeys.** The multi-registration design costs nothing to add —
  `HotKeyCenter` is already keyed by id — but four more combinations to choose
  without colliding multiplies a problem that cannot be detected.
- **Naming which system feature owns a combination.** No API reports it.
- **A global monitor fallback** when the hotkey does not fire. Apple documents
  that a global monitor cannot prevent normal delivery, so the keystroke would
  reach the frontmost app as well — and it is the permanently-installed monitor
  this whole module exists to avoid.
