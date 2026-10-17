# Security

## Reporting

Report vulnerabilities privately through GitHub's
[security advisories](https://github.com/GcdZ03/CreativeNotch/security/advisories/new)
rather than as a public issue.

## Supported versions

The latest release only. This is a personal project with no backport policy.

## What this app can do on your machine

Worth knowing before you install it:

- **It is not sandboxed.** Private frameworks and a `perl` subprocess make
  sandboxing impractical. The private frameworks are MediaRemote, read
  through the system's own `perl` so the notch can show what is playing, and
  the window server's SkyLight functions, so the notch stays still while
  Spaces switch. Both are looked up at runtime; neither needs a permission.
- **It asks for one permission, and only when you use it:** the camera, the
  first time the camera tab runs. Nothing is requested at launch, and it does
  not ask for Accessibility. Drags onto the shelf arrive through AppKit's own
  drag events, the global shortcut goes through the window server, and the
  trackpad swipes are scroll events already delivered to the notch's own
  window — no global event monitor.
- **It is ad-hoc signed, not notarised.** Apple has not reviewed it. The
  installer works precisely because `curl` avoids the quarantine flag that
  would otherwise make Gatekeeper block it. Read
  [`Scripts/install.sh`](Scripts/install.sh) before piping it to your shell.
- **Clipboard history is in memory only** and cleared on quit, and it skips
  anything marked `org.nspasteboard.ConcealedType` — the convention password
  managers use — before reading any content. Nothing you copy is written to
  disk or leaves your machine.
- **AirDrop from the shelf** hands the file to macOS's own AirDrop service;
  the app has no networking of its own for it.
- **No telemetry, no network calls, no analytics.** The app makes no outbound
  connections at all. The only network activity in this project is the
  installer fetching a release from GitHub.

## Verifying a release

Every release ships a SHA-256 checksum:

```bash
shasum -a 256 -c CreativeNotch-vX.Y.Z.tar.gz.sha256   # the version you downloaded
codesign --verify --deep --strict CreativeNotch.app
```

Releases are built by GitHub Actions from a tagged commit — never uploaded by
hand — and the workflow fails if a team identifier ever appears in the
signature.
