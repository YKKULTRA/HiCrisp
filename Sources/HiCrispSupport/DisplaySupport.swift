import CoreGraphics
import Foundation

public enum RefreshRateSupport {
    public static func normalizedRates(_ rates: [Double]) -> [Double] {
        rates.sorted(by: >).reduce(into: []) { normalized, rate in
            guard !normalized.contains(where: { abs($0 - rate) < 0.02 }) else { return }
            normalized.append(rate)
        }
    }

    public static func preferredRate(stored: Double?, current: Double?, available: [Double]) -> Double {
        let normalized = normalizedRates(available)
        guard !normalized.isEmpty else { return 0 }

        if let stored, stored > 0, let closest = closestRate(to: stored, in: normalized) {
            return closest
        }

        if let current, current > 0, let closest = closestRate(to: current, in: normalized) {
            return closest
        }

        return normalized[0]
    }

    public static func closestRate(to desired: Double, in available: [Double]) -> Double? {
        available.min { lhs, rhs in
            let lhsDistance = abs(lhs - desired)
            let rhsDistance = abs(rhs - desired)
            if abs(lhsDistance - rhsDistance) < 0.0001 {
                return lhs > rhs
            }
            return lhsDistance < rhsDistance
        }
    }

    public static func label(for rate: Double) -> String {
        let rounded = rate.rounded()
        if abs(rate - rounded) < 0.05 {
            return "\(Int(rounded))Hz"
        }

        let formatted = String(format: "%.2f", rate)
        let trimmed = formatted.replacingOccurrences(
            of: #"(\.\d*?[1-9])0+$|\.0+$"#,
            with: "$1",
            options: .regularExpression
        )
        return "\(trimmed)Hz"
    }
}

public enum PhysicalSizeEstimator {
    public static func fallbackSizeMM(nativeWidth: Int, nativeHeight: Int) -> CGSize {
        guard nativeWidth > 0, nativeHeight > 0 else {
            return CGSize(width: 597, height: 336)
        }

        let assumedPPI = inferredPPI(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        let widthMM = Double(nativeWidth) / assumedPPI * 25.4
        let heightMM = Double(nativeHeight) / assumedPPI * 25.4
        return CGSize(width: widthMM, height: heightMM)
    }

    private static func inferredPPI(nativeWidth: Int, nativeHeight: Int) -> Double {
        if nativeWidth >= 3800 || nativeHeight >= 2100 {
            return 140
        }

        if nativeWidth >= 3000 {
            return 110
        }

        if nativeWidth >= 2500 || nativeHeight >= 1400 {
            return 109
        }

        return 92
    }
}
