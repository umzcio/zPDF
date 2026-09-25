//
//  CommentFileInfo.swift
//  zPDF
//
//  Purpose: Reads review metadata PDFKit does not expose from the editing
//  revision's own object graph (CoreGraphics): which comment a reply is
//  "in reply to" (/IRT, /RT), and embedded media (FileAttachment /FS /EF
//  data, Sound stream samples). CoreGraphics resolves an indirect object to
//  one dictionary pointer, so an /IRT target is found by identity among the
//  page /Annots arrays. PDFKit's page.annotations order matches /Annots,
//  which is how SaveBaseline maps source indices to PDFAnnotation objects.
//

import AppKit
import PDFKit

struct CommentFileEntry {
    var parent: (page: Int, index: Int)?
    var groupedWithParent = false
    var fileName: String?
    var fileSize: Int?
    var soundDuration: Double?
}

@MainActor
enum CommentFileInfo {
    private final class Cache {
        weak var baseline: SaveBaseline?
        var entries: [[CommentFileEntry?]] = []
    }
    private static var caches: [ObjectIdentifier: Cache] = [:]

    /// Per source page, per /Annots index. Recomputed when the revision changes.
    static func entries(for baseline: SaveBaseline) -> [[CommentFileEntry?]] {
        let key = ObjectIdentifier(baseline)
        if let cache = caches[key], cache.baseline === baseline { return cache.entries }
        caches = caches.filter { $0.value.baseline != nil }
        let cache = Cache()
        cache.baseline = baseline
        cache.entries = build(pages: baseline.sourcePages)
        caches[key] = cache
        return cache.entries
    }

    static func entry(for annotation: PDFAnnotation, baseline: SaveBaseline) -> CommentFileEntry? {
        guard let position = baseline.position(of: annotation) else { return nil }
        let all = entries(for: baseline)
        guard all.indices.contains(position.page), all[position.page].indices.contains(position.index) else { return nil }
        return all[position.page][position.index]
    }

    private static func annotationDictionaries(_ page: PDFPage) -> [CGPDFDictionaryRef] {
        guard let dictionary = page.pageRef?.dictionary else { return [] }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &array), let array else { return [] }
        return (0..<CGPDFArrayGetCount(array)).compactMap { index in
            var entry: CGPDFDictionaryRef?
            return CGPDFArrayGetDictionary(array, index, &entry) ? entry : nil
        }
    }

    private static func build(pages: [PDFPage]) -> [[CommentFileEntry?]] {
        let dictionaries = pages.map(annotationDictionaries)
        var positions: [CGPDFDictionaryRef: (Int, Int)] = [:]
        for (page, list) in dictionaries.enumerated() {
            for (index, dictionary) in list.enumerated() { positions[dictionary] = (page, index) }
        }
        return dictionaries.map { list in
            list.map { dictionary in
                var entry = CommentFileEntry()
                var irt: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "IRT", &irt), let irt, let parent = positions[irt] {
                    entry.parent = parent
                    entry.groupedWithParent = name(dictionary, "RT") == "Group"
                }
                switch name(dictionary, "Subtype") {
                case "FileAttachment":
                    if let file = fileStream(dictionary) {
                        entry.fileName = file.name
                        entry.fileSize = file.size
                    }
                case "Sound":
                    if let sound = soundStream(dictionary) { entry.soundDuration = sound.duration }
                default: break
                }
                return entry
            }
        }
    }

    nonisolated static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    nonisolated static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }

    nonisolated static func number(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Double? {
        var real: CGPDFReal = 0
        if CGPDFDictionaryGetNumber(dictionary, key, &real) { return Double(real) }
        var integer: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(dictionary, key, &integer) { return Double(integer) }
        return nil
    }

    private static func fileStream(_ annotation: CGPDFDictionaryRef) -> (name: String, size: Int?, stream: CGPDFStreamRef?)? {
        var spec: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(annotation, "FS", &spec), let spec else { return nil }
        let name = string(spec, "UF") ?? string(spec, "F") ?? "Attachment"
        var ef: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetDictionary(spec, "EF", &ef), let ef {
            if !CGPDFDictionaryGetStream(ef, "UF", &stream) { _ = CGPDFDictionaryGetStream(ef, "F", &stream) }
        }
        var size: Int?
        if let stream, let info = CGPDFStreamGetDictionary(stream) {
            var params: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(info, "Params", &params), let params, let value = number(params, "Size") { size = Int(value) }
        }
        return (name, size, stream)
    }

    private static func soundStream(_ annotation: CGPDFDictionaryRef) -> (stream: CGPDFStreamRef, rate: Int, channels: Int, bits: Int,
                                                                          encoding: String, duration: Double)? {
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(annotation, "Sound", &stream), let stream, let info = CGPDFStreamGetDictionary(stream) else { return nil }
        let rate = Int(number(info, "R") ?? 8000), channels = Int(number(info, "C") ?? 1), bits = Int(number(info, "B") ?? 8)
        var format = CGPDFDataFormat.raw
        let length = (CGPDFStreamCopyData(stream, &format) as Data?)?.count ?? 0
        let duration = Double(length) / Double(max(1, rate * channels * max(1, bits / 8)))
        return (stream, rate, channels, bits, name(info, "E") ?? "Raw", duration)
    }

    private static func dictionary(for annotation: PDFAnnotation, baseline: SaveBaseline) -> CGPDFDictionaryRef? {
        guard let position = baseline.position(of: annotation), baseline.sourcePages.indices.contains(position.page) else { return nil }
        let list = annotationDictionaries(baseline.sourcePages[position.page])
        return list.indices.contains(position.index) ? list[position.index] : nil
    }

    /// Embedded file bytes of a loaded FileAttachment comment.
    static func attachment(of annotation: PDFAnnotation, baseline: SaveBaseline) -> (name: String, data: Data)? {
        guard let dictionary = dictionary(for: annotation, baseline: baseline),
              let file = fileStream(dictionary), let stream = file.stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw else { return nil }
        return (file.name, data)
    }

    /// A loaded Sound comment as playable WAV (PCM encodings).
    static func soundWAV(of annotation: PDFAnnotation, baseline: SaveBaseline) -> Data? {
        guard let dictionary = dictionary(for: annotation, baseline: baseline),
              let sound = soundStream(dictionary), [8, 16].contains(sound.bits), ["Raw", "Signed"].contains(sound.encoding) else { return nil }
        var format = CGPDFDataFormat.raw
        guard var samples = CGPDFStreamCopyData(sound.stream, &format) as Data?, format == .raw else { return nil }
        if sound.bits == 16 {
            // PDF sound samples are big-endian; WAV is little-endian.
            samples = Data(samples.withUnsafeBytes { raw -> [UInt8] in
                var bytes = Array(raw)
                var i = 0
                while i + 1 < bytes.count { bytes.swapAt(i, i + 1); i += 2 }
                return bytes
            })
        } else if sound.encoding == "Signed" {
            samples = Data(samples.map { $0 &+ 128 })
        }
        return WAV.encode(samples: samples, rate: sound.rate, channels: sound.channels, bits: sound.bits)
    }
}

/// Minimal RIFF/WAVE writer for PCM samples.
enum WAV {
    static func encode(samples: Data, rate: Int, channels: Int, bits: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let blockAlign = channels * bits / 8
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(channels))
        append(UInt32(rate)); append(UInt32(rate * blockAlign)); append(UInt16(blockAlign)); append(UInt16(bits))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count))
        data.append(samples)
        return data
    }
}
