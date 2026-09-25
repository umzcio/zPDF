import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Standard dialog chrome for workflow sheets: title, explanation, content,
/// and a trailing Cancel / primary button row. Keeps every sheet aligned.
struct WorkflowSheetFrame<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var subtitle: String?
    var primaryTitle: String
    var primaryDisabled = false
    var busy = false
    var busyLabel = "Working…"
    var width: CGFloat = 500
    var primary: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
                .disabled(busy)
            HStack(spacing: DesignTokens.Spacing.small) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(busyLabel).font(.system(size: 12)).foregroundStyle(DesignTokens.Colors.mutedText)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Button(primaryTitle, action: primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(primaryDisabled || busy)
            }
        }
        .padding(DesignTokens.Spacing.xLarge)
        .frame(width: width)
    }
}

/// A labeled form row with a fixed-width leading label so controls align.
struct WorkflowRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 120
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.medium) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.text)
                .frame(width: labelWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Which pages an operation applies to.
enum PageScope: Hashable {
    case all, current, range
}

/// All / Current / Range picker with validation (one-based user input).
struct PageScopePicker: View {
    @Binding var scope: PageScope
    @Binding var rangeText: String
    let pageCount: Int
    var currentPage: Int
    var labelWidth: CGFloat = 120
    var allowsCurrent = true

    var body: some View {
        WorkflowRow(label: "Pages:", labelWidth: labelWidth) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Pages", selection: $scope) {
                    Text("All \(pageCount)").tag(PageScope.all)
                    if allowsCurrent { Text("Current (\(currentPage))").tag(PageScope.current) }
                    Text("Range").tag(PageScope.range)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Choose the pages this applies to")
                if scope == .range {
                    TextField("e.g. 1, 3–5", text: $rangeText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .accessibilityLabel("Page range")
                        .help("Page numbers or ranges from 1 to \(pageCount)")
                    if !rangeText.isEmpty, (try? PageRangeSelection.parse(rangeText, pageCount: pageCount)) == nil {
                        Label("Enter pages from 1 to \(pageCount), such as 1, 3–5.", systemImage: "exclamationmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    /// Zero-based pages, nil for all; throws on an invalid range.
    static func pages(_ scope: PageScope, range: String, current: Int, count: Int) throws -> [Int]? {
        switch scope {
        case .all: return nil
        case .current: return [current - 1]
        case .range: return Array(try PageRangeSelection.parse(range, pageCount: count))
        }
    }

    static func isValid(_ scope: PageScope, range: String, count: Int) -> Bool {
        scope != .range || (try? PageRangeSelection.parse(range, pageCount: count)) != nil
    }
}

/// Points <-> user units for size fields.
enum MeasurementUnit: String, CaseIterable, Identifiable {
    case inches, millimeters, points
    var id: String { rawValue }
    var title: String {
        switch self { case .inches: "in"; case .millimeters: "mm"; case .points: "pt" }
    }
    var pointsPerUnit: Double {
        switch self { case .inches: 72; case .millimeters: 72 / 25.4; case .points: 1 }
    }
    func format(_ points: Double) -> String {
        let value = points / pointsPerUnit
        return value.formatted(.number.precision(.fractionLength(0...(self == .points ? 1 : 2))))
    }
}

/// A numeric field bound to a value in points, displayed in `unit`.
struct PointsField: View {
    let label: String
    @Binding var points: Double
    let unit: MeasurementUnit
    var width: CGFloat = 64

    var body: some View {
        HStack(spacing: 4) {
            TextField(label, value: Binding(get: { points / unit.pointsPerUnit },
                                            set: { points = max(0, $0) * unit.pointsPerUnit }),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("\(label) in \(unit.title)")
                .help("\(label) in \(unit.title)")
            Text(unit.title).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.mutedText)
        }
    }
}

/// Inline, non-modal result or error line used under panel actions.
struct WorkflowStatus: View {
    enum Kind { case info, success, failure }
    let text: String
    var kind: Kind = .info

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: kind == .success ? "checkmark.circle.fill" : kind == .failure ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(kind == .success ? DesignTokens.Colors.readyGreen : kind == .failure ? Color.orange : DesignTokens.Colors.mutedText)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }
}

/// Full-width bordered button used for the primary actions inside panels,
/// so panel actions line up instead of floating at their intrinsic widths.
struct PanelActionButton: View {
    let title: String
    let symbolName: String
    var help: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbolName)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(prominent ? DesignTokens.Colors.controlAccent : nil)
        .controlSize(.regular)
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

@MainActor
enum FilePicker {
    /// Presents an open panel synchronously-modal (sheets use it while open).
    static func choose(types: [UTType], multiple: Bool, title: String, prompt: String = "Choose") -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseFolder(title: String, prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveDestination(title: String, name: String, type: UTType = .pdf, directory: URL? = nil) -> SaveDestination? {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return SaveDestination(url: url, overwrite: FileManager.default.fileExists(atPath: url.path))
    }
}

extension ByteCountFormatter {
    static func file(_ bytes: Int) -> String { string(fromByteCount: Int64(bytes), countStyle: .file) }
}
