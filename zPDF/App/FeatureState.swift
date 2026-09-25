import AppKit
import Foundation
import PDFKit

/// UI state for the viewing, navigation, search, print, automation and help
/// features. Owned by AppState (`appState.features`) so feature code never
/// grows AppState itself. Per-document view state is keyed by tab id.
@MainActor @Observable
final class FeatureState {
    // Sheets and panels presented by FeatureHost.
    var propertiesTabID: UUID?
    var propertiesInitialPane: DocumentPropertiesPane = .description
    var printTabID: UUID?
    /// Options the next print dialog starts with (e.g. from a custom command).
    var printInitialOptions: PrintOptions?
    var showingAdvancedSearch = false
    var helpTopic: HelpTopicID?
    var showingOnboarding = false
    var showingWhatsNew = false
    var xmpTabID: UUID?

    /// Per-document viewing state (cover page, split view, guides...).
    @ObservationIgnored private(set) var viewing: [UUID: DocumentViewingState] = [:]

    func viewing(for tab: DocumentTab) -> DocumentViewingState {
        if let existing = viewing[tab.id] { return existing }
        let created = DocumentViewingState()
        viewing[tab.id] = created
        return created
    }

    func forget(_ tabID: UUID) { viewing[tabID] = nil }

    let readAloud = ReadAloudController()
    /// Marquee chosen for File ▸ Print Selected Area.
    var printArea: (tabID: UUID, page: Int, rect: CGRect)?
    /// True while the marquee for printing is armed on the canvas.
    var selectingPrintArea = false
    @ObservationIgnored private var marqueeTool: MarqueeCanvasTool?

    func marquee(_ appState: AppState) -> MarqueeCanvasTool {
        if let marqueeTool { return marqueeTool }
        let tool = MarqueeCanvasTool(appState: appState)
        marqueeTool = tool
        return tool
    }
    let measure = MeasureSession()
    let autoScroll = AutoScrollController()
    @ObservationIgnored private var measureCanvasTool: MeasureCanvasTool?

    func measureTool(_ appState: AppState) -> MeasureCanvasTool {
        if let measureCanvasTool { return measureCanvasTool }
        let tool = MeasureCanvasTool(appState: appState)
        measureCanvasTool = tool
        return tool
    }
    /// Reading order of one page, drawn by the canvas overlay.
    var readingOrder: (tabID: UUID, page: Int, items: [ReadingOrderItem])?

    /// Tabs whose document-defined initial view was already applied.
    @ObservationIgnored var appliedInitialView: Set<UUID> = []
}

/// View-only state for one open document. Nothing here is saved into the PDF.
@MainActor @Observable
final class DocumentViewingState {
    /// Two-up with the first page shown alone (Acrobat "Show Cover Page").
    var showsCoverPage = false
    var split: SplitViewMode = .none
    /// Guides in page space, per page index.
    var horizontalGuides: [Int: [CGFloat]] = [:]
    var verticalGuides: [Int: [CGFloat]] = [:]
    var loupeActive = false
    var panZoomActive = false
    var reflowActive = false
    var readingOrderOverlay = false
}

enum SplitViewMode: String, CaseIterable, Identifiable {
    case none, vertical, horizontal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "No Split"
        case .vertical: "Split Side by Side"
        case .horizontal: "Split Top and Bottom"
        }
    }
}

/// Identifies an in-app help page (see HelpCatalog).
struct HelpTopicID: Hashable, Identifiable {
    let rawValue: String
    var id: String { rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

enum DocumentPropertiesPane: String, CaseIterable, Identifiable {
    case description = "Description", security = "Security", fonts = "Fonts", initialView = "Initial View",
         custom = "Custom", advanced = "Advanced"
    var id: String { rawValue }
}

extension AppState {
    func showDocumentProperties(_ pane: DocumentPropertiesPane = .description) {
        guard let tab = activeTab, commitFieldEditing() else { return }
        features.propertiesInitialPane = pane
        features.propertiesTabID = tab.id
    }

    func tab(withID id: UUID?) -> DocumentTab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }
}
