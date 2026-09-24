import AppKit
import SwiftUI
import XCTest
@testable import zPDF

@MainActor
final class PreferencesTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "zpdf.preferences.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testPreferencesPersistAcrossInstances() {
        withDefaults { defaults in
            let first = AppPreferences(defaults: defaults)
            first.increaseContrast = true
            first.reduceMotion = true
            first.reduceTransparency = true
            first.appearance = .dark
            first.accent = .purple
            first.recentFileLimit = 42
            first.rememberReadingPosition = false
            first.restoreOpenDocuments = true
            first.defaultZoom = .fitWidth
            first.defaultViewMode = .facing
            first.showPageGaps = false
            first.rememberSidebar = false
            first.sidebarVisible = false
            first.commentAuthor = "Review Team"
            first.highlightColor = .pink
            first.underlineColor = .blue
            first.noteColor = .green
            first.keepAnnotationToolSelected = true
            first.openCommentsAutomatically = true
            first.highlightFormFields = false

            let next = AppPreferences(defaults: defaults)
            XCTAssertTrue(next.increaseContrast)
            XCTAssertTrue(next.reduceMotion)
            XCTAssertTrue(next.reduceTransparency)
            XCTAssertEqual(next.appearance, .dark)
            XCTAssertEqual(next.accent, .purple)
            XCTAssertEqual(next.recentFileLimit, 42)
            XCTAssertFalse(next.rememberReadingPosition)
            XCTAssertTrue(next.restoreOpenDocuments)
            XCTAssertEqual(next.defaultZoom, .fitWidth)
            XCTAssertEqual(next.defaultViewMode, .facing)
            XCTAssertFalse(next.showPageGaps)
            XCTAssertFalse(next.rememberSidebar)
            XCTAssertFalse(next.sidebarVisible)
            XCTAssertEqual(next.commentAuthor, "Review Team")
            XCTAssertEqual(next.highlightColor, .pink)
            XCTAssertEqual(next.underlineColor, .blue)
            XCTAssertEqual(next.noteColor, .green)
            XCTAssertTrue(next.keepAnnotationToolSelected)
            XCTAssertTrue(next.openCommentsAutomatically)
            XCTAssertFalse(next.highlightFormFields)
        }
    }

    func testResetKeepsRecentFilesAndOtherDefaults() {
        withDefaults { defaults in
            let history = Data("retained bookmarks".utf8)
            defaults.set(history, forKey: Constants.DefaultsKey.recentFiles)
            defaults.set("keep", forKey: "unrelated.setting")
            let preferences = AppPreferences(defaults: defaults)
            preferences.appearance = .light
            preferences.accent = .red
            preferences.recentFileLimit = 0
            preferences.commentAuthor = "Changed"
            preferences.restoreOpenDocuments = true
            preferences.highlightFormFields = false
            preferences.increaseContrast = true
            preferences.reduceMotion = true
            preferences.reduceTransparency = true
            preferences.reset()
            let reloaded = AppPreferences(defaults: defaults)
            XCTAssertFalse(reloaded.increaseContrast)
            XCTAssertFalse(reloaded.reduceMotion)
            XCTAssertFalse(reloaded.reduceTransparency)
            XCTAssertEqual(reloaded.appearance, .system)
            XCTAssertEqual(reloaded.accent, .system)
            XCTAssertEqual(reloaded.recentFileLimit, 20)
            XCTAssertEqual(reloaded.defaultZoom, .fitPage)
            XCTAssertEqual(reloaded.commentAuthor, NSFullUserName())
            XCTAssertFalse(reloaded.restoreOpenDocuments)
            XCTAssertTrue(reloaded.highlightFormFields)
            XCTAssertEqual(defaults.data(forKey: Constants.DefaultsKey.recentFiles), history)
            XCTAssertEqual(defaults.string(forKey: "unrelated.setting"), "keep")
        }
    }

    func testInvalidPersistedValuesUseSafeDefaults() {
        withDefaults { defaults in
            for key in ["appearance", "accent", "defaultZoom", "defaultViewMode", "highlightColor", "highlightFormFields"] {
                defaults.set("unknown-new-value", forKey: AppPreferences.keyPrefix + key)
            }
            defaults.set(-500, forKey: AppPreferences.keyPrefix + "recentFileLimit")
            let preferences = AppPreferences(defaults: defaults)
            XCTAssertEqual(preferences.appearance, .system)
            XCTAssertEqual(preferences.accent, .system)
            XCTAssertEqual(preferences.defaultZoom, .fitPage)
            XCTAssertEqual(preferences.defaultViewMode, .continuous)
            XCTAssertEqual(preferences.highlightColor, .yellow)
            XCTAssertTrue(preferences.highlightFormFields)
            XCTAssertEqual(preferences.recentFileLimit, 0)
        }
    }

    func testRecentLimitClampsWritesAndReloads() {
        withDefaults { defaults in
            let preferences = AppPreferences(defaults: defaults)
            preferences.recentFileLimit = 999
            XCTAssertEqual(preferences.recentFileLimit, 100)
            XCTAssertEqual(AppPreferences(defaults: defaults).recentFileLimit, 100)
            preferences.recentFileLimit = -1
            XCTAssertEqual(preferences.recentFileLimit, 0)
            XCTAssertEqual(AppPreferences(defaults: defaults).recentFileLimit, 0)
        }
    }

    func testExplicitFalseSurvivesForDefaultTruePreferences() {
        withDefaults { defaults in
            let preferences = AppPreferences(defaults: defaults)
            preferences.showPageGaps = false
            preferences.rememberSidebar = false
            preferences.highlightFormFields = false
            let restored = AppPreferences(defaults: defaults)
            XCTAssertFalse(restored.showPageGaps)
            XCTAssertFalse(restored.rememberSidebar)
            XCTAssertFalse(restored.highlightFormFields)
        }
    }

    func testAppAccessibilityAddsToSystemAccommodations() {
        withDefaults { defaults in
            let preferences = AppPreferences(defaults: defaults)
            let enabled = AccessibilityOptions(increaseContrast: true, reduceMotion: true, reduceTransparency: true)
            XCTAssertEqual(preferences.accessibilityOptions(system: enabled), enabled)
            preferences.increaseContrast = true
            preferences.reduceMotion = true
            preferences.reduceTransparency = true
            XCTAssertEqual(preferences.accessibilityOptions(system: AccessibilityOptions()), enabled)
            preferences.reset()
            XCTAssertEqual(preferences.accessibilityOptions(system: enabled), enabled)
            XCTAssertEqual(preferences.accessibilityOptions(system: AccessibilityOptions()), AccessibilityOptions())
        }
    }

    func testIncreasedContrastUsesBrighterDarkAndDarkerLightAccents() {
        for accent in AppAccent.allCases where accent != .system {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = NSAppearance(named: name)!
                var normal = NSColor.black
                var high = NSColor.black
                appearance.performAsCurrentDrawingAppearance {
                    normal = NSColor(DesignTokens.Colors.accent(for: accent)).usingColorSpace(.sRGB)!
                    high = NSColor(DesignTokens.Colors.accent(for: accent, increasedContrast: true)).usingColorSpace(.sRGB)!
                }
                let normalSum = normal.redComponent + normal.greenComponent + normal.blueComponent
                let highSum = high.redComponent + high.greenComponent + high.blueComponent
                if name == .darkAqua { XCTAssertGreaterThan(highSum, normalSum, accent.title) }
                else { XCTAssertLessThan(highSum, normalSum, accent.title) }
            }
        }
    }

    func testAccessibilityUpdatesReachHostedViewsAndNativeAppearance() {
        withDefaults { defaults in
            let preferences = AppPreferences(defaults: defaults)
            preferences.appearance = .dark
            let probe = AccessibilityProbeView()
            let previousAppearance = NSApp.appearance
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AccessibilityProbe(view: probe)
                .modifier(AppAppearanceModifier(preferences: preferences)))
            defer { window.close(); NSApp.appearance = previousAppearance }
            func settle() {
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            settle()
            preferences.increaseContrast = true
            preferences.reduceMotion = true
            preferences.reduceTransparency = true
            settle()
            XCTAssertEqual(probe.options, AccessibilityOptions(increaseContrast: true, reduceMotion: true, reduceTransparency: true))
            XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
            preferences.appearance = .light
            settle()
            XCTAssertEqual(NSApp.appearance?.name, .aqua)
            preferences.reset()
            settle()
            XCTAssertEqual(probe.options, SystemAccessibility.shared.options)
            if !SystemAccessibility.shared.options.increaseContrast { XCTAssertNil(NSApp.appearance) }
        }
    }

    func testNamedAccentPalettesHaveReadableTextAndWhiteLabels() {
        func luminance(_ hex: UInt32) -> Double {
            let channels = [Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)]
                .map { $0 / 255 }
                .map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        for accent in AppAccent.allCases where accent != .system {
            let palette = accent.palette
            XCTAssertGreaterThanOrEqual(1.05 / (luminance(palette.light) + 0.05), 4.5, accent.title)
            XCTAssertGreaterThanOrEqual((luminance(palette.dark) + 0.05) / (luminance(0x303030) + 0.05), 4.5, accent.title)
            XCTAssertGreaterThanOrEqual(1.05 / (luminance(palette.highLight) + 0.05), 7, accent.title)
            XCTAssertGreaterThanOrEqual((luminance(palette.highDark) + 0.05) / (luminance(0x303030) + 0.05), 7, accent.title)
        }
    }
}

private final class AccessibilityProbeView: NSView {
    var options = AccessibilityOptions()
}

private struct AccessibilityProbe: NSViewRepresentable {
    @Environment(\.appAccessibility) var options
    let view: AccessibilityProbeView
    func makeNSView(context: Context) -> AccessibilityProbeView { view }
    func updateNSView(_ view: AccessibilityProbeView, context: Context) { view.options = options }
}
