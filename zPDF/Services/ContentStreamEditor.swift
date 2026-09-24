//
//  ContentStreamEditor.swift
//  zPDF
//
//  Purpose: Content-stream parser/rewriter backing PDFKitEngine's
//  content-editing API (textRuns / replaceTextRun). PDFKit cannot edit
//  page content, so this file re-parses a page's content stream(s) via
//  CGPDFDocument (PDFPage exposes no content-stream accessor), interprets
//  BT/ET text objects (Tf/Tm/Td/TD/T* positioning, Tj/TJ/'/" show
//  operators) into EditableTextRun values, and rewrites a run's string
//  operand(s) in the raw stream bytes.
//
//  Write path (replaceTextRun): the document is serialized with
//  `dataRepresentation()`, the content-stream object (and, for embedded
//  subset fonts, the font dictionary) is located in the serialized bytes,
//  and a classic PDF incremental update is appended (new object versions +
//  xref subsection + trailer with /Prev). The updated bytes are re-opened
//  as a new PDFDocument and the edited page is swapped into the SAME live
//  PDFDocument object (remove + insert — PDFKit deep-copies pages across
//  documents), which is what makes PDFView re-render and `document.string`
//  re-extract: PDFKit caches page content, so a page-object replacement is
//  the verified refresh mechanism (an in-place data mutation alone is not
//  observable by the live document).
//
//  Subset-font handling: CoreGraphics/PDFKit always embed subset fonts
//  (e.g. "AAAAAB+Helvetica"), whose embedded glyph program only covers the
//  characters originally drawn — replacement text with new characters
//  could neither render nor extract. When the run's font is embedded or
//  subset, replaceTextRun additionally appends a de-substituted font
//  dictionary (non-embedded /Type1, BaseFont without the subset prefix,
//  WinAnsiEncoding) so the system font renders the new text. Trade-off:
//  other runs sharing that font resource are re-decoded as WinAnsi
//  (identical for ASCII).
//
//  Known limits (phase 4): WinAnsi/MacRoman decoding only (no ToUnicode
//  CMaps, no /Differences); inline images (BI/ID/EI) are not tokenized;
//  non-Flate stream filters (LZW/ASCII85) and cross-reference streams make
//  replaceTextRun throw .unsupportedOperation; run bounds are approximate
//  (baseline origin, font-size height).
//
//  Phase: 4 — real implementation (see IMPLEMENTATION.md phase 4).
//

import Compression
import CoreGraphics
import Foundation
import PDFKit

enum ContentStreamEditor {

    // MARK: - Engine entry points

    /// Parse the page's content stream(s) and return its text runs in
    /// stream order. Returns an empty array for out-of-range pages and
    /// pages without parseable text.
    static func textRuns(onPageAt index: Int, in document: PDFDocument) -> [EditableTextRun] {
        guard index >= 0, index < document.pageCount,
              let data = document.dataRepresentation(),
              let content = PageContent(data: data, pageIndex: index) else {
            return []
        }
        return content.runs.enumerated().map { offset, run in
            EditableTextRun(id: offset, pageIndex: index, text: run.text,
                            bounds: run.bounds,
                            fontName: run.font?.displayName ?? run.fontResource,
                            fontSize: run.fontSize)
        }
    }

    /// Rewrite one run's text in the page content stream and swap the
    /// edited page into the live document (see the file header for the
    /// full write-path description).
    static func replaceTextRun(_ run: EditableTextRun, with newText: String, in document: PDFDocument) throws {
        guard run.pageIndex >= 0, run.pageIndex < document.pageCount else {
            throw PDFEngineError.pageIndexOutOfRange(run.pageIndex)
        }
        guard let data = document.dataRepresentation(),
              let content = PageContent(data: data, pageIndex: run.pageIndex) else {
            throw PDFEngineError.unsupportedOperation("Text-run editing (document data unavailable)")
        }
        guard run.id >= 0, run.id < content.runs.count else {
            throw PDFEngineError.unsupportedOperation("Text-run editing (stale run reference — re-fetch runs)")
        }
        let target = content.runs[run.id]
        guard let font = target.font else {
            throw PDFEngineError.unsupportedOperation("Text-run editing (font \"\(target.fontResource)\" not in page resources)")
        }
        // Embedded/subset fonts cannot render new characters; they are
        // de-substituted to a non-embedded WinAnsi font (file header).
        let outputEncoding: TextEncoding = font.needsDeSubset ? .winAnsi : font.encoding
        guard let encoded = newText.data(using: outputEncoding.stringEncoding) else {
            throw PDFEngineError.unsupportedOperation(
                "Text-run editing (characters not representable in font \"\(font.displayName)\")")
        }
        let operand = Self.literalString(for: [UInt8](encoded))

        let originalStream = content.streams[target.streamIndex]
        var newStream = originalStream
        switch target.replacement {
        case .stringOperand(let range):
            newStream.replaceSubrange(range, with: operand)
        case .arrayAndOperator(let range):
            // A TJ array is replaced by an equivalent single Tj string.
            newStream.replaceSubrange(range, with: operand + Data(" Tj".utf8))
        }

        let serialized = SerializedPDF(data: data)
        let objects = serialized.indirectObjects()
        guard let streamObject = objects.first(where: { serialized.decodedStreamData(of: $0) == originalStream }) else {
            throw PDFEngineError.unsupportedOperation("Text-run editing (content stream uses an unsupported filter)")
        }
        var replacements: [SerializedPDF.Replacement] = [
            SerializedPDF.Replacement(object: streamObject, streamData: newStream)
        ]
        if font.needsDeSubset {
            let marker = Data("/BaseFont /\(font.baseFont)".utf8)
            guard let fontObject = objects.first(where: { serialized.data[$0.body].range(of: marker) != nil }) else {
                throw PDFEngineError.unsupportedOperation("Text-run editing (font dictionary not found)")
            }
            let body = "<< /Type /Font /Subtype /Type1 /BaseFont /\(font.displayName) /Encoding /WinAnsiEncoding >>"
            replacements.append(SerializedPDF.Replacement(object: fontObject, dictionary: Data(body.utf8)))
        }
        guard let updatedData = serialized.incrementalUpdate(replacing: replacements),
              let updated = PDFDocument(data: updatedData),
              updated.pageCount > run.pageIndex,
              let newPage = updated.page(at: run.pageIndex) else {
            throw PDFEngineError.unsupportedOperation("Text-run editing (updated document failed to parse)")
        }
        // Verified refresh mechanism: swapping the page object inside the
        // same live document invalidates PDFKit's caches, so PDFView
        // re-renders and document.string re-extracts the new text.
        document.removePage(at: run.pageIndex)
        document.insert(newPage, at: run.pageIndex)
    }

    // MARK: - Page content parsing

    /// One parsed text show operation with everything a rewrite needs.
    private struct ParsedRun {
        /// Byte range to replace in the decoded stream: just the string
        /// literal for Tj/'/", the whole "[ … ] TJ" sequence for TJ.
        enum Replacement {
            case stringOperand(Range<Int>)
            case arrayAndOperator(Range<Int>)
        }
        let text: String
        let fontResource: String
        let font: FontInfo?
        /// Effective size in points (Tf size × text-matrix scale).
        let fontSize: CGFloat
        let bounds: CGRect
        let streamIndex: Int
        let replacement: Replacement
    }

    /// Everything parsed from one page of a serialized document: the
    /// decoded content streams plus the text runs found in them.
    private struct PageContent {
        let streams: [Data]
        let runs: [ParsedRun]

        init?(data: Data, pageIndex: Int) {
            guard let provider = CGDataProvider(data: data as CFData),
                  let cgDocument = CGPDFDocument(provider),
                  let page = cgDocument.page(at: pageIndex + 1) else {
                return nil
            }
            let fonts = Self.fontMap(for: page)
            guard let contentsObject = Self.object("Contents", in: page.dictionary) else {
                return nil
            }
            var decodedStreams: [Data] = []
            var stream: CGPDFStreamRef?
            var array: CGPDFArrayRef?
            if CGPDFObjectGetValue(contentsObject, .stream, &stream), let stream {
                if let decoded = Self.decodedStreamData(stream) { decodedStreams.append(decoded) }
            } else if CGPDFObjectGetValue(contentsObject, .array, &array), let array {
                for index in 0..<CGPDFArrayGetCount(array) {
                    var element: CGPDFObjectRef?
                    var elementStream: CGPDFStreamRef?
                    if CGPDFArrayGetObject(array, index, &element),
                       CGPDFObjectGetValue(element!, .stream, &elementStream),
                       let elementStream,
                       let decoded = Self.decodedStreamData(elementStream) {
                        decodedStreams.append(decoded)
                    }
                }
            }
            streams = decodedStreams
            var parsed: [ParsedRun] = []
            for (streamIndex, streamData) in decodedStreams.enumerated() {
                parsed.append(contentsOf: ContentStreamEditor.interpret(stream: streamData, streamIndex: streamIndex, fonts: fonts))
            }
            runs = parsed
        }

        private static func object(_ key: String, in dictionary: CGPDFDictionaryRef?) -> CGPDFObjectRef? {
            guard let dictionary else { return nil }
            var object: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(dictionary, key, &object) else { return nil }
            return object
        }

        private static func decodedStreamData(_ stream: CGPDFStreamRef) -> Data? {
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) else { return nil }
            return data as Data
        }

        /// The page's /Resources /Font map as resource name → FontInfo.
        /// /Resources may be inherited, so walk the /Parent chain.
        private static func fontMap(for page: CGPDFPage) -> [String: FontInfo] {
            var dictionary = page.dictionary
            var resources: CGPDFDictionaryRef?
            while let current = dictionary {
                if let object = object("Resources", in: current),
                   CGPDFObjectGetValue(object, .dictionary, &resources), resources != nil {
                    break
                }
                guard let parent = object("Parent", in: current) else { break }
                var parentDictionary: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(parent, .dictionary, &parentDictionary) else { break }
                dictionary = parentDictionary
            }
            guard let resources,
                  let fontsObject = object("Font", in: resources) else { return [:] }
            var fontsDictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(fontsObject, .dictionary, &fontsDictionary),
                  let fontsDictionary else { return [:] }
            /// Reference box so the CGPDF applier C callback can collect
            /// results without a raw pointer to a Swift Dictionary.
            final class FontMapBox {
                var fonts: [String: FontInfo] = [:]
            }
            let box = FontMapBox()
            CGPDFDictionaryApplyFunction(fontsDictionary, { key, object, info in
                guard let info else { return }
                var fontDictionary: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &fontDictionary),
                      let fontDictionary else { return }
                let name = String(cString: key)
                Unmanaged<FontMapBox>.fromOpaque(info).takeUnretainedValue()
                    .fonts[name] = FontInfo(resourceName: name, dictionary: fontDictionary)
            }, Unmanaged.passUnretained(box).toOpaque())
            return box.fonts
        }
    }

    /// A page font resource: PostScript name, encoding, and glyph widths.
    private struct FontInfo {
        /// Raw /BaseFont (may carry a "AAAAAB+" subset prefix).
        let baseFont: String
        let encoding: TextEncoding
        let firstChar: Int
        /// Glyph advances in 1/1000 em, indexed by char code - firstChar.
        let widths: [CGFloat]
        let isSubset: Bool
        let isEmbedded: Bool

        var displayName: String {
            guard isSubset else { return baseFont }
            return String(baseFont.dropFirst(7))
        }

        /// Subset/embedded fonts cannot render characters that were not in
        /// the original document, so rewrites de-substitute them.
        var needsDeSubset: Bool { isSubset || isEmbedded }

        init?(resourceName: String, dictionary: CGPDFDictionaryRef) {
            var baseFontChars: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "BaseFont", &baseFontChars),
                  let baseFontChars else { return nil }
            baseFont = String(cString: baseFontChars)
            let pattern = #"^[A-Z]{6}\+"#
            isSubset = baseFont.range(of: pattern, options: .regularExpression) != nil

            encoding = TextEncoding(fontDictionary: dictionary)

            var first: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(dictionary, "FirstChar", &first)
            firstChar = Int(first)
            var parsedWidths: [CGFloat] = []
            var widthsArray: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Widths", &widthsArray), let widthsArray {
                for index in 0..<CGPDFArrayGetCount(widthsArray) {
                    var value: CGPDFReal = 0
                    if CGPDFArrayGetNumber(widthsArray, index, &value) {
                        parsedWidths.append(CGFloat(value))
                    }
                }
            }
            widths = parsedWidths

            var descriptor: CGPDFDictionaryRef?
            var embedded = false
            if CGPDFDictionaryGetDictionary(dictionary, "FontDescriptor", &descriptor), let descriptor {
                for key in ["FontFile", "FontFile2", "FontFile3"] {
                    var object: CGPDFObjectRef?
                    if CGPDFDictionaryGetObject(descriptor, key, &object) { embedded = true }
                }
            }
            isEmbedded = embedded
        }
    }

    // MARK: - Content stream interpreter

    /// Single-byte text encodings this phase supports.
    private enum TextEncoding {
        case winAnsi
        case macRoman

        var stringEncoding: String.Encoding {
            switch self {
            case .winAnsi: .windowsCP1252
            case .macRoman: .macOSRoman
            }
        }

        /// The font dictionary's /Encoding: a name, or a dictionary whose
        /// /BaseEncoding name is used (/Differences are not applied).
        /// Defaults to WinAnsi when absent or unrecognized.
        init(fontDictionary: CGPDFDictionaryRef) {
            var nameChars: UnsafePointer<CChar>?
            var encodingName: String?
            if CGPDFDictionaryGetName(fontDictionary, "Encoding", &nameChars), let nameChars {
                encodingName = String(cString: nameChars)
            } else {
                var encodingDictionary: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(fontDictionary, "Encoding", &encodingDictionary),
                   let encodingDictionary {
                    var baseChars: UnsafePointer<CChar>?
                    if CGPDFDictionaryGetName(encodingDictionary, "BaseEncoding", &baseChars), let baseChars {
                        encodingName = String(cString: baseChars)
                    }
                }
            }
            switch encodingName {
            case "MacRomanEncoding": self = .macRoman
            default: self = .winAnsi
            }
        }

        func decode(_ bytes: [UInt8]) -> String {
            String(bytes: bytes, encoding: stringEncoding)
                ?? String(decoding: bytes, as: UTF8.self)
        }
    }

    private enum Token {
        case number(Double)
        case name(String)
        /// Decoded string bytes plus the literal's full byte range.
        case string([UInt8], Range<Int>)
        case arrayOpen(Int)
        case arrayClose(Int)
        case dictionaryOpen
        case dictionaryClose
        /// A bare word (operator) with its byte range.
        case keyword(String, Range<Int>)
    }

    private enum Operand {
        case number(Double)
        case name(String)
        case string([UInt8], Range<Int>)
        case array([Operand], Range<Int>)
    }

    /// Tokenize a decoded content stream. Whitespace/comments separate
    /// tokens; literal strings decode escapes; hex strings decode pairs.
    /// Inline images (BI/ID/EI) are not handled (phase-4 limit).
    private static func tokenize(_ bytes: [UInt8]) -> [Token] {
        func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x00 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
        }
        func isDelimiter(_ byte: UInt8) -> Bool {
            switch byte {
            case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: true
            default: false
            }
        }
        var tokens: [Token] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if isWhitespace(byte) {
                index += 1
                continue
            }
            if byte == 0x25 { // % comment → end of line
                while index < bytes.count && bytes[index] != 0x0A && bytes[index] != 0x0D { index += 1 }
                continue
            }
            switch byte {
            case 0x28: // ( literal string
                let start = index
                index += 1
                var decoded: [UInt8] = []
                var depth = 1
                while index < bytes.count && depth > 0 {
                    let current = bytes[index]
                    if current == 0x5C, index + 1 < bytes.count { // backslash escape
                        let escaped = bytes[index + 1]
                        switch escaped {
                        case 0x6E: decoded.append(0x0A); index += 2
                        case 0x72: decoded.append(0x0D); index += 2
                        case 0x74: decoded.append(0x09); index += 2
                        case 0x62: decoded.append(0x08); index += 2
                        case 0x66: decoded.append(0x0C); index += 2
                        case 0x28, 0x29, 0x5C: decoded.append(escaped); index += 2
                        case 0x0A: index += 2 // line continuation
                        case 0x0D:
                            index += 2
                            if index < bytes.count && bytes[index] == 0x0A { index += 1 }
                        case 0x30...0x39: // up to 3 octal digits
                            var value = 0
                            var digits = 0
                            var cursor = index + 1
                            while cursor < bytes.count && digits < 3,
                                  bytes[cursor] >= 0x30 && bytes[cursor] <= 0x39 {
                                value = value * 8 + Int(bytes[cursor] - 0x30)
                                cursor += 1
                                digits += 1
                            }
                            decoded.append(UInt8(truncatingIfNeeded: value))
                            index = cursor
                        default: decoded.append(escaped); index += 2
                        }
                    } else if current == 0x28 {
                        depth += 1
                        decoded.append(current)
                        index += 1
                    } else if current == 0x29 {
                        depth -= 1
                        if depth > 0 { decoded.append(current) }
                        index += 1
                    } else {
                        decoded.append(current)
                        index += 1
                    }
                }
                tokens.append(.string(decoded, start..<index))
            case 0x3C: // < hex string or << dictionary
                if index + 1 < bytes.count && bytes[index + 1] == 0x3C {
                    tokens.append(.dictionaryOpen)
                    index += 2
                } else {
                    let start = index
                    index += 1
                    var nibbles: [UInt8] = []
                    while index < bytes.count && bytes[index] != 0x3E {
                        let current = bytes[index]
                        if let value = Self.hexValue(of: current) { nibbles.append(value) }
                        index += 1
                    }
                    index += 1 // consume >
                    var decoded: [UInt8] = []
                    var cursor = 0
                    while cursor < nibbles.count {
                        let high = nibbles[cursor]
                        let low = cursor + 1 < nibbles.count ? nibbles[cursor + 1] : 0
                        decoded.append(high << 4 | low)
                        cursor += 2
                    }
                    tokens.append(.string(decoded, start..<index))
                }
            case 0x3E: // >> dictionary close
                tokens.append(.dictionaryClose)
                index += (index + 1 < bytes.count && bytes[index + 1] == 0x3E) ? 2 : 1
            case 0x5B:
                tokens.append(.arrayOpen(index))
                index += 1
            case 0x5D:
                tokens.append(.arrayClose(index + 1))
                index += 1
            case 0x2F: // / name
                index += 1
                let start = index
                while index < bytes.count && !isWhitespace(bytes[index]) && !isDelimiter(bytes[index]) {
                    index += 1
                }
                tokens.append(.name(String(decoding: bytes[start..<index], as: UTF8.self)))
            default: // number or keyword
                let start = index
                while index < bytes.count && !isWhitespace(bytes[index]) && !isDelimiter(bytes[index]) {
                    index += 1
                }
                let word = String(decoding: bytes[start..<index], as: UTF8.self)
                if let value = Double(word),
                   word.first.map({ $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) == true {
                    tokens.append(.number(value))
                } else {
                    tokens.append(.keyword(word, start..<index))
                }
            }
        }
        return tokens
    }

    private static func hexValue(of byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    /// Interpret one decoded content stream, tracking the graphics/text
    /// state, and return its text runs in show order.
    private static func interpret(stream: Data, streamIndex: Int, fonts: [String: FontInfo]) -> [ParsedRun] {
        let bytes = [UInt8](stream)
        var runs: [ParsedRun] = []
        var operands: [Operand] = []
        var arrayStack: [[Operand]] = []
        var arrayStartStack: [Int] = []

        var ctm = CGAffineTransform.identity
        var ctmStack: [CGAffineTransform] = []
        var inText = false
        var textMatrix = CGAffineTransform.identity
        var lineMatrix = CGAffineTransform.identity
        var fontResource = ""
        var fontSize: CGFloat = 0
        var leading: CGFloat = 0

        func numbers(_ count: Int) -> [Double]? {
            guard operands.count >= count else { return nil }
            let tail = operands.suffix(count)
            var values: [Double] = []
            for operand in tail {
                guard case .number(let value) = operand else { return nil }
                values.append(value)
            }
            return values
        }

        func moveText(toX tx: CGFloat, y ty: CGFloat) {
            lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
            textMatrix = lineMatrix
        }

        /// Record a run for a show operation and advance the text matrix.
        /// `range`/`isArray` describe the bytes a rewrite will replace.
        func show(stringBytes: [UInt8], adjustments: [Double], range: Range<Int>, isArray: Bool) {
            guard inText else { return }
            let font = fonts[fontResource]
            let encoding = font?.encoding ?? .winAnsi
            let text = encoding.decode(stringBytes)
            let matrixScale = max(0.0001, hypot(textMatrix.a, textMatrix.b))
            let effectiveSize = fontSize * matrixScale
            var advance: CGFloat = 0
            for (offset, byte) in stringBytes.enumerated() {
                let widthIndex = Int(byte) - (font?.firstChar ?? 0)
                if let font, widthIndex >= 0, widthIndex < font.widths.count {
                    advance += font.widths[widthIndex] / 1000 * fontSize
                } else {
                    advance += fontSize / 2
                }
                if isArray, offset < adjustments.count {
                    // TJ numbers shift the next glyph left in 1/1000 em.
                    advance -= CGFloat(adjustments[offset]) / 1000 * fontSize
                }
            }
            let userAdvance = advance * matrixScale * max(0.0001, hypot(ctm.a, ctm.b))
            let origin = CGPoint(x: textMatrix.tx, y: textMatrix.ty).applying(ctm)
            let replacement: ParsedRun.Replacement = isArray ? .arrayAndOperator(range) : .stringOperand(range)
            runs.append(ParsedRun(text: text, fontResource: fontResource, font: font,
                                  fontSize: effectiveSize,
                                  bounds: CGRect(x: origin.x, y: origin.y,
                                                 width: max(userAdvance, 1), height: max(effectiveSize, 1)),
                                  streamIndex: streamIndex, replacement: replacement))
            textMatrix = CGAffineTransform(translationX: advance, y: 0).concatenating(textMatrix)
        }

        for token in tokenize(bytes) {
            switch token {
            case .number(let value): operands.append(.number(value))
            case .name(let name): operands.append(.name(name))
            case .string(let decoded, let range): operands.append(.string(decoded, range))
            case .arrayOpen(let offset):
                arrayStack.append(operands)
                arrayStartStack.append(offset)
                operands = []
            case .arrayClose(let end):
                let elements = operands
                operands = arrayStack.popLast() ?? []
                let start = arrayStartStack.popLast() ?? end
                operands.append(.array(elements, start..<end))
            case .dictionaryOpen, .dictionaryClose:
                operands = []
            case .keyword(let word, let range):
                switch word {
                case "q":
                    ctmStack.append(ctm)
                case "Q":
                    ctm = ctmStack.popLast() ?? .identity
                case "cm":
                    if let v = numbers(6) {
                        let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                        ctm = m.concatenating(ctm)
                    }
                case "BT":
                    inText = true
                    textMatrix = .identity
                    lineMatrix = .identity
                case "ET":
                    inText = false
                case "Tf":
                    if operands.count >= 2,
                       case .name(let name) = operands[operands.count - 2],
                       case .number(let size) = operands[operands.count - 1] {
                        fontResource = name
                        fontSize = CGFloat(size)
                    }
                case "Td":
                    if let v = numbers(2) { moveText(toX: v[0], y: v[1]) }
                case "TD":
                    if let v = numbers(2) {
                        leading = -v[1]
                        moveText(toX: v[0], y: v[1])
                    }
                case "Tm":
                    if let v = numbers(6) {
                        textMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                        lineMatrix = textMatrix
                    }
                case "T*":
                    moveText(toX: 0, y: -leading)
                case "TL":
                    if let v = numbers(1) { leading = v[0] }
                case "Tj":
                    if case .string(let decoded, let stringRange)? = operands.last {
                        show(stringBytes: decoded, adjustments: [], range: stringRange, isArray: false)
                    }
                case "'", "\"":
                    moveText(toX: 0, y: -leading)
                    if case .string(let decoded, let stringRange)? = operands.last {
                        show(stringBytes: decoded, adjustments: [], range: stringRange, isArray: false)
                    }
                case "TJ":
                    if case .array(let elements, let arrayRange)? = operands.last {
                        var decoded: [UInt8] = []
                        var adjustments: [Double] = []
                        for element in elements {
                            switch element {
                            case .string(let bytes, _):
                                decoded.append(contentsOf: bytes)
                                adjustments.append(contentsOf: [Double](repeating: 0, count: bytes.count))
                            case .number(let value):
                                if !adjustments.isEmpty {
                                    adjustments[adjustments.count - 1] = value
                                }
                            default: break
                            }
                        }
                        // Replace the array AND the TJ keyword itself.
                        show(stringBytes: decoded, adjustments: adjustments,
                             range: arrayRange.lowerBound..<range.upperBound, isArray: true)
                    }
                default:
                    break // unsupported operator — operands are dropped
                }
                operands = []
            }
        }
        return runs
    }

    // MARK: - Literal string emission

    /// Escape bytes as a PDF literal string, "( … )".
    private static func literalString(for bytes: [UInt8]) -> Data {
        var out = Data([0x28])
        for byte in bytes {
            switch byte {
            case 0x28: out.append(contentsOf: [0x5C, 0x28])
            case 0x29: out.append(contentsOf: [0x5C, 0x29])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])
            case 0x09: out.append(contentsOf: [0x5C, 0x74])
            case 0x08: out.append(contentsOf: [0x5C, 0x62])
            case 0x0C: out.append(contentsOf: [0x5C, 0x66])
            case 0x20...0x7E: out.append(byte)
            default: // octal escape for everything else
                out.append(0x5C)
                out.append(0x30 + (byte >> 6))
                out.append(0x30 + ((byte >> 3) & 0x07))
                out.append(0x30 + (byte & 0x07))
            }
        }
        out.append(0x29)
        return out
    }

    // MARK: - Serialized PDF surgery

    /// Minimal reader/writer for a classically serialized PDF (the output
    /// of PDFKit's `dataRepresentation()`): enumerates indirect objects,
    /// decodes Flate/identity streams, parses the trailer, and appends an
    /// incremental update section.
    private struct SerializedPDF {
        struct IndirectObject {
            let number: Int
            let generation: Int
            /// Bytes after "N G obj" through the end of "endobj".
            let body: Range<Int>
        }

        /// One object override in an incremental update: either a plain
        /// dictionary body or a new (uncompressed) stream.
        struct Replacement {
            let object: IndirectObject
            var dictionary: Data?
            var streamData: Data?
        }

        let data: Data

        func indirectObjects() -> [IndirectObject] {
            var objects: [IndirectObject] = []
            let marker = Data(" obj".utf8)
            let endMarker = Data("endobj".utf8)
            var position = data.startIndex
            while let markerRange = data.range(of: marker, in: position..<data.endIndex) {
                var cursor = markerRange.lowerBound
                func skipSpaces() { while cursor > 0 && data[cursor - 1] == 0x20 { cursor -= 1 } }
                func readNumber() -> Int? {
                    skipSpaces()
                    let end = cursor
                    while cursor > 0 && data[cursor - 1] >= 0x30 && data[cursor - 1] <= 0x39 { cursor -= 1 }
                    guard cursor < end else { return nil }
                    return Int(String(decoding: data[cursor..<end], as: UTF8.self))
                }
                let parsed = readNumber().flatMap { generation in
                    readNumber().map { (number: $0, generation: generation) }
                }
                guard let parsed,
                      let endRange = data.range(of: endMarker, in: markerRange.upperBound..<data.endIndex) else {
                    position = markerRange.upperBound
                    continue
                }
                objects.append(IndirectObject(number: parsed.number, generation: parsed.generation,
                                              body: markerRange.upperBound..<endRange.upperBound))
                position = endRange.upperBound
            }
            return objects
        }

        /// The decoded stream data of an object (identity or FlateDecode;
        /// other filters return nil). Exactly /Length bytes are read so
        /// uncompressed streams match CGPDF's decoding byte-for-byte.
        func decodedStreamData(of object: IndirectObject) -> Data? {
            let streamMarker = Data("stream".utf8)
            guard let streamRange = data.range(of: streamMarker, in: object.body) else { return nil }
            let header = data[object.body.lowerBound..<streamRange.lowerBound]
            var start = streamRange.upperBound
            guard start < data.endIndex else { return nil }
            if data[start] == 0x0D && start + 1 < data.endIndex && data[start + 1] == 0x0A {
                start += 2
            } else {
                start += 1
            }
            let declaredLength = Self.dictionaryInteger("Length", in: header)
            let raw: Data
            if let declaredLength, start + declaredLength <= data.endIndex {
                raw = Data(data[start..<(start + declaredLength)])
            } else {
                guard let endRange = data.range(of: Data("endstream".utf8), in: start..<object.body.upperBound)
                else { return nil }
                raw = Data(data[start..<endRange.lowerBound])
            }
            if header.range(of: Data("FlateDecode".utf8)) != nil {
                return Self.inflateZlib(raw)
            }
            return raw
        }

        /// FlateDecode is zlib-wrapped (RFC 1950) deflate; the Compression
        /// framework's COMPRESSION_ZLIB is raw deflate (RFC 1951), so the
        /// 2-byte zlib header is skipped (the adler32 trailer is ignored).
        static func inflateZlib(_ data: Data) -> Data? {
            guard data.count > 2 else { return nil }
            let source = data.dropFirst(2)
            let capacity = max(4096, source.count * 16)
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }
            let count = source.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return compression_decode_buffer(destination, capacity,
                                                 base.assumingMemoryBound(to: UInt8.self),
                                                 buffer.count, nil, COMPRESSION_ZLIB)
            }
            guard count > 0 else { return nil }
            return Data(bytes: destination, count: count)
        }

        static func dictionaryInteger(_ key: String, in bytes: Data.SubSequence) -> Int? {
            guard let keyRange = bytes.range(of: Data("/\(key) ".utf8)) else { return nil }
            var cursor = keyRange.upperBound
            let start = cursor
            while cursor < bytes.endIndex && bytes[cursor] >= 0x30 && bytes[cursor] <= 0x39 { cursor += 1 }
            guard cursor > start else { return nil }
            return Int(String(decoding: bytes[start..<cursor], as: UTF8.self))
        }

        /// Last-trailer values needed to chain an incremental update:
        /// /Root (as a full indirect reference), /Size, and the previous
        /// startxref offset. Cross-reference streams have no "trailer"
        /// keyword and are unsupported.
        func trailer() -> (root: String, size: Int, previousStartXref: Int)? {
            let text = String(decoding: data, as: UTF8.self)
            guard let trailerRange = text.range(of: "trailer", options: .backwards),
                  let root = Self.trailerEntry("Root", in: String(text[trailerRange.upperBound...])),
                  let sizeText = Self.trailerEntry("Size", in: String(text[trailerRange.upperBound...])),
                  let size = Int(sizeText),
                  let startXrefRange = text.range(of: "startxref", options: .backwards) else {
                return nil
            }
            let tail = text[startXrefRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
            guard let previous = tail.first.flatMap(Int.init) else { return nil }
            return (root, size, previous)
        }

        private static func trailerEntry(_ key: String, in trailer: String) -> String? {
            guard let keyRange = trailer.range(of: "/\(key) ") else { return nil }
            let rest = String(trailer[keyRange.upperBound...])
            if let reference = rest.range(of: #"^\d+ \d+ R"#, options: .regularExpression) {
                return String(rest[reference])
            }
            let end = rest.firstIndex(where: { " \r\n/>".contains($0) }) ?? rest.endIndex
            return String(rest[..<end])
        }

        /// Append a classic incremental update: new versions of the given
        /// objects, one xref subsection per contiguous object run, and a
        /// trailer chaining to the previous startxref. Returns nil when
        /// the file has no classic trailer.
        func incrementalUpdate(replacing replacements: [Replacement]) -> Data? {
            guard let trailer = trailer() else { return nil }
            var output = Data(data)
            var offsets: [(number: Int, offset: Int)] = []
            for replacement in replacements {
                offsets.append((replacement.object.number, output.count + 1)) // + leading \n
                var objectData = Data("\n\(replacement.object.number) \(replacement.object.generation) obj\n".utf8)
                if let streamData = replacement.streamData {
                    objectData.append(Data("<< /Length \(streamData.count) >>\nstream\n".utf8))
                    objectData.append(streamData)
                    objectData.append(Data("\nendstream\nendobj\n".utf8))
                } else if let dictionary = replacement.dictionary {
                    objectData.append(dictionary)
                    objectData.append(Data("\nendobj\n".utf8))
                }
                output.append(objectData)
            }
            let xrefOffset = output.count
            var xref = Data("xref\n".utf8)
            let sorted = offsets.sorted { $0.number < $1.number }
            var index = 0
            while index < sorted.count {
                var runEnd = index
                while runEnd + 1 < sorted.count && sorted[runEnd + 1].number == sorted[runEnd].number + 1 {
                    runEnd += 1
                }
                xref.append(Data("\(sorted[index].number) \(runEnd - index + 1)\n".utf8))
                for entry in sorted[index...runEnd] {
                    xref.append(Data(String(format: "%010d 00000 n \r\n", entry.offset).utf8))
                }
                index = runEnd + 1
            }
            output.append(xref)
            let maxNumber = sorted.map(\.number).max() ?? 0
            output.append(Data("""
                trailer
                << /Size \(max(trailer.size, maxNumber + 1)) /Root \(trailer.root) /Prev \(trailer.previousStartXref) >>
                startxref
                \(xrefOffset)
                %%EOF

                """.utf8))
            return output
        }
    }
}
