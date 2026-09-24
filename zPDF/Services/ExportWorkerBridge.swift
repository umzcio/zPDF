import Foundation
import CryptoKit

struct ExportNotice: Identifiable, Sendable {
    let code: String
    let pages: [Int]
    var id: String { code }
    var message: String {
        switch code {
        case "PICTURE_LABELS_KEPT": "Map or diagram labels are preserved in pictures and their descriptions, rather than editable text."
        case "IMAGE_DOWNSAMPLED": "Some images were reduced to 200 dpi or less."
        case "VECTOR_ARTWORK_RENDERED", "VECTOR_ARTWORK_BACKDROP", "TEXT_SIDEWAYS_RENDERED": "Some drawings or rotated text were preserved as pictures."
        case "VECTOR_ARTWORK_OVERLAPS_TEXT": "A drawing overlapping text could not be reproduced. Review the affected pages."
        case "MISSING_UNICODE_MAP": "Some characters could not be identified and appear as replacement characters."
        case "GLYPH_INFERRED", "GLYPH_RECOVERED": "Some characters were recovered from font information or inferred. Check their spelling."
        case "TEXT_INVISIBLE_KEPT_HIDDEN": "Hidden or OCR text was retained separately; recognition errors may remain."
        case "FORM_VALUE_UNPAIRED": "Some form values could not be matched confidently to their labels."
        case "LAYOUT_PAGE_ROTATED": "Rotated page layout may differ in readers other than Word."
        case "MD_FORMATTING_NOT_KEPT": "Markdown does not preserve page layout, fonts, colors, highlighting, alignment or decorative rules."
        case "MD_TABLE_HEADER_FLATTENED", "MD_TABLE_SPANS_NOT_KEPT": "Complex table headers or merged cells were simplified for Markdown."
        case "MD_COMMENTS_AS_QUOTES": "Comments were exported as quotations."
        case "MD_LIST_MARKERS_AS_DIGITS": "Lettered or Roman-numeral lists use numeric markers."
        case "XLSX_PICTURE_OMITTED": "Pictures are represented by descriptions in this workbook."
        case "XLSX_NO_TABLES": "No tables were detected; content appears on the Text sheet."
        case "TABLE_BODY_RECOVERED": "Some table rows were reconstructed from column alignment. Check the columns."
        case "TABLE_JOINED": "Continuing table sections were joined with a single header."
        case "LAYOUT_RULES_DROPPED": "Some decorative lines could not be preserved."
        case "LAYOUT_FILLS_DROPPED": "Some background colors or shading could not be preserved."
        case "LAYOUT_FILLS_AS_BACKDROP": "Some background colors or shading were preserved as pictures."
        case "TABLE_SPAN_IRREGULAR": "Some merged table cells were simplified. Check the table layout."
        case "LAYOUT_PAGE_UPRIGHT": "A rotated page was rebuilt upright."
        case "LINK_DROPPED_UNSAFE_SCHEME", "LINK_SCHEME_NOT_ALLOWED": "Some links use unsupported destinations and remain plain text."
        case "XLSX_CELL_OVERLAP": "Some table cells overlap. Check their placement in the workbook."
        case "XLSX_LINKS_REDUCED": "Some links were simplified because spreadsheet cells support only one link."
        case "MD_TABLE_NO_HEADER": "A table had no identifiable header. Review its Markdown heading row."
        case "MD_PICTURES_AS_DATA_URI": "Pictures are embedded in the Markdown. Some readers cannot display them."
        case "IMAGE_ONLY_PAGE": "A page without selectable text was preserved as a picture."
        case "BLANK_PAGE": "A blank page was found in the selected pages."
        case "CONTENT_OUTSIDE_CROPBOX": "Content outside the visible page boundary was omitted."
        case "CONTENT_EXCLUDED_BY_OPTION": "Some content was omitted by the export settings."
        case "IMAGE_HIDDEN": "A hidden image was not included."
        case "IMAGE_NOT_EXTRACTED": "An image could not be extracted. Review the affected page."
        case "VECTOR_ARTWORK_BLANK", "VECTOR_ARTWORK_PAGE_DECORATION": "Some page decoration was omitted or simplified."
        case "WIDGET_WITHOUT_FORM": "A form control could not be associated with a form field. Check its value."
        case "PARTIAL_CONTENT": "Some content could not be converted. Review the affected pages."
        default: code.replacingOccurrences(of: "_", with: " ").lowercased().capitalized + ". Review the exported content."
        }
    }
}

/// Owns the versioned export protocol and publication, separately from PDF Save.
enum ExportWorkerBridge {
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func export(input: URL, options: ConversionOptions, destination: SaveDestination,
                       cancellation: ConversionCancellation,
                       progress: @escaping @Sendable (String, Int, Int) -> Void) async throws -> ConversionResult {
        try await Task.detached(priority: .userInitiated) {
            try cancellation.check()
            guard options.format.usesWorker, !options.pages.isEmpty, options.pages.count <= 500,
                  (try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 512 * 1024 * 1024,
                  !SaveDestination.sameFile(input, destination.url) else {
                throw failure("EXPORT_LIMIT", "Choose up to 500 pages from a PDF smaller than 512 MB and a separate destination.")
            }
            let manager = FileManager.default
            let staging = destination.url.deletingLastPathComponent().appendingPathComponent(".zpdf-export-\(UUID())", isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: staging) }
            guard let runtime = Bundle.main.resourceURL?.appendingPathComponent("EngineRuntime") else {
                throw failure("EXPORT_UNAVAILABLE", "The exporter is missing from this app build.")
            }
            let transport = try NativeHelperTransport(executable: runtime.appendingPathComponent("python/bin/python3.13"),
                arguments: ["-B", "-u", runtime.appendingPathComponent("support/export_worker.py").path],
                environment: ["PYTHONHOME": runtime.appendingPathComponent("python").path,
                              "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": NSTemporaryDirectory()],
                limits: .init(command: 900))
            defer { transport.dispose() }
            let caps = try transport.exchange(["protocol_version": 1, "operation": "capabilities"], check: cancellation.check) { _ in true }
            guard caps["protocol_version"] as? Int == 1,
                  let formats = caps["formats"] as? [String: [String: Any]],
                  let capability = formats[options.format.rawValue], capability["available"] as? Bool == true else {
                throw failure("EXPORT_UNAVAILABLE", "This exporter build does not support the selected format.")
            }
            var settings: [String: Any] = [:]
            if options.format.hasLayout {
                guard let supported = capability["options"] as? [String: Any],
                      (supported["layout_mode"] as? [String])?.contains(options.layoutMode) == true else {
                    throw failure("UNSUPPORTED_OPTION", "This layout mode is unavailable.")
                }
                settings["layout_mode"] = options.layoutMode
            }
            // A fresh folder avoids replacing or deleting unrelated companion assets.
            let stem = destination.url.deletingPathExtension().lastPathComponent
            let safeStem = String(stem.unicodeScalars.map { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").contains($0) ? String($0) : "_" }.joined().prefix(60))
            let assetName = "\(safeStem.isEmpty ? "Export" : safeStem)_images_\(UUID().uuidString.prefix(8))"
            if options.format == .markdown { settings["markdown_images"] = "folder"; settings["markdown_asset_folder"] = assetName }
            let hash = try digest(input), job = UUID().uuidString
            let request: [String: Any] = ["protocol_version": 1, "operation": "convert", "job_id": job,
                "snapshot": ["path": input.path, "sha256": hash], "staging_directory": staging.path,
                "format": options.format.rawValue, "pages": options.pages.map { $0 + 1 }, "options": settings]
            let response = try transport.exchange(request, check: cancellation.check) { message in
                guard message["protocol_version"] as? Int == 1, message["job_id"] as? String == job else { throw transport.invalidReply() }
                if message["event"] as? String == "progress" {
                    let stage = message["stage"] as? String ?? ""
                    progress(["extract": "Reading pages", "write": "Creating export", "validate": "Checking export"][stage] ?? "Exporting",
                             message["pages_done"] as? Int ?? 0, message["pages_total"] as? Int ?? 1)
                    return false
                }
                guard message["event"] as? String == "result" else { throw transport.invalidReply() }
                return true
            }
            if response["status"] as? String == "cancelled" { throw CancellationError() }
            guard ["ok", "ok_with_warnings"].contains(response["status"] as? String ?? "") else {
                let error = response["error"] as? [String: Any] ?? [:]
                let code = error["code"] as? String ?? "EXPORT_FAILED"
                let text: String
                switch code {
                case "OCR_REQUIRED": text = "These pages need OCR before they can be converted. Export images instead."
                case "POLICY_BLOCKED": text = "Encrypted and XFA documents are not supported by this exporter."
                case "INVALID_REQUEST": text = "The export request was rejected (\(error["message_key"] as? String ?? "invalid_request")). No output was published."
                case "SOURCE_CHANGED": text = "The export snapshot changed. Retry from the document."
                default: text = "The exporter could not complete this document (\(code)). Your PDF and existing export are unchanged."
                }
                throw failure(code, text)
            }
            guard response["snapshot_sha256"] as? String == hash, let artifact = response["artifact"] as? [String: Any],
                  artifact["relative_path"] as? String == "document.\(options.format.fileExtension)" else { throw transport.invalidReply() }
            let primary = staging.appendingPathComponent("document.\(options.format.fileExtension)")
            var byteCount = try validate(primary, metadata: artifact)
            guard artifact["files"] == nil || artifact["files"] is [[String: Any]],
                  let stats = response["stats"] as? [String: Any], stats["pages_processed"] as? Int == options.pages.count else { throw transport.invalidReply() }
            let files = artifact["files"] as? [[String: Any]] ?? []
            var seen = Set<String>()
            for file in files {
                guard options.format == .markdown, let relative = file["relative_path"] as? String,
                      relative.hasPrefix(assetName + "/"), relative.split(separator: "/").count == 2,
                      !relative.contains(".."), seen.insert(relative).inserted else { throw transport.invalidReply() }
                byteCount += try validate(staging.appendingPathComponent(relative), metadata: file)
            }
            if !files.isEmpty {
                let folder = staging.appendingPathComponent(assetName)
                let flags = try folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard flags.isDirectory == true, flags.isSymbolicLink != true,
                      Set(try manager.contentsOfDirectory(atPath: folder.path).map { assetName + "/" + $0 }) == seen else { throw transport.invalidReply() }
            }
            let expectedItems: Set<String> = files.isEmpty ? [primary.lastPathComponent] : [primary.lastPathComponent, assetName]
            guard Set(try manager.contentsOfDirectory(atPath: staging.path)) == expectedItems else { throw transport.invalidReply() }
            try cancellation.check()
            try publish(primary: primary, assets: files.isEmpty ? nil : staging.appendingPathComponent(assetName),
                        destination: destination, cancellation: cancellation)
            var grouped: [String: Set<Int>] = [:]
            for warning in response["warnings"] as? [[String: Any]] ?? [] {
                guard let code = warning["code"] as? String else { continue }
                if grouped[code] == nil { grouped[code] = [] }
                if let page = warning["page"] as? Int { grouped[code]?.insert(page) }
            }
            return ConversionResult(url: destination.url, fileCount: 1 + files.count, byteCount: byteCount,
                pagesWithoutText: [], notices: grouped.keys.sorted().map { ExportNotice(code: $0, pages: grouped[$0]!.sorted()) })
        }.value
    }

    static func validate(_ url: URL, metadata: [String: Any]) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let expected = metadata["sha256"] as? String, let bytes = metadata["bytes"] as? Int,
              bytes > 0, values.fileSize == bytes, try digest(url) == expected else {
            throw failure("EXPORT_INVALID", "The export failed its integrity check. No output was published.")
        }
        return Int64(bytes)
    }

    static func publish(primary: URL, assets: URL?, destination: SaveDestination, cancellation: ConversionCancellation) throws {
        let manager = FileManager.default
        let assetTarget = assets.map { destination.url.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent) }
        try cancellation.publish {
            var coordinationError: NSError?, outcome: Result<Void, Error>?
            NSFileCoordinator().coordinate(writingItemAt: destination.url, options: .forReplacing, error: &coordinationError) { target in
                outcome = Result {
                    let exists = manager.fileExists(atPath: target.path)
                    if exists {
                        let flags = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard destination.overwrite, flags.isRegularFile == true, flags.isSymbolicLink != true else {
                            throw failure("DESTINATION_EXISTS", "Choose another output name or approve replacing the existing file.")
                        }
                    }
                    var movedAssets = false
                    do {
                        if let assets, let assetTarget {
                            guard !manager.fileExists(atPath: assetTarget.path) else { throw failure("DESTINATION_EXISTS", "The image folder already exists. Retry with another output name.") }
                            try manager.moveItem(at: assets, to: assetTarget); movedAssets = true
                        }
                        if exists { _ = try manager.replaceItemAt(target, withItemAt: primary) }
                        else { try manager.moveItem(at: primary, to: target) }
                    } catch {
                        if movedAssets, let assetTarget { try? manager.removeItem(at: assetTarget) }
                        throw error
                    }
                }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw failure("EXPORT_FAILED", "The export destination could not be accessed.") }
            try outcome.get()
        }
    }
    private static func failure(_ code: String, _ message: String) -> NativeSaveError { NativeSaveError(code: code, message: message) }
}
