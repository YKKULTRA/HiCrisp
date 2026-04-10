import CoreGraphics
import Foundation
import AppKit
import CGVirtualDisplayAPI

/// Manages a virtual display + mirror setup to enable HiDPI on non-Retina monitors.
///
/// Creates a virtual display at 2x resolution with HiDPI=1, mirrors the physical
/// display onto it. macOS renders at 2x and downscales to the panel (exact 2:1 box filter).
/// No system files modified. Reverts when the app quits.
final class VirtualDisplayManager: ObservableObject {

    @Published var isActive = false
    @Published var lastError: String?

    private var virtualDisplay: CGVirtualDisplay?
    private var physicalDisplayID: CGDirectDisplayID = 0
    private var generation: Int = 0  // cancellation token for async work

    // MARK: - Enable HiDPI

    func enableHiDPI(
        physicalDisplay: DisplayInfo,
        targetWidth: Int,
        targetHeight: Int,
        refreshRate: Double,
        completion: @escaping (Bool, String) -> Void
    ) {
        // Clean up existing virtual display (without touching generation)
        tearDown()

        // Increment generation AFTER cleanup to cancel any old in-flight async work
        generation += 1
        let currentGeneration = generation

        physicalDisplayID = physicalDisplay.id

        let pixelWidth = UInt32(targetWidth * 2)
        let pixelHeight = UInt32(targetHeight * 2)

        // --- Create virtual display descriptor ---
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "\(physicalDisplay.name) HiDPI"
        descriptor.vendorID = 0xF0F0
        descriptor.productID = 0x1234
        descriptor.serialNum = 0x0001
        descriptor.maxPixelsWide = pixelWidth
        descriptor.maxPixelsHigh = pixelHeight

        // Use the ACTUAL physical monitor dimensions from EDID for correct DPI calculation.
        // This ensures macOS font rendering and UI sizing match what you see on screen.
        let physSize = physicalDisplay.physicalSizeMM
        if physSize.width > 0 && physSize.height > 0 {
            descriptor.sizeInMillimeters = physSize
        } else {
            // Fallback: approximate 27" 16:9
            descriptor.sizeInMillimeters = CGSize(width: 597, height: 336)
        }

        // sRGB IEC 61966-2-1 color primaries with D65 white point.
        // These match the Samsung LC27RG50's gamut (101.5% sRGB).
        // Using standard sRGB avoids unnecessary color space conversion during mirroring,
        // since the physical display's profile is also sRGB-like.
        descriptor.redPrimary = CGPoint(x: 0.6400, y: 0.3300)
        descriptor.greenPrimary = CGPoint(x: 0.3000, y: 0.6000)
        descriptor.bluePrimary = CGPoint(x: 0.1500, y: 0.0600)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)

        descriptor.queue = DispatchQueue.global(qos: .userInteractive)
        descriptor.terminationHandler = {
            NSLog("[VirtualDisplay] Virtual display terminated by system")
        }

        // --- Create virtual display ---
        guard let vDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            completion(false, "Failed to create virtual display")
            return
        }

        let vDisplayID = vDisplay.displayID
        guard vDisplayID != 0 else {
            completion(false, "Virtual display created with invalid ID")
            return
        }

        NSLog("[VirtualDisplay] Created ID=%u, backing=%ux%u, physSize=%.0fx%.0fmm",
              vDisplayID, pixelWidth, pixelHeight, physSize.width, physSize.height)

        // --- Apply HiDPI settings with two modes ---
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            // Full 2x backing mode (e.g. 3840x2160)
            CGVirtualDisplayMode(width: pixelWidth, height: pixelHeight, refreshRate: refreshRate),
            // Logical resolution mode (e.g. 1920x1080) - macOS shows this as "HiDPI"
            CGVirtualDisplayMode(width: UInt32(targetWidth), height: UInt32(targetHeight), refreshRate: refreshRate),
        ]

        guard vDisplay.apply(settings) else {
            completion(false, "Failed to apply HiDPI settings")
            return
        }

        virtualDisplay = vDisplay

        // --- Wait for system to register, then configure mirroring ---
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, self.generation == currentGeneration else { return }

            // Verify virtual display is online
            if !self.isDisplayOnline(vDisplayID) {
                // Retry once after additional delay
                Thread.sleep(forTimeInterval: 1.0)
                guard self.generation == currentGeneration else { return }
                if !self.isDisplayOnline(vDisplayID) {
                    DispatchQueue.main.async {
                        self.tearDown()
                        completion(false, "Virtual display not recognized by system")
                    }
                    return
                }
            }

            // Configure mirroring: physical display mirrors virtual (virtual is master)
            // This is the ONLY correct direction for HiDPI.
            // CGConfigureDisplayMirrorOfDisplay(cfg, slave, master)
            //   slave = physical display (becomes a mirror)
            //   master = virtual display (source of HiDPI content)
            var config: CGDisplayConfigRef?
            var err = CGBeginDisplayConfiguration(&config)
            guard err == .success, let cfg = config else {
                DispatchQueue.main.async {
                    self.tearDown()
                    completion(false, "Failed to begin display configuration")
                }
                return
            }

            err = CGConfigureDisplayMirrorOfDisplay(cfg, physicalDisplay.id, vDisplayID)
            guard err == .success else {
                CGCancelDisplayConfiguration(cfg)
                DispatchQueue.main.async {
                    self.tearDown()
                    completion(false, "Failed to configure mirroring (error \(err.rawValue))")
                }
                return
            }

            err = CGCompleteDisplayConfiguration(cfg, .forSession)
            guard err == .success else {
                DispatchQueue.main.async {
                    self.tearDown()
                    completion(false, "Failed to complete display configuration (error \(err.rawValue))")
                }
                return
            }

            NSLog("[VirtualDisplay] Mirroring active: physical %u mirrors virtual %u", physicalDisplay.id, vDisplayID)

            // --- Post-setup: assign sRGB profile and verify ---
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard self.generation == currentGeneration else { return }

                // Assign sRGB ICC profile to virtual display to minimize color conversion
                Self.assignSRGBProfile(to: vDisplayID)

                // Verify HiDPI is actually active via NSScreen
                let verified = DisplayManager.verifyHiDPIActive(displayID: vDisplayID)
                NSLog("[VirtualDisplay] backingScaleFactor verification: %@", verified ? "2.0x confirmed" : "NOT 2.0x")

                self.isActive = true
                self.lastError = nil

                let suffix = verified ? "" : " (warning: backingScaleFactor != 2.0)"
                completion(true, "HiDPI enabled at \(targetWidth)x\(targetHeight) @ \(Int(refreshRate))Hz\(suffix)")
            }
        }
    }

    // MARK: - Disable HiDPI

    func disableHiDPI() {
        generation += 1
        tearDown()
    }

    private func tearDown() {
        if physicalDisplayID != 0 {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let cfg = config {
                CGConfigureDisplayMirrorOfDisplay(cfg, physicalDisplayID, kCGNullDirectDisplay)
                CGCompleteDisplayConfiguration(cfg, .forSession)
            }
        }

        virtualDisplay = nil
        physicalDisplayID = 0
        isActive = false
    }

    deinit {
        tearDown()
    }

    // MARK: - Helpers

    private func isDisplayOnline(_ displayID: CGDirectDisplayID) -> Bool {
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &onlineDisplays, &count)
        return (0..<Int(count)).contains { onlineDisplays[$0] == displayID }
    }

    /// Assign the system sRGB ICC profile to the virtual display.
    /// This ensures minimal color space conversion overhead when mirroring
    /// to a real sRGB monitor, preserving sharpness and color accuracy.
    private static func assignSRGBProfile(to displayID: CGDirectDisplayID) {
        let srgbProfilePath = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
        guard FileManager.default.fileExists(atPath: srgbProfilePath) else {
            NSLog("[VirtualDisplay] sRGB profile not found at expected path")
            return
        }

        guard let uuid = CGDisplayCreateUUIDFromDisplayID(UInt32(displayID))?.takeRetainedValue() else {
            NSLog("[VirtualDisplay] Could not get UUID for display %u", displayID)
            return
        }

        let profileURL = URL(fileURLWithPath: srgbProfilePath) as CFURL

        guard let defaultProfileKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue(),
              let userScopeKey = kColorSyncProfileUserScope?.takeUnretainedValue(),
              let displayClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue() else {
            NSLog("[VirtualDisplay] ColorSync constants unavailable")
            return
        }

        let profileInfo: [CFString: Any] = [
            defaultProfileKey: profileURL,
            userScopeKey: kCFPreferencesCurrentUser as Any,
        ]

        let success = ColorSyncDeviceSetCustomProfiles(
            displayClass,
            uuid,
            profileInfo as CFDictionary
        )

        NSLog("[VirtualDisplay] sRGB profile assignment: %@", success ? "success" : "failed")
    }
}
