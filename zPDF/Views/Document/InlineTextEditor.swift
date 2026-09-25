import AppKit
import PDFKit

extension NSAttributedString.Key {
    /// Engine key of the PDF font a run came from.
    static let zpdfFontKey = NSAttributedString.Key("zpdfFontKey")
    /// Name of the on-screen face chosen for that PDF font (unchanged = original).
    static let zpdfOriginalFace = NSAttributedString.Key("zpdfOriginalFace")
}

/// In-place editor for a text block (or a new text box). Works in page units:
/// the view's bounds are in PDF points and its frame is scaled to the zoom, so
/// text lays out exactly as it will on the page and zooming only rescales.
@MainActor
final class InlineTextEditor: NSTextView {
    weak var page: PDFPage?
    var block: TextBlock?
    var digest: String = ""
    /// New text: user-space top-left of the box.
    var newTextPoint: CGPoint?
    /// Width fixed by the user (drawn box or resized); otherwise grows.
    var fixedWidth: Bool
    /// Page-space translation applied by dragging the box.
    var offset: CGPoint = .zero
    /// Block-local width in points.
    var boxWidth: CGFloat
    private var initialText = ""
    private var initialSignature = ""
    private let initialWidth: CGFloat
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?
    var onSelectionFormat: ((TextFormat) -> Void)?
    var alignmentChoice: TextAlignmentChoice
    var lineSpacing: Double

    struct Result {
        var runs: [[String: Any]]
        var plainText: String
        var alignment: TextAlignmentChoice
        var lineSpacing: Double
        var width: Double?
        var offset: CGPoint
        var changedText: Bool
        var changedStyle: Bool
        var changedGeometry: Bool
    }

    init(block: TextBlock?, format: TextFormat, width: CGFloat?, fixedWidth: Bool) {
        self.block = block
        self.fixedWidth = fixedWidth
        alignmentChoice = block?.align ?? format.alignment
        lineSpacing = block?.lineSpacing ?? format.lineSpacing
        boxWidth = width ?? CGFloat(block?.width ?? 200)
        initialWidth = boxWidth
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: boxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isRichText = true
        allowsUndo = true
        usesFontPanel = true
        importsGraphics = false
        drawsBackground = true
        // PDF pages are white regardless of the app appearance.
        backgroundColor = .white
        insertionPointColor = .black
        textContainerInset = .zero
        isVerticallyResizable = true
        isHorizontallyResizable = !fixedWidth && block == nil
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false
        focusRingType = .none
        setAccessibilityLabel(block == nil ? "New text box" : "Edit text")
        setAccessibilityHelp("Type to edit. Press Escape to cancel, or click outside the box to apply.")
        let paragraph = paragraphStyle(size: block?.size ?? format.size)
        if let block {
            let text = NSMutableAttributedString()
            for run in block.runs {
                let font = run.style.font(size: CGFloat(run.size))
                text.append(NSAttributedString(string: run.text, attributes: [
                    .font: font, .foregroundColor: run.color, .paragraphStyle: paragraph,
                    .zpdfFontKey: run.fontKey, .zpdfOriginalFace: font.fontName]))
            }
            // Trailing soft space from line joins is not part of the text.
            while text.string.hasSuffix(" ") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
            storage.setAttributedString(text)
            typingAttributes = text.length > 0 ? text.attributes(at: max(0, text.length - 1), effectiveRange: nil) : [:]
        } else {
            typingAttributes = [.font: format.nsFont(), .foregroundColor: format.color, .paragraphStyle: paragraph]
        }
        initialText = string
        initialSignature = styleSignature()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func paragraphStyle(size: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignmentChoice.nsAlignment
        let height = CGFloat(lineSpacing * size)
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return style
    }

    /// Lay out in page units inside a frame scaled by `scale` (view points per page point).
    func layout(originInView topLeft: CGPoint, scale: CGFloat) {
        guard let layoutManager, let textContainer else { return }
        textContainer.size = CGSize(width: isHorizontallyResizable ? 10_000 : boxWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let firstSize = (textStorage?.length ?? 0) > 0 ? ((textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 12) : (typingFont?.pointSize ?? 12)
        let minHeight = CGFloat(lineSpacing) * firstSize
        let width = isHorizontallyResizable ? max(used.width + 4, 40) : boxWidth
        let height = max(used.height, minHeight)
        let size = CGSize(width: width, height: height)
        setFrameSize(CGSize(width: size.width * scale, height: size.height * scale))
        setFrameOrigin(CGPoint(x: topLeft.x, y: topLeft.y - size.height * scale))
        setBoundsSize(size)
        if isHorizontallyResizable { boxWidth = width }
        needsDisplay = true
    }

    var typingFont: NSFont? { typingAttributes[.font] as? NSFont }

    /// Distance from the top of the first line to its baseline, in points.
    var firstBaselineOffset: CGFloat {
        guard let layoutManager, let textContainer, (textStorage?.length ?? 0) > 0 else {
            let font = typingFont ?? NSFont.systemFont(ofSize: 12)
            return CGFloat(lineSpacing) * font.pointSize - (CGFloat(lineSpacing) * font.pointSize - font.ascender + font.descender) / 2 + 0
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: 0)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyph)
        return fragment.minY + location.y
    }

    // MARK: - Keys

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.contains(.command) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        (superview as? ContentEditOverlay)?.editorDidChange()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { onSelectionFormat?(currentFormat()) }
    }

    // MARK: - Formatting

    func currentFormat() -> TextFormat {
        var format = TextFormat()
        let range = selectedRange()
        let attributes: [NSAttributedString.Key: Any]
        if range.length > 0, let storage = textStorage, range.location < storage.length {
            attributes = storage.attributes(at: range.location, effectiveRange: nil)
        } else if range.location > 0, let storage = textStorage, range.location - 1 < storage.length {
            attributes = storage.attributes(at: range.location - 1, effectiveRange: nil)
        } else {
            attributes = typingAttributes
        }
        let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 12)
        format.family = font.familyName ?? "Helvetica"
        format.size = Double((font.pointSize * 10).rounded() / 10)
        let traits = NSFontManager.shared.traits(of: font)
        format.bold = traits.contains(.boldFontMask)
        format.italic = traits.contains(.italicFontMask)
        format.color = attributes[.foregroundColor] as? NSColor ?? .black
        format.alignment = alignmentChoice
        format.lineSpacing = lineSpacing
        return format
    }

    /// Applies panel changes to the selection (or everything when nothing is selected).
    func apply(_ next: TextFormat, previous: TextFormat) {
        guard let storage = textStorage else { return }
        var range = selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: storage.length) }
        let manager = NSFontManager.shared
        let fontChanged = next.family != previous.family || next.size != previous.size
            || next.bold != previous.bold || next.italic != previous.italic
        if next.alignment != previous.alignment || next.lineSpacing != previous.lineSpacing {
            alignmentChoice = next.alignment
            lineSpacing = next.lineSpacing
        }
        if shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            if fontChanged {
                storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                    var font = value as? NSFont ?? next.nsFont()
                    if next.family != previous.family { font = manager.convert(font, toFamily: next.family) }
                    if next.size != previous.size { font = manager.convert(font, toSize: CGFloat(next.size)) }
                    if next.bold != previous.bold {
                        font = next.bold ? manager.convert(font, toHaveTrait: .boldFontMask) : manager.convert(font, toNotHaveTrait: .boldFontMask)
                    }
                    if next.italic != previous.italic {
                        font = next.italic ? manager.convert(font, toHaveTrait: .italicFontMask) : manager.convert(font, toNotHaveTrait: .italicFontMask)
                    }
                    storage.addAttribute(.font, value: font, range: sub)
                }
            }
            if next.color != previous.color {
                storage.addAttribute(.foregroundColor, value: next.color, range: range)
            }
            let paragraphRange = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.font, in: paragraphRange) { value, sub, _ in
                let size = Double((value as? NSFont)?.pointSize ?? 12)
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(size: size), range: sub)
            }
            storage.endEditing()
            didChangeText()
        }
        var typing = typingAttributes
        if var font = typing[.font] as? NSFont {
            if next.family != previous.family { font = manager.convert(font, toFamily: next.family) }
            if next.size != previous.size { font = manager.convert(font, toSize: CGFloat(next.size)) }
            if next.bold != previous.bold {
                font = next.bold ? manager.convert(font, toHaveTrait: .boldFontMask) : manager.convert(font, toNotHaveTrait: .boldFontMask)
            }
            if next.italic != previous.italic {
                font = next.italic ? manager.convert(font, toHaveTrait: .italicFontMask) : manager.convert(font, toNotHaveTrait: .italicFontMask)
            }
            typing[.font] = font
        }
        if next.color != previous.color { typing[.foregroundColor] = next.color }
        typing[.paragraphStyle] = paragraphStyle(size: Double((typing[.font] as? NSFont)?.pointSize ?? 12))
        typingAttributes = typing
        (superview as? ContentEditOverlay)?.editorDidChange()
    }

    // MARK: - Result

    private func styleSignature() -> String {
        guard let storage = textStorage else { return "" }
        var parts: [String] = ["\(alignmentChoice.rawValue)|\(lineSpacing)"]
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            let font = attributes[.font] as? NSFont
            let color = (attributes[.foregroundColor] as? NSColor)?.engineRGB ?? []
            parts.append("\(range.length):\(font?.fontName ?? "")/\(font?.pointSize ?? 0)/\(color)")
        }
        return parts.joined(separator: ";")
    }

    func result() -> Result {
        var runs: [[String: Any]] = []
        let storage = textStorage ?? NSTextStorage()
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            let text = (storage.string as NSString).substring(with: range)
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 12)
            let color = attributes[.foregroundColor] as? NSColor ?? .black
            var spec: [String: Any] = font.engineSpec
            if let key = attributes[.zpdfFontKey] as? String, !key.isEmpty,
               attributes[.zpdfOriginalFace] as? String == font.fontName {
                spec = ["original": key, "fallback": font.engineSpec]
            }
            runs.append(["text": text, "font": spec, "size": Double(font.pointSize), "color": color.engineRGB])
        }
        let widthChanged = abs(boxWidth - initialWidth) > 0.5
        return Result(runs: runs, plainText: storage.string, alignment: alignmentChoice, lineSpacing: lineSpacing,
                      width: (widthChanged || fixedWidth) ? Double(boxWidth) : nil, offset: offset,
                      changedText: storage.string != initialText, changedStyle: styleSignature() != initialSignature,
                      changedGeometry: widthChanged || abs(offset.x) > 0.01 || abs(offset.y) > 0.01)
    }
}
