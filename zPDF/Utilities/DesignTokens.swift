//
//  DesignTokens.swift
//  zPDF
//
//  Purpose: Design tokens lifted from the approved prototype
//  (../app/index.html :root CSS + component styles). All colors, spacing,
//  radii, and fixed layout dimensions live here — views must not hard-code
//  them.
//  Phase: 1 (stable). No TODOs here.
//

import SwiftUI

extension Color {
    /// Initialize from a 0xRRGGBB hex value.
    init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

/// Plain buttons still need an unmistakable keyboard focus indicator.
struct KeyboardFocusRing: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                    .stroke(focused ? Color(nsColor: .keyboardFocusIndicatorColor) : .clear,
                            lineWidth: 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

enum DesignTokens {

    enum Colors {
        /// Foreground accents need contrast on both plain and tinted surfaces.
        @MainActor private static var increasedContrast: Bool {
            AppPreferences.shared.increaseContrast || SystemAccessibility.shared.options.increaseContrast
        }
        @MainActor static var accent: Color {
            accent(for: AppPreferences.shared.accent, increasedContrast: increasedContrast)
        }
        /// Filled controls keep white labels legible in every selected palette.
        @MainActor static var controlAccent: Color {
            let high = increasedContrast
            if AppPreferences.shared.accent == .system {
                return Color(nsColor: NSColor(name: nil) { appearance in
                    var resolved = NSColor.systemBlue
                    appearance.performAsCurrentDrawingAppearance {
                        resolved = contrastAdjustedSystemAccent(onDark: false, increasedContrast: high)
                    }
                    return resolved
                })
            }
            return Color(hex: high ? AppPreferences.shared.accent.palette.highLight : AppPreferences.shared.accent.palette.light)
        }
        @MainActor static var accentHover: Color { controlAccent.opacity(0.85) }
        @MainActor static var accentTint: Color { accent.opacity(0.12) }

        static func accent(for selection: AppAccent, increasedContrast: Bool = false) -> Color {
            if selection == .system {
                return Color(nsColor: NSColor(name: nil) { appearance in
                    let match = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua,
                                                           .accessibilityHighContrastAqua, .darkAqua, .aqua])
                    let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
                    let high = increasedContrast || match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
                    var resolved = NSColor.systemBlue
                    appearance.performAsCurrentDrawingAppearance {
                        resolved = contrastAdjustedSystemAccent(onDark: dark, increasedContrast: high)
                    }
                    return resolved
                })
            }
            let palette = selection.palette
            return adaptive(light: palette.light, dark: palette.dark,
                            highContrastLight: palette.highLight, highContrastDark: palette.highDark,
                            forceHighContrast: increasedContrast)
        }

        /// System accents can be yellow or graphite. Preserve their hue while
        /// adjusting foreground luminance against the app's light/dark chrome.
        private static func contrastAdjustedSystemAccent(onDark: Bool, increasedContrast: Bool) -> NSColor {
            let source = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            var rgb = [source.redComponent, source.greenComponent, source.blueComponent]
            let target: CGFloat = increasedContrast ? 7 : 5
            func luminance(_ channels: [CGFloat]) -> CGFloat {
                let linear = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
            }
            for _ in 0..<50 {
                let lum = luminance(rgb)
                let ratio = onDark ? (lum + 0.05) / 0.08 : 1.05 / (lum + 0.05)
                if ratio >= target { break }
                rgb = rgb.map { onDark ? $0 + (1 - $0) * 0.06 : $0 * 0.94 }
            }
            return NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        }
        /// Semantic chrome colors follow the window appearance.
        static let text = Color.primary
        /// Opaque secondary text: AppKit's 50%-black label is below 4.5:1
        /// on white. Keep small labels readable on chrome and inset surfaces.
        @MainActor static var mutedText: Color { adaptive(light: 0x595959, dark: 0xB8B8B8,
                                        highContrastLight: 0x333333, highContrastDark: 0xE0E0E0, forceHighContrast: increasedContrast) }
        /// Borders and grouped control surfaces.
        @MainActor static var hairline: Color {
            increasedContrast
                ? adaptive(light: 0x666666, dark: 0xAAAAAA, highContrastLight: 0x666666, highContrastDark: 0xAAAAAA)
                : Color(nsColor: .separatorColor)
        }
        static let surface = Color(nsColor: .controlBackgroundColor)
        static let inset = Color.primary.opacity(0.05)
        /// Starred-file indicator (#F5A623 in the prototype).
        static let starActive = adaptive(light: 0x875100, dark: 0xFFC15E,
                                         highContrastLight: 0x633A00, highContrastDark: 0xFFE0A6)
        /// #canvas-wrap background behind the page.
        static let canvasBackground = Color(nsColor: .underPageBackgroundColor)
        /// Status bar success state.
        static let readyGreen = adaptive(light: 0x176B38, dark: 0x64D98B,
                                         highContrastLight: 0x104D28, highContrastDark: 0xA0F5BC)
        /// File-card thumbnail well.
        static let thumbnailWell = Color(nsColor: .windowBackgroundColor)

        private static func adaptive(light: UInt32, dark: UInt32,
                                     highContrastLight: UInt32, highContrastDark: UInt32,
                                     forceHighContrast: Bool = false) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let value: UInt32
                switch appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua,
                                                   .accessibilityHighContrastAqua, .darkAqua, .aqua]) {
                case .accessibilityHighContrastDarkAqua: value = highContrastDark
                case .accessibilityHighContrastAqua: value = highContrastLight
                case .darkAqua: value = forceHighContrast ? highContrastDark : dark
                default: value = forceHighContrast ? highContrastLight : light
                }
                return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                               green: CGFloat((value >> 8) & 0xFF) / 255,
                               blue: CGFloat(value & 0xFF) / 255, alpha: 1)
            })
        }
    }

    enum Motion {
        /// Completion feedback without moving page hit targets, including Reduce Motion.
        static let pageDropFeedback = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    }

    enum Spacing {
        static let xxSmall: CGFloat = 2
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 36
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 10
    }

    enum Layout {
        static let railWidth: CGFloat = 56
        static let tabStripHeight: CGFloat = 36
        static let toolbarHeight: CGFloat = 44
        static let sidebarWidth: CGFloat = 224
        static let inspectorWidth: CGFloat = 280
        static let statusBarHeight: CGFloat = 24
        static let homeSidebarWidth: CGFloat = 190
        static let recentCardMinWidth: CGFloat = 172
        static let toolCardMinWidth: CGFloat = 196
    }
}
