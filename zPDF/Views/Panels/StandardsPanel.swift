import AppKit
import PDFKit
import SwiftUI

/// Output standards the app can validate and convert to.
enum OutputStandard: String, CaseIterable, Identifiable {
    case pdfa2b = "PDF/A-2b", pdfa3b = "PDF/A-3b", pdfx4 = "PDF/X-4", pdfe1 = "PDF/E-1"
    var id: String { rawValue }
    var purpose: String {
        switch self {
        case .pdfa2b: "Long-term archiving"
        case .pdfa3b: "Archiving with attached source files"
        case .pdfx4: "Commercial printing"
        case .pdfe1: "Engineering documents"
        }
    }
    var ops: [[String: Any]] {
        switch self {
        case .pdfa2b: [["op": "convert_pdfa", "level": "2b"]]
        case .pdfa3b: [["op": "convert_pdfa", "level": "3b"]]
        case .pdfx4: [["op": "convert_pdfx", "bleed": 0]]
        case .pdfe1: [["op": "convert_pdfe"]]
        }
    }
    var suffix: String {
        switch self {
        case .pdfa2b, .pdfa3b: "PDFA"
        case .pdfx4: "PDFX"
        case .pdfe1: "PDFE"
        }
    }
}

struct StandardIssue: Identifiable {
    let id = UUID()
    let rule: String
    let message: String
    let severity: String
    let count: Int
    let fixable: Bool
}

struct PreflightResult: Identifiable {
    let id = UUID()
    let rule: String
    let title: String
    let severity: String
    let detail: String
    let pages: [Int]
    let fix: String?

    var fixTitle: String? {
        switch fix {
        case "embed_fonts": "Embed fonts"
        case "downsample": "Downsample"
        case "map_spots": "Convert to process"
        case "flatten": "Flatten"
        case "hairlines": "Thicken to 0.25 pt"
        case "set_trim": "Set TrimBox"
        case "flatten_annotations": "Flatten"
        case "remove_javascript": "Remove"
        case "convert_pdfx": "Convert to PDF/X-4"
        case "convert_pdfa": "Convert to PDF/A-2b"
        default: nil
        }
    }

    var fixOps: [[String: Any]]? {
        switch fix {
        case "embed_fonts": [["op": "embed_fonts"]]
        case "downsample": [["op": "optimize", "preset": "medium", "compress": false]]
        case "map_spots": [["op": "map_spots_to_process"]]
        case "flatten": [["op": "flatten_transparency", "dpi": 300]]
        case "hairlines": [["op": "fix_hairlines", "min_width": 0.25]]
        case "set_trim": [["op": "set_trim_to_crop"]]
        case "flatten_annotations": [["op": "flatten_annotations"]]
        case "remove_javascript": [["op": "remove_javascript"]]
        case "convert_pdfx": OutputStandard.pdfx4.ops
        case "convert_pdfa": OutputStandard.pdfa2b.ops
        default: nil
        }
    }
}

/// Severity icon shared by validation and preflight lists.
struct SeverityIcon: View {
    let severity: String
    var body: some View {
        Image(systemName: severity == "error" ? "xmark.octagon.fill" : severity == "warning" ? "exclamationmark.triangle.fill"
              : severity == "pass" ? "checkmark.circle.fill" : "info.circle")
            .foregroundStyle(severity == "error" ? Color.red : severity == "warning" ? Color.orange
                             : severity == "pass" ? DesignTokens.Colors.readyGreen : DesignTokens.Colors.mutedText)
            .accessibilityLabel(severity == "pass" ? "Passed" : severity.capitalized)
    }
}

/// Standards (PDF/A, PDF/X, PDF/E), preflight and print production tools.
struct StandardsPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let tab = appState.activeTab {
            StandardsControls(tab: tab).id(tab.id)
        } else {
            PanelNote("Open a document to check standards.")
        }
    }
}

private struct StandardsControls: View {
    @Environment(AppState.self) private var appState
    let tab: DocumentTab
    @State private var standard: OutputStandard = .pdfa2b
    @State private var claims: [String] = []
    @State private var issues: [StandardIssue]?
    @State private var compliant = false
    @State private var validating = false
    @State private var profile = "commercial"
    @State private var preflight: [PreflightResult]?
    @State private var preflightSummary = ""
    @State private var running = false
    @State private var inks: [(name: String, alternate: String, mappable: Bool)] = []
    @State private var process: [String] = []
    @State private var inksLoaded = false
    @State private var marks = (crop: true, bleed: true, registration: true, bars: true, info: true)
    @State private var bleed = 9.0
    @State private var flattenDPI = 300

    private static let profiles: [(String, String)] = [("commercial", "Commercial print (PDF/X-4 readiness)"),
                                                       ("digital", "Digital printing"), ("web", "Online publishing"),
                                                       ("archive", "Archiving (PDF/A-2b readiness)")]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            standardsSection
            preflightSection
            printSection
            PanelNote("Validation uses zPDF's built-in checks for the rules it can test and fix. It is not a certified validator; confirm critical deliveries with your print provider's or archive's validator.")
        }
        .task { await loadClaims() }
    }

    // MARK: Standards

    private var standardsSection: some View {
        PanelSection(title: "Standards") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                if !claims.isEmpty {
                    Label("Identifies as \(claims.joined(separator: ", "))", systemImage: "checkmark.seal")
                        .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                Picker("Standard", selection: $standard) {
                    ForEach(OutputStandard.allCases) { item in
                        Text("\(item.rawValue) — \(item.purpose)").tag(item)
                    }
                }
                .labelsHidden()
                .onChange(of: standard) { _, _ in issues = nil }
                .help("The standard to check or convert to")
                HStack(spacing: 6) {
                    Button(validating ? "Checking…" : "Validate", action: validate)
                        .disabled(validating || tab.editSource == nil)
                        .help("Check the saved revision against \(standard.rawValue)")
                    Button("Save as \(standard.rawValue)…") {
                        Task {
                            await appState.saveTransformedCopy(of: tab, ops: standard.ops, title: "Save as \(standard.rawValue)",
                                                               suffix: standard.suffix)
                        }
                    }
                    .disabled(!tab.allowsSaveEdits)
                    .help("Convert a copy to \(standard.rawValue); the open document is unchanged")
                }
                .controlSize(.small)
                Button("Convert This Document") {
                    appState.runDocumentTransform(standard.ops, actionName: "Convert to \(standard.rawValue)", in: tab) { _ in
                        Task { await loadClaims(); validate() }
                    }
                }
                .controlSize(.small)
                .disabled(!tab.allowsSaveEdits)
                .help("Convert the open document (Undo available); Save keeps the result")
                if let issues {
                    if compliant {
                        WorkflowStatus(text: "No \(standard.rawValue) problems found by the built-in checks.", kind: .success)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(issues) { issue in
                                HStack(alignment: .top, spacing: 6) {
                                    SeverityIcon(severity: issue.severity)
                                    Text(issue.message + (issue.count > 1 ? " (\(issue.count)×)" : ""))
                                        .font(.system(size: 11))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    if !issue.fixable {
                                        Text("Manual").font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText)
                                            .help("Conversion cannot fix this automatically")
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Preflight

    private var preflightSection: some View {
        PanelSection(title: "Preflight") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Picker("Profile", selection: $profile) {
                    ForEach(Self.profiles, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .onChange(of: profile) { _, _ in preflight = nil }
                .help("Choose what the document will be used for")
                PanelActionButton(title: running ? "Analyzing…" : "Analyze", symbolName: "checklist",
                                  help: "Check fonts, images, color, transparency, lines and boxes", action: runPreflight)
                    .disabled(running || tab.editSource == nil)
                if let preflight {
                    Text(preflightSummary).font(.system(size: 11, weight: .medium))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(preflight) { result in
                            PreflightRow(result: result, tab: tab) {
                                guard let ops = result.fixOps else { return }
                                appState.runDocumentTransform(ops, actionName: result.fixTitle ?? "Fix", in: tab) { _ in runPreflight() }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Print production

    private var printSection: some View {
        PanelSection(title: "Print production") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                PanelActionButton(title: "Output Preview…", symbolName: "circle.lefthalf.filled",
                                  help: "Preview CMYK separations and total ink coverage") { appState.present(.outputPreview) }
                PanelActionButton(title: "Set Page Boxes…", symbolName: "crop",
                                  help: "Set crop, trim, bleed and art boxes (⇧⌘T)") { appState.present(.pageBoxes) }
                    .disabled(!tab.allowsSaveEdits)
                DisclosureGroup("Printer marks") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Crop marks", isOn: $marks.crop)
                        Toggle("Bleed marks", isOn: $marks.bleed)
                        Toggle("Registration marks", isOn: $marks.registration)
                        Toggle("Color bars", isOn: $marks.bars)
                        Toggle("Page information", isOn: $marks.info)
                        HStack {
                            Text("Bleed")
                            PointsField(label: "Bleed", points: $bleed, unit: .millimeters, width: 50)
                        }
                        HStack {
                            Button("Add Marks") {
                                appState.runDocumentTransform([["op": "printer_marks", "crop": marks.crop, "bleed_marks": marks.bleed,
                                                                "registration": marks.registration, "color_bars": marks.bars,
                                                                "page_info": marks.info, "bleed": bleed,
                                                                "title": (tab.displayName as NSString).deletingPathExtension]],
                                                              actionName: "Add Printer Marks", in: tab)
                            }
                            .help("Enlarge the page and draw marks outside the trim and bleed")
                            Button("Remove") {
                                appState.runDocumentTransform([["op": "remove_printer_marks"]], actionName: "Remove Printer Marks", in: tab)
                            }
                            .help("Remove marks added by zPDF and restore the page size")
                        }
                        .controlSize(.small)
                    }
                    .font(.system(size: 12)).padding(.top, 4)
                }
                .font(.system(size: 12))
                .disabled(!tab.allowsSaveEdits)
                DisclosureGroup("Transparency flattener") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Resolution", selection: $flattenDPI) {
                            ForEach([150, 300, 600], id: \.self) { Text("\($0) dpi").tag($0) }
                        }
                        .fixedSize()
                        Text("Pages that use transparency are rasterized at this resolution; their text stays searchable as an invisible layer.")
                            .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Flatten Transparency") {
                            appState.runDocumentTransform([["op": "flatten_transparency", "dpi": flattenDPI]],
                                                          actionName: "Flatten Transparency", in: tab) { results in
                                let pages = results.first?["pages"] as? Int ?? 0
                                appState.exportMessage = nil
                                preflightSummary = pages == 0 ? "No pages use transparency." : "Flattened \(pages) page(s)."
                            }
                        }
                        .controlSize(.small)
                    }
                    .font(.system(size: 12)).padding(.top, 4)
                }
                .font(.system(size: 12))
                .disabled(!tab.allowsSaveEdits)
                DisclosureGroup("Ink manager") {
                    VStack(alignment: .leading, spacing: 4) {
                        if !inksLoaded {
                            ProgressView().controlSize(.small)
                        } else {
                            if !process.isEmpty {
                                Text("Process: " + process.joined(separator: ", ")).font(.system(size: 11))
                            }
                            if inks.isEmpty {
                                Text("No spot colors.").font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                            }
                            ForEach(inks, id: \.name) { ink in
                                HStack {
                                    Image(systemName: "drop.fill").foregroundStyle(DesignTokens.Colors.accent)
                                    Text(ink.name).font(.system(size: 11))
                                    Spacer()
                                    Text("→ \(ink.alternate)").font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            if inks.contains(where: \.mappable) {
                                Button("Convert All Spots to Process") {
                                    appState.runDocumentTransform([["op": "map_spots_to_process"]], actionName: "Convert Spot Colors", in: tab) { _ in
                                        Task { await loadInks() }
                                    }
                                }
                                .controlSize(.small)
                                .help("Replace spot inks with their CMYK/RGB equivalents")
                            }
                        }
                    }
                    .padding(.top, 4)
                    .task { await loadInks() }
                }
                .font(.system(size: 12))
                PanelActionButton(title: "Fix Hairlines", symbolName: "line.diagonal",
                                  help: "Thicken lines thinner than 0.25 pt so they print") {
                    appState.runDocumentTransform([["op": "fix_hairlines", "min_width": 0.25]], actionName: "Fix Hairlines", in: tab)
                }
                .disabled(!tab.allowsSaveEdits)
            }
        }
    }

    // MARK: Actions

    private func loadClaims() async {
        guard tab.editSource != nil, let result = try? await appState.queryDocument("standards_status", in: tab) else { return }
        claims = result["claims"] as? [String] ?? []
    }

    private func loadInks() async {
        guard let result = try? await appState.queryDocument("inks", in: tab) else { inksLoaded = true; return }
        process = result["process"] as? [String] ?? []
        inks = (result["spots"] as? [[String: Any]] ?? []).map {
            ($0["name"] as? String ?? "", $0["alternate"] as? String ?? "", $0["mappable"] as? Bool ?? false)
        }
        inksLoaded = true
    }

    private func validate() {
        validating = true
        Task {
            defer { validating = false }
            do {
                let result = try await appState.queryDocument("validate_standard", params: ["standard": standard.rawValue], in: tab)
                compliant = result["compliant"] as? Bool ?? false
                issues = (result["issues"] as? [[String: Any]] ?? []).map {
                    StandardIssue(rule: $0["rule"] as? String ?? "", message: $0["message"] as? String ?? "",
                                  severity: $0["severity"] as? String ?? "error", count: $0["count"] as? Int ?? 1,
                                  fixable: $0["fixable"] as? Bool ?? false)
                }
            } catch {
                appState.saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            }
        }
    }

    private func runPreflight() {
        running = true
        Task {
            defer { running = false }
            do {
                let result = try await appState.queryDocument("preflight", params: ["profile": profile], in: tab)
                preflight = (result["results"] as? [[String: Any]] ?? []).map {
                    PreflightResult(rule: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "",
                                    severity: $0["severity"] as? String ?? "info", detail: $0["detail"] as? String ?? "",
                                    pages: $0["pages"] as? [Int] ?? [], fix: $0["fix"] as? String)
                }
                let errors = result["errors"] as? Int ?? 0, warnings = result["warnings"] as? Int ?? 0
                preflightSummary = errors + warnings == 0 ? "No problems found." :
                    "\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")"
            } catch {
                appState.saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            }
        }
    }
}

private struct PreflightRow: View {
    let result: PreflightResult
    let tab: DocumentTab
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            SeverityIcon(severity: result.severity).font(.system(size: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if !result.detail.isEmpty {
                    Text(result.detail).font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let first = result.pages.first {
                    Button("Page\(result.pages.count > 1 ? "s" : "") " + result.pages.prefix(6).map { "\($0 + 1)" }.joined(separator: ", ")
                           + (result.pages.count > 6 ? "…" : "")) { tab.goToPage(first + 1) }
                        .buttonStyle(.link).font(.system(size: 10.5))
                        .help("Go to page \(first + 1)")
                }
            }
            Spacer(minLength: 0)
            if let title = result.fixTitle, result.severity != "pass" {
                Button(title, action: fix).controlSize(.mini)
                    .disabled(!tab.allowsSaveEdits)
                    .help("Apply this fix to the document (Undo available)")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Output preview

/// Approximate separations preview: the page rendered to CMYK through
/// ColorSync (Generic CMYK), shown with selected plates and total-ink
/// warnings. Spot colors appear through their process alternates.
struct OutputPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State private var page = 1
    @State private var plates: Set<Int> = [0, 1, 2, 3]
    @State private var limit = 300.0
    @State private var showLimit = true
    @State private var render: CMYKRender?
    @State private var hover: [Int]?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            HStack {
                Text("Output Preview").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Stepper("Page \(page) of \(tab.pageCount)", value: $page, in: 1...max(1, tab.pageCount))
                    .accessibilityLabel("Preview page")
            }
            HStack(alignment: .top, spacing: DesignTokens.Spacing.large) {
                Group {
                    if let render, let image = render.image(plates: plates, limit: showLimit ? limit : nil) {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .overlay(Rectangle().stroke(DesignTokens.Colors.hairline))
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 420, height: 520)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Separations").font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignTokens.Colors.mutedText)
                    ForEach(Array(["Cyan", "Magenta", "Yellow", "Black"].enumerated()), id: \.offset) { index, name in
                        Toggle(isOn: Binding(get: { plates.contains(index) },
                                             set: { if $0 { plates.insert(index) } else { plates.remove(index) } })) {
                            HStack {
                                Circle().fill([Color.cyan, Color.pink, Color.yellow, Color.black][index]).frame(width: 10, height: 10)
                                Text(name)
                                Spacer()
                                if let render { Text("\(Int(render.average[index].rounded()))%").monospacedDigit()
                                    .foregroundStyle(DesignTokens.Colors.mutedText) }
                            }
                        }
                        .help("Show or hide the \(name.lowercased()) plate; the figure is the page's average coverage")
                    }
                    Divider()
                    Toggle("Highlight total ink above", isOn: $showLimit)
                    HStack {
                        Slider(value: $limit, in: 200...400, step: 10) { Text("Limit") }
                        Text("\(Int(limit))%").monospacedDigit().frame(width: 44)
                    }.disabled(!showLimit)
                    if let render {
                        Text("Maximum total ink: \(Int(render.maxTotal.rounded()))%").font(.system(size: 11))
                        Text("\(String(format: "%.1f", render.percentOver(limit)))% of the page exceeds \(Int(limit))%")
                            .font(.system(size: 11)).foregroundStyle(render.percentOver(limit) > 0 ? .orange : DesignTokens.Colors.mutedText)
                    }
                    Spacer()
                    Text("Simulated with the Generic CMYK profile. Spot colors preview through their process equivalents; this is not a RIP.")
                        .font(.system(size: 10.5)).foregroundStyle(DesignTokens.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 220)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Spacing.xLarge)
        .task(id: page) {
            render = nil
            guard let pdfPage = tab.pdfDocument?.page(at: page - 1) else { return }
            render = CMYKRender(page: pdfPage)
        }
        .onAppear { page = tab.currentPage }
    }
}

/// A page rendered into an 8-bit CMYK buffer with coverage statistics.
struct CMYKRender {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let average: [Double]
    let maxTotal: Double
    private let totals: [UInt16]

    @MainActor
    init?(page: PDFPage, maxSide: CGFloat = 900) {
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = maxSide / max(size.width, size.height)
        width = max(1, Int(size.width * scale)); height = max(1, Int(size.height * scale))
        guard let space = CGColorSpace(name: CGColorSpace.genericCMYK),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(CGColor(genericCMYKCyan: 0, magenta: 0, yellow: 0, black: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.transform(context, for: .cropBox)
        page.draw(with: .cropBox, to: context)
        guard let data = context.data else { return nil }
        let count = width * height * 4
        let buffer = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
        pixels = buffer
        var sums = [Double](repeating: 0, count: 4)
        var totals = [UInt16](repeating: 0, count: width * height)
        var maxTotal: UInt16 = 0
        for i in 0..<(width * height) {
            var t: UInt16 = 0
            for c in 0..<4 {
                let v = buffer[i * 4 + c]
                sums[c] += Double(v)
                t += UInt16(v)
            }
            totals[i] = t
            maxTotal = max(maxTotal, t)
        }
        self.totals = totals
        let n = Double(width * height)
        average = sums.map { $0 / n / 255 * 100 }
        self.maxTotal = Double(maxTotal) / 255 * 100
    }

    func percentOver(_ limit: Double) -> Double {
        let threshold = UInt16(limit / 100 * 255)
        return Double(totals.filter { $0 > threshold }.count) / Double(max(1, totals.count)) * 100
    }

    func image(plates: Set<Int>, limit: Double?) -> CGImage? {
        var buffer = pixels
        for i in 0..<(width * height) {
            for c in 0..<4 where !plates.contains(c) { buffer[i * 4 + c] = 0 }
        }
        guard let space = CGColorSpace(name: CGColorSpace.genericCMYK),
              let provider = CGDataProvider(data: Data(buffer) as CFData),
              let cmyk = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                 space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let rgb = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        rgb.draw(cmyk, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let limit, let data = rgb.data {
            let threshold = UInt16(limit / 100 * 255)
            let out = data.assumingMemoryBound(to: UInt8.self)
            let stride = rgb.bytesPerRow
            for y in 0..<height {
                for x in 0..<width where totals[y * width + x] > threshold {
                    // CG bitmap rows are top-down in memory for this context.
                    let offset = y * stride + x * 4
                    out[offset] = 255; out[offset + 1] = 0; out[offset + 2] = 200; out[offset + 3] = 255
                }
            }
        }
        return rgb.makeImage()
    }
}
