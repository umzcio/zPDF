// Compare Files: word-level text differences with page mapping, visual
// (pixel) differences on rendered pages, and a PDF comparison report.

import AppKit
import PDFKit

struct CompareWord {
    let text: String
    let key: String
    let page: Int
    let range: NSRange
}

struct TextChange: Identifiable {
    enum Kind: String { case inserted, deleted, replaced }
    let id = UUID()
    let kind: Kind
    let oldText: String
    let newText: String
    let oldPage: Int?
    let newPage: Int?
    var oldIndexes: [Int] = []
    var newIndexes: [Int] = []
    var oldRects: [CGRect] = []   // page space
    var newRects: [CGRect] = []
}

struct VisualChange: Identifiable {
    let id = UUID()
    let oldPage: Int
    let newPage: Int
    /// Changed regions, normalized (0–1) with a top-left origin, in the page's visual orientation.
    let regions: [CGRect]
}

@MainActor
final class ComparisonResult: Identifiable {
    let id = UUID()
    let oldName: String
    let newName: String
    let oldDocument: PDFDocument
    let newDocument: PDFDocument
    let pagePairs: [(old: Int?, new: Int?)]
    var textChanges: [TextChange]
    let visualChanges: [VisualChange]
    let date = Date()

    init(oldName: String, newName: String, oldDocument: PDFDocument, newDocument: PDFDocument,
         pagePairs: [(old: Int?, new: Int?)], textChanges: [TextChange], visualChanges: [VisualChange]) {
        self.oldName = oldName; self.newName = newName
        self.oldDocument = oldDocument; self.newDocument = newDocument
        self.pagePairs = pagePairs; self.textChanges = textChanges; self.visualChanges = visualChanges
    }

    var insertedCount: Int { textChanges.filter { $0.kind == .inserted }.count }
    var deletedCount: Int { textChanges.filter { $0.kind == .deleted }.count }
    var replacedCount: Int { textChanges.filter { $0.kind == .replaced }.count }
    var summary: String {
        if textChanges.isEmpty && visualChanges.isEmpty { return "No differences found." }
        return "\(textChanges.count) text change\(textChanges.count == 1 ? "" : "s") · \(visualChanges.reduce(0) { $0 + $1.regions.count }) visual region\(visualChanges.count == 1 ? "" : "s")"
    }
}

@MainActor
enum CompareService {
    static func words(in document: PDFDocument) -> [CompareWord] {
        var out: [CompareWord] = []
        for index in 0..<document.pageCount {
            guard let text = document.page(at: index)?.string as NSString? else { continue }
            var location = 0
            let length = text.length
            let whitespace = CharacterSet.whitespacesAndNewlines
            while location < length {
                while location < length, let scalar = UnicodeScalar(text.character(at: location)), whitespace.contains(scalar) { location += 1 }
                let start = location
                while location < length {
                    if let scalar = UnicodeScalar(text.character(at: location)), whitespace.contains(scalar) { break }
                    location += 1
                }
                if location > start {
                    let range = NSRange(location: start, length: location - start)
                    let word = text.substring(with: range)
                    let key = word.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .punctuationCharacters)
                    out.append(CompareWord(text: word, key: key.isEmpty ? word : key, page: index, range: range))
                }
            }
        }
        return out
    }

    /// Word-level diff (Myers via CollectionDifference) grouped into changes.
    static func textChanges(old: [CompareWord], new: [CompareWord]) -> (changes: [TextChange], matches: [(Int, Int)]) {
        let difference = new.map(\.key).difference(from: old.map(\.key))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var i = 0, j = 0
        var changes: [TextChange] = []
        var matches: [(Int, Int)] = []
        var pendingOld: [Int] = [], pendingNew: [Int] = []
        func flush() {
            guard !pendingOld.isEmpty || !pendingNew.isEmpty else { return }
            let kind: TextChange.Kind = pendingOld.isEmpty ? .inserted : pendingNew.isEmpty ? .deleted : .replaced
            // Split runs that cross pages so each change maps to one page per side.
            let oldPage = pendingOld.first.map { old[$0].page }
            let newPage = pendingNew.first.map { new[$0].page }
            changes.append(TextChange(kind: kind,
                                      oldText: pendingOld.map { old[$0].text }.joined(separator: " "),
                                      newText: pendingNew.map { new[$0].text }.joined(separator: " "),
                                      oldPage: oldPage ?? matches.last.map { old[$0.0].page },
                                      newPage: newPage ?? matches.last.map { new[$0.1].page },
                                      oldIndexes: pendingOld, newIndexes: pendingNew))
            pendingOld = []; pendingNew = []
        }
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                if let last = pendingOld.last, old[last].page != old[i].page { flush() }
                pendingOld.append(i); i += 1
            } else if j < new.count, inserted.contains(j) {
                if let last = pendingNew.last, new[last].page != new[j].page { flush() }
                pendingNew.append(j); j += 1
            } else if i < old.count, j < new.count {
                flush()
                matches.append((i, j)); i += 1; j += 1
            } else { break }
        }
        flush()
        return (changes, matches)
    }

    /// Pairs pages by where matched words landed; unmatched pages pair by position.
    static func pagePairs(oldCount: Int, newCount: Int, old: [CompareWord], new: [CompareWord],
                          matches: [(Int, Int)]) -> [(old: Int?, new: Int?)] {
        var votes: [Int: [Int: Int]] = [:]
        for (a, b) in matches { votes[old[a].page, default: [:]][new[b].page, default: 0] += 1 }
        var mapping: [Int: Int] = [:]
        var usedNew = Set<Int>()
        for page in 0..<oldCount {
            // Most shared words wins; ties go to the page nearest the same position.
            if let best = votes[page]?.max(by: { ($0.value, -abs($0.key - page)) < ($1.value, -abs($1.key - page)) })?.key,
               !usedNew.contains(best) {
                mapping[page] = best; usedNew.insert(best)
            }
        }
        // Text-less pages (scans, drawings) pair by position with free pages.
        var freeNew = (0..<newCount).filter { !usedNew.contains($0) }
        for page in 0..<oldCount where mapping[page] == nil {
            let preferred = freeNew.first { $0 == page } ?? freeNew.first { $0 > (mapping.filter { $0.key < page }.values.max() ?? -1) }
            if let preferred { mapping[page] = preferred; freeNew.removeAll { $0 == preferred } }
        }
        var pairs: [(Int?, Int?)] = (0..<oldCount).map { ($0, mapping[$0]) }
        for page in freeNew { pairs.append((nil, page)) }
        return pairs.sorted { ($0.1 ?? Int.max, $0.0 ?? Int.max) < ($1.1 ?? Int.max, $1.0 ?? Int.max) }
    }

    static func rects(for indexes: [CompareWord], in document: PDFDocument) -> [CGRect] {
        indexes.compactMap { word in
            guard let page = document.page(at: word.page), let selection = page.selection(for: word.range) else { return nil }
            return selection.bounds(for: page)
        }
    }

    // MARK: Visual

    static func rendered(_ page: PDFPage, width: Int, height: Int) -> [UInt8]? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bounds = page.bounds(for: .cropBox)
        let visual = page.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        context.scaleBy(x: CGFloat(width) / visual.width, y: CGFloat(height) / visual.height)
        page.transform(context, for: .cropBox)
        page.draw(with: .cropBox, to: context)
        guard let data = context.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
    }

    /// Regions whose rendered pixels differ, as normalized top-left rects.
    static func visualRegions(old: PDFPage, new: PDFPage, maxSide: Int = 800, cell: Int = 8,
                              threshold: UInt8 = 48) -> [CGRect] {
        let bounds = old.bounds(for: .cropBox)
        let visual = old.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = CGFloat(maxSide) / max(visual.width, visual.height)
        let width = max(cell, Int(visual.width * scale)), height = max(cell, Int(visual.height * scale))
        guard let a = rendered(old, width: width, height: height), let b = rendered(new, width: width, height: height) else { return [] }
        let columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        var grid = [Bool](repeating: false, count: columns * rows)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where (a[row + x] > b[row + x] ? a[row + x] - b[row + x] : b[row + x] - a[row + x]) > threshold {
                grid[(y / cell) * columns + x / cell] = true
            }
        }
        // Connected components (8-neighbour, with a one-cell gap bridged).
        var seen = [Bool](repeating: false, count: grid.count)
        var regions: [CGRect] = []
        for start in grid.indices where grid[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var minX = start % columns, maxX = minX, minY = start / columns, maxY = minY
            while let current = stack.popLast() {
                let cx = current % columns, cy = current / columns
                minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, ny >= 0, nx < columns, ny < rows else { continue }
                        let n = ny * columns + nx
                        if grid[n] && !seen[n] { seen[n] = true; stack.append(n) }
                    }
                }
            }
            // Bitmap rows run top-down in memory.
            regions.append(CGRect(x: CGFloat(minX * cell) / CGFloat(width), y: CGFloat(minY * cell) / CGFloat(height),
                                  width: CGFloat((maxX - minX + 1) * cell) / CGFloat(width),
                                  height: CGFloat((maxY - minY + 1) * cell) / CGFloat(height)))
        }
        return regions.filter { $0.width * $0.height > 0.00002 }
    }

    static func compare(old: PDFDocument, oldName: String, new: PDFDocument, newName: String,
                        progress: ((Double) -> Void)? = nil) async -> ComparisonResult {
        let oldWords = words(in: old), newWords = words(in: new)
        progress?(0.2)
        await Task.yield()
        var (changes, matches) = textChanges(old: oldWords, new: newWords)
        // Geometry for changed words only (PDFKit selections are costly).
        if changes.count <= 2000 {
            for index in changes.indices {
                changes[index].oldRects = rects(for: changes[index].oldIndexes.map { oldWords[$0] }, in: old)
                changes[index].newRects = rects(for: changes[index].newIndexes.map { newWords[$0] }, in: new)
            }
        }
        progress?(0.5)
        let pairs = pagePairs(oldCount: old.pageCount, newCount: new.pageCount, old: oldWords, new: newWords, matches: matches)
        var visual: [VisualChange] = []
        for (n, pair) in pairs.enumerated() {
            guard let o = pair.old, let w = pair.new, let op = old.page(at: o), let np = new.page(at: w) else { continue }
            let regions = visualRegions(old: op, new: np)
            if !regions.isEmpty { visual.append(VisualChange(oldPage: o, newPage: w, regions: regions)) }
            progress?(0.5 + 0.5 * Double(n + 1) / Double(max(1, pairs.count)))
            await Task.yield()
        }
        return ComparisonResult(oldName: oldName, newName: newName, oldDocument: old, newDocument: new,
                                pagePairs: pairs, textChanges: changes, visualChanges: visual)
    }

    // MARK: Report

    /// Writes a comparison report: summary, change list, then side-by-side pages.
    static func writeReport(_ result: ComparisonResult, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 792, height: 612)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: "Comparison Report",
                                                                     kCGPDFContextCreator as String: "zPDF"] as CFDictionary) else {
            throw CreationError.failed("The report could not be written.")
        }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        func begin() {
            context.beginPDFPage(nil)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        }
        func draw(_ text: String, _ font: NSFont, _ color: NSColor = .black, in rect: CGRect) {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        // Summary + change list.
        var lines: [(String, NSColor)] = result.textChanges.map { change in
            let page = "p. \((change.newPage ?? change.oldPage).map { "\($0 + 1)" } ?? "–")"
            switch change.kind {
            case .inserted: return ("\(page)  Inserted: “\(change.newText.prefix(140))”", .systemGreen.blended(withFraction: 0.4, of: .black) ?? .systemGreen)
            case .deleted: return ("\(page)  Deleted: “\(change.oldText.prefix(140))”", .systemRed)
            case .replaced: return ("\(page)  Replaced “\(change.oldText.prefix(70))” with “\(change.newText.prefix(70))”", .systemOrange.blended(withFraction: 0.3, of: .black) ?? .systemOrange)
            }
        }
        for visual in result.visualChanges {
            lines.append(("p. \(visual.newPage + 1)  \(visual.regions.count) changed region\(visual.regions.count == 1 ? "" : "s") on the rendered page", .darkGray))
        }
        var y: CGFloat = 0
        var first = true
        var remaining = lines[...]
        repeat {
            begin()
            if first {
                draw("Comparison Report", .boldSystemFont(ofSize: 22), in: CGRect(x: 48, y: 540, width: 700, height: 30))
                draw("Older: \(result.oldName)\nNewer: \(result.newName)\nCompared \(formatter.string(from: result.date))",
                     .systemFont(ofSize: 11), .darkGray, in: CGRect(x: 48, y: 480, width: 700, height: 56))
                draw("\(result.insertedCount) insertion(s) · \(result.deletedCount) deletion(s) · \(result.replacedCount) replacement(s) · \(result.visualChanges.count) page(s) with visual differences",
                     .systemFont(ofSize: 12, weight: .medium), in: CGRect(x: 48, y: 452, width: 700, height: 20))
                y = 430
                first = false
            } else { y = 560 }
            while let line = remaining.first, y > 48 {
                draw(line.0, .systemFont(ofSize: 10), line.1, in: CGRect(x: 48, y: y - 14, width: 700, height: 14))
                y -= 16
                remaining = remaining.dropFirst()
            }
            context.endPDFPage()
        } while !remaining.isEmpty
        // Side-by-side pages with highlights.
        let changedPages = Set(result.textChanges.compactMap(\.newPage) + result.visualChanges.map(\.newPage)
                               + result.textChanges.filter { $0.newPage == nil }.compactMap(\.oldPage))
        for pair in result.pagePairs where pair.new.map(changedPages.contains) == true || (pair.new == nil && pair.old != nil) {
            begin()
            draw("Page \(pair.old.map { "\($0 + 1)" } ?? "—") (older)  ↔  page \(pair.new.map { "\($0 + 1)" } ?? "—") (newer)",
                 .systemFont(ofSize: 11, weight: .medium), in: CGRect(x: 36, y: 584, width: 720, height: 18))
            for (side, index, document) in [(0, pair.old, result.oldDocument), (1, pair.new, result.newDocument)] {
                let frame = CGRect(x: side == 0 ? 36 : 408, y: 36, width: 348, height: 540)
                context.setStrokeColor(NSColor.gray.cgColor)
                context.stroke(frame)
                guard let index, let page = document.page(at: index) else {
                    draw("No matching page", .systemFont(ofSize: 11), .gray, in: frame.insetBy(dx: 20, dy: 250))
                    continue
                }
                let bounds = page.bounds(for: .cropBox)
                let visualSize = page.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
                let scale = min(frame.width / visualSize.width, frame.height / visualSize.height)
                let origin = CGPoint(x: frame.midX - visualSize.width * scale / 2, y: frame.midY - visualSize.height * scale / 2)
                context.saveGState()
                context.translateBy(x: origin.x, y: origin.y)
                context.scaleBy(x: scale, y: scale)
                context.saveGState()
                page.transform(context, for: .cropBox)
                page.draw(with: .cropBox, to: context)
                context.restoreGState()
                // Highlights in visual space.
                let color: NSColor = side == 0 ? .systemRed : .systemGreen
                for change in result.textChanges where (side == 0 ? change.oldPage : change.newPage) == index {
                    for rect in side == 0 ? change.oldRects : change.newRects {
                        let v = visualRect(rect, page: page)
                        context.setFillColor(color.withAlphaComponent(0.25).cgColor)
                        context.fill(v)
                    }
                }
                for visual in result.visualChanges where (side == 0 ? visual.oldPage : visual.newPage) == index {
                    for region in visual.regions {
                        let r = CGRect(x: region.minX * visualSize.width, y: (1 - region.maxY) * visualSize.height,
                                       width: region.width * visualSize.width, height: region.height * visualSize.height)
                        context.setStrokeColor(NSColor.systemOrange.cgColor)
                        context.setLineWidth(1.5 / scale)
                        context.stroke(r)
                    }
                }
                context.restoreGState()
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Page-space rect → visual (rotation-applied, bottom-left origin) rect.
    static func visualRect(_ rect: CGRect, page: PDFPage) -> CGRect {
        let b = page.bounds(for: .cropBox)
        let r = rect.offsetBy(dx: -b.minX, dy: -b.minY)
        switch (page.rotation % 360 + 360) % 360 {
        case 90: return CGRect(x: r.minY, y: b.width - r.maxX, width: r.height, height: r.width)
        case 180: return CGRect(x: b.width - r.maxX, y: b.height - r.maxY, width: r.width, height: r.height)
        case 270: return CGRect(x: b.height - r.maxY, y: r.minX, width: r.height, height: r.width)
        default: return r
        }
    }
}
