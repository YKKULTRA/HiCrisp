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
    enum ProfileStrategy: Equatable {
        case srgb
        case matchPhysicalDisplay
    }

    struct HiDPISession {
        let physicalDisplayID: CGDirectDisplayID
        let physicalDisplayName: String
        let virtualDisplayID: CGDirectDisplayID
        let targetWidth: Int
        let targetHeight: Int
        let refreshRate: Double
        let profileDescription: String
        let usesEstimatedPhysicalSize: Bool
        let usedFallbackProfile: Bool
    }

    /// Vendor ID used for HiCrisp virtual displays, so the UI can filter them out.
    static let virtualVendorID: UInt32 = 0xF0F0

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
        preferPhysicalColorProfile: Bool,
        completion: @escaping (Bool, String) -> Void
    ) {
        let previousVirtualDisplayID = activeSession?.virtualDisplayID

        // Tear down any existing session before starting a new one.
        tearDown()
        lastError = nil

        generation += 1
        let currentGeneration = generation

        waitForDisplayToTerminate(previousVirtualDisplayID, generation: currentGeneration) { [weak self] terminated in
            guard let self, self.generation == currentGeneration else { return }

            guard terminated else {
                self.fail(
                    "Previous virtual display is still registered with macOS. Wait a moment and try again.",
                    completion: completion
                )
                return
            }

            self.startHiDPISession(
                physicalDisplay: physicalDisplay,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                refreshRate: refreshRate,
                preferPhysicalColorProfile: preferPhysicalColorProfile,
                currentGeneration: currentGeneration,
                completion: completion
            )
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

    private func startHiDPISession(
        physicalDisplay: DisplayInfo,
        targetWidth: Int,
        targetHeight: Int,
        refreshRate: Double,
        preferPhysicalColorProfile: Bool,
        currentGeneration: Int,
        completion: @escaping (Bool, String) -> Void
    ) {
        physicalDisplayID = physicalDisplay.id

        let pixelWidth = UInt32(targetWidth * 2)
        let pixelHeight = UInt32(targetHeight * 2)
        let profileStrategy: ProfileStrategy = preferPhysicalColorProfile ? .matchPhysicalDisplay : .srgb
        let profileAssignment = Self.bestProfileAssignment(
            for: physicalDisplay.id,
            strategy: profileStrategy
        )

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "\(physicalDisplay.name) HiDPI"
        descriptor.vendorID = Self.virtualVendorID
        descriptor.productID = 0x1234
        descriptor.serialNum = 0x0001
        descriptor.maxPixelsWide = pixelWidth
        descriptor.maxPixelsHigh = pixelHeight

        let usesEstimatedPhysicalSize = physicalDisplay.physicalSizeMM.width <= 0 || physicalDisplay.physicalSizeMM.height <= 0
        let resolvedPhysicalSize = usesEstimatedPhysicalSize
            ? PhysicalSizeEstimator.fallbackSizeMM(nativeWidth: targetWidth, nativeHeight: targetHeight)
            : physicalDisplay.physicalSizeMM
        descriptor.sizeInMillimeters = resolvedPhysicalSize

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

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: pixelWidth, height: pixelHeight, refreshRate: refreshRate),
            CGVirtualDisplayMode(width: UInt32(targetWidth), height: UInt32(targetHeight), refreshRate: refreshRate),
        ]

        guard vDisplay.apply(settings) else {
            fail("Failed to apply HiDPI settings", completion: completion)
            return
        }

        virtualDisplay = vDisplay

        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, self.generation == currentGeneration else { return }

            if !self.isDisplayOnline(vDisplayID) {
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

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard self.generation == currentGeneration else { return }

                Self.assignColorProfile(profileAssignment, to: vDisplayID)
                self.waitForHiDPIActivation(displayID: vDisplayID, generation: currentGeneration) { verified in
                    guard self.generation == currentGeneration else { return }

                    NSLog("[VirtualDisplay] backingScaleFactor verification: %@", verified ? "2.0x confirmed" : "NOT 2.0x")

                    guard verified else {
                        self.tearDown()
                        self.fail(
                            "HiDPI verification failed. macOS did not switch the session to true 2x backing scale.",
                            completion: completion
                        )
                        return
                    }

                    self.activeSession = HiDPISession(
                        physicalDisplayID: physicalDisplay.id,
                        physicalDisplayName: physicalDisplay.name,
                        virtualDisplayID: vDisplayID,
                        targetWidth: targetWidth,
                        targetHeight: targetHeight,
                        refreshRate: refreshRate,
                        profileDescription: profileAssignment.description,
                        usesEstimatedPhysicalSize: usesEstimatedPhysicalSize,
                        usedFallbackProfile: profileAssignment.usedFallback
                    )
                    self.lastError = nil

                    let profileSuffix = profileAssignment.usedFallback ? " using fallback sRGB profile" : ""
                    self.complete(
                        true,
                        "HiDPI enabled on \(physicalDisplay.name) at \(targetWidth)x\(targetHeight) @ \(RefreshRateSupport.label(for: refreshRate))\(profileSuffix)",
                        completion: completion
                    )
                }
            }
        }
    }

    private func isDisplayOnline(_ displayID: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &onlineDisplays, &count)
        return (0..<Int(count)).contains { onlineDisplays[$0] == displayID }
    }

    private func waitForDisplayToTerminate(
        _ displayID: CGDirectDisplayID?,
        generation: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard let displayID, displayID != 0 else {
            completion(true)
            return
        }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }

            let deadline = Date().addingTimeInterval(4.0)
            while self.generation == generation && Date() < deadline {
                if !self.isDisplayOnline(displayID) {
                    DispatchQueue.main.async {
                        completion(true)
                    }
                    return
                }

                Thread.sleep(forTimeInterval: 0.2)
            }

            DispatchQueue.main.async {
                completion(!self.isDisplayOnline(displayID))
            }
        }
    }

    private func waitForHiDPIActivation(
        displayID: CGDirectDisplayID,
        generation: Int,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }

            let deadline = Date().addingTimeInterval(2.5)
            while self.generation == generation && Date() < deadline {
                if DisplayManager.verifyHiDPIActive(displayID: displayID) {
                    DispatchQueue.main.async {
                        completion(true)
                    }
                    return
                }

                Thread.sleep(forTimeInterval: 0.2)
            }

            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    private struct ProfileAssignment {
        let url: CFURL
        let description: String
        let usedFallback: Bool
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

    private static func bestProfileAssignment(
        for physicalDisplayID: CGDirectDisplayID,
        strategy: ProfileStrategy
    ) -> ProfileAssignment {
        if strategy == .matchPhysicalDisplay,
           let assignment = physicalProfileAssignment(for: physicalDisplayID) {
            NSLog("[VirtualDisplay] Using physical display ICC profile: %@", assignment.description)
            return assignment
        }

        if strategy == .matchPhysicalDisplay {
            NSLog("[VirtualDisplay] Physical profile lookup failed, falling back to sRGB")
        }

        let srgbProfilePath = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
        let profileURL = URL(fileURLWithPath: srgbProfilePath) as CFURL
        return ProfileAssignment(
            url: profileURL,
            description: "sRGB IEC61966-2.1",
            usedFallback: strategy == .matchPhysicalDisplay
        )
    }

    private static func physicalProfileAssignment(for physicalDisplayID: CGDirectDisplayID) -> ProfileAssignment? {
        guard let unmanagedProfile = ColorSyncProfileCreateWithDisplayID(physicalDisplayID) else {
            NSLog("[VirtualDisplay] No ColorSync profile found for display %u", physicalDisplayID)
            return nil
        }

        let profile = unmanagedProfile.takeRetainedValue()
        guard let unmanagedProfileURL = ColorSyncProfileGetURL(profile, nil) else {
            NSLog("[VirtualDisplay] ColorSync profile has no URL for display %u", physicalDisplayID)
            return nil
        }

        let profileURL = unmanagedProfileURL.takeUnretainedValue()
        let description = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?

        return ProfileAssignment(
            url: profileURL,
            description: description ?? "Matched physical display profile",
            usedFallback: false
        )
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
