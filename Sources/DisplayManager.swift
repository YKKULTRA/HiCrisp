import CoreGraphics
import Foundation
import IOKit
import AppKit
import HiCrispSupport

// MARK: - Display Mode

struct DisplayMode: Identifiable, Hashable {
    let id: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiDPI: Bool
    let cgMode: CGDisplayMode

    var label: String {
        let hidpi = isHiDPI ? " HiDPI" : ""
        let hz = refreshRate > 0 ? " @ \(Int(refreshRate))Hz" : ""
        return "\(width)x\(height)\(hz)\(hidpi)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(pixelWidth)
        hasher.combine(pixelHeight)
        hasher.combine(Int(refreshRate * 100)) // preserve fractional Hz (59.94 vs 60)
        hasher.combine(isHiDPI)
    }

    static func == (lhs: DisplayMode, rhs: DisplayMode) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
            && lhs.pixelWidth == rhs.pixelWidth && lhs.pixelHeight == rhs.pixelHeight
            && abs(lhs.refreshRate - rhs.refreshRate) < 0.1 && lhs.isHiDPI == rhs.isHiDPI
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

    var vendorHex: String { String(format: "%x", vendorID) }
    var productHex: String { String(format: "%x", productID) }

    var isHiDPIActive: Bool {
        guard let cur = currentMode else { return false }
        return cur.isHiDPI && cur.width == nativeWidth && cur.height == nativeHeight
    }

    var hasNativeHiDPI: Bool {
        modes.contains { $0.isHiDPI && $0.width == nativeWidth && $0.height == nativeHeight }
    }

    func nativeHiDPIMode(refreshRate: Double? = nil) -> DisplayMode? {
        let candidates = modes.filter { $0.isHiDPI && $0.width == nativeWidth && $0.height == nativeHeight }
        if let hz = refreshRate {
            return candidates.first { abs($0.refreshRate - hz) < 1.0 }
                ?? candidates.max(by: { $0.refreshRate < $1.refreshRate })
        }
        return candidates.max(by: { $0.refreshRate < $1.refreshRate })
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

    init() {
        let error = CGDisplayRegisterReconfigurationCallback(
            Self.handleDisplayReconfiguration,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if error != .success {
            NSLog("[DisplayManager] Failed to register display callback: %d", error.rawValue)
        }

        refresh()
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(
            Self.handleDisplayReconfiguration,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func refresh() {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        displays = (0..<Int(displayCount)).map { i in
            makeDisplayInfo(for: displayIDs[i])
        }
    }

    private func makeDisplayInfo(for displayID: CGDirectDisplayID) -> DisplayInfo {
        let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
        let vendorID = CGDisplayVendorNumber(displayID)
        let productID = CGDisplayModelNumber(displayID)
        let name = getDisplayName(displayID, vendorID: vendorID, productID: productID)

        // Get actual physical size from EDID (CoreGraphics reads this from the display)
        let physicalSize = CGDisplayScreenSize(displayID) // returns CGSize in mm

        // Enumerate all modes including HiDPI
        let options: [CFString: Any] = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue as Any]
        let allModes = CGDisplayCopyAllDisplayModes(displayID, options as CFDictionary) as? [CGDisplayMode] ?? []

        var modeIndex: Int32 = 0
        let modes: [DisplayMode] = allModes.map { cgMode in
            let mode = DisplayMode(
                id: modeIndex,
                width: cgMode.width, height: cgMode.height,
                pixelWidth: cgMode.pixelWidth, pixelHeight: cgMode.pixelHeight,
                refreshRate: cgMode.refreshRate,
                isHiDPI: cgMode.pixelWidth > cgMode.width,
                cgMode: cgMode
            )
            modeIndex += 1
            return mode
        }

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

        let currentCGMode = CGDisplayCopyDisplayMode(displayID)
        var currentMode: DisplayMode? = nil
        if let cur = currentCGMode {
            currentMode = DisplayMode(
                id: -1, width: cur.width, height: cur.height,
                pixelWidth: cur.pixelWidth, pixelHeight: cur.pixelHeight,
                refreshRate: cur.refreshRate,
                isHiDPI: cur.pixelWidth > cur.width,
                cgMode: cur
            )
        }

        return DisplayInfo(
            id: displayID, name: name, vendorID: vendorID,
            productID: productID, isBuiltIn: isBuiltIn,
            nativeWidth: nativeW, nativeHeight: nativeH,
            physicalSizeMM: physicalSize,
            modes: modes, currentMode: currentMode
        )
    }

    func switchMode(displayID: CGDirectDisplayID, mode: DisplayMode) -> Bool {
        let result = CGDisplaySetDisplayMode(displayID, mode.cgMode, nil)
        if result == .success {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refresh()
            }
            return true
        }
        return false
    }

    /// Check if HiDPI is truly active by verifying NSScreen backingScaleFactor
    static func verifyHiDPIActive(displayID: CGDirectDisplayID) -> Bool {
        for screen in NSScreen.screens {
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            if screenNumber == displayID || CGDisplayMirrorsDisplay(screenNumber ?? 0) == displayID {
                return screen.backingScaleFactor == 2.0
            }
        }
        return false
    }

    private func getDisplayName(_ displayID: CGDirectDisplayID, vendorID: UInt32, productID: UInt32) -> String {
        var name = "Display \(displayID)"

        var iterator = io_iterator_t()
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return name
        }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any] {
                let vid = info[kDisplayVendorID] as? UInt32 ?? 0
                let pid = info[kDisplayProductID] as? UInt32 ?? 0
                if vid == vendorID && pid == productID {
                    if let names = info[kDisplayProductName] as? [String: String],
                       let firstName = names.values.first {
                        name = firstName
                        IOObjectRelease(service)
                        break  // found match, stop iterating
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)
        return name
    }

    private static let handleDisplayReconfiguration: CGDisplayReconfigurationCallBack = { _, _, userInfo in
        guard let userInfo else { return }

        let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            manager.refresh()
        }
    }
}
