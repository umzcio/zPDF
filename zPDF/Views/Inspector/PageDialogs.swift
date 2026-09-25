// Page dialogs (Acrobat's Organize Pages dialogs): Insert, Replace, Number
// Pages, Set Page Boxes, Change Page Size, Page Transitions and Split.

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Insert

struct InsertPagesSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case blank, file
        var id: String { rawValue }
        var title: String { self == .blank ? "Blank Page" : "From File" }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State var mode: Mode
    @State private var position: PageInsertionPosition = .afterCurrent
    @State private var paper: PaperSize = .matchCurrent
    @State private var customWidth = 612.0
    @State private var customHeight = 792.0
    @State private var unit: MeasurementUnit = .inches
    @State private var landscape = false
    @State private var count = 1
    @State private var files: [URL] = []
    @State private var rangeText = ""
    @State private var imagePaper: PaperSize = .matchCurrent
    @State private var imageFit = "fit"
    @State private var busy = false

    init(tab: DocumentTab, mode: Mode) {
        self.tab = tab
        _mode = State(initialValue: mode)
    }

    private var singlePDF: URL? { files.count == 1 && PageFileKind.isPDF(files[0]) ? files[0] : nil }
    private var singlePDFPageCount: Int { singlePDF.flatMap { CGPDFDocument($0 as CFURL)?.numberOfPages } ?? 0 }
    private var rangeValid: Bool {
        rangeText.trimmingCharacters(in: .whitespaces).isEmpty || singlePDF == nil
            || (try? PageRangeSelection.parse(rangeText, pageCount: singlePDFPageCount)) != nil
    }

    var body: some View {
        WorkflowSheetFrame(title: "Insert Pages",
                           subtitle: "Inserted pages keep their links, comments and form fields. Undo removes them; Save keeps them.",
                           primaryTitle: "Insert",
                           primaryDisabled: mode == .file && (files.isEmpty || !rangeValid),
                           busy: busy, busyLabel: "Inserting…", primary: insert) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                Picker("Insert", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Insert blank pages or pages from PDF and image files")
                WorkflowRow(label: "Location:") {
                    Picker("Location", selection: $position) {
                        ForEach(PageInsertionPosition.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .help("Where the new pages go (current page is \(tab.currentPage))")
                }
                if mode == .blank { blankOptions } else { fileOptions }
            }
        }
    }

    private var blankOptions: some View {
        Group {
            WorkflowRow(label: "Page size:") {
                Picker("Page size", selection: $paper) {
                    ForEach(PaperSize.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if paper == .custom {
                WorkflowRow(label: "Dimensions:") {
                    HStack(spacing: 8) {
                        PointsField(label: "Width", points: $customWidth, unit: unit)
                        Text("×").foregroundStyle(DesignTokens.Colors.mutedText)
                        PointsField(label: "Height", points: $customHeight, unit: unit)
                        Picker("Unit", selection: $unit) {
                            ForEach(MeasurementUnit.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
            }
            WorkflowRow(label: "Orientation:") {
                Picker("Orientation", selection: $landscape) {
                    Label("Portrait", systemImage: "rectangle.portrait").tag(false)
                    Label("Landscape", systemImage: "rectangle").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(paper == .matchCurrent)
            }
            WorkflowRow(label: "Number of pages:") {
                Stepper(value: $count, in: 1...100) {
                    TextField("Count", value: $count, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 50)
                        .accessibilityLabel("Number of pages")
                }
                .fixedSize()
            }
        }
    }

    private var fileOptions: some View {
        Group {
            WorkflowRow(label: "Files:") {
                VStack(alignment: .leading, spacing: 6) {
                    if files.isEmpty {
                        Text("PDFs and images (JPEG, PNG, HEIC, TIFF…)").font(.system(size: 12))
                            .foregroundStyle(DesignTokens.Colors.mutedText)
                    } else {
                        ForEach(files, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: PageFileKind.isImage(url) ? "photo" : "doc.richtext")
                                    .foregroundStyle(DesignTokens.Colors.mutedText)
                                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { files.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(DesignTokens.Colors.mutedText)
                                    .help("Remove \(url.lastPathComponent)")
                                    .accessibilityLabel("Remove \(url.lastPathComponent)")
                            }
                            .font(.system(size: 12))
                        }
                    }
                    Button(files.isEmpty ? "Choose Files…" : "Add Files…") {
                        files += FilePicker.choose(types: [.pdf] + PageFileKind.imageTypes, multiple: true,
                                                   title: "Insert Pages", prompt: "Choose")
                    }
                    .help("Choose PDF or image files to insert")
                }
            }
            if let singlePDF {
                WorkflowRow(label: "Pages:") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("All \(singlePDFPageCount) pages", text: $rangeText)
                            .textFieldStyle(.roundedBorder).frame(width: 180)
                            .accessibilityLabel("Pages of \(singlePDF.lastPathComponent) to insert")
                            .help("Leave empty for all pages, or enter pages such as 1, 3–5")
                        if !rangeValid {
                            Label("Enter pages from 1 to \(singlePDFPageCount).", systemImage: "exclamationmark.circle")
                                .font(.system(size: 11)).foregroundStyle(.red)
                        }
                    }
                }
            }
            if files.contains(where: PageFileKind.isImage) {
                WorkflowRow(label: "Image pages:") {
                    HStack {
                        Picker("Image page size", selection: $imagePaper) {
                            Text("Size of each image").tag(PaperSize.matchCurrent)
                            ForEach(PaperSize.fixed.filter { $0 != .custom }) { Text($0.title).tag($0) }
                        }.labelsHidden().fixedSize()
                        if imagePaper != .matchCurrent {
                            Picker("Fit", selection: $imageFit) {
                                Text("Fit").tag("fit")
                                Text("Fill").tag("fill")
                                Text("Actual size").tag("actual")
                            }.labelsHidden().fixedSize()
                        }
                    }
                }
            }
        }
    }

    private func insert() {
        busy = true
        let index = position.index(in: tab)
        Task {
            let ok: Bool
            if mode == .blank {
                var size = paper == .custom ? CGSize(width: customWidth, height: customHeight) : paper.points
                if let current = size, landscape != (current.width > current.height) {
                    size = CGSize(width: current.height, height: current.width)
                }
                ok = await appState.insertBlankPages(count: count, size: size, landscape: nil, at: index, in: tab)
            } else {
                var pages: [Int]?
                if singlePDF != nil, !rangeText.trimmingCharacters(in: .whitespaces).isEmpty {
                    pages = Array(try PageRangeSelection.parse(rangeText, pageCount: singlePDFPageCount))
                }
                var imageOptions: [String: Any] = [:]
                if let size = imagePaper.points {
                    imageOptions = ["page_size": [Double(size.width), Double(size.height)], "fit": imageFit, "margin": 0]
                }
                ok = await appState.insertFiles(files, pages: pages, at: index, in: tab, imageOptions: imageOptions)
            }
            busy = false
            if ok { dismiss() }
        }
    }
}

// MARK: - Replace

struct ReplacePagesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State private var targetText = ""
    @State private var file: URL?
    @State private var sourceStart = 1
    @State private var busy = false

    private var targets: [Int]? {
        let text = targetText.isEmpty ? "\(tab.currentPage)" : targetText
        return (try? PageRangeSelection.parse(text, pageCount: tab.pageCount)).map(Array.init)
    }
    private var sourceCount: Int { file.flatMap { CGPDFDocument($0 as CFURL)?.numberOfPages } ?? 0 }
    private var enoughPages: Bool { (targets?.count ?? 0) > 0 && sourceStart - 1 + (targets?.count ?? 0) <= sourceCount }

    var body: some View {
        WorkflowSheetFrame(title: "Replace Pages",
                           subtitle: "Replaces page content with pages from another PDF. Comments, form fields, links and bookmarks of the original pages are kept.",
                           primaryTitle: "Replace", primaryDisabled: targets == nil || file == nil || !enoughPages,
                           busy: busy, busyLabel: "Replacing…", primary: replace) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                WorkflowRow(label: "Replace pages:") {
                    TextField("\(tab.currentPage)", text: $targetText)
                        .textFieldStyle(.roundedBorder).frame(width: 180)
                        .accessibilityLabel("Pages to replace")
                        .help("Pages in this document, such as 2 or 4–6")
                }
                WorkflowRow(label: "With pages from:") {
                    HStack {
                        Text(file?.lastPathComponent ?? "No file chosen").lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(file == nil ? DesignTokens.Colors.mutedText : DesignTokens.Colors.text)
                        Button("Choose…") {
                            file = FilePicker.choose(types: [.pdf], multiple: false, title: "Replace Pages").first
                            sourceStart = 1
                        }
                        .help("Choose the PDF that contains the replacement pages")
                    }
                }
                WorkflowRow(label: "Starting at page:") {
                    HStack {
                        Stepper(value: $sourceStart, in: 1...max(1, sourceCount)) {
                            TextField("Start", value: $sourceStart, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 50)
                                .accessibilityLabel("First replacement page")
                        }.fixedSize()
                        if let targets, file != nil {
                            Text(enoughPages ? "Uses pages \(sourceStart)–\(sourceStart + targets.count - 1) of \(sourceCount)"
                                             : "Needs \(targets.count) page(s); the file has \(sourceCount)")
                                .font(.system(size: 11))
                                .foregroundStyle(enoughPages ? DesignTokens.Colors.mutedText : .red)
                        }
                    }
                }.disabled(file == nil)
            }
        }
    }

    private func replace() {
        guard let targets, let file else { return }
        busy = true
        Task {
            let ok = await appState.replacePages(targets, with: file, sourcePages: targets.indices.map { sourceStart - 1 + $0 }, in: tab)
            busy = false
            if ok { dismiss() }
        }
    }
}

// MARK: - Page labels

struct PageLabelsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State private var ranges: [PageLabelRange] = []
    @State private var loaded = false
    @State private var busy = false

    var body: some View {
        WorkflowSheetFrame(title: "Number Pages",
                           subtitle: "Page labels are the numbers readers show, such as i–iv for front matter. They don't change the page order.",
                           primaryTitle: "Apply", primaryDisabled: !loaded || hasDuplicateStarts,
                           busy: busy || !loaded, busyLabel: loaded ? "Applying…" : "Reading labels…", width: 580, primary: apply) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("From page").gridColumnAlignment(.trailing)
                        Text("Style")
                        Text("Prefix")
                        Text("Start at")
                        Text("Preview")
                        Color.clear.frame(width: 20, height: 1)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.mutedText)
                    ForEach($ranges) { $range in
                        GridRow {
                            Stepper(value: Binding(get: { range.start + 1 }, set: { range.start = $0 - 1 }),
                                    in: 1...max(1, tab.pageCount)) {
                                Text("\(range.start + 1)").monospacedDigit().frame(width: 30, alignment: .trailing)
                            }
                            .accessibilityLabel("Range starts at page")
                            .accessibilityValue("\(range.start + 1)")
                            .disabled(range.start == 0 && ranges.first?.id == range.id)
                            Picker("Style", selection: $range.style) {
                                ForEach(PageLabelRange.Style.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(width: 130)
                            TextField("None", text: $range.prefix)
                                .textFieldStyle(.roundedBorder).frame(width: 70)
                                .accessibilityLabel("Prefix")
                            TextField("1", value: $range.first, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 50)
                                .accessibilityLabel("Start number")
                            Text(preview(range)).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                                .lineLimit(1).frame(width: 110, alignment: .leading)
                            Button { ranges.removeAll { $0.id == range.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .disabled(ranges.count == 1)
                                .help("Remove this range")
                                .accessibilityLabel("Remove range starting at page \(range.start + 1)")
                        }
                    }
                }
                HStack {
                    Button {
                        let next = min(tab.pageCount - 1, max(tab.currentPage - 1, (ranges.map(\.start).max() ?? 0) + 1))
                        ranges.append(PageLabelRange(start: next))
                        ranges.sort { $0.start < $1.start }
                    } label: { Label("Add Range", systemImage: "plus") }
                    .disabled(ranges.count >= tab.pageCount)
                    .help("Start a new numbering range")
                    Button("Use Page Numbers") { ranges = [PageLabelRange(start: 0)] }
                        .help("Reset to plain 1, 2, 3 labels (removes custom labels)")
                    Spacer()
                    if hasDuplicateStarts {
                        Label("Each range needs its own first page.", systemImage: "exclamationmark.circle")
                            .font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
            }
        }
        .task { await load() }
    }

    private var hasDuplicateStarts: Bool { Set(ranges.map(\.start)).count != ranges.count }

    private func preview(_ range: PageLabelRange) -> String {
        let next = ranges.map(\.start).filter { $0 > range.start }.min() ?? tab.pageCount
        let count = max(0, next - range.start)
        let labels = (0..<min(count, 3)).map { range.label(offset: $0) }
        return labels.joined(separator: ", ") + (count > 3 ? "…" : "")
    }

    private func load() async {
        defer { loaded = true }
        guard let result = try? await appState.queryDocument("page_labels", in: tab),
              let items = result["ranges"] as? [[String: Any]], !items.isEmpty else {
            ranges = [PageLabelRange(start: 0)]
            return
        }
        ranges = items.map {
            PageLabelRange(start: $0["start"] as? Int ?? 0,
                           style: PageLabelRange.Style(rawValue: $0["style"] as? String ?? "") ?? .none,
                           prefix: $0["prefix"] as? String ?? "", first: $0["first"] as? Int ?? 1)
        }
    }

    private func apply() {
        busy = true
        let plain = ranges.count == 1 && ranges[0] == PageLabelRange(start: 0)
        Task {
            let ok = await appState.setPageLabels(plain ? [] : ranges.sorted { $0.start < $1.start }, in: tab)
            busy = false
            if ok { dismiss() }
        }
    }
}

// MARK: - Page boxes

struct PageBoxesSheet: View {
    enum Box: String, CaseIterable, Identifiable {
        case CropBox, TrimBox, BleedBox, ArtBox, MediaBox
        var id: String { rawValue }
        var title: String {
            switch self {
            case .CropBox: "Crop Box"
            case .TrimBox: "Trim Box"
            case .BleedBox: "Bleed Box"
            case .ArtBox: "Art Box"
            case .MediaBox: "Media Box"
            }
        }
        var color: Color {
            switch self {
            case .CropBox: .blue
            case .TrimBox: .green
            case .BleedBox: .red
            case .ArtBox: .purple
            case .MediaBox: .gray
            }
        }
        var help: String {
            switch self {
            case .CropBox: "The visible page area in viewers and when printing"
            case .TrimBox: "The finished size after trimming (print production)"
            case .BleedBox: "The area printed beyond the trim so edges don't show paper"
            case .ArtBox: "The meaningful content area, for placing the page elsewhere"
            case .MediaBox: "The physical page size; other boxes stay inside it"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State private var box: Box = .CropBox
    @State private var margins: [Box: [Double]] = [:]   // left, bottom, right, top
    @State private var unit: MeasurementUnit = .inches
    @State private var scope: PageScope = .all
    @State private var rangeText = ""
    @State private var remove = false
    @State private var busy = false

    private var media: CGRect { tab.pdfDocument?.page(at: tab.currentPage - 1)?.bounds(for: .mediaBox) ?? .zero }

    private func current(_ box: Box) -> [Double] {
        if let value = margins[box] { return value }
        guard let page = tab.pdfDocument?.page(at: tab.currentPage - 1) else { return [0, 0, 0, 0] }
        let kind: PDFDisplayBox = [.CropBox: .cropBox, .TrimBox: .trimBox, .BleedBox: .bleedBox, .ArtBox: .artBox, .MediaBox: .mediaBox][box]!
        let rect = page.bounds(for: kind)
        return [rect.minX - media.minX, rect.minY - media.minY, media.maxX - rect.maxX, media.maxY - rect.maxY].map { max(0, $0) }
    }

    private func binding(_ index: Int) -> Binding<Double> {
        Binding(get: { current(box)[index] }, set: { value in
            var values = current(box); values[index] = value; margins[box] = values
        })
    }

    var body: some View {
        WorkflowSheetFrame(title: "Set Page Boxes",
                           subtitle: "Margins are measured inward from the media box. Changes apply as one step you can undo.",
                           primaryTitle: "Apply",
                           primaryDisabled: margins.isEmpty && !remove || !PageScopePicker.isValid(scope, range: rangeText, count: tab.pageCount),
                           busy: busy, busyLabel: "Applying…", width: 580, primary: apply) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.large) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                    WorkflowRow(label: "Box:", labelWidth: 80) {
                        Picker("Box", selection: $box) {
                            ForEach(Box.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }.labelsHidden().fixedSize()
                        .help(box.help)
                    }
                    Text(box.help).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    if box == .MediaBox {
                        PanelNote("Shrinking the media box clips the page. Use Change Page Size to scale content instead.")
                    }
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Text("Top").gridColumnAlignment(.trailing)
                            PointsField(label: "Top", points: binding(3), unit: unit)
                        }
                        GridRow {
                            Text("Left")
                            PointsField(label: "Left", points: binding(0), unit: unit)
                        }
                        GridRow {
                            Text("Right")
                            PointsField(label: "Right", points: binding(2), unit: unit)
                        }
                        GridRow {
                            Text("Bottom")
                            PointsField(label: "Bottom", points: binding(1), unit: unit)
                        }
                    }
                    .font(.system(size: 12))
                    .disabled(remove)
                    HStack {
                        Picker("Unit", selection: $unit) {
                            ForEach(MeasurementUnit.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().fixedSize()
                        Button("Set to Zero") { margins[box] = [0, 0, 0, 0] }
                            .help("Make this box match the media box")
                    }
                    if box != .MediaBox && box != .CropBox {
                        Toggle("Remove this box", isOn: $remove)
                            .help("Delete the \(box.title.lowercased()) so it falls back to the crop box")
                    }
                }
                BoxPreview(page: tab.pdfDocument?.page(at: tab.currentPage - 1), media: media,
                           boxes: Box.allCases.filter { $0 != .MediaBox }.map { ($0.title, $0.color, rect(for: $0), $0 == box) })
                    .frame(width: 200, height: 250)
            }
            PageScopePicker(scope: $scope, rangeText: $rangeText, pageCount: tab.pageCount,
                            currentPage: tab.currentPage, labelWidth: 80)
        }
    }

    private func rect(for box: Box) -> CGRect {
        let m = current(box)
        return CGRect(x: media.minX + m[0], y: media.minY + m[1],
                      width: max(0, media.width - m[0] - m[2]), height: max(0, media.height - m[1] - m[3]))
    }

    private func apply() {
        guard let pages = try? PageScopePicker.pages(scope, range: rangeText, current: tab.currentPage, count: tab.pageCount) else { return }
        var boxes: [String: Any] = [:]
        for (key, value) in margins where !(remove && key == box) {
            boxes[key.rawValue] = ["margins": value]
        }
        busy = true
        Task {
            let ok = await appState.setPageBoxes(boxes, remove: remove ? [box.rawValue] : [], pages: pages, in: tab)
            busy = false
            if ok { dismiss() }
        }
    }
}

/// Page thumbnail with page-box outlines drawn over it.
struct BoxPreview: View {
    @Environment(AppState.self) private var appState
    let page: PDFPage?
    let media: CGRect
    let boxes: [(String, Color, CGRect, Bool)]

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / max(1, media.width), geometry.size.height / max(1, media.height))
            let size = CGSize(width: media.width * scale, height: media.height * scale)
            ZStack(alignment: .topLeading) {
                if let page, let image = page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox) as NSImage? {
                    Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                } else {
                    Color.white.frame(width: size.width, height: size.height)
                }
                ForEach(Array(boxes.enumerated()), id: \.offset) { _, item in
                    let r = item.2
                    Rectangle()
                        .stroke(item.1, style: StrokeStyle(lineWidth: item.3 ? 2 : 1, dash: item.3 ? [] : [3, 2]))
                        .frame(width: r.width * scale, height: r.height * scale)
                        .offset(x: (r.minX - media.minX) * scale, y: (media.maxY - r.maxY) * scale)
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(Rectangle().stroke(DesignTokens.Colors.hairline))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement()
        .accessibilityLabel("Preview of page boxes on the current page")
    }
}

// MARK: - Resize

struct ResizePagesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State private var paper: PaperSize = .letter
    @State private var width = 612.0
    @State private var height = 792.0
    @State private var unit: MeasurementUnit = .inches
    @State private var landscape = false
    @State private var mode = "scale"
    @State private var scope: PageScope = .all
    @State private var rangeText = ""
    @State private var busy = false

    var body: some View {
        WorkflowSheetFrame(title: "Change Page Size",
                           subtitle: "Scale content to the new size, or keep content at 100% and change only the page area.",
                           primaryTitle: "Resize",
                           primaryDisabled: !PageScopePicker.isValid(scope, range: rangeText, count: tab.pageCount) || width < 3 || height < 3,
                           busy: busy, busyLabel: "Resizing…", primary: apply) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                WorkflowRow(label: "New size:") {
                    Picker("New size", selection: $paper) {
                        ForEach(PaperSize.fixed) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                if paper == .custom {
                    WorkflowRow(label: "Dimensions:") {
                        HStack(spacing: 8) {
                            PointsField(label: "Width", points: $width, unit: unit)
                            Text("×").foregroundStyle(DesignTokens.Colors.mutedText)
                            PointsField(label: "Height", points: $height, unit: unit)
                            Picker("Unit", selection: $unit) {
                                ForEach(MeasurementUnit.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                    }
                }
                WorkflowRow(label: "Orientation:") {
                    Picker("Orientation", selection: $landscape) {
                        Label("Portrait", systemImage: "rectangle.portrait").tag(false)
                        Label("Landscape", systemImage: "rectangle").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                WorkflowRow(label: "Content:") {
                    Picker("Content", selection: $mode) {
                        Text("Scale to fit").tag("scale")
                        Text("Keep size (change canvas)").tag("canvas")
                        Text("Stretch to fill").tag("stretch")
                    }.pickerStyle(.radioGroup).labelsHidden()
                }
                PageScopePicker(scope: $scope, rangeText: $rangeText, pageCount: tab.pageCount, currentPage: tab.currentPage)
            }
        }
        .onChange(of: paper) { _, value in
            if let size = value.points { width = size.width; height = size.height }
        }
    }

    private func apply() {
        guard let pages = try? PageScopePicker.pages(scope, range: rangeText, current: tab.currentPage, count: tab.pageCount) else { return }
        var size = CGSize(width: width, height: height)
        if landscape != (size.width > size.height) { size = CGSize(width: size.height, height: size.width) }
        busy = true
        Task {
            let ok = await appState.resizePages(to: size, mode: mode, pages: pages, in: tab)
            busy = false
            if ok { dismiss() }
        }
    }
}

// MARK: - Transitions

struct TransitionsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State private var style = "Dissolve"
    @State private var direction = 0
    @State private var speed = 1.0
    @State private var autoAdvance = false
    @State private var seconds = 5.0
    @State private var scope: PageScope = .all
    @State private var rangeText = ""
    @State private var busy = false

    private static let styles: [(String, String)] = [
        ("None", "No transition"), ("Dissolve", "Dissolve"), ("Fade", "Fade"), ("Wipe", "Wipe"), ("Push", "Push"),
        ("Cover", "Cover"), ("Uncover", "Uncover"), ("Split", "Split"), ("Blinds", "Blinds"), ("Box", "Box"),
        ("Glitter", "Glitter"), ("Fly", "Fly"),
    ]
    private var directional: Bool { ["Wipe", "Push", "Cover", "Uncover", "Glitter", "Fly"].contains(style) }

    var body: some View {
        WorkflowSheetFrame(title: "Page Transitions",
                           subtitle: "Transitions play when the PDF is presented full screen in readers that support them.",
                           primaryTitle: "Apply", primaryDisabled: !PageScopePicker.isValid(scope, range: rangeText, count: tab.pageCount),
                           busy: busy, busyLabel: "Applying…", primary: apply) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                WorkflowRow(label: "Transition:") {
                    Picker("Transition", selection: $style) {
                        ForEach(Self.styles, id: \.0) { Text($0.1).tag($0.0) }
                    }.labelsHidden().fixedSize()
                }
                if directional {
                    WorkflowRow(label: "Direction:") {
                        Picker("Direction", selection: $direction) {
                            Text("Left to right").tag(0)
                            Text("Bottom to top").tag(90)
                            Text("Right to left").tag(180)
                            Text("Top to bottom").tag(270)
                        }.labelsHidden().fixedSize()
                    }
                }
                WorkflowRow(label: "Speed:") {
                    Picker("Speed", selection: $speed) {
                        Text("Slow").tag(2.0)
                        Text("Medium").tag(1.0)
                        Text("Fast").tag(0.5)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }.disabled(style == "None")
                WorkflowRow(label: "Auto flip:") {
                    HStack {
                        Toggle("Advance after", isOn: $autoAdvance)
                        TextField("Seconds", value: $seconds, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 50).disabled(!autoAdvance)
                            .accessibilityLabel("Seconds before advancing")
                        Text("seconds").font(.system(size: 12)).foregroundStyle(DesignTokens.Colors.mutedText)
                    }
                }.disabled(style == "None")
                PageScopePicker(scope: $scope, rangeText: $rangeText, pageCount: tab.pageCount, currentPage: tab.currentPage)
            }
        }
    }

    private func apply() {
        guard let pages = try? PageScopePicker.pages(scope, range: rangeText, current: tab.currentPage, count: tab.pageCount) else { return }
        busy = true
        Task {
            let ok = await appState.setTransitions(style: style == "None" ? nil : style, duration: speed,
                                                   direction: directional ? direction : nil,
                                                   advance: autoAdvance && seconds > 0 ? seconds : nil, pages: pages, in: tab)
            busy = false
            if ok { dismiss() }
        }
    }
}

// MARK: - Split

struct SplitDocumentSheet: View {
    enum Method: String, CaseIterable, Identifiable {
        case pages, size, bookmarks
        var id: String { rawValue }
        var title: String {
            switch self { case .pages: "Number of pages"; case .size: "File size"; case .bookmarks: "Top-level bookmarks" }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State private var method: Method = .pages
    @State private var interval = 1
    @State private var megabytes = 5.0
    @State private var busy = false
    @State private var message: String?

    private var bookmarkCount: Int { tab.pdfDocument?.outlineRoot?.numberOfChildren ?? 0 }

    var body: some View {
        WorkflowSheetFrame(title: "Split Document",
                           subtitle: "Saves the parts in a new folder. Current edits are included; the open document is unchanged.",
                           primaryTitle: "Split…", primaryDisabled: method == .bookmarks && bookmarkCount == 0,
                           busy: busy, busyLabel: "Splitting…", primary: split) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                WorkflowRow(label: "Split by:") {
                    Picker("Split by", selection: $method) {
                        ForEach(Method.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.radioGroup).labelsHidden()
                }
                switch method {
                case .pages:
                    WorkflowRow(label: "Pages per file:") {
                        Stepper(value: $interval, in: 1...max(1, tab.pageCount)) {
                            TextField("Pages", value: $interval, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 50)
                                .accessibilityLabel("Pages per file")
                        }.fixedSize()
                    }
                    Text("Creates \(Int(ceil(Double(tab.pageCount) / Double(max(1, interval))))) file(s).")
                        .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                case .size:
                    WorkflowRow(label: "Maximum size:") {
                        HStack {
                            TextField("MB", value: $megabytes, format: .number.precision(.fractionLength(0...1)))
                                .textFieldStyle(.roundedBorder).frame(width: 60)
                                .accessibilityLabel("Maximum file size in megabytes")
                            Text("MB").font(.system(size: 12)).foregroundStyle(DesignTokens.Colors.mutedText)
                        }
                    }
                    Text("Sizes are estimated from each page's content; a single page larger than the limit becomes its own file.")
                        .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                case .bookmarks:
                    Text(bookmarkCount == 0 ? "This document has no bookmarks."
                         : "Creates one file per top-level bookmark (\(bookmarkCount)), named after the bookmark.")
                        .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                if let message { WorkflowStatus(text: message, kind: .failure) }
            }
        }
    }

    private func split() {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                let plan: [(name: String?, pages: [Int])]
                switch method {
                case .pages:
                    plan = stride(from: 0, to: tab.pageCount, by: interval).map { (nil, Array($0..<min($0 + interval, tab.pageCount))) }
                case .bookmarks:
                    plan = SplitPlanner.bookmarkGroups(tab)
                case .size:
                    let result = try await appState.queryDocument("split_by_size", params: ["max_bytes": Int(megabytes * 1_000_000)], in: tab)
                    plan = ((result["groups"] as? [[Int]]) ?? []).map { (nil, $0) }
                }
                guard !plan.isEmpty else { message = "Nothing to split."; return }
                dismiss()
                appState.splitDocument(tab, plan: plan)
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

enum SplitPlanner {
    /// Top-level bookmarks → page groups in current page order.
    @MainActor
    static func bookmarkGroups(_ tab: DocumentTab) -> [(name: String?, pages: [Int])] {
        guard let document = tab.pdfDocument, let root = document.outlineRoot else { return [] }
        var starts: [(String, Int)] = []
        for index in 0..<root.numberOfChildren {
            guard let child = root.child(at: index), let page = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page else { continue }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { continue }
            starts.append((child.label ?? "Bookmark \(index + 1)", pageIndex))
        }
        starts.sort { $0.1 < $1.1 }
        var groups: [(String?, [Int])] = []
        if let first = starts.first, first.1 > 0 { groups.append(("Front matter", Array(0..<first.1))) }
        for (n, item) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].1 : document.pageCount
            guard end > item.1 else { continue }
            groups.append((item.0, Array(item.1..<end)))
        }
        return groups
    }

    static func safeName(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(80)).isEmpty ? "Part" : String(cleaned.prefix(80))
    }
}

@MainActor
extension AppState {
    /// Writes each page group as its own PDF into a new folder the user names.
    /// The whole folder is published only after every part succeeds.
    @discardableResult
    func splitDocument(_ tab: DocumentTab, plan: [(name: String?, pages: [Int])],
                       destination: SaveDestination? = nil) -> Task<Bool, Never> {
        guard tab.allowsSaveEdits, saves[tab.id] == nil, commitFieldEditing(),
              let url = tab.url, let hash = tab.sourceHash, let document = tab.pdfDocument, let baseline = tab.saveBaseline else {
            saveError = OpenError(fileName: tab.displayName, message: "Wait until the document is ready before splitting.")
            return Task { false }
        }
        let changes: NativeSaveChanges
        do { changes = try baseline.changes(in: document) } catch {
            saveError = OpenError(fileName: tab.displayName, message: error.localizedDescription)
            return Task { false }
        }
        let source = (url: tab.editSource?.url ?? url, hash: tab.editSource?.hash ?? hash)
        let guardian = tab.editSource == nil ? nil : NativeSourceGuard(url: url, hash: hash)
        tab.isSaving = true
        tab.operationLabel = "Split PDF…"
        exportMessage = nil
        let task = Task { () -> Bool in
            defer {
                tab.isSaving = false; tab.operationLabel = nil
                saves[tab.id] = nil; saveDestinations[tab.id] = nil
                refreshUnsavedChanges(tab)
            }
            do {
                let panel = NSSavePanel()
                panel.title = "Split Document"
                panel.message = "Choose a new folder name for the complete set of split PDFs."
                panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " split"
                panel.directoryURL = url.deletingLastPathComponent()
                let target: URL
                if let destination { target = destination.url }
                else {
                    guard panel.runModal() == .OK, let chosen = panel.url else { return false }
                    target = chosen
                }
                if FileManager.default.fileExists(atPath: target.path) {
                    throw NativeSaveError(code: "DESTINATION_EXISTS", message: "Choose a new folder name for the split PDFs. Existing folders are not replaced.")
                }
                saveDestinations[tab.id] = target
                let access = target.startAccessingSecurityScopedResource()
                defer { if access { target.stopAccessingSecurityScopedResource() } }
                guard try await allowStaging(in: target.deletingLastPathComponent(), for: tab) else { return false }
                let order = changes.pages ?? (0..<document.pageCount).map { NativePageSelection(sourceIndex: $0, rotationDelta: 0) }
                let staging = target.deletingLastPathComponent().appendingPathComponent(".zpdf-split-\(UUID())", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: staging) }
                let stem = (tab.displayName as NSString).deletingPathExtension
                var used = Set<String>()
                for (n, part) in plan.enumerated() {
                    var partChanges = changes
                    partChanges.pages = part.pages.map { order[$0] }
                    var name = part.name.map(SplitPlanner.safeName) ?? "\(stem)-part\(n + 1)"
                    if part.name != nil { name = String(format: "%02d ", n + 1) + name }
                    while used.contains(name.lowercased()) { name += " \(n + 1)" }
                    used.insert(name.lowercased())
                    _ = try await NativeSaveBridge.save(source.url, expectedHash: source.hash, changes: partChanges,
                                                        destination: staging.appendingPathComponent(name + ".pdf"), sourceGuard: guardian)
                }
                try FileManager.default.moveItem(at: staging, to: target)
                exportMessage = "Saved \(plan.count) PDFs in \(target.lastPathComponent)."
                exportedURL = target
                return true
            } catch {
                saveError = OpenError(fileName: "Split PDF", message: error.localizedDescription)
                return false
            }
        }
        saves[tab.id] = task
        return task
    }
}
