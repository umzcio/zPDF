import Foundation
import NaturalLanguage
import PDFKit

/// Options for Advanced Search.
struct SearchOptions: Hashable, Sendable {
    var wholeWords = false
    var caseSensitive = false
    var regex = false
    var stemming = false
    /// Words that must all occur within this many words (0 = off).
    var proximity = 0
    var ignoreDiacritics = true
    var includeBookmarks = true
    var includeComments = true
    var includeAttachments = false
    var maxResults = 500
    var contextWords = 8
}

/// Where a match was found.
enum SearchLocation: Hashable, Sendable {
    case page(Int)
    case bookmark(String)
    case comment(page: Int, author: String?)
    case attachment(name: String, page: Int)

    var title: String {
        switch self {
        case .page(let page): "Page \(page + 1)"
        case .bookmark(let title): "Bookmark “\(title)”"
        case .comment(let page, let author): "Comment on page \(page + 1)" + (author.map { " by \($0)" } ?? "")
        case .attachment(let name, let page): "Attachment \(name), page \(page + 1)"
        }
    }

    var page: Int? {
        switch self {
        case .page(let page): page
        case .comment(let page, _): page
        case .bookmark, .attachment: nil
        }
    }
}

struct SearchHit: Identifiable, Hashable, Sendable {
    let id = UUID()
    let document: URL
    let location: SearchLocation
    let range: NSRange
    let before: String
    let match: String
    let after: String
}

/// Text sources for one document (page text, bookmarks, comments, attachments).
struct SearchableDocument: Sendable {
    var url: URL
    var pages: [String]
    var bookmarks: [String] = []
    var comments: [(page: Int, author: String?, text: String)] = []
    var attachments: [(name: String, pages: [String])] = []

    /// Reads a PDF (off the main thread). Locked PDFs yield no text.
    static func load(_ url: URL, options: SearchOptions, displayURL: URL? = nil) -> SearchableDocument? {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        var result = SearchableDocument(url: displayURL ?? url, pages: (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" })
        if options.includeBookmarks, let root = document.outlineRoot {
            func walk(_ node: PDFOutline) {
                for index in 0..<node.numberOfChildren {
                    guard let child = node.child(at: index) else { continue }
                    if let label = child.label { result.bookmarks.append(label) }
                    walk(child)
                }
            }
            walk(root)
        }
        if options.includeComments {
            for index in 0..<document.pageCount {
                for annotation in document.page(at: index)?.annotations ?? [] where !["Widget", "Link", "Popup"].contains(annotation.type ?? "") {
                    if let contents = annotation.contents, !contents.isEmpty {
                        result.comments.append((index, annotation.userName, contents))
                    }
                }
            }
        }
        if options.includeAttachments {
            result.attachments = EmbeddedPDFText.extract(from: url)
        }
        return result
    }
}

/// Text of PDFs embedded in a PDF (attachments), via CoreGraphics.
enum EmbeddedPDFText {
    static func extract(from url: URL, limit: Int = 20) -> [(name: String, pages: [String])] {
        guard let document = CGPDFDocument(url as CFURL), let catalog = document.catalog else { return [] }
        var names: CGPDFDictionaryRef?
        var tree: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names,
              CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &tree), let tree else { return [] }
        var found: [(String, [String])] = []
        func visit(_ node: CGPDFDictionaryRef, depth: Int) {
            guard depth < 16, found.count < limit else { return }
            var pairs: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Names", &pairs), let pairs {
                var index = 0
                while index + 1 < CGPDFArrayGetCount(pairs), found.count < limit {
                    var key: CGPDFStringRef?
                    var spec: CGPDFDictionaryRef?
                    if CGPDFArrayGetString(pairs, index, &key), CGPDFArrayGetDictionary(pairs, index + 1, &spec), let spec {
                        let name = key.flatMap { CGPDFStringCopyTextString($0) as String? } ?? "attachment"
                        if name.lowercased().hasSuffix(".pdf"), let data = streamData(spec), let pdf = PDFDocument(data: data), !pdf.isLocked {
                            found.append((name, (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }))
                        }
                    }
                    index += 2
                }
            }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
                for index in 0..<CGPDFArrayGetCount(kids) {
                    var kid: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(kids, index, &kid), let kid { visit(kid, depth: depth + 1) }
                }
            }
        }
        visit(tree, depth: 0)
        return found
    }

    private static func streamData(_ spec: CGPDFDictionaryRef) -> Data? {
        var ef: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(spec, "EF", &ef), let ef else { return nil }
        var stream: CGPDFStreamRef?
        if !CGPDFDictionaryGetStream(ef, "UF", &stream) { _ = CGPDFDictionaryGetStream(ef, "F", &stream) }
        guard let stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), format == .raw else { return nil }
        return data as Data
    }
}

/// Finds matches in text according to SearchOptions.
struct SearchMatcher: Sendable {
    let query: String
    let options: SearchOptions
    private let regex: NSRegularExpression?
    private let terms: [String]
    private let lemmas: Set<String>

    init(query: String, options: SearchOptions) throws {
        self.query = query
        self.options = options
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        terms = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if options.regex {
            var flags: NSRegularExpression.Options = [.useUnicodeWordBoundaries]
            if !options.caseSensitive { flags.insert(.caseInsensitive) }
            do { regex = try NSRegularExpression(pattern: trimmed, options: flags) }
            catch { throw NativeSaveError(code: "INVALID_PATTERN", message: "The regular expression isn't valid: \(error.localizedDescription)") }
        } else {
            regex = nil
        }
        lemmas = options.stemming ? Set(terms.flatMap { Self.lemmaForms($0) }) : []
    }

    var usesWordMatching: Bool { !options.regex && (options.stemming || options.proximity > 0) }

    /// All match ranges in `text`.
    func matches(in text: String) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0, !terms.isEmpty else { return [] }
        if let regex {
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range).filter { $0.length > 0 }
        }
        if usesWordMatching { return wordMatches(in: text) }
        var options: NSString.CompareOptions = []
        if !self.options.caseSensitive { options.insert(.caseInsensitive) }
        if self.options.ignoreDiacritics { options.insert(.diacriticInsensitive) }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var found: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let range = ns.range(of: needle, options: options, range: search)
            guard range.location != NSNotFound else { break }
            if !self.options.wholeWords || (SearchWordBoundary.isBoundary(in: text, at: range.location)
                                            && SearchWordBoundary.isBoundary(in: text, at: NSMaxRange(range))) {
                found.append(range)
            }
            let next = range.location + max(1, range.length)
            search = NSRange(location: next, length: ns.length - next)
        }
        return found
    }

    /// Stemming and/or proximity: tokenize into words and compare words
    /// (or their lemmas) with the query terms.
    private func wordMatches(in text: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [(range: NSRange, forms: Set<String>)] = []
        let tagger = options.stemming ? NLTagger(tagSchemes: [.lemma]) : nil
        tagger?.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            var forms: Set<String> = [normalize(word)]
            if let tagger {
                let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma)
                if let lemma = tag?.rawValue { forms.insert(normalize(lemma)) }
                forms.formUnion(Self.lemmaForms(word).map(normalize))
            }
            words.append((NSRange(range, in: text), forms))
            return true
        }
        let wanted = terms.map { term -> Set<String> in
            var forms: Set<String> = [normalize(term)]
            if options.stemming { forms.formUnion(Self.lemmaForms(term).map(normalize)) }
            return forms
        }
        func matchesTerm(_ index: Int, _ term: Int) -> Bool { !words[index].forms.isDisjoint(with: wanted[term]) }
        var found: [NSRange] = []
        if options.proximity > 0 && wanted.count > 1 {
            // Every term within `proximity` words of the first term's hit.
            for (index, _) in words.enumerated() where matchesTerm(index, 0) {
                let window = max(0, index - options.proximity)...min(words.count - 1, index + options.proximity)
                var hits: [Int] = [index]
                var ok = true
                for term in 1..<wanted.count {
                    guard let hit = window.first(where: { matchesTerm($0, term) }) else { ok = false; break }
                    hits.append(hit)
                }
                if ok, let low = hits.min(), let high = hits.max() {
                    let start = words[low].range.location
                    found.append(NSRange(location: start, length: NSMaxRange(words[high].range) - start))
                }
            }
        } else {
            for index in words.indices where wanted.indices.contains(where: { matchesTerm(index, $0) }) {
                found.append(words[index].range)
            }
        }
        return found
    }

    private func normalize(_ word: String) -> String {
        var options: String.CompareOptions = []
        if !self.options.caseSensitive { options.insert(.caseInsensitive) }
        if self.options.ignoreDiacritics { options.insert(.diacriticInsensitive) }
        return word.folding(options: options, locale: nil)
    }

    /// The lemma of a single word (and the word itself).
    static func lemmaForms(_ word: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        let (tag, _) = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma)
        return [word, tag?.rawValue].compactMap { $0 }
    }

    /// Context snippet (words before/after) for a match.
    func hit(in text: String, range: NSRange, document: URL, location: SearchLocation) -> SearchHit {
        let ns = text as NSString
        func words(_ string: String, fromEnd: Bool) -> String {
            let parts = string.split(whereSeparator: \.isWhitespace)
            let chosen = fromEnd ? parts.suffix(options.contextWords) : parts.prefix(options.contextWords)
            return chosen.joined(separator: " ")
        }
        let before = ns.substring(to: range.location)
        let after = ns.substring(from: NSMaxRange(range))
        return SearchHit(document: document, location: location, range: range,
                         before: words(String(before.suffix(400)), fromEnd: true),
                         match: ns.substring(with: range).replacingOccurrences(of: "\n", with: " "),
                         after: words(String(after.prefix(400)), fromEnd: false))
    }

    func search(_ document: SearchableDocument, limit: Int) -> [SearchHit] {
        var hits: [SearchHit] = []
        func add(_ text: String, _ location: SearchLocation) {
            for range in matches(in: text) {
                guard hits.count < limit else { return }
                hits.append(hit(in: text, range: range, document: document.url, location: location))
            }
        }
        for (index, text) in document.pages.enumerated() { add(text, .page(index)); if hits.count >= limit { return hits } }
        for title in document.bookmarks { add(title, .bookmark(title)) }
        for comment in document.comments { add(comment.text, .comment(page: comment.page, author: comment.author)) }
        for attachment in document.attachments {
            for (index, text) in attachment.pages.enumerated() { add(text, .attachment(name: attachment.name, page: index)) }
        }
        return hits
    }
}

// MARK: - Folder index

/// Local full-text indexes of folders for instant searching. Stored in the
/// app's private Application Support container (never inside the folder).
@MainActor @Observable
final class SearchIndexStore {
    static let shared = SearchIndexStore()

    struct Folder: Codable, Hashable {
        var path: String
        var name: String
        var bookmark: Data?
        var updated: Date
        var documentCount: Int
    }

    struct IndexedFile: Codable {
        var path: String
        var modified: Date
        var pages: [String]
        var bookmarks: [String]
        var comments: [IndexedComment]
    }

    struct IndexedComment: Codable {
        var page: Int
        var author: String?
        var text: String
    }

    private(set) var folders: [Folder] = []
    private(set) var building: String?
    private(set) var progress: Double = 0

    nonisolated private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("zPDF/SearchIndexes", isDirectory: true)
    }
    nonisolated private static var manifest: URL { directory.appendingPathComponent("folders.json") }

    init() {
        if let data = try? Data(contentsOf: Self.manifest), let stored = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = stored
        }
    }

    nonisolated private static func indexFile(for path: String) -> URL {
        let name = Data(path.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").prefix(120)
        return directory.appendingPathComponent("\(name).json")
    }

    private func persistManifest() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(folders) { try? data.write(to: Self.manifest, options: .atomic) }
    }

    func remove(_ path: String) {
        folders.removeAll { $0.path == path }
        try? FileManager.default.removeItem(at: Self.indexFile(for: path))
        persistManifest()
    }

    /// Builds or refreshes the index for `folder` (changed files only).
    func build(_ folder: URL) async throws {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        building = folder.lastPathComponent
        progress = 0
        defer { building = nil }
        let path = folder.standardizedFileURL.path
        let existing = Self.load(path)
        let files = BatchRun.collectPDFs([folder])
        var entries: [IndexedFile] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let cached = existing[file.path], cached.modified == modified {
                entries.append(cached)
            } else {
                let loaded = await Task.detached(priority: .utility) { () -> IndexedFile? in
                    guard let doc = SearchableDocument.load(file, options: SearchOptions(includeBookmarks: true, includeComments: true)) else { return nil }
                    return IndexedFile(path: file.path, modified: modified, pages: doc.pages, bookmarks: doc.bookmarks,
                                       comments: doc.comments.map { IndexedComment(page: $0.page, author: $0.author, text: $0.text) })
                }.value
                if let loaded { entries.append(loaded) }
            }
            progress = Double(index + 1) / Double(max(1, files.count))
        }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: Self.indexFile(for: path), options: .atomic)
        let bookmark = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let record = Folder(path: path, name: folder.lastPathComponent, bookmark: bookmark, updated: Date(), documentCount: entries.count)
        folders.removeAll { $0.path == path }
        folders.append(record)
        persistManifest()
    }

    nonisolated static func load(_ path: String) -> [String: IndexedFile] {
        guard let data = try? Data(contentsOf: indexFile(for: path)),
              let entries = try? JSONDecoder().decode([IndexedFile].self, from: data) else { return [:] }
        return Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Resolves the folder's security-scoped bookmark (for opening results).
    func resolve(_ folder: Folder) -> URL? {
        guard let bookmark = folder.bookmark else { return URL(fileURLWithPath: folder.path) }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Searchable documents from an index (fast: no PDF parsing).
    nonisolated static func documents(in path: String, options: SearchOptions) -> [SearchableDocument] {
        load(path).values.sorted { $0.path < $1.path }.map { entry in
            SearchableDocument(url: URL(fileURLWithPath: entry.path), pages: entry.pages,
                               bookmarks: options.includeBookmarks ? entry.bookmarks : [],
                               comments: options.includeComments ? entry.comments.map { ($0.page, $0.author, $0.text) } : [])
        }
    }
}
