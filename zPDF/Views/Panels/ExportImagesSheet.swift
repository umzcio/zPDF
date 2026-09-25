import AppKit
import PDFKit
import SwiftUI

/// Export pages as images (JPEG/PNG/TIFF at a chosen resolution and color
/// space) or extract every embedded image in its original encoding.
struct ExportImagesSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case pages, embedded
        var id: String { rawValue }
        var title: String { self == .pages ? "Pages as Images" : "Embedded Images" }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let tab: DocumentTab
    @State private var mode: Mode = .pages
    @State private var format: PageImageFormat = .png
    @State private var dpi = 150
    @State private var color: PageImageColor = .rgb
    @State private var quality = 85.0
    @State private var multipage = false
    @State private var scope: PageScope = .all
    @State private var rangeText = ""
    @State private var progress: Int?
    @State private var message: String?

    private var pageTotal: Int {
        (try? PageScopePicker.pages(scope, range: rangeText, current: tab.currentPage, count: tab.pageCount))??.count ?? tab.pageCount
    }

    var body: some View {
        WorkflowSheetFrame(title: "Export Images",
                           subtitle: mode == .pages ? "Each page becomes an image file in a folder you choose."
                                                    : "Saves every image in the document, in its original format where possible (JPEG and JPEG 2000 unchanged).",
                           primaryTitle: "Export…",
                           primaryDisabled: !PageScopePicker.isValid(scope, range: rangeText, count: tab.pageCount) || (format == .png && color == .cmyk),
                           busy: progress != nil, busyLabel: progress.map { "Exporting \($0) of \(pageTotal)…" } ?? "",
                           primary: export) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                Picker("Export", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                if mode == .pages {
                    WorkflowRow(label: "Format:") {
                        Picker("Format", selection: $format) {
                            ForEach(PageImageFormat.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    WorkflowRow(label: "Resolution:") {
                        Picker("Resolution", selection: $dpi) {
                            ForEach([72, 96, 150, 200, 300, 600], id: \.self) { Text("\($0) dpi").tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                    WorkflowRow(label: "Color:") {
                        Picker("Color", selection: $color) {
                            ForEach(PageImageColor.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help(format == .png ? "PNG supports RGB and grayscale" : "Choose the color space of the images")
                    }
                    if format == .png && color == .cmyk {
                        WorkflowStatus(text: "PNG doesn't support CMYK. Choose JPEG or TIFF.", kind: .failure)
                    }
                    if format == .jpeg {
                        WorkflowRow(label: "Quality:") {
                            HStack {
                                Slider(value: $quality, in: 30...100, step: 5) { Text("Quality") }.frame(width: 180)
                                Text("\(Int(quality))").monospacedDigit()
                            }
                        }
                    }
                    if format == .tiff {
                        WorkflowRow(label: "") {
                            Toggle("One multi-page TIFF file", isOn: $multipage)
                        }
                    }
                    PageScopePicker(scope: $scope, rangeText: $rangeText, pageCount: tab.pageCount, currentPage: tab.currentPage)
                }
                if let message { WorkflowStatus(text: message, kind: .failure) }
            }
        }
    }

    private func export() {
        guard let document = tab.pdfDocument,
              let folder = FilePicker.chooseFolder(title: "Export Images", prompt: "Export Here") else { return }
        let base = (tab.displayName as NSString).deletingPathExtension
        let access = folder.startAccessingSecurityScopedResource()
        message = nil
        if mode == .embedded {
            progress = 0
            Task {
                defer { progress = nil; if access { folder.stopAccessingSecurityScopedResource() } }
                do {
                    let work = try NativeWorkDirectory()
                    let result = try await appState.queryDocument("extract_images", params: ["directory": work.url.path], in: tab)
                    let images = result["images"] as? [[String: Any]] ?? []
                    var count = 0
                    for image in images {
                        guard let path = image["path"] as? String else { continue }
                        let source = URL(fileURLWithPath: path)
                        let target = PageImageExporter.unique(folder.appendingPathComponent("\(base)-\(source.lastPathComponent)"))
                        try FileManager.default.copyItem(at: source, to: target)
                        count += 1
                    }
                    let skipped = result["skipped"] as? Int ?? 0
                    dismiss()
                    appState.exportMessage = count == 0 ? "This document has no extractable images."
                        : "Saved \(count) image\(count == 1 ? "" : "s") in \(folder.lastPathComponent)." + (skipped > 0 ? " \(skipped) could not be extracted." : "")
                    appState.exportedURL = folder
                } catch {
                    message = error.localizedDescription
                }
            }
            return
        }
        guard let pages = try? PageScopePicker.pages(scope, range: rangeText, current: tab.currentPage, count: tab.pageCount) else { return }
        let list = pages ?? Array(0..<document.pageCount)
        progress = 0
        Task {
            defer { progress = nil; if access { folder.stopAccessingSecurityScopedResource() } }
            do {
                await Task.yield()
                let files = try PageImageExporter.export(document, pages: list, format: format, dpi: CGFloat(dpi), color: color,
                                                         quality: quality / 100, multipageTIFF: multipage, to: folder,
                                                         baseName: base) { progress = $0 }
                dismiss()
                appState.exportMessage = "Saved \(files.count) image file\(files.count == 1 ? "" : "s") in \(folder.lastPathComponent)."
                appState.exportedURL = files.count == 1 ? files[0] : folder
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
