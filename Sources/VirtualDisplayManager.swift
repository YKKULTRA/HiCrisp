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
///
/// All state, including the `generation` cancellation token, is only touched on the main queue.
final class VirtualDisplayManager: ObservableObject {
    enum ProfileStrategy: Equatable {
        case srgb
        case matchPhysicalDisplay
    }

    struct HiDPISession {
        let physicalDisplayID: CGDirectDisplayID
        let physicalDisplayName: String
        let virtualDisplayID: CGDirectDisplayID
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
    private var terminationObserver: NSObjectProtocol?

    var isActive: Bool {
        activeSession != nil
    }

    func isActive(for displayID: CGDirectDisplayID) -> Bool {
        activeSession?.physicalDisplayID == displayID
    }

    init() {
        // Revert explicitly on quit instead of relying on process exit to drop the mirror.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.disableHiDPI()
        }
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
        // Covers both an active session and an attempt that is still setting up.
        let previousVirtualDisplayID = virtualDisplay?.displayID

        // Invalidate in-flight work, then tear down any existing session before starting a new one.
        generation += 1
        let currentGeneration = generation
        tearDown()
        lastError = nil

        // macOS keeps a released virtual display registered briefly, and recreating it before then fails.
        poll(timeout: 4.0, generation: currentGeneration, until: {
            previousVirtualDisplayID.map { !Self.isDisplayOnline($0) } ?? true
        }) { [weak self] terminated in
            guard let self else { return }

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
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
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
        // Mirror the monitor's own model and serial so each monitor gets a distinct, stable virtual
        // display identity, and macOS keeps separate per-display settings for each.
        descriptor.productID = physicalDisplay.productID
        descriptor.serialNum = CGDisplaySerialNumber(physicalDisplay.id)
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
            failAndTearDown("Virtual display created with invalid ID", completion: completion)
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
            failAndTearDown("Failed to apply HiDPI settings", completion: completion)
            return
        }

        virtualDisplay = vDisplay

        let session = HiDPISession(
            physicalDisplayID: physicalDisplay.id,
            physicalDisplayName: physicalDisplay.name,
            virtualDisplayID: vDisplayID,
            profileDescription: profileAssignment.description,
            usesEstimatedPhysicalSize: usesEstimatedPhysicalSize,
            usedFallbackProfile: profileAssignment.usedFallback
        )
        let profileSuffix = profileAssignment.usedFallback ? " using fallback sRGB profile" : ""
        let successMessage = "HiDPI enabled on \(physicalDisplay.name) at \(targetWidth)x\(targetHeight) @ \(RefreshRateSupport.label(for: refreshRate))\(profileSuffix)"

        // Give macOS time to register the new display, then allow it one more second to appear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }

            self.poll(timeout: 1.0, generation: currentGeneration, until: {
                Self.isDisplayOnline(vDisplayID)
            }) { online in
                guard online else {
                    self.failAndTearDown("Virtual display not recognized by system", completion: completion)
                    return
                }

                self.mirror(
                    session,
                    profile: profileAssignment,
                    successMessage: successMessage,
                    currentGeneration: currentGeneration,
                    completion: completion
                )
            }
        }
    }

    private func mirror(
        _ session: HiDPISession,
        profile: ProfileAssignment,
        successMessage: String,
        currentGeneration: Int,
        completion: @escaping (Bool, String) -> Void
    ) {
        physicalDisplayID = session.physicalDisplayID

        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success, let cfg = config else {
            failAndTearDown("Failed to begin display configuration", completion: completion)
            return
        }

        err = CGConfigureDisplayMirrorOfDisplay(cfg, session.physicalDisplayID, session.virtualDisplayID)
        guard err == .success else {
            CGCancelDisplayConfiguration(cfg)
            failAndTearDown("Failed to configure mirroring (error \(err.rawValue))", completion: completion)
            return
        }

        err = CGCompleteDisplayConfiguration(cfg, .forSession)
        guard err == .success else {
            failAndTearDown("Failed to complete display configuration (error \(err.rawValue))", completion: completion)
            return
        }

        NSLog("[VirtualDisplay] Mirroring active: physical %u mirrors virtual %u",
              session.physicalDisplayID, session.virtualDisplayID)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }

            Self.assignColorProfile(profile, to: session.virtualDisplayID)
            self.poll(timeout: 2.5, generation: currentGeneration, until: {
                DisplayManager.backingScale(for: session.virtualDisplayID) == 2.0
            }) { verified in
                let scale = DisplayManager.backingScale(for: session.virtualDisplayID)
                NSLog("[VirtualDisplay] backingScaleFactor verification: %@ (%.2f)",
                      verified ? "2.0x confirmed" : "NOT 2.0x", Double(scale ?? 0))

                guard verified else {
                    let detail = scale.map { String(format: "macOS reported a %.2fx backing scale instead of 2x.", Double($0)) }
                        ?? "macOS did not expose the virtual display as a screen."
                    self.failAndTearDown("HiDPI verification failed. \(detail)", completion: completion)
                    return
                }

                self.activeSession = session
                self.lastError = nil
                completion(true, successMessage)
            }
        }
    }

    private static func isDisplayOnline(_ displayID: CGDirectDisplayID) -> Bool {
        DisplayManager.onlineDisplayIDs().contains(displayID)
    }

    /// Checks `condition` on the main queue every 0.2s until it holds or `timeout` passes.
    /// Stops without calling `completion` once `generation` is superseded.
    private func poll(
        timeout: TimeInterval,
        generation: Int,
        until condition: @escaping () -> Bool,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        func check() {
            guard self.generation == generation else { return }

            if condition() {
                completion(true)
            } else if Date() >= deadline {
                completion(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check)
            }
        }

        check()
    }

    private struct ProfileAssignment {
        let url: CFURL
        let description: String
        let usedFallback: Bool
    }

    private func fail(_ message: String, completion: (Bool, String) -> Void) {
        lastError = message
        completion(false, message)
    }

    /// Ends the current attempt: ignores its pending callbacks and releases what it created.
    private func failAndTearDown(_ message: String, completion: (Bool, String) -> Void) {
        generation += 1
        tearDown()
        fail(message, completion: completion)
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
