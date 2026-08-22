# Security

## Reporting

Report vulnerabilities privately through GitHub's
[security advisories](https://github.com/GcdZ03/CreativeNotch/security/advisories/new)
rather than as a public issue.

## Supported versions

The latest release only. This is a personal project with no backport policy.

## What this app can do on your machine

Worth knowing before you install anything that asks for Accessibility:

- **It is not sandboxed.** A private framework and a `perl` subprocess (both
  planned for the media module) make sandboxing impractical.
- **It requests Accessibility access**, which is a powerful permission. It is
  used for exactly two things: global key events, so the HUD can show volume
  and brightness; and drag detection, so the file shelf can open as a drop
  target. Both are optional — the app runs without granting it.
- **It is ad-hoc signed, not notarised.** Apple has not reviewed it. The
  installer works precisely because `curl` avoids the quarantine flag that
  would otherwise make Gatekeeper block it. Read
  [`Scripts/install.sh`](Scripts/install.sh) before piping it to your shell.
- **Clipboard history, once built, will be in memory only** and cleared on
  quit, and will skip anything marked `org.nspasteboard.ConcealedType` — the
  convention password managers use. Nothing you copy is written to disk or
  leaves your machine.
- **No telemetry, no network calls, no analytics.** The app makes no outbound
  connections at all. The only network activity in this project is the
  installer fetching a release from GitHub.

## Verifying a release

Every release ships a SHA-256 checksum:

```bash
shasum -a 256 -c CreativeNotch-v0.2.0.tar.gz.sha256
codesign --verify --deep --strict CreativeNotch.app
```

Releases are built by GitHub Actions from a tagged commit — never uploaded by
hand — and the workflow fails if a team identifier ever appears in the
signature.
