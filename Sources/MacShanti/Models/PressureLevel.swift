import SwiftUI
import AppKit

/// System memory pressure, mapped to the menubar dot color.
enum PressureLevel: Int, Codable, CaseIterable {
    case normal = 0   // green
    case warning = 1  // yellow
    case critical = 2 // red

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "Critical"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .normal: return NSColor.systemGreen
        case .warning: return NSColor.systemYellow
        case .critical: return NSColor.systemRed
        }
    }

    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }

    /// Classify pressure from used ratio and swap usage.
    static func classify(usedRatio: Double, swapUsedBytes: UInt64) -> PressureLevel {
        let swapGB = Double(swapUsedBytes) / 1_073_741_824.0
        if usedRatio >= 0.90 || swapGB >= 3.0 {
            return .critical
        }
        if usedRatio >= 0.75 || swapGB >= 1.0 {
            return .warning
        }
        return .normal
    }
}
