//
//  CommentSummary.swift
//  zPDF
//
//  Purpose: "Summarize Comments" — an Acrobat-style review report as a new
//  PDF: per document page, a thumbnail beside numbered comments with type,
//  author, date, status, quoted text and indented replies. Written only to
//  a destination the user chooses (or straight to the print system).
//

import AppKit
import PDFKit

enum CommentSummary {
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 48
    private static let thumbWidth: CGFloat = 150

    static func render(title: String, document: PDFDocument, comments: [Comment], date: Date = Date()) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box,
                                      [kCGPDFContextTitle: "Comments on \(title)", kCGPDFContextCreator: "zPDF"] as CFDictionary) else {
            return Data()
        }
        var writer = Writer(context: context)
        writer.beginPage()
        writer.text("Summary of Comments", font: .systemFont(ofSize: 20, weight: .bold), color: .black)
        writer.text(title, font: .systemFont(ofSize: 12, weight: .medium), color: .darkGray)
        let total = comments.reduce(0) { $0 + 1 + $1.totalReplyCount }
        writer.text("\(comments.count) comment\(comments.count == 1 ? "" : "s"), \(total - comments.count) repl\(total - comments.count == 1 ? "y" : "ies") · \(date.formatted(date: .long, time: .shortened))",
                    font: .systemFont(ofSize: 10), color: .gray)
        writer.gap(14)
        let grouped = Dictionary(grouping: comments, by: \.pageIndex)
        var number = 0
        for pageIndex in grouped.keys.sorted() {
            guard let items = grouped[pageIndex] else { continue }
            writer.ensure(80)
            writer.rule()
            writer.text("Page \(pageIndex + 1)", font: .systemFont(ofSize: 13, weight: .semibold), color: .black)
            writer.gap(4)
            let top = writer.y
            if let page = document.page(at: pageIndex) {
                let bounds = page.bounds(for: .cropBox)
                let height = thumbWidth * bounds.height / max(1, bounds.width)
                let fitted = min(height, top - margin)
                let image = page.thumbnail(of: CGSize(width: thumbWidth * 2, height: fitted * 2), for: .cropBox)
                if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let rect = CGRect(x: margin, y: top - fitted, width: thumbWidth, height: fitted)
                    context.draw(cg, in: rect)
                    context.setStrokeColor(NSColor(white: 0.8, alpha: 1).cgColor)
                    context.setLineWidth(0.5)
                    context.stroke(rect)
                }
                writer.floatBottom = top - fitted
            }
            writer.indent = thumbWidth + 16
            for comment in items {
                number += 1
                writer.comment(comment, number: number, depth: 0)
            }
            writer.indent = 0
            writer.clearFloat()
            writer.gap(10)
        }
        writer.endPage()
        context.closePDF()
        return data as Data
    }

    private struct Writer {
        let context: CGContext
        var y: CGFloat = 0
        var indent: CGFloat = 0
        var floatBottom: CGFloat?
        var pageOpen = false
        var pageNumber = 0

        init(context: CGContext) { self.context = context }

        mutating func beginPage() {
            context.beginPDFPage(nil)
            pageOpen = true
            pageNumber += 1
            y = pageSize.height - margin
            floatBottom = nil
            footer()
        }

        mutating func endPage() {
            guard pageOpen else { return }
            context.endPDFPage()
            pageOpen = false
        }

        mutating func ensure(_ height: CGFloat) {
            if y - height < margin {
                endPage()
                beginPage()
            }
        }

        mutating func gap(_ value: CGFloat) { y -= value }

        mutating func clearFloat() {
            if let bottom = floatBottom, bottom < y { y = bottom }
            floatBottom = nil
        }

        mutating func rule() {
            context.setStrokeColor(NSColor(white: 0.85, alpha: 1).cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: margin, y: y))
            context.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
            context.strokePath()
            y -= 8
        }

        func footer() {
            draw(NSAttributedString(string: "Page \(pageNumber)", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.gray]),
                 in: CGRect(x: margin, y: margin - 26, width: pageSize.width - 2 * margin, height: 12))
        }

        func draw(_ string: NSAttributedString, in rect: CGRect) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            string.draw(with: rect, options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        }

        mutating func text(_ string: String, font: NSFont, color: NSColor, extraIndent: CGFloat = 0) {
            guard !string.isEmpty else { return }
            let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            layout(attributed, extraIndent: extraIndent)
        }

        mutating func layout(_ attributed: NSAttributedString, extraIndent: CGFloat = 0) {
            var left = margin + indent + extraIndent
            var width = pageSize.width - margin - left
            var size = attributed.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).size
            if y - size.height < margin {
                endPage(); beginPage()
                // The thumbnail stays with its page; later lines use full width.
                left = margin + extraIndent
                width = pageSize.width - margin - left
                indent = 0
                size = attributed.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).size
            }
            draw(attributed, in: CGRect(x: left, y: y - ceil(size.height), width: width, height: ceil(size.height)))
            y -= ceil(size.height) + 2
        }

        mutating func comment(_ comment: Comment, number: Int, depth: Int) {
            let extra = CGFloat(depth) * 16
            let header = NSMutableAttributedString()
            let bold = NSFont.systemFont(ofSize: 10, weight: .semibold), regular = NSFont.systemFont(ofSize: 10)
            if depth == 0 {
                header.append(NSAttributedString(string: "\(number). \(comment.kind.singular)  ", attributes: [.font: bold, .foregroundColor: NSColor.black]))
            } else {
                header.append(NSAttributedString(string: "↳ Reply  ", attributes: [.font: bold, .foregroundColor: NSColor.darkGray]))
            }
            let when = comment.date == .distantPast ? "" : comment.date.formatted(date: .abbreviated, time: .shortened)
            header.append(NSAttributedString(string: [comment.author, when].filter { !$0.isEmpty }.joined(separator: " · "),
                                             attributes: [.font: regular, .foregroundColor: NSColor.darkGray]))
            if comment.status != .none {
                header.append(NSAttributedString(string: "  [\(comment.status.title)]", attributes: [.font: bold, .foregroundColor: NSColor.systemBlue]))
            }
            if comment.isMarked {
                header.append(NSAttributedString(string: "  ✓", attributes: [.font: bold, .foregroundColor: NSColor.systemGreen]))
            }
            ensure(28)
            layout(header, extraIndent: extra)
            if let quoted = comment.quotedText, !quoted.isEmpty {
                text("“\(quoted)”", font: .systemFont(ofSize: 9.5).withTraits(.italic), color: .darkGray, extraIndent: extra + 10)
            }
            if !comment.text.isEmpty {
                text(comment.text, font: .systemFont(ofSize: 10.5), color: .black, extraIndent: extra + 10)
            }
            if let name = comment.attachmentName {
                text("Attachment: \(name)", font: .systemFont(ofSize: 9.5), color: .darkGray, extraIndent: extra + 10)
            }
            gap(4)
            for reply in comment.replies { self.comment(reply, number: number, depth: depth + 1) }
        }
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
    }
}
