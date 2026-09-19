# Launch at login — what the probe measured

`docs/ROADMAP.md` §1 asked two questions it said documentation could not
answer, and warned that a web search returns a confident wrong answer to the
first. Both are now measured. **Both came back the opposite of the fear**, and
the probe found a third thing nobody thought to ask about, which is the one
that changes the module's shape.

Measured on macOS 26, Apple Silicon, 2026-09-19, with a throwaway bundle —
`com.gcdz.creativenotch-smprobe`, **ad-hoc signed**, `LSUIElement`, built and
rebuilt by a script that rewrites a marker string to force a new code hash.
The probe calls `SMAppService.mainApp` and nothing else. It was unregistered
from every copy afterwards, and `sfltool dumpbtm` confirms the real app has
zero records.

## Q1. Does `register()` accept an ad-hoc signature?

**Yes.** No error, and the status moves straight to `enabled`.

```
status before:  notFound(3)
register:       OK
status after:   enabled(1)
```

The roadmap was right to distrust the search result. *"Ad hoc signing is not
sufficient for SMAppService operations"* is **false for `mainApp`**. It is a
generalisation of one reply about an embedded helper, whose identity must
match its container — a code path `mainApp` does not use. Design against
Apple's own text; it never says what *properly signed* means, and what it
actually requires here is a signature, not a trusted one.

**Consequence:** the module ships as a toggle, not as an explanation.

## Q2. Does a registration survive a different cdhash at the same path?

**Yes.** Registered under one hash, rebuilt in place under another, and the
record was untouched:

```
cdhash at registration:  8a965e534e9567adaf62c99bc638bf28ee5eb4ba
cdhash after rebuild:    bf2acd93841a4883ed667c23b5d1434f12ee9d67
status read by the new binary:  enabled(1)
```

**Background Task Management does not pin to the code hash the way TCC
does.** This is the important asymmetry for this project: the same ad-hoc
signature that revokes Accessibility on every rebuild, and re-prompts for the
camera on every update, costs a login item nothing.

So the entry in `ROADMAP.md` that grouped launch at login with Accessibility
and the camera under "the identity is the variable" was wrong about this one.
Three of the four rows in that table still hold; this row does not.

## Q3, which nobody asked: the record is keyed by bundle identifier, and
## **reading `.status` repoints it**

This is the finding with teeth, and it is a hazard specific to how this
project is developed.

`sfltool dumpbtm` shows one record per **bundle identifier**, carrying a URL:

```
Identifier:         2.com.gcdz.creativenotch-smprobe
Bundle Identifier:  com.gcdz.creativenotch-smprobe
URL:                file:///…/smprobe/SMProbe.app/
```

Two copies of the same bundle at different paths share that one record. And
the URL follows whichever copy last **touched** the service — where touching
it means reading `.status`, with no `register()` call anywhere:

| Step | URL in the record |
|---|---|
| `register()` from copy **A** | …/smprobe/**SMProbe.app** |
| `.status` read from copy **B**, nothing else | …/smprobe/**moved/SMProbe.app** |
| `.status` read from copy **A** again | …/smprobe/**SMProbe.app** |

Reproducible in both directions. A plain read is a write.

**Why that matters here and not in most apps.** This project is developed by
running `./Scripts/dev.sh`, which builds to `dist/CreativeNotch.app` — and
begins by `rm -rf`-ing it. A user with the released app in `/Applications`
and launch at login switched on would have their login item silently
repointed at `dist/` the moment a dev build's Settings window read its own
status. At the next login macOS would launch the dev build, or, after the
next `dev.sh`, nothing at all. Nothing would fail, nothing would be logged,
and the symptom — "it stopped launching at login" — would appear days later
with no connection to the cause.

The status read is not avoidable in general: the whole point of the toggle is
that it shows what the system actually thinks rather than what the user last
clicked. So the module has to decide **whether it is the copy entitled to
ask**, and that decision has to happen before the read. See the spec, §3.

## Q4. What the status values actually mean

The two "off" values are not interchangeable, and the difference is only
visible if you look:

| Value | When |
|---|---|
| `notFound(3)` | no record for this bundle identifier has ever existed |
| `notRegistered(0)` | a record exists and is disabled — including after `unregister()` |
| `enabled(1)` | registered |
| `requiresApproval(2)` | **not measured** — needs the user to deny it in System Settings |

`unregister()` leaves a tombstone rather than deleting the record:

```
Disposition: [disabled, allowed, notified] (0xa)
```

Which confirms, in passing, the roadmap's aside that *"a BTM record survives
deleting the app entirely"* — it survives as a **disabled** record. That is
why `status == .enabled` is the only safe test, and why the roadmap is right
that a status read is not evidence the app will actually launch.

## What is still not measured, and cannot be from here

**Whether the app actually launches after a real logout.** Every finding above
is about the *record*. None of them proves macOS starts an ad-hoc-signed,
non-notarised, quarantine-free app at login — only a logout and a `pgrep`
does, and that needs a human at the machine.

`Scripts/verify-login-item.sh` is that check, in a form that records the
before state rather than trusting anyone to remember it: `arm` before logging
out, `check` after logging back in, twice.

The risk of building the module before that is now small and one-directional:
if the launch itself turns out to be refused, the toggle is already reading
the real status, so it would show `enabled` while nothing started. That is the
one failure this module is built to make impossible, and it is the reason the
spec keeps the manual fallback text in the UI rather than behind a condition
(§5). **Run the logout check before believing the toggle.**

## Reproducing it

The probe is not kept. It was ~40 lines: `SMAppService.mainApp`, a
`register` / `unregister` / `status` command word, and a marker string the
build script rewrites to change the hash. Rebuild it from this document if
the question comes back — in particular, **re-measure Q3 on a new macOS
release**, because a repoint-on-read is much more likely to be a bug than a
contract.
