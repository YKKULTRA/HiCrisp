import CoreGraphics
import Foundation
import AppKit
import ColorSync
import CGVirtualDisplayAPI
import HiCrispSupport

/// Manages a virtual display + mirror setup to enable HiDPI on non-Retina monitors.
///
/// Creates a virtual display at 2x resolution with HiDPI=1, mirrors the physical
/// display onto it. macOS renders at 2x and downscales to the panel (exact 2:1 box filter).
/// No system files modified. Reverts when the app quits.
final class VirtualDisplayManager: ObservableObject {
    struct HiDPISession {
        let physicalDisplayID: CGDirectDisplayID
        let physicalDisplayName: String
        let virtualDisplayID: CGDirectDisplayID
        let targetWidth: Int
        let targetHeight: Int
        let refreshRate: Double
        let profileDescription: String
        let usesEstimatedPhysicalSize: Bool
    }

    @Published private(set) var activeSession: HiDPISession?
    @Published private(set) var lastError: String?

    private var virtualDisplay: CGVirtualDisplay?
    private var physicalDisplayID: CGDirectDisplayID = 0
    private var generation: Int = 0  // cancellation token for async work

    var isActive: Bool {
        activeSession != nil
    }

    func isActive(for displayID: CGDirectDisplayID) -> Bool {
        activeSession?.physicalDisplayID == displayID
    }

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
        lastError = nil

        // Increment generation AFTER cleanup to cancel any old in-flight async work
        generation += 1
        let currentGeneration = generation

        physicalDisplayID = physicalDisplay.id

        let pixelWidth = UInt32(targetWidth * 2)
        let pixelHeight = UInt32(targetHeight * 2)
        let profileAssignment = Self.bestProfileAssignment(for: physicalDisplay.id)

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
        let usesEstimatedPhysicalSize = physicalDisplay.physicalSizeMM.width <= 0 || physicalDisplay.physicalSizeMM.height <= 0
        let resolvedPhysicalSize = usesEstimatedPhysicalSize
            ? PhysicalSizeEstimator.fallbackSizeMM(nativeWidth: targetWidth, nativeHeight: targetHeight)
            : physicalDisplay.physicalSizeMM
        descriptor.sizeInMillimeters = resolvedPhysicalSize

        // Use neutral sRGB primaries at creation time, then immediately assign the
        // physical display's ICC profile when available once the virtual display is online.
        descriptor.redPrimary = CGPoint(x: 0.6400, y: 0.3300)
        descriptor.greenPrimary = CGPoint(x: 0.3000, y: 0.6000)
        descriptor.bluePrimary = CGPoint(x: 0.1500, y: 0.0600)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)

        descriptor.queue = DispatchQueue.global(qos: .userInteractive)
        descriptor.terminationHandler = { [weak self] in
            NSLog("[VirtualDisplay] Virtual display terminated by system")
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.lastError = "Virtual display was terminated by macOS"
                self.disableHiDPI(clearLastError: false)
            }
        }

        // --- Create virtual display ---
        guard let vDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            fail("Failed to create virtual display", completion: completion)
            return
        }

        let vDisplayID = vDisplay.displayID
        guard vDisplayID != 0 else {
            fail("Virtual display created with invalid ID", completion: completion)
            return
        }

        NSLog("[VirtualDisplay] Created ID=%u, backing=%ux%u, physSize=%.0fx%.0fmm",
              vDisplayID, pixelWidth, pixelHeight, resolvedPhysicalSize.width, resolvedPhysicalSize.height)

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
            fail("Failed to apply HiDPI settings", completion: completion)
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
                        self.fail("Virtual display not recognized by system", completion: completion)
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
                    self.fail("Failed to begin display configuration", completion: completion)
                }
                return
            }

            err = CGConfigureDisplayMirrorOfDisplay(cfg, physicalDisplay.id, vDisplayID)
            guard err == .success else {
                CGCancelDisplayConfiguration(cfg)
                DispatchQueue.main.async {
                    self.tearDown()
                    self.fail("Failed to configure mirroring (error \(err.rawValue))", completion: completion)
                }
                return
            }

            err = CGCompleteDisplayConfiguration(cfg, .forSession)
            guard err == .success else {
                DispatchQueue.main.async {
                    self.tearDown()
                    self.fail("Failed to complete display configuration (error \(err.rawValue))", completion: completion)
                }
                return
            }

            NSLog("[VirtualDisplay] Mirroring active: physical %u mirrors virtual %u", physicalDisplay.id, vDisplayID)

            // --- Post-setup: assign sRGB profile and verify ---
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard self.generation == currentGeneration else { return }

                // Match the physical display profile when possible to minimize conversion.
                Self.assignColorProfile(profileAssignment, to: vDisplayID)

                // Verify HiDPI is actually active via NSScreen
                let verified = DisplayManager.verifyHiDPIActive(displayID: vDisplayID)
                NSLog("[VirtualDisplay] backingScaleFactor verification: %@", verified ? "2.0x confirmed" : "NOT 2.0x")

                self.activeSession = HiDPISession(
                    physicalDisplayID: physicalDisplay.id,
                    physicalDisplayName: physicalDisplay.name,
                    virtualDisplayID: vDisplayID,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    refreshRate: refreshRate,
                    profileDescription: profileAssignment.description,
                    usesEstimatedPhysicalSize: usesEstimatedPhysicalSize
                )
                self.lastError = nil

                let suffix = verified ? "" : " (warning: backingScaleFactor != 2.0)"
                self.complete(
                    true,
                    "HiDPI enabled on \(physicalDisplay.name) at \(targetWidth)x\(targetHeight) @ \(RefreshRateSupport.label(for: refreshRate))\(suffix)",
                    completion: completion
                )
            }
        }
    }

    // MARK: - Disable HiDPI

    func disableHiDPI(clearLastError: Bool = true) {
        generation += 1
        if clearLastError {
            lastError = nil
        }
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
        activeSession = nil
    }

    deinit {
        tearDown()
    }

    // MARK: - Helpers

    private func isDisplayOnline(_ displayID: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &onlineDisplays, &count)
        return (0..<Int(count)).contains { onlineDisplays[$0] == displayID }
    }

    private struct ProfileAssignment {
        let url: CFURL
        let description: String
    }

    private func fail(_ message: String, completion: @escaping (Bool, String) -> Void) {
        lastError = message
        complete(false, message, completion: completion)
    }

    private func complete(
        _ success: Bool,
        _ message: String,
        completion: @escaping (Bool, String) -> Void
    ) {
        DispatchQueue.main.async {
            completion(success, message)
        }
    }

    private static func bestProfileAssignment(for physicalDisplayID: CGDirectDisplayID) -> ProfileAssignment {
        // Matching the physical display's profile directly looked attractive,
        // but it crashes on some systems during profile handoff. Use a safe
        // system sRGB profile until that path can be reintroduced reliably.
        let srgbProfilePath = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
        let profileURL = URL(fileURLWithPath: srgbProfilePath) as CFURL
        return ProfileAssignment(url: profileURL, description: "sRGB IEC61966-2.1")
    }

    /// Assign the chosen ICC profile to the virtual display.
    private static func assignColorProfile(_ profile: ProfileAssignment, to displayID: CGDirectDisplayID) {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(UInt32(displayID))?.takeRetainedValue() else {
            NSLog("[VirtualDisplay] Could not get UUID for display %u", displayID)
            return
        }

        guard let defaultProfileKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue(),
              let userScopeKey = kColorSyncProfileUserScope?.takeUnretainedValue(),
              let displayClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue() else {
            NSLog("[VirtualDisplay] ColorSync constants unavailable")
            return
        }

        let profileInfo: [CFString: Any] = [
            defaultProfileKey: profile.url,
            userScopeKey: kCFPreferencesCurrentUser as Any,
        ]

        let success = ColorSyncDeviceSetCustomProfiles(
            displayClass,
            uuid,
            profileInfo as CFDictionary
        )

        NSLog("[VirtualDisplay] Profile assignment (%@): %@", profile.description, success ? "success" : "failed")
    }
}
