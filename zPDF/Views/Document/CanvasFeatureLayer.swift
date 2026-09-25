import CoreImage
import PDFKit
import SwiftUI

/// Sits above the page canvas: applies view-only display settings to the
/// shared PDFView (cover page, smoothing, shadows, document colors) and hosts
/// the canvas overlays (rulers/grid/guides, measuring, loupe, reading order)
/// and Reflow. Overlays pass mouse events through unless a tool is active.
struct CanvasFeatureLayer: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState

    var body: some View {
        let viewing = appState.features.viewing(for: tab)
        let preferences = appState.preferences
        let measure = appState.features.measure
        ZStack {
            CanvasOverlayRepresentable(viewStore: appState.pdfViewStore, document: tab.pdfDocument, content: overlayContent)
            if viewing.loupeActive {
                LoupeOverlay(viewStore: appState.pdfViewStore) { viewing.loupeActive = false }
            }
            if viewing.reflowActive {
                ReflowView(tab: tab) { viewing.reflowActive = false }
            }
        }
        .overlay(alignment: .bottom) {
            if tab.saveBlock == "XFA_EDIT_BLOCKED", preferences.showXFANotice {
                XFANoticeBanner(tab: tab).padding(.bottom, 12)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if viewing.panZoomActive && !viewing.reflowActive {
                PanZoomPanel(tab: tab, viewStore: appState.pdfViewStore) { viewing.panZoomActive = false }
                    .padding(16)
            }
        }
        .overlay(alignment: .bottom) {
            if appState.features.autoScroll.isActive {
                AutoScrollBanner(controller: appState.features.autoScroll)
            }
        }
        .overlay(alignment: .top) {
            if appState.features.selectingPrintArea, appState.activeTab === tab {
                CanvasHintBanner(symbol: "crop", text: "Drag a rectangle around the area to print.") {
                    appState.features.selectingPrintArea = false
                }
            } else if let kind = measure.kind, appState.activeTab === tab {
                MeasureBanner(kind: kind, calibrating: measure.calibrating) {
                    measure.kind = nil
                    measure.calibrating = false
                    measure.cancelInProgress()
                }
            }
        }
        .onAppear { apply() }
        .onChange(of: viewing.showsCoverPage) { _, _ in apply() }
        .onChange(of: tab.viewMode) { _, _ in DispatchQueue.main.async { apply() } }
        .onChange(of: tab.pdfDocument) { _, _ in DispatchQueue.main.async { apply() } }
        .onChange(of: preferences.smoothImages) { _, _ in apply() }
        .onChange(of: preferences.pageShadows) { _, _ in apply() }
        .onChange(of: preferences.documentColorMode) { _, _ in apply() }
        .onChange(of: preferences.customPageTextColor) { _, _ in apply() }
        .onChange(of: preferences.customPageBackgroundColor) { _, _ in apply() }
        // One canvas interaction at a time: arming another tool ends measuring.
        .onChange(of: appState.armedAnnotationTool) { _, tool in if tool != nil { measure.kind = nil } }
        .onChange(of: appState.armedFormFieldTool) { _, tool in if tool != nil { measure.kind = nil } }
        .onChange(of: appState.textEditingModeActive) { _, active in if active { measure.kind = nil } }
        .onChange(of: tab.editSource?.hash) { _, _ in measure.loadDocumentScales(appState: appState, tab: tab) }
        .task(id: tab.id) { measure.loadDocumentScales(appState: appState, tab: tab) }
        .task(id: "\(viewing.readingOrderOverlay)-\(tab.currentPage)-\(tab.editSource?.hash ?? "")") {
            await loadReadingOrder(viewing.readingOrderOverlay)
        }
    }

    /// Reading order for the overlay and the Accessibility panel list.
    private func loadReadingOrder(_ active: Bool) async {
        guard active, appState.canQuery(tab) else {
            if !active, appState.features.readingOrder?.tabID == tab.id { appState.features.readingOrder = nil }
            return
        }
        let page = tab.currentPage - 1
        guard let result = try? await appState.documentQuery("reading_order", params: ["page": page], in: tab,
                                                              as: ReadingOrderResult.self) else { return }
        appState.features.readingOrder = (tab.id, page, result.items)
    }

    private var overlayContent: CanvasOverlayContent {
        let preferences = appState.preferences
        let viewing = appState.features.viewing(for: tab)
        var content = CanvasOverlayContent()
        content.showRulers = preferences.showRulers
        content.showGrid = preferences.showGrid
        content.showGuides = preferences.showGuides
        content.unit = preferences.pageUnits
        content.gridSpacing = preferences.gridSpacing
        content.gridSubdivisions = preferences.gridSubdivisions
        content.gridColor = preferences.gridColor.nsColor
        content.guideColor = preferences.guideColor.nsColor
        content.viewing = viewing
        if viewing.readingOrderOverlay, let order = appState.features.readingOrder, order.tabID == tab.id {
            content.readingOrder = (order.page, order.items)
        }
        let measure = appState.features.measure
        if appState.features.selectingPrintArea, appState.activeTab === tab {
            content.tool = appState.features.marquee(appState)
        } else if measure.kind != nil, appState.activeTab === tab {
            content.tool = appState.features.measureTool(appState)
        }
        // Touch observed values so SwiftUI redraws the overlay when they change.
        _ = (measure.points, measure.hover, measure.measurements, viewing.horizontalGuides, viewing.verticalGuides)
        return content
    }

    private func apply() {
        guard let view = appState.pdfViewStore.pdfView, view.document === tab.pdfDocument else { return }
        let viewing = appState.features.viewing(for: tab)
        DocumentDisplay.apply(to: view, coverPage: viewing.showsCoverPage, preferences: appState.preferences)
    }
}

private struct AutoScrollBanner: View {
    let controller: AutoScrollController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.reversed ? "arrow.up" : "arrow.down").foregroundStyle(DesignTokens.Colors.accent)
            Text("Scrolling \(Int(controller.speed)) pt/s").font(.system(size: 11)).monospacedDigit()
            Text("1–9 speed · − reverse · Esc stop").font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
            Button("Stop") { controller.stop() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.accent)
                .help("Stop automatic scrolling (⇧⌘H)")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(DesignTokens.Colors.hairline, lineWidth: 1))
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Floating hint with a cancel button for canvas tools.
struct CanvasHintBanner: View {
    let symbol: String
    let text: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(DesignTokens.Colors.accent)
            Text(text).font(.system(size: 11))
            Button("Cancel", action: cancel)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.accent)
                .help("Cancel (Esc)")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(DesignTokens.Colors.hairline, lineWidth: 1))
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Floating hint while the Measure tool owns the canvas.
private struct MeasureBanner: View {
    let kind: MeasureSession.Kind
    let calibrating: Bool
    let done: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbol).foregroundStyle(DesignTokens.Colors.accent)
            Text(calibrating ? "Draw a line over a known length to set the scale." : kind.help)
                .font(.system(size: 11))
            Text("Esc to cancel").font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
            Button("Done", action: done)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.accent)
                .help("Stop measuring")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(DesignTokens.Colors.hairline, lineWidth: 1))
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Display settings shared by the main canvas, split panes and extra windows.
@MainActor
enum DocumentDisplay {
    static func apply(to view: PDFView, coverPage: Bool, preferences: AppPreferences) {
        if view.displaysAsBook != coverPage { view.displaysAsBook = coverPage }
        view.interpolationQuality = preferences.smoothImages ? .high : .none
        view.pageShadowsEnabled = preferences.pageShadows
        applyColors(to: view, mode: preferences.documentColorMode, preferences: preferences)
    }

    /// Replace document colors with a Core Image filter on the page layer.
    /// Only the on-screen rendering changes; printing and Save are unaffected.
    static func applyColors(to view: PDFView, mode: DocumentColorMode, preferences: AppPreferences) {
        view.wantsLayer = true
        guard let filter = colorFilter(mode: mode, preferences: preferences) else {
            if !(view.contentFilters.isEmpty) { view.contentFilters = [] }
            return
        }
        view.layerUsesCoreImageFilters = true
        view.contentFilters = filter
    }

    static func colorFilter(mode: DocumentColorMode, preferences: AppPreferences) -> [CIFilter]? {
        switch mode {
        case .original:
            return nil
        case .night:
            // Invert luminance but keep hues recognisable (invert + 180° hue).
            guard let invert = CIFilter(name: "CIColorInvert"), let hue = CIFilter(name: "CIHueAdjust") else { return nil }
            hue.setValue(Float.pi, forKey: kCIInputAngleKey)
            return [invert, hue]
        default:
            let pair = mode.mapping ?? (preferences.customPageTextColor, preferences.customPageBackgroundColor)
            return [mappingFilter(text: pair.text, background: pair.background)]
        }
    }

    /// Maps luminance 0 → text color and 1 → background color.
    static func mappingFilter(text: UInt32, background: UInt32) -> CIFilter {
        func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        let t = rgb(text), b = rgb(background)
        let weights: (CGFloat, CGFloat, CGFloat) = (0.2126, 0.7152, 0.0722)
        let filter = CIFilter(name: "CIColorMatrix")!
        func vector(_ delta: CGFloat) -> CIVector {
            CIVector(x: delta * weights.0, y: delta * weights.1, z: delta * weights.2, w: 0)
        }
        filter.setValue(vector(b.0 - t.0), forKey: "inputRVector")
        filter.setValue(vector(b.1 - t.1), forKey: "inputGVector")
        filter.setValue(vector(b.2 - t.2), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: t.0, y: t.1, z: t.2, w: 0), forKey: "inputBiasVector")
        return filter
    }
}
