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

    /// Classify pressure. The **kernel's live memory-pressure level** is the
    /// primary signal (this is what Activity Monitor's green/yellow/red graph
    /// reflects). Swap size and RAM fill only escalate severity when free RAM is
    /// genuinely low — high swap with plenty of free RAM is historical, not an
    /// emergency, so it stays green.
    ///
    /// - Parameter kernelPressureRaw: `kern.memorystatus_vm_pressure_level`
    ///   (1 = normal, 2 = warning, 4 = critical).
    static func classify(kernelPressureRaw: Int32,
                         usedRatio: Double,
                         freeRatio: Double,
                         swapUsedBytes: UInt64) -> PressureLevel {
        // Primary: the kernel's own pressure verdict.
        var level: PressureLevel
        switch kernelPressureRaw {
        case 4: level = .critical
        case 2: level = .warning
        default: level = .normal
        }

        // Secondary: only when free RAM is actually scarce do swap/fill matter.
        let lowRAM = freeRatio < 0.10
        let swapGB = Double(swapUsedBytes) / 1_073_741_824.0
        if lowRAM && swapGB >= 1.0 {
            level = max(level, .warning)
        }
        if lowRAM && usedRatio >= 0.90 {
            level = max(level, .critical)
        }
        return level
    }
}

extension PressureLevel: Comparable {
    static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
