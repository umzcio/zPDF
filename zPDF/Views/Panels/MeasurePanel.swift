import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Measure tool: distance, perimeter and area with scale and calibration,
/// snapping, a measurement list and CSV export. Measurements are saved as
/// standard Line / PolyLine / Polygon annotations with a /Measure dictionary.
struct MeasurePanel: View {
    @Environment(AppState.self) private var appState
    @State private var documentItems: [DocumentMeasurement] = []
    @State private var showingCalibration = false

    private var tab: DocumentTab? { appState.activeTab }
    private var session: MeasureSession { appState.features.measure }

    var body: some View {
        @Bindable var preferences = appState.preferences
        let session = self.session
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            PanelSection(title: "Measuring Tools") {
                PanelToolGrid {
                    ForEach(MeasureSession.Kind.allCases) { kind in
                        PanelToolButton(title: kind.title, symbolName: kind.symbol, isActive: session.kind == kind && !session.calibrating) {
                            activate(kind)
                        }
                        .help(kind.help)
                    }
                    PanelToolButton(title: "Calibrate", symbolName: "scope", isActive: session.calibrating) {
                        session.calibrating.toggle()
                        session.kind = session.calibrating ? .distance : nil
                        session.cancelInProgress()
                        startCanvasInteraction()
                    }
                    .help("Draw a line over a known length on the page to set the scale")
                }
                .disabled(tab == nil)
                PanelNote("Snaps to line ends, midpoints and intersections. Hold Shift for 45° angles. Delete removes the last point; Esc cancels.")
            }

            PanelSection(title: "Scale") {
                scaleEditor(preferences: preferences)
                if let tab, let docScale = session.documentScales[tab.id]?[tab.currentPage - 1] {
                    Toggle(isOn: $preferences.measureUseDocumentScale) {
                        Text("Use the document's scale (\(docScale.ratio))").font(.system(size: 11.5))
                    }
                    .toggleStyle(.checkbox)
                    .help("This page defines its own measurement scale")
                }
                Button("Save Scale in Document") { saveScale() }
                    .controlSize(.small)
                    .disabled(tab?.allowsSaveEdits != true)
                    .help("Store this scale in every page so other PDF viewers measure the same way")
            }

            PanelSection(title: "Snapping") {
                Toggle("Endpoints", isOn: $preferences.measureSnapEndpoints)
                Toggle("Midpoints", isOn: $preferences.measureSnapMidpoints)
                Toggle("Intersections", isOn: $preferences.measureSnapIntersections)
                Toggle("Along paths", isOn: $preferences.measureSnapPaths)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))

            measurementsSection(preferences: preferences)
        }
        .task(id: tab?.editSource?.hash) { await loadDocumentItems() }
        .onChange(of: session.pendingCalibration?.tabID) { _, value in showingCalibration = value != nil }
        .sheet(isPresented: $showingCalibration, onDismiss: { session.pendingCalibration = nil }) {
            if let pending = session.pendingCalibration {
                CalibrationSheet(points: pending.points)
            }
        }
    }

    private func scaleEditor(preferences: AppPreferences) -> some View {
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                TextField("Page", value: $preferences.measureScalePage, format: .number)
                    .frame(width: 52).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Page length")
                Picker("Page unit", selection: $preferences.measureScalePageUnit) {
                    ForEach([MeasureUnit.inch, .mm, .cm, .pt]) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 58)
                Text("=")
                TextField("Real", value: $preferences.measureScaleReal, format: .number)
                    .frame(width: 60).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Real-world length")
                Picker("Real unit", selection: $preferences.measureScaleRealUnit) {
                    ForEach(MeasureUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 58)
            }
            .controlSize(.small)
            Stepper("Precision: \(preferences.measurePrecision) decimal\(preferences.measurePrecision == 1 ? "" : "s")",
                    value: $preferences.measurePrecision, in: 0...4)
                .font(.system(size: 11.5))
        }
    }

    private func measurementsSection(preferences: AppPreferences) -> some View {
        @Bindable var preferences = preferences
        let pending = tab.map { session.measurements(for: $0.id).filter { !$0.committed } } ?? []
        return PanelSection(title: "Measurements") {
            Toggle("Add measurements to the document", isOn: $preferences.measureAddAnnotations)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .help("Save each measurement as a PDF measurement annotation. Off: keep them on screen until you add them.")
            if documentItems.isEmpty && pending.isEmpty {
                Text("No measurements yet.").font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
            }
            ForEach(Array(documentItems.enumerated()), id: \.offset) { _, item in
                measurementRow(symbol: symbol(item.kind), label: item.label.isEmpty ? item.kind.capitalized : item.label,
                               page: item.page, saved: true)
            }
            ForEach(pending) { item in
                measurementRow(symbol: item.kind.symbol, label: item.label, page: item.page, saved: false)
            }
            HStack {
                Button("Add to Document") {
                    if let tab { appState.commitMeasurements(pending, in: tab) }
                }
                .disabled(pending.isEmpty || tab?.allowsSaveEdits != true)
                .help("Save the on-screen measurements as annotations")
                Button("Export CSV…") { exportCSV(pending: pending) }
                    .disabled(documentItems.isEmpty && pending.isEmpty)
                    .help("Save every measurement in this document as a spreadsheet file")
            }
            .controlSize(.small)
            if !pending.isEmpty {
                Button("Clear On-Screen Measurements") { if let tab { session.remove(Set(session.measurements(for: tab.id).filter { !$0.committed }.map(\.id))) } }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
    }

    private func measurementRow(symbol: String, label: String, page: Int, saved: Bool) -> some View {
        Button { tab?.goToPage(page + 1) } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).frame(width: 16).foregroundStyle(DesignTokens.Colors.mutedText)
                Text(label).font(.system(size: 12)).monospacedDigit()
                Spacer()
                Text("p. \(page + 1)").font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                if !saved {
                    Image(systemName: "circle.dashed").font(.system(size: 10)).foregroundStyle(.orange)
                        .help("Not yet saved in the document")
                        .accessibilityLabel("Not saved")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Go to page \(page + 1)")
    }

    private func symbol(_ kind: String) -> String {
        MeasureSession.Kind(rawValue: kind)?.symbol ?? "ruler"
    }

    private func activate(_ kind: MeasureSession.Kind) {
        session.calibrating = false
        session.kind = session.kind == kind ? nil : kind
        session.cancelInProgress()
        startCanvasInteraction()
    }

    /// Only one canvas interaction is live at a time.
    private func startCanvasInteraction() {
        guard session.kind != nil else { return }
        appState.armedAnnotationTool = nil
        appState.armedFormFieldTool = nil
        appState.textEditingModeActive = false
        appState.signatureService.disarmPlacement()
    }

    private func loadDocumentItems() async {
        guard let tab, appState.canQuery(tab) else { documentItems = []; return }
        documentItems = (try? await appState.documentQuery("measurements", in: tab, as: DocumentMeasurementsResult.self).items) ?? []
        session.loadDocumentScales(appState: appState, tab: tab)
    }

    private func saveScale() {
        guard let tab else { return }
        let scale = MeasureSession.preferenceScale(appState.preferences)
        Task {
            await appState.performDocumentEdit([["op": "set_page_scale", "ratio": scale.ratio, "factor": scale.factor, "unit": scale.unit]],
                                               actionName: "Save Measurement Scale", in: tab)
        }
    }

    private func exportCSV(pending: [MeasureSession.Measurement]) {
        guard let tab else { return }
        let panel = NSSavePanel()
        panel.title = "Export Measurements"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = (tab.displayName as NSString).deletingPathExtension + " measurements.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = MeasurementCSV.make(document: documentItems, pending: pending, fileName: tab.displayName)
        do { try Data(csv.utf8).write(to: url, options: .atomic) }
        catch { appState.reportPanelError(error, in: tab) }
    }
}

/// Sets the scale from a line the user drew over a known length.
private struct CalibrationSheet: View {
    let points: [CGPoint]
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var real: Double = 1
    @State private var unit: MeasureUnit = .ft

    private var inches: Double { MeasureSession.length(points) / 72 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calibrate Scale").font(.headline)
            Text("The line you drew is \(inches.formatted(.number.precision(.fractionLength(3)))) in on the page. How long is it in reality?")
                .font(.callout).foregroundStyle(DesignTokens.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Length", value: $real, format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
                    .accessibilityLabel("Real-world length")
                Picker("Unit", selection: $unit) { ForEach(MeasureUnit.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(width: 130)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set Scale") {
                    let preferences = appState.preferences
                    preferences.measureScalePageUnit = .inch
                    preferences.measureScalePage = (inches * 10_000).rounded() / 10_000
                    preferences.measureScaleRealUnit = unit
                    preferences.measureScaleReal = real
                    preferences.measureUseDocumentScale = false
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(real > 0) || inches <= 0)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
