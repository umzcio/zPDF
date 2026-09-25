import AppKit
import PDFKit

/// Measuring on the canvas: distance, perimeter and area with a drawing
/// scale, snapping to vector geometry, and measurement annotations saved as
/// standard Line / PolyLine / Polygon annotations with a /Measure dictionary.
@MainActor @Observable
final class MeasureSession {
    enum Kind: String, CaseIterable, Identifiable {
        case distance, perimeter, area
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .distance: "ruler"
            case .perimeter: "point.topleft.down.to.point.bottomright.curvepath"
            case .area: "square.dashed"
            }
        }
        var help: String {
            switch self {
            case .distance: "Distance: click two points"
            case .perimeter: "Perimeter: click each point, double-click or press Return to finish"
            case .area: "Area: click each corner, double-click, press Return or click the first point to close"
            }
        }
    }

    struct Measurement: Identifiable, Hashable {
        let id = UUID()
        let tabID: UUID
        let page: Int
        let kind: Kind
        let points: [CGPoint]
        let value: Double
        let unit: String
        let label: String
        let ratio: String
        var committed: Bool
    }

    enum SnapKind { case endpoint, midpoint, intersection, path, grid }

    /// Active tool (nil = measuring is off).
    var kind: Kind?
    /// Calibration mode: the next distance sets the scale instead.
    var calibrating = false
    var pendingCalibration: (tabID: UUID, points: [CGPoint])?
    private(set) var measurements: [Measurement] = []
    /// In-progress points on `activePage`.
    var points: [CGPoint] = []
    var activePage: Int?
    var hover: CGPoint?
    var snapped: SnapKind?
    /// Document viewport scales per page (from `page_scales`), when present.
    var documentScales: [UUID: [Int: PageScale]] = [:]
    @ObservationIgnored var snapCache: [String: SnapGeometry] = [:]
    @ObservationIgnored var loadingSnap: Set<String> = []

    struct PageScale: Hashable {
        let ratio: String
        let factor: Double
        let unit: String
    }

    struct SnapGeometry {
        var endpoints: [CGPoint] = []
        var midpoints: [CGPoint] = []
        var intersections: [CGPoint] = []
        var segments: [(CGPoint, CGPoint)] = []
    }

    func measurements(for tabID: UUID) -> [Measurement] { measurements.filter { $0.tabID == tabID } }

    func add(_ measurement: Measurement) { measurements.append(measurement) }

    func markCommitted(_ ids: Set<UUID>) {
        measurements = measurements.map { item in
            var copy = item
            if ids.contains(item.id) { copy.committed = true }
            return copy
        }
    }

    func remove(_ ids: Set<UUID>) { measurements.removeAll { ids.contains($0.id) } }
    func clear(tabID: UUID) { measurements.removeAll { $0.tabID == tabID } }

    func cancelInProgress() {
        points = []
        activePage = nil
    }

    // MARK: - Scale

    /// Real units per PDF point and the ratio label for a page.
    func scale(for tab: DocumentTab, page: Int, preferences: AppPreferences) -> PageScale {
        if preferences.measureUseDocumentScale, let scale = documentScales[tab.id]?[page] { return scale }
        return Self.preferenceScale(preferences)
    }

    static func preferenceScale(_ preferences: AppPreferences) -> PageScale {
        let pagePoints = preferences.measureScalePage * preferences.measureScalePageUnit.inches * 72
        let factor = pagePoints > 0 ? preferences.measureScaleReal / pagePoints : 1 / 72
        let ratio = "\(format(preferences.measureScalePage)) \(preferences.measureScalePageUnit.rawValue) = \(format(preferences.measureScaleReal)) \(preferences.measureScaleRealUnit.rawValue)"
        return PageScale(ratio: ratio, factor: factor, unit: preferences.measureScaleRealUnit.rawValue)
    }

    nonisolated static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
    }

    // MARK: - Geometry

    static func length(_ points: [CGPoint], closed: Bool = false) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<points.count { total += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y) }
        if closed, let first = points.first, let last = points.last { total += hypot(first.x - last.x, first.y - last.y) }
        return total
    }

    static func area(_ points: [CGPoint]) -> Double {
        guard points.count > 2 else { return 0 }
        var sum = 0.0
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            sum += Double(a.x * b.y - b.x * a.y)
        }
        return abs(sum) / 2
    }

    /// Value in real units and its label.
    static func value(kind: Kind, points: [CGPoint], scale: PageScale, precision: Int) -> (Double, String, String) {
        let digits = max(0, min(6, precision))
        switch kind {
        case .distance, .perimeter:
            let value = length(points) * scale.factor
            return (value, scale.unit, "\(value.formatted(.number.precision(.fractionLength(digits)))) \(scale.unit)")
        case .area:
            let value = area(points) * scale.factor * scale.factor
            return (value, "sq \(scale.unit)", "\(value.formatted(.number.precision(.fractionLength(digits)))) sq \(scale.unit)")
        }
    }

    // MARK: - Snapping

    /// Snaps `point` (page space) given a tolerance in page points.
    func snap(_ point: CGPoint, key: String, tolerance: CGFloat, preferences: AppPreferences,
              gridStep: CGFloat?) -> (CGPoint, SnapKind?) {
        if let geometry = snapCache[key] {
            func nearest(_ candidates: [CGPoint]) -> CGPoint? {
                var best: CGPoint?
                var bestDistance = tolerance
                for candidate in candidates {
                    let distance = hypot(candidate.x - point.x, candidate.y - point.y)
                    if distance <= bestDistance { best = candidate; bestDistance = distance }
                }
                return best
            }
            if preferences.measureSnapEndpoints, let hit = nearest(geometry.endpoints) { return (hit, .endpoint) }
            if preferences.measureSnapIntersections, let hit = nearest(geometry.intersections) { return (hit, .intersection) }
            if preferences.measureSnapMidpoints, let hit = nearest(geometry.midpoints) { return (hit, .midpoint) }
            if preferences.measureSnapPaths {
                var best: CGPoint?
                var bestDistance = tolerance
                for (a, b) in geometry.segments {
                    let projected = Self.project(point, a, b)
                    let distance = hypot(projected.x - point.x, projected.y - point.y)
                    if distance <= bestDistance { best = projected; bestDistance = distance }
                }
                if let best { return (best, .path) }
            }
        }
        if let gridStep, gridStep > 0 {
            let snapped = CGPoint(x: (point.x / gridStep).rounded() * gridStep, y: (point.y / gridStep).rounded() * gridStep)
            if hypot(snapped.x - point.x, snapped.y - point.y) <= tolerance { return (snapped, .grid) }
        }
        return (point, nil)
    }

    static func project(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return a }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return CGPoint(x: a.x + t * dx, y: a.y + t * dy)
    }

    /// Loads PDF vector geometry for snapping (cached per revision + page).
    func loadSnapGeometry(appState: AppState, tab: DocumentTab, page: Int) {
        let key = "\(tab.editSource?.hash ?? tab.id.uuidString)-\(page)"
        guard snapCache[key] == nil, !loadingSnap.contains(key), appState.canQuery(tab) else { return }
        loadingSnap.insert(key)
        Task {
            defer { loadingSnap.remove(key) }
            guard let json = try? await appState.documentQueryJSON("vector_snap_points", params: ["page": page, "max_points": 6000], in: tab) else { return }
            func points(_ name: String) -> [CGPoint] {
                ((json[name] as? [[Double]]) ?? []).compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
            }
            var geometry = SnapGeometry(endpoints: points("endpoints"), midpoints: points("midpoints"),
                                        intersections: points("intersections"))
            geometry.segments = ((json["segments"] as? [[Double]]) ?? []).compactMap {
                $0.count == 4 ? (CGPoint(x: $0[0], y: $0[1]), CGPoint(x: $0[2], y: $0[3])) : nil
            }
            snapCache[key] = geometry
        }
    }

    func snapKey(tab: DocumentTab, page: Int) -> String { "\(tab.editSource?.hash ?? tab.id.uuidString)-\(page)" }

    /// Reads the document's own viewport scales once per revision.
    func loadDocumentScales(appState: AppState, tab: DocumentTab) {
        guard appState.canQuery(tab) else { return }
        Task {
            guard let json = try? await appState.documentQueryJSON("page_scales", in: tab),
                  let pages = json["pages"] as? [[String: Any]] else { return }
            var scales: [Int: PageScale] = [:]
            for entry in pages {
                guard let page = entry["page"] as? Int, let ratio = entry["ratio"] as? String,
                      let factor = entry["factor"] as? Double, let unit = entry["unit"] as? String else { continue }
                scales[page] = PageScale(ratio: ratio, factor: factor, unit: unit)
            }
            documentScales[tab.id] = scales
        }
    }

    /// Engine `add_measurements` items for `list`.
    static func engineItems(_ list: [Measurement], color: AnnotationPreferenceColor, author: String, scales: (Measurement) -> PageScale) -> [[String: Any]] {
        let rgb = color.nsColor.usingColorSpace(.sRGB) ?? .red
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return list.map { item in
            let scale = scales(item)
            return ["page": item.page, "kind": item.kind.rawValue, "points": item.points.map { [Double($0.x), Double($0.y)] },
                    "label": item.label, "unit": scale.unit, "ratio": scale.ratio, "factor": scale.factor,
                    "color": components, "author": author, "name": "zpdf-measure-\(item.id.uuidString.lowercased())"]
        }
    }
}

/// Existing measurement annotations in the document (`measurements` query).
struct DocumentMeasurement: Decodable, Hashable {
    let page: Int
    let subtype: String
    let kind: String
    let name: String?
    let points: [[Double]]
    let label: String
    let ratio: String?
    let author: String?
}

struct DocumentMeasurementsResult: Decodable { let items: [DocumentMeasurement] }

enum MeasurementCSV {
    /// RFC 4180 CSV of measurements (document annotations plus pending ones).
    static func make(document: [DocumentMeasurement], pending: [MeasureSession.Measurement], fileName: String) -> String {
        func field(_ value: String) -> String {
            value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        var rows = ["Document,Page,Type,Measurement,Scale,Author,Saved in PDF,Points"]
        for item in document {
            let points = item.points.map { String(format: "%.2f %.2f", $0.first ?? 0, $0.last ?? 0) }.joined(separator: "; ")
            rows.append([fileName, "\(item.page + 1)", item.kind.capitalized, item.label, item.ratio ?? "", item.author ?? "", "Yes", points]
                .map(field).joined(separator: ","))
        }
        for item in pending where !item.committed {
            let points = item.points.map { String(format: "%.2f %.2f", $0.x, $0.y) }.joined(separator: "; ")
            rows.append([fileName, "\(item.page + 1)", item.kind.title, item.label, item.ratio, "", "No", points]
                .map(field).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}
