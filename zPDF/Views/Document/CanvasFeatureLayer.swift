import CoreImage
import PDFKit
import SwiftUI

/// Sits above the page canvas: applies view-only display settings to the
/// shared PDFView (cover page, smoothing, shadows, document colors) and hosts
/// the canvas overlays (rulers/grid/guides, measuring, loupe, reading order).
/// Overlays pass mouse events through unless a tool is active.
struct CanvasFeatureLayer: View {
    let tab: DocumentTab
    @Environment(AppState.self) private var appState

    var body: some View {
        let viewing = appState.features.viewing(for: tab)
        let preferences = appState.preferences
        ZStack {
            Color.clear
                .allowsHitTesting(false)
                .onAppear { apply() }
                .onChange(of: viewing.showsCoverPage) { _, _ in apply() }
                .onChange(of: tab.viewMode) { _, _ in DispatchQueue.main.async { apply() } }
                .onChange(of: tab.pdfDocument) { _, _ in DispatchQueue.main.async { apply() } }
                .onChange(of: preferences.smoothImages) { _, _ in apply() }
                .onChange(of: preferences.pageShadows) { _, _ in apply() }
                .onChange(of: preferences.documentColorMode) { _, _ in apply() }
                .onChange(of: preferences.customPageTextColor) { _, _ in apply() }
                .onChange(of: preferences.customPageBackgroundColor) { _, _ in apply() }
        }
    }

    private func apply() {
        guard let view = appState.pdfViewStore.pdfView, view.document === tab.pdfDocument else { return }
        let viewing = appState.features.viewing(for: tab)
        DocumentDisplay.apply(to: view, coverPage: viewing.showsCoverPage, preferences: appState.preferences)
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
