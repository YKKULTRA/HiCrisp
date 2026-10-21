import CoreGraphics
import Foundation
import IOKit
import AppKit
import HiCrispSupport

// MARK: - Display Mode

struct DisplayMode {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    init(_ mode: CGDisplayMode) {
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
    }

    var isHiDPI: Bool { pixelWidth > width }

    var label: String {
        let hidpi = isHiDPI ? " HiDPI" : ""
        let hz = refreshRate > 0 ? " @ \(RefreshRateSupport.label(for: refreshRate))" : ""
        return "\(width)x\(height)\(hz)\(hidpi)"
    }
}

// MARK: - Display Info

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let vendorID: UInt32
    let productID: UInt32
    let isBuiltIn: Bool
    let nativeWidth: Int
    let nativeHeight: Int
    let physicalSizeMM: CGSize  // actual physical dimensions from EDID
    let modes: [DisplayMode]
    let currentMode: DisplayMode?

    var storageKey: String {
        DisplayIdentity.storageKey(vendorID: vendorID, productID: productID)
    }

    var availableRefreshRates: [Double] {
        let rates = modes.filter { !$0.isHiDPI && $0.width == nativeWidth && $0.height == nativeHeight }
            .map { $0.refreshRate }
        return RefreshRateSupport.normalizedRates(rates)
    }
}

// MARK: - Display Manager

final class DisplayManager: ObservableObject {
    @Published var displays: [DisplayInfo] = []

    /// Names seen while a display was an NSScreen, kept for when it is mirrored and is not.
    private var nameCache: [CGDirectDisplayID: String] = [:]
    private var screenObserver: NSObjectProtocol?

    init() {
        let error = CGDisplayRegisterReconfigurationCallback(
            Self.handleDisplayReconfiguration,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if error != .success {
            NSLog("[DisplayManager] Failed to register display callback: %d", error.rawValue)
        }

        // NSScreen catches up after CoreGraphics reports a change, so refresh again for names.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        refresh()
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(
            Self.handleDisplayReconfiguration,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func refresh() {
        displays = Self.onlineDisplayIDs().map { makeDisplayInfo(for: $0) }
    }

    /// Every online display, including ones mirroring another. Empty if CoreGraphics fails.
    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var error = CGGetOnlineDisplayList(0, nil, &count)
        guard error == .success else {
            NSLog("[DisplayManager] Failed to count online displays: %d", error.rawValue)
            return []
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        error = CGGetOnlineDisplayList(count, &displayIDs, &count)
        guard error == .success else {
            NSLog("[DisplayManager] Failed to list online displays: %d", error.rawValue)
            return []
        }

        return Array(displayIDs.prefix(Int(count)))
    }

    private func makeDisplayInfo(for displayID: CGDirectDisplayID) -> DisplayInfo {
        let vendorID = CGDisplayVendorNumber(displayID)
        let productID = CGDisplayModelNumber(displayID)

        // Enumerate all modes including HiDPI
        let options: [CFString: Any] = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue as Any]
        let allModes = CGDisplayCopyAllDisplayModes(displayID, options as CFDictionary) as? [CGDisplayMode] ?? []
        let modes = allModes.map(DisplayMode.init)

        // Native resolution = largest non-HiDPI pixel dimensions from mode list
        let nonHiDPIModes = modes.filter { !$0.isHiDPI }
        let nativeW: Int
        let nativeH: Int
        if let largest = nonHiDPIModes.max(by: { ($0.pixelWidth * $0.pixelHeight) < ($1.pixelWidth * $1.pixelHeight) }) {
            nativeW = largest.pixelWidth
            nativeH = largest.pixelHeight
        } else {
            // Fallback: use current mode pixel dimensions
            nativeW = CGDisplayPixelsWide(displayID)
            nativeH = CGDisplayPixelsHigh(displayID)
        }

        return DisplayInfo(
            id: displayID,
            name: displayName(for: displayID, vendorID: vendorID, productID: productID),
            vendorID: vendorID,
            productID: productID,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            nativeWidth: nativeW, nativeHeight: nativeH,
            physicalSizeMM: CGDisplayScreenSize(displayID),  // CoreGraphics reads this from EDID
            modes: modes,
            currentMode: CGDisplayCopyDisplayMode(displayID).map(DisplayMode.init)
        )
    }

    /// Backing scale of the screen showing `displayID`, directly or through a display mirroring it.
    static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat? {
        NSScreen.screens.first { screen in
            guard let screenID = screen.displayID else { return false }
            return screenID == displayID || CGDisplayMirrorsDisplay(screenID) == displayID
        }?.backingScaleFactor
    }

    private func displayName(for displayID: CGDirectDisplayID, vendorID: UInt32, productID: UInt32) -> String {
        let screenName = NSScreen.screens.first { $0.displayID == displayID }?.localizedName
        guard let name = screenName
            ?? nameCache[displayID]
            ?? Self.ioKitDisplayName(vendorID: vendorID, productID: productID) else {
            return "Display \(displayID)"
        }

        nameCache[displayID] = name
        return name
    }

    /// IODisplayConnect only exists on Intel Macs. Apple Silicon has no matching services.
    private static func ioKitDisplayName(vendorID: UInt32, productID: UInt32) -> String? {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            guard let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any],
                  info[kDisplayVendorID] as? UInt32 == vendorID,
                  info[kDisplayProductID] as? UInt32 == productID,
                  let names = info[kDisplayProductName] as? [String: String],
                  let name = names.values.first else {
                continue
            }
            return name
        }
        return nil
    }

    private static let handleDisplayReconfiguration: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        // Each change is reported once before and once after it applies; only the second is useful.
        guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }

        let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            manager.refresh()
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
