import XCTest
@testable import HiCrispSupport

final class DisplaySupportTests: XCTestCase {
    func testPreferredRateUsesStoredSelectionWhenAvailable() {
        let selected = RefreshRateSupport.preferredRate(
            stored: 59.94,
            current: 60,
            available: [60, 59.94, 120]
        )

        XCTAssertEqual(selected, 59.94, accuracy: 0.001)
    }

    func testPreferredRateFallsBackToCurrentRate() {
        let selected = RefreshRateSupport.preferredRate(
            stored: nil,
            current: 143.9,
            available: [60, 120, 144]
        )

        XCTAssertEqual(selected, 144, accuracy: 0.001)
    }

    func testNormalizedRatesDropsNearDuplicateValues() {
        let normalized = RefreshRateSupport.normalizedRates([60, 60.01, 59.94, 119.99, 120])

        XCTAssertEqual(normalized.count, 3)
        XCTAssertEqual(normalized[0], 120, accuracy: 0.001)
        XCTAssertEqual(normalized[1], 60.01, accuracy: 0.001)
        XCTAssertEqual(normalized[2], 59.94, accuracy: 0.001)
    }

    func testRefreshRateLabelsPreserveFractionalRates() {
        XCTAssertEqual(RefreshRateSupport.label(for: 60), "60Hz")
        XCTAssertEqual(RefreshRateSupport.label(for: 59.94), "59.94Hz")
    }

    func testFallbackSizePreservesUltrawideAspectRatio() {
        let size = PhysicalSizeEstimator.fallbackSizeMM(nativeWidth: 3440, nativeHeight: 1440)

        XCTAssertEqual(size.width / size.height, 3440.0 / 1440.0, accuracy: 0.01)
        XCTAssertGreaterThan(size.width, 750)
        XCTAssertLessThan(size.width, 820)
    }

    func testFallbackSizeFor1080pStaysInCommonDesktopRange() {
        let size = PhysicalSizeEstimator.fallbackSizeMM(nativeWidth: 1920, nativeHeight: 1080)
        let diagonalInches = hypot(size.width, size.height) / 25.4

        XCTAssertGreaterThan(diagonalInches, 23)
        XCTAssertLessThan(diagonalInches, 25)
    }
}
