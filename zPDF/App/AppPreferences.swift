import AppKit
import Observation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum AppAccent: String, CaseIterable, Identifiable {
    case system, blue, red, purple, green, orange, pink
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Dark fills retain white-label contrast; brighter foregrounds work on dark chrome.
    var palette: (light: UInt32, dark: UInt32, highLight: UInt32, highDark: UInt32) {
        switch self {
        case .system, .blue: (0x0059BA, 0x64ACFF, 0x003F87, 0xA8D1FF)
        case .red: (0xB4232C, 0xFF8B91, 0x86151D, 0xFFC4C7)
        case .purple: (0x7738AE, 0xC8A0FF, 0x572281, 0xE2CBFF)
        case .green: (0x196B3B, 0x72D79A, 0x104C29, 0xADF0C7)
        case .orange: (0x9A4700, 0xFFAF67, 0x713300, 0xFFD3AC)
        case .pink: (0xAD236E, 0xFF91CA, 0x80154F, 0xFFC4E4)
        }
    }
}

enum DefaultPDFZoom: String, CaseIterable, Identifiable {
    case actualSize, fitPage, fitWidth
    var id: String { rawValue }
    var title: String {
        switch self { case .actualSize: "Actual Size"; case .fitPage: "Fit Page"; case .fitWidth: "Fit Width" }
    }
}

enum AnnotationPreferenceColor: String, CaseIterable, Identifiable {
    case yellow, red, green, blue, purple, pink
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// PDF colors are fixed sRGB, independent of interface appearance.
    var nsColor: NSColor {
        switch self {
        case .yellow: NSColor(srgbRed: 1, green: 0.85, blue: 0.15, alpha: 1)
        case .red: NSColor(srgbRed: 0.90, green: 0.20, blue: 0.22, alpha: 1)
        case .green: NSColor(srgbRed: 0.15, green: 0.65, blue: 0.30, alpha: 1)
        case .blue: NSColor(srgbRed: 0.15, green: 0.45, blue: 0.95, alpha: 1)
        case .purple: NSColor(srgbRed: 0.60, green: 0.30, blue: 0.85, alpha: 1)
        case .pink: NSColor(srgbRed: 0.95, green: 0.35, blue: 0.65, alpha: 1)
        }
    }
}

/// Preferences are deliberately separate from document state and PDF bytes.
/// Isolated defaults make persistence testable without changing the user's settings.
@MainActor @Observable
final class AppPreferences {
    static let shared = AppPreferences()
    static let keyPrefix = "zpdf.preferences.v1."
    @ObservationIgnored private let defaults: UserDefaults

    var increaseContrast: Bool { didSet { persist("increaseContrast", increaseContrast) } }
    var reduceMotion: Bool { didSet { persist("reduceMotion", reduceMotion) } }
    var reduceTransparency: Bool { didSet { persist("reduceTransparency", reduceTransparency) } }

    var appearance: AppAppearance { didSet { persist("appearance", appearance.rawValue) } }
    var accent: AppAccent { didSet { persist("accent", accent.rawValue) } }
    var recentFileLimit: Int {
        didSet {
            let valid = min(100, max(0, recentFileLimit))
            if valid != recentFileLimit { recentFileLimit = valid }
            persist("recentFileLimit", valid)
        }
    }
    var rememberReadingPosition: Bool { didSet { persist("rememberReadingPosition", rememberReadingPosition) } }
    var restoreOpenDocuments: Bool { didSet { persist("restoreOpenDocuments", restoreOpenDocuments) } }
    var defaultZoom: DefaultPDFZoom { didSet { persist("defaultZoom", defaultZoom.rawValue) } }
    var defaultViewMode: PDFViewMode { didSet { persist("defaultViewMode", defaultViewMode.rawValue) } }
    var showPageGaps: Bool { didSet { persist("showPageGaps", showPageGaps) } }
    var rememberSidebar: Bool { didSet { persist("rememberSidebar", rememberSidebar) } }
    var sidebarVisible: Bool { didSet { persist("sidebarVisible", sidebarVisible) } }
    var commentAuthor: String { didSet { persist("commentAuthor", commentAuthor) } }
    var highlightColor: AnnotationPreferenceColor { didSet { persist("highlightColor", highlightColor.rawValue) } }
    var underlineColor: AnnotationPreferenceColor { didSet { persist("underlineColor", underlineColor.rawValue) } }
    var noteColor: AnnotationPreferenceColor { didSet { persist("noteColor", noteColor.rawValue) } }
    var keepAnnotationToolSelected: Bool { didSet { persist("keepAnnotationToolSelected", keepAnnotationToolSelected) } }
    var openCommentsAutomatically: Bool { didSet { persist("openCommentsAutomatically", openCommentsAutomatically) } }
    var highlightFormFields: Bool { didSet { persist("highlightFormFields", highlightFormFields) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func raw(_ key: String) -> String { defaults.string(forKey: Self.keyPrefix + key) ?? "" }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            (defaults.object(forKey: Self.keyPrefix + key) as? NSNumber)?.boolValue ?? fallback
        }
        increaseContrast = bool("increaseContrast", false)
        reduceMotion = bool("reduceMotion", false)
        reduceTransparency = bool("reduceTransparency", false)
        appearance = AppAppearance(rawValue: raw("appearance")) ?? .system
        accent = AppAccent(rawValue: raw("accent")) ?? .system
        recentFileLimit = min(100, max(0, (defaults.object(forKey: Self.keyPrefix + "recentFileLimit") as? NSNumber)?.intValue ?? 20))
        rememberReadingPosition = bool("rememberReadingPosition", true)
        restoreOpenDocuments = bool("restoreOpenDocuments", false)
        defaultZoom = DefaultPDFZoom(rawValue: raw("defaultZoom")) ?? .fitPage
        defaultViewMode = PDFViewMode(rawValue: raw("defaultViewMode")) ?? .continuous
        showPageGaps = bool("showPageGaps", true)
        rememberSidebar = bool("rememberSidebar", true)
        sidebarVisible = bool("sidebarVisible", true)
        commentAuthor = defaults.string(forKey: Self.keyPrefix + "commentAuthor") ?? NSFullUserName()
        highlightColor = AnnotationPreferenceColor(rawValue: raw("highlightColor")) ?? .yellow
        underlineColor = AnnotationPreferenceColor(rawValue: raw("underlineColor")) ?? .red
        noteColor = AnnotationPreferenceColor(rawValue: raw("noteColor")) ?? .yellow
        keepAnnotationToolSelected = bool("keepAnnotationToolSelected", false)
        openCommentsAutomatically = bool("openCommentsAutomatically", false)
        highlightFormFields = bool("highlightFormFields", true)
    }

    /// Does not clear recents, bookmarks or any document/recovery state.
    func reset() {
        increaseContrast = false; reduceMotion = false; reduceTransparency = false
        appearance = .system; accent = .system; recentFileLimit = 20
        rememberReadingPosition = true; restoreOpenDocuments = false
        defaultZoom = .fitPage; defaultViewMode = .continuous; showPageGaps = true
        rememberSidebar = true; sidebarVisible = true; commentAuthor = NSFullUserName()
        highlightColor = .yellow; underlineColor = .red; noteColor = .yellow
        keepAnnotationToolSelected = false; openCommentsAutomatically = false; highlightFormFields = true
    }

    func accessibilityOptions(system: AccessibilityOptions) -> AccessibilityOptions {
        AccessibilityOptions(increaseContrast: increaseContrast || system.increaseContrast,
                             reduceMotion: reduceMotion || system.reduceMotion,
                             reduceTransparency: reduceTransparency || system.reduceTransparency)
    }

    private func persist(_ key: String, _ value: Any) { defaults.set(value, forKey: Self.keyPrefix + key) }
}

/// App-local accommodations add to, and never turn off, system accommodations.
struct AccessibilityOptions: Equatable {
    var increaseContrast = false
    var reduceMotion = false
    var reduceTransparency = false
}

private struct AccessibilityOptionsKey: EnvironmentKey {
    static let defaultValue = AccessibilityOptions()
}

extension EnvironmentValues {
    var appAccessibility: AccessibilityOptions {
        get { self[AccessibilityOptionsKey.self] }
        set { self[AccessibilityOptionsKey.self] = newValue }
    }
}

@MainActor @Observable
final class SystemAccessibility {
    static let shared = SystemAccessibility()
    private(set) var options = AccessibilityOptions()
    private(set) var voiceOverEnabled = false
    @ObservationIgnored private var displayObserver: NSObjectProtocol?
    @ObservationIgnored private var voiceOverObserver: NSKeyValueObservation?

    private init() {
        refresh()
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        voiceOverObserver = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        let workspace = NSWorkspace.shared
        options = AccessibilityOptions(
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency)
        voiceOverEnabled = workspace.isVoiceOverEnabled
    }
}
