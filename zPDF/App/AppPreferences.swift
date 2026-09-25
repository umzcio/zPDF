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

    // General & documents
    var useDocumentInitialView: Bool { didSet { persist("useDocumentInitialView", useDocumentInitialView) } }
    var hasCompletedOnboarding: Bool { didSet { persist("hasCompletedOnboarding", hasCompletedOnboarding) } }
    var lastSeenWhatsNew: String { didSet { persist("lastSeenWhatsNew", lastSeenWhatsNew) } }
    var showWhatsNewAfterUpdates: Bool { didSet { persist("showWhatsNewAfterUpdates", showWhatsNewAfterUpdates) } }
    var showXFANotice: Bool { didSet { persist("showXFANotice", showXFANotice) } }

    // Identity (the name is shared with comment authoring)
    var identityEmail: String { didSet { persist("identityEmail", identityEmail) } }
    var identityOrganization: String { didSet { persist("identityOrganization", identityOrganization) } }
    var identityTitle: String { didSet { persist("identityTitle", identityTitle) } }

    // Page display
    var smoothImages: Bool { didSet { persist("smoothImages", smoothImages) } }
    var pageShadows: Bool { didSet { persist("pageShadows", pageShadows) } }
    var showPageLabels: Bool { didSet { persist("showPageLabels", showPageLabels) } }
    /// Zoom In/Out stops as fractions (1 = 100%), sorted and clamped.
    var zoomSteps: [Double] {
        didSet {
            let valid = Self.normalizedZoomSteps(zoomSteps)
            if valid != zoomSteps { zoomSteps = valid; return }
            persist("zoomSteps", valid)
        }
    }

    // Accessibility: document colors
    var documentColorMode: DocumentColorMode { didSet { persist("documentColorMode", documentColorMode.rawValue) } }
    var customPageTextColor: UInt32 { didSet { persist("customPageTextColor", Int(customPageTextColor)) } }
    var customPageBackgroundColor: UInt32 { didSet { persist("customPageBackgroundColor", Int(customPageBackgroundColor)) } }

    // Reading
    var readAloudVoice: String { didSet { persist("readAloudVoice", readAloudVoice) } }
    var readAloudRate: Double { didSet { persist("readAloudRate", readAloudRate) } }
    var readAloudHighlight: Bool { didSet { persist("readAloudHighlight", readAloudHighlight) } }
    var autoScrollSpeed: Double { didSet { persist("autoScrollSpeed", autoScrollSpeed) } }

    // Full screen
    var fullScreenAdvance: Bool { didSet { persist("fullScreenAdvance", fullScreenAdvance) } }
    var fullScreenAdvanceSeconds: Double { didSet { persist("fullScreenAdvanceSeconds", fullScreenAdvanceSeconds) } }
    var fullScreenLoop: Bool { didSet { persist("fullScreenLoop", fullScreenLoop) } }
    var fullScreenClickAdvances: Bool { didSet { persist("fullScreenClickAdvances", fullScreenClickAdvances) } }
    var fullScreenBackground: FullScreenBackground { didSet { persist("fullScreenBackground", fullScreenBackground.rawValue) } }
    var fullScreenTransition: PageTransitionStyle { didSet { persist("fullScreenTransition", fullScreenTransition.rawValue) } }
    var fullScreenUseDocumentTransitions: Bool { didSet { persist("fullScreenUseDocumentTransitions", fullScreenUseDocumentTransitions) } }
    var fullScreenShowNavigation: Bool { didSet { persist("fullScreenShowNavigation", fullScreenShowNavigation) } }

    // Units & guides
    var pageUnits: PageUnit { didSet { persist("pageUnits", pageUnits.rawValue) } }
    var showRulers: Bool { didSet { persist("showRulers", showRulers) } }
    var showGrid: Bool { didSet { persist("showGrid", showGrid) } }
    var showGuides: Bool { didSet { persist("showGuides", showGuides) } }
    var gridSpacing: Double { didSet { persist("gridSpacing", gridSpacing) } }
    var gridSubdivisions: Int { didSet { persist("gridSubdivisions", gridSubdivisions) } }
    var gridColor: OverlayColor { didSet { persist("gridColor", gridColor.rawValue) } }
    var guideColor: OverlayColor { didSet { persist("guideColor", guideColor.rawValue) } }
    var snapToGrid: Bool { didSet { persist("snapToGrid", snapToGrid) } }

    // Measuring
    var measureScalePage: Double { didSet { persist("measureScalePage", measureScalePage) } }
    var measureScalePageUnit: MeasureUnit { didSet { persist("measureScalePageUnit", measureScalePageUnit.rawValue) } }
    var measureScaleReal: Double { didSet { persist("measureScaleReal", measureScaleReal) } }
    var measureScaleRealUnit: MeasureUnit { didSet { persist("measureScaleRealUnit", measureScaleRealUnit.rawValue) } }
    var measurePrecision: Int { didSet { persist("measurePrecision", measurePrecision) } }
    var measureSnapEndpoints: Bool { didSet { persist("measureSnapEndpoints", measureSnapEndpoints) } }
    var measureSnapMidpoints: Bool { didSet { persist("measureSnapMidpoints", measureSnapMidpoints) } }
    var measureSnapIntersections: Bool { didSet { persist("measureSnapIntersections", measureSnapIntersections) } }
    var measureSnapPaths: Bool { didSet { persist("measureSnapPaths", measureSnapPaths) } }
    var measureAddAnnotations: Bool { didSet { persist("measureAddAnnotations", measureAddAnnotations) } }
    var measureColor: AnnotationPreferenceColor { didSet { persist("measureColor", measureColor.rawValue) } }
    var measureUseDocumentScale: Bool { didSet { persist("measureUseDocumentScale", measureUseDocumentScale) } }

    // Search
    var searchIncludeBookmarks: Bool { didSet { persist("searchIncludeBookmarks", searchIncludeBookmarks) } }
    var searchIncludeComments: Bool { didSet { persist("searchIncludeComments", searchIncludeComments) } }
    var searchIncludeAttachments: Bool { didSet { persist("searchIncludeAttachments", searchIncludeAttachments) } }
    var searchIgnoreDiacritics: Bool { didSet { persist("searchIgnoreDiacritics", searchIgnoreDiacritics) } }
    var searchMaxResults: Int { didSet { persist("searchMaxResults", searchMaxResults) } }
    var searchContextWords: Int { didSet { persist("searchContextWords", searchContextWords) } }

    // Spelling
    var checkSpellingWhileTyping: Bool { didSet { persist("checkSpellingWhileTyping", checkSpellingWhileTyping) } }
    var correctSpellingAutomatically: Bool { didSet { persist("correctSpellingAutomatically", correctSpellingAutomatically) } }
    var spellingLanguage: String { didSet { persist("spellingLanguage", spellingLanguage) } }

    // Security
    var linkPolicy: LinkOpeningPolicy { didSet { persist("linkPolicy", linkPolicy.rawValue) } }

    // Tools
    var favoriteTools: [String] { didSet { persist("favoriteTools", favoriteTools) } }

    static let defaultZoomSteps: [Double] = [0.50, 0.67, 0.75, 0.90, 1.00, 1.10, 1.25, 1.50, 1.75, 2.00]

    static func normalizedZoomSteps(_ steps: [Double]) -> [Double] {
        let clamped = steps.filter(\.isFinite).map { min(max($0, Constants.Limits.minZoom), Constants.Limits.maxZoom) }
        let unique = Array(Set(clamped.map { ($0 * 100).rounded() / 100 })).sorted()
        return unique.count >= 2 ? unique : defaultZoomSteps
    }

    init(defaults: UserDefaults = AppEnvironment.defaults) {
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
        func double(_ key: String, _ fallback: Double) -> Double {
            (defaults.object(forKey: Self.keyPrefix + key) as? NSNumber)?.doubleValue ?? fallback
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            (defaults.object(forKey: Self.keyPrefix + key) as? NSNumber)?.intValue ?? fallback
        }
        func string(_ key: String, _ fallback: String) -> String { defaults.string(forKey: Self.keyPrefix + key) ?? fallback }
        useDocumentInitialView = bool("useDocumentInitialView", true)
        hasCompletedOnboarding = bool("hasCompletedOnboarding", false)
        lastSeenWhatsNew = string("lastSeenWhatsNew", "")
        showWhatsNewAfterUpdates = bool("showWhatsNewAfterUpdates", true)
        showXFANotice = bool("showXFANotice", true)
        identityEmail = string("identityEmail", "")
        identityOrganization = string("identityOrganization", "")
        identityTitle = string("identityTitle", "")
        smoothImages = bool("smoothImages", true)
        pageShadows = bool("pageShadows", true)
        showPageLabels = bool("showPageLabels", true)
        zoomSteps = Self.normalizedZoomSteps((defaults.array(forKey: Self.keyPrefix + "zoomSteps") as? [Double]) ?? Self.defaultZoomSteps)
        documentColorMode = DocumentColorMode(rawValue: raw("documentColorMode")) ?? .original
        customPageTextColor = UInt32(clamping: int("customPageTextColor", 0x1E1E1E))
        customPageBackgroundColor = UInt32(clamping: int("customPageBackgroundColor", 0xF4ECD8))
        readAloudVoice = string("readAloudVoice", "")
        readAloudRate = double("readAloudRate", 0.5)
        readAloudHighlight = bool("readAloudHighlight", true)
        autoScrollSpeed = double("autoScrollSpeed", 40)
        fullScreenAdvance = bool("fullScreenAdvance", false)
        fullScreenAdvanceSeconds = double("fullScreenAdvanceSeconds", 5)
        fullScreenLoop = bool("fullScreenLoop", false)
        fullScreenClickAdvances = bool("fullScreenClickAdvances", true)
        fullScreenBackground = FullScreenBackground(rawValue: raw("fullScreenBackground")) ?? .black
        fullScreenTransition = PageTransitionStyle(rawValue: raw("fullScreenTransition")) ?? .none
        fullScreenUseDocumentTransitions = bool("fullScreenUseDocumentTransitions", true)
        fullScreenShowNavigation = bool("fullScreenShowNavigation", true)
        pageUnits = PageUnit(rawValue: raw("pageUnits")) ?? (Locale.current.measurementSystem == .metric ? .millimeters : .inches)
        showRulers = bool("showRulers", false)
        showGrid = bool("showGrid", false)
        showGuides = bool("showGuides", true)
        gridSpacing = double("gridSpacing", 1)
        gridSubdivisions = int("gridSubdivisions", 4)
        gridColor = OverlayColor(rawValue: raw("gridColor")) ?? .cyan
        guideColor = OverlayColor(rawValue: raw("guideColor")) ?? .magenta
        snapToGrid = bool("snapToGrid", false)
        measureScalePage = double("measureScalePage", 1)
        measureScalePageUnit = MeasureUnit(rawValue: raw("measureScalePageUnit")) ?? .inch
        measureScaleReal = double("measureScaleReal", 1)
        measureScaleRealUnit = MeasureUnit(rawValue: raw("measureScaleRealUnit")) ?? .inch
        measurePrecision = int("measurePrecision", 2)
        measureSnapEndpoints = bool("measureSnapEndpoints", true)
        measureSnapMidpoints = bool("measureSnapMidpoints", true)
        measureSnapIntersections = bool("measureSnapIntersections", true)
        measureSnapPaths = bool("measureSnapPaths", true)
        measureAddAnnotations = bool("measureAddAnnotations", true)
        measureColor = AnnotationPreferenceColor(rawValue: raw("measureColor")) ?? .red
        measureUseDocumentScale = bool("measureUseDocumentScale", true)
        searchIncludeBookmarks = bool("searchIncludeBookmarks", true)
        searchIncludeComments = bool("searchIncludeComments", true)
        searchIncludeAttachments = bool("searchIncludeAttachments", false)
        searchIgnoreDiacritics = bool("searchIgnoreDiacritics", true)
        searchMaxResults = int("searchMaxResults", 500)
        searchContextWords = int("searchContextWords", 8)
        checkSpellingWhileTyping = bool("checkSpellingWhileTyping", true)
        correctSpellingAutomatically = bool("correctSpellingAutomatically", false)
        spellingLanguage = string("spellingLanguage", "")
        linkPolicy = LinkOpeningPolicy(rawValue: raw("linkPolicy")) ?? .ask
        favoriteTools = (defaults.array(forKey: Self.keyPrefix + "favoriteTools") as? [String]) ?? []
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
        // Onboarding/What's New history and the identity details are kept.
        useDocumentInitialView = true; showWhatsNewAfterUpdates = true; showXFANotice = true
        smoothImages = true; pageShadows = true; showPageLabels = true; zoomSteps = Self.defaultZoomSteps
        documentColorMode = .original; customPageTextColor = 0x1E1E1E; customPageBackgroundColor = 0xF4ECD8
        readAloudVoice = ""; readAloudRate = 0.5; readAloudHighlight = true; autoScrollSpeed = 40
        fullScreenAdvance = false; fullScreenAdvanceSeconds = 5; fullScreenLoop = false; fullScreenClickAdvances = true
        fullScreenBackground = .black; fullScreenTransition = .none; fullScreenUseDocumentTransitions = true
        fullScreenShowNavigation = true
        pageUnits = Locale.current.measurementSystem == .metric ? .millimeters : .inches
        showRulers = false; showGrid = false; showGuides = true; gridSpacing = 1; gridSubdivisions = 4
        gridColor = .cyan; guideColor = .magenta; snapToGrid = false
        measureScalePage = 1; measureScalePageUnit = .inch; measureScaleReal = 1; measureScaleRealUnit = .inch
        measurePrecision = 2; measureSnapEndpoints = true; measureSnapMidpoints = true; measureSnapIntersections = true
        measureSnapPaths = true; measureAddAnnotations = true; measureColor = .red; measureUseDocumentScale = true
        searchIncludeBookmarks = true; searchIncludeComments = true; searchIncludeAttachments = false
        searchIgnoreDiacritics = true; searchMaxResults = 500; searchContextWords = 8
        checkSpellingWhileTyping = true; correctSpellingAutomatically = false; spellingLanguage = ""
        linkPolicy = .ask
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
