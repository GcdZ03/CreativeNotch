# CreativeNotch

A macOS notch utility — media controls, a file shelf, clipboard history, and
system HUD replacement, surfaced in the MacBook notch.

Built around one constraint the existing apps in this category get wrong:
**no subsystem is allowed to run when it isn't needed.** Polling is centrally
gated on system activity rather than trusted to each module.

## Status

🚧 Design phase — see [`docs/specs/`](docs/specs/).

## Requirements

- macOS 26+
- Xcode 26+

## License

Private project.
