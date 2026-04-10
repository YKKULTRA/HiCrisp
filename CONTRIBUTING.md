# Contributing

HiCrisp is a small macOS SwiftPM app built around private display APIs. Contributions are welcome, but changes should stay conservative and easy to test on real hardware.

## Setup

From the repository root:

```bash
swift build
```

To produce a runnable app bundle:

```bash
./build.sh
```

## Project Structure

- `Sources/App.swift`: app entry point
- `Sources/MenuBarView.swift`: menu bar UI and user actions
- `Sources/DisplayManager.swift`: physical display discovery and display mode inspection
- `Sources/VirtualDisplayManager.swift`: virtual display lifecycle, mirroring, and cleanup
- `Sources/CGVirtualDisplayAPI/include/CGVirtualDisplay.h`: private API declarations used by Swift

## Development Guidelines

- Keep behavior reversible within the current login session.
- Do not introduce changes that require patching system display override files.
- Prefer explicit failure messages over silent fallbacks.
- Assume private APIs can behave differently across macOS versions.
- Test with a real external display whenever you touch mirroring or mode-selection logic.

## Before Opening a PR

- Build the package with `swift build`.
- Build the app bundle with `./build.sh`.
- If you changed display logic, test both enable and disable flows on hardware.
- Document any macOS-version-specific behavior in the PR description.

## Scope That Fits This Repo

Good contributions:

- reliability improvements around virtual display setup and teardown
- better error reporting and troubleshooting output
- safer refresh-rate or display-selection logic
- menu bar UX improvements that do not hide failure states
- documentation and build ergonomics

Changes that need stronger justification:

- broad refactors without hardware-backed validation
- behavior that persists system-wide display changes
- assumptions that a private API is stable across all macOS releases

## Reporting Issues

When filing a bug, include:

- macOS version
- Mac model
- external monitor model
- connection type, if known
- selected resolution and refresh rate
- Console logs related to `VirtualDisplay`, if available
