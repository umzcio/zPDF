import AppKit
import SwiftUI

/// Units for rulers, grids, page sizes and measurement defaults.
enum PageUnit: String, CaseIterable, Identifiable, Codable {
    case points, inches, millimeters, centimeters, picas
    var id: String { rawValue }
    var title: String {
        switch self {
        case .points: "Points"
        case .inches: "Inches"
        case .millimeters: "Millimeters"
        case .centimeters: "Centimeters"
        case .picas: "Picas"
        }
    }
    var symbol: String {
        switch self {
        case .points: "pt"
        case .inches: "in"
        case .millimeters: "mm"
        case .centimeters: "cm"
        case .picas: "pc"
        }
    }
    /// PDF points per unit.
    var points: Double {
        switch self {
        case .points: 1
        case .inches: 72
        case .millimeters: 72 / 25.4
        case .centimeters: 72 / 2.54
        case .picas: 12
        }
    }
    func value(fromPoints points: Double) -> Double { points / self.points }
    func format(_ points: Double, digits: Int? = nil) -> String {
        let value = value(fromPoints: points)
        let places = digits ?? (self == .points ? 0 : self == .millimeters ? 1 : 2)
        return value.formatted(.number.precision(.fractionLength(places)))
    }
    /// Major tick spacing on rulers, in units, adapted to zoom.
    func rulerStep(pointsPerPixel: Double) -> (major: Double, minor: Int) {
        let candidates: [(Double, Int)]
        switch self {
        case .inches: candidates = [(0.25, 4), (0.5, 4), (1, 8), (2, 4), (5, 5)]
        case .millimeters: candidates = [(5, 5), (10, 10), (20, 4), (50, 5), (100, 10)]
        case .centimeters: candidates = [(0.5, 5), (1, 10), (2, 4), (5, 5), (10, 10)]
        case .points: candidates = [(18, 3), (36, 6), (72, 6), (144, 4), (288, 4)]
        case .picas: candidates = [(1, 6), (3, 3), (6, 6), (12, 4), (24, 4)]
        }
        // Keep major ticks at least ~60 pixels apart.
        for candidate in candidates where candidate.0 * self.points / pointsPerPixel >= 60 { return candidate }
        return candidates.last!
    }
}

/// Acrobat "Replace document colors" and night reading modes.
enum DocumentColorMode: String, CaseIterable, Identifiable {
    case original, night, highContrastBlackOnWhite, highContrastYellowOnBlack, highContrastGreenOnBlack,
         highContrastWhiteOnBlack, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "Original colors"
        case .night: "Night (inverted)"
        case .highContrastBlackOnWhite: "High contrast: black on white"
        case .highContrastYellowOnBlack: "High contrast: yellow on black"
        case .highContrastGreenOnBlack: "High contrast: green on black"
        case .highContrastWhiteOnBlack: "High contrast: white on black"
        case .custom: "Custom colors"
        }
    }
    /// (text, page background) sRGB hex for mapped modes.
    var mapping: (text: UInt32, background: UInt32)? {
        switch self {
        case .original, .night, .custom: nil
        case .highContrastBlackOnWhite: (0x000000, 0xFFFFFF)
        case .highContrastYellowOnBlack: (0xFFFF00, 0x000000)
        case .highContrastGreenOnBlack: (0x00FF00, 0x000000)
        case .highContrastWhiteOnBlack: (0xFFFFFF, 0x000000)
        }
    }
}

enum PageTransitionStyle: String, CaseIterable, Identifiable {
    case none, dissolve, push, wipe, moveIn, reveal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "No Transition"
        case .dissolve: "Dissolve"
        case .push: "Push"
        case .wipe: "Wipe"
        case .moveIn: "Move In"
        case .reveal: "Reveal"
        }
    }
}

enum FullScreenBackground: String, CaseIterable, Identifiable {
    case black, gray, white
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: NSColor {
        switch self {
        case .black: .black
        case .gray: NSColor(white: 0.25, alpha: 1)
        case .white: .white
        }
    }
}

enum OverlayColor: String, CaseIterable, Identifiable {
    case blue, cyan, magenta, red, green, gray
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var nsColor: NSColor {
        switch self {
        case .blue: NSColor(srgbRed: 0.15, green: 0.45, blue: 0.95, alpha: 1)
        case .cyan: NSColor(srgbRed: 0.0, green: 0.72, blue: 0.85, alpha: 1)
        case .magenta: NSColor(srgbRed: 0.85, green: 0.2, blue: 0.75, alpha: 1)
        case .red: NSColor(srgbRed: 0.9, green: 0.2, blue: 0.22, alpha: 1)
        case .green: NSColor(srgbRed: 0.15, green: 0.65, blue: 0.3, alpha: 1)
        case .gray: NSColor(white: 0.5, alpha: 1)
        }
    }
}

enum LinkOpeningPolicy: String, CaseIterable, Identifiable {
    case ask, allow, block
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: "Ask before opening"
        case .allow: "Open without asking"
        case .block: "Never open"
        }
    }
}

/// Real-world units available for measurements.
enum MeasureUnit: String, CaseIterable, Identifiable, Codable {
    case pt, inch = "in", ft, yd, mi, mm, cm, m, km
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pt: "Points"
        case .inch: "Inches"
        case .ft: "Feet"
        case .yd: "Yards"
        case .mi: "Miles"
        case .mm: "Millimeters"
        case .cm: "Centimeters"
        case .m: "Meters"
        case .km: "Kilometers"
        }
    }
    /// Size of one unit in inches (for converting between units).
    var inches: Double {
        switch self {
        case .pt: 1.0 / 72
        case .inch: 1
        case .ft: 12
        case .yd: 36
        case .mi: 63360
        case .mm: 1 / 25.4
        case .cm: 1 / 2.54
        case .m: 1000 / 25.4
        case .km: 1_000_000 / 25.4
        }
    }
}
