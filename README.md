# HiCrisp

HiCrisp is a macOS menu bar app that enables HiDPI-style 2x rendering on external displays that normally only expose standard scaling modes.

It does this without patching system files. Instead, it creates a virtual display with Apple's private `CGVirtualDisplay` API, mirrors your physical monitor to that display, and lets macOS render the desktop at 2x before downscaling it back to the panel.

## What It Does

- Runs as a lightweight menu bar app.
- Detects connected displays and focuses on external monitors.
- Offers one-click HiDPI enable/disable for the selected external display.
- Preserves the monitor's physical size data so UI scale and font rendering stay sensible.
- Lets you choose the refresh rate exposed to the virtual display.
- Reverts cleanly when disabled or when the app exits.

## How It Works

At a high level, HiCrisp:

1. Reads the physical display's native resolution, available refresh rates, and EDID-reported physical size.
2. Creates a virtual display at 2x the target resolution.
3. Applies two modes to that virtual display: the backing resolution and the logical HiDPI resolution.
4. Configures the physical monitor to mirror the virtual display.
5. Lets macOS render UI and text at 2x scale, which produces sharper output on many non-Retina panels.

This approach is session-based. No display override files are written, and no permanent system configuration is modified.

## Why HiCrisp?

Most external monitors on macOS either:
- look blurry at native scaling, or
- waste space with built-in HiDPI modes.

HiCrisp forces proper 2x rendering on displays that don’t officially support it without patching system files.
For example, on a 2560×1440 monitor:

- Virtual display: 5120×2880
- Logical (HiDPI): 2560×1440 (2x scaling)
- Result: sharper text and UI, similar layout size

## Requirements

- macOS 13 or newer
- An external monitor connected to the Mac
- Xcode command line tools or a Swift toolchain if building from source

## Important Caveats

- HiCrisp uses private Apple APIs (`CGVirtualDisplay`). That means it may break on future macOS releases.
- This is not App Store-compatible.
- Current implementation manages one virtual-display HiDPI session at a time.
- If macOS rejects the virtual display or mirroring operation, HiDPI will not activate.
- Color/profile handling is tuned for sRGB-like displays and may not be ideal for every panel.

 ## Is This For You?

Works best if you:
- use a non-Retina external monitor (1080p/1440p/ultrawide)
- care about text sharpness over raw performance
- are comfortable running experimental macOS utilities

Not ideal if you:
- rely on color-critical workflows
- need guaranteed stability across macOS updates

## Build

Build the app bundle from the repo root:

```bash
./build.sh
```

That script:

- builds the Swift package in release mode
- creates `HiCrisp.app`
- writes a minimal `Info.plist`
- applies ad-hoc signing

You can also build the executable directly:

```bash
swift build -c release
```

## Run

After building:

```bash
open HiCrisp.app
```

To install it locally:

```bash
cp -r HiCrisp.app /Applications/
```

## Repo Layout

```text
Sources/
  App.swift                   App entry point and menu bar scene
  MenuBarView.swift           SwiftUI menu bar interface
  DisplayManager.swift        Physical display discovery and mode inspection
  VirtualDisplayManager.swift Virtual display creation and mirroring logic
  CGVirtualDisplayAPI/        Private API headers bridged into SwiftPM
Package.swift                 Swift package definition
build.sh                      Release build + app bundle packaging
```

## Development Notes

- The app is packaged as a Swift executable target rather than an Xcode project.
- `CGVirtualDisplayAPI` is bridged through a local C target so Swift can access the private Objective-C interfaces.
- The package links against `/System/Library/PrivateFrameworks` via unsafe linker flags.

See [CONTRIBUTING.md](CONTRIBUTING.md) for local development and contribution notes.

## Troubleshooting

### The app builds but HiDPI does not activate

- Confirm the external display is connected and detected by macOS.
- Try a different refresh rate from the menu.
- Disable and re-enable the session after the monitor finishes reconnecting.
- Check Console.app for `VirtualDisplay` log lines.

### macOS says the app is damaged or blocks launch

Ad-hoc signing is enough for local builds, but downloaded artifacts may still carry quarantine attributes. If needed:

```bash
xattr -dr com.apple.quarantine HiCrisp.app
```

### The display layout looks wrong after disabling

Turn HiDPI off from the menu first. If the display arrangement still looks stale, disconnect and reconnect the external monitor or reopen macOS Display Settings.

## Status

This project is best treated as an experimental utility for local use on supported macOS versions, not as a stable product surface.
