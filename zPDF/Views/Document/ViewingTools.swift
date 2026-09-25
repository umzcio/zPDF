import PDFKit
import SwiftUI

// MARK: - Loupe

/// Cursor-following magnifier over the canvas. It never intercepts clicks;
/// the magnification is chosen in its banner (Esc or Done closes it).
struct LoupeOverlay: View {
    let viewStore: PDFViewStore
    let close: () -> Void
    @State private var magnification: Double = 3

    var body: some View {
        ZStack(alignment: .top) {
            LoupeRepresentable(viewStore: viewStore, magnification: magnification)
            HStack(spacing: 8) {
                Image(systemName: "plus.magnifyingglass").foregroundStyle(DesignTokens.Colors.accent)
                Text("Loupe").font(.system(size: 11, weight: .medium))
                Picker("Magnification", selection: $magnification) {
                    ForEach([2.0, 3.0, 4.0, 6.0], id: \.self) { Text("\(Int($0))×").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .controlSize(.small)
                .help("Loupe magnification")
                Button("Done", action: close)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.accent)
                    .keyboardShortcut(.cancelAction)
                    .help("Close the loupe (Esc)")
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(DesignTokens.Colors.hairline, lineWidth: 1))
            .padding(.top, 8)
        }
    }
}

private struct LoupeRepresentable: NSViewRepresentable {
    let viewStore: PDFViewStore
    let magnification: Double

    func makeNSView(context: Context) -> LoupeHostView {
        let view = LoupeHostView()
        view.viewStore = viewStore
        return view
    }

    func updateNSView(_ view: LoupeHostView, context: Context) {
        view.magnification = magnification
        view.refresh()
    }
}

@MainActor
final class LoupeHostView: NSView {
    weak var viewStore: PDFViewStore?
    var magnification: Double = 3
    private let lens = PDFView()
    private var tracking: NSTrackingArea?
    private let size: CGFloat = 220
    private var lastPoint: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        lens.autoScales = false
        lens.displayMode = .singlePageContinuous
        lens.displaysPageBreaks = false
        lens.wantsLayer = true
        lens.layer?.cornerRadius = size / 2
        lens.layer?.borderWidth = 2
        lens.layer?.borderColor = NSColor.controlAccentColor.cgColor
        lens.layer?.masksToBounds = true
        lens.isHidden = true
        lens.setAccessibilityElement(false)
        addSubview(lens)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        lastPoint = event.locationInWindow
        refresh()
    }

    override func mouseExited(with event: NSEvent) { lens.isHidden = true }

    func refresh() {
        guard let pdfView = viewStore?.pdfView, let window = pdfView.window, let location = lastPoint,
              window === self.window else { lens.isHidden = true; return }
        let inPDF = pdfView.convert(location, from: nil)
        guard pdfView.bounds.contains(inPDF), let page = pdfView.page(for: inPDF, nearest: false) else {
            lens.isHidden = true
            return
        }
        if lens.document !== pdfView.document { lens.document = pdfView.document }
        lens.backgroundColor = pdfView.backgroundColor
        lens.contentFilters = pdfView.contentFilters
        lens.scaleFactor = pdfView.scaleFactor * CGFloat(magnification)
        let local = convert(location, from: nil)
        lens.frame = NSRect(x: local.x - size / 2, y: local.y - size / 2, width: size, height: size)
        lens.isHidden = false
        let pagePoint = pdfView.convert(inPDF, to: page)
        lens.layoutDocumentView()
        guard let documentView = lens.documentView, let clip = documentView.enclosingScrollView?.contentView else { return }
        let inLens = lens.convert(pagePoint, from: page)
        let inDocument = documentView.convert(inLens, from: lens)
        let origin = NSPoint(x: inDocument.x - clip.bounds.width / 2, y: inDocument.y - clip.bounds.height / 2)
        clip.scroll(to: origin)
        documentView.enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

// MARK: - Pan & Zoom

/// Mini map of the current page with the visible region; drag to pan,
/// use the slider to zoom.
struct PanZoomPanel: View {
    let tab: DocumentTab
    let viewStore: PDFViewStore
    let close: () -> Void
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pan & Zoom").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .help("Close Pan & Zoom")
                    .accessibilityLabel("Close Pan & Zoom")
            }
            PanZoomMap(tab: tab, viewStore: viewStore, tick: tick)
                .frame(width: 180, height: 200)
            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 10))
                Slider(value: Binding(get: { tab.zoomFactor }, set: { tab.setZoom($0) }),
                       in: ZoomController.minimumZoom...ZoomController.maximumZoom)
                    .controlSize(.mini)
                    .accessibilityLabel("Zoom")
                    .accessibilityValue(ZoomController.percentString(tab.zoomFactor))
                Image(systemName: "plus.magnifyingglass").font(.system(size: 10))
            }
            Text(ZoomController.percentString(tab.zoomFactor)).font(.system(size: 10)).foregroundStyle(DesignTokens.Colors.mutedText)
        }
        .padding(10)
        .frame(width: 200)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.large).stroke(DesignTokens.Colors.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in tick &+= 1 }
    }
}

private struct PanZoomMap: View {
    let tab: DocumentTab
    let viewStore: PDFViewStore
    let tick: Int

    var body: some View {
        GeometryReader { proxy in
            let _ = tick
            if let view = viewStore.pdfView, let page = view.currentPage {
                let box = page.bounds(for: .cropBox)
                let scale = min(proxy.size.width / box.width, proxy.size.height / box.height)
                let size = CGSize(width: box.width * scale, height: box.height * scale)
                let origin = CGPoint(x: (proxy.size.width - size.width) / 2, y: (proxy.size.height - size.height) / 2)
                let visible = view.convert(view.bounds, to: page).intersection(box)
                let frame = CGRect(x: origin.x + (visible.minX - box.minX) * scale,
                                   y: origin.y + (box.maxY - visible.maxY) * scale,
                                   width: visible.width * scale, height: visible.height * scale)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: page.thumbnail(of: size, for: .cropBox))
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .offset(x: origin.x, y: origin.y)
                        .accessibilityHidden(true)
                    Rectangle()
                        .stroke(DesignTokens.Colors.accent, lineWidth: 2)
                        .background(DesignTokens.Colors.accent.opacity(0.12))
                        .frame(width: max(8, frame.width), height: max(8, frame.height))
                        .offset(x: frame.minX, y: frame.minY)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let x = box.minX + (value.location.x - origin.x) / scale
                    let y = box.maxY - (value.location.y - origin.y) / scale
                    let target = CGRect(x: x - visible.width / 2, y: y - visible.height / 2, width: visible.width, height: visible.height)
                    view.go(to: target, on: page)
                })
                .accessibilityElement()
                .accessibilityLabel("Page overview. Drag to move the visible area.")
            }
        }
    }
}

// MARK: - Auto scroll

/// Continuous scrolling at a user-set speed (⇧⌘H). While active, 1–9 set the
/// speed, − reverses direction and Esc stops.
@MainActor @Observable
final class AutoScrollController {
    private(set) var isActive = false
    var speed: Double = 40
    var reversed = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var viewStore: PDFViewStore?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var remainder: CGFloat = 0

    func toggle(appState: AppState) {
        isActive ? stop() : start(appState: appState)
    }

    func start(appState: AppState) {
        guard appState.activeTab != nil else { return }
        stop()
        viewStore = appState.pdfViewStore
        speed = appState.preferences.autoScrollSpeed
        isActive = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak appState] event in
            nonisolated(unsafe) let local = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let appState else { return false }
                return self.handle(local, appState: appState)
            }
            return handled ? nil : event
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        isActive = false
        reversed = false
    }

    private func handle(_ event: NSEvent, appState: AppState) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(event.window?.firstResponder is NSText) else { return false }
        if event.keyCode == 53 { stop(); return true }
        guard let characters = event.charactersIgnoringModifiers else { return false }
        if characters == "-" { reversed.toggle(); return true }
        if let digit = Int(characters), (1...9).contains(digit) {
            speed = Double(digit) * 15
            appState.preferences.autoScrollSpeed = speed
            return true
        }
        return false
    }

    private func step() {
        guard let view = viewStore?.pdfView, let documentView = view.documentView,
              let scroll = documentView.enclosingScrollView else { stop(); return }
        let clip = scroll.contentView
        remainder += CGFloat(speed / 60)
        let delta = floor(remainder)
        guard delta >= 1 else { return }
        remainder -= delta
        let forward = !reversed
        let direction: CGFloat = (forward == documentView.isFlipped) ? 1 : -1
        let original = clip.bounds.origin
        let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: original.x, y: original.y + direction * delta),
                                                     size: clip.bounds.size)).origin
        if abs(target.y - original.y) < 0.5 {
            // End of a single page view: advance, or stop at the document end.
            if view.canGoToNextPage && forward { view.goToNextPage(nil) }
            else if view.canGoToPreviousPage && !forward { view.goToPreviousPage(nil) }
            else { stop() }
            return
        }
        clip.scroll(to: target)
        scroll.reflectScrolledClipView(clip)
    }
}

// MARK: - Reflow

/// Reflowed, resizable text of the current page (⌘4). Lines are joined into
/// paragraphs; headings keep their relative size. Use the toolbar zoom or
/// ⌘+/⌘− to change the text size.
struct ReflowView: View {
    let tab: DocumentTab
    let close: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft").foregroundStyle(DesignTokens.Colors.accent)
                Text("Reflow — Page \(tab.currentPage) of \(tab.pageCount)").font(.system(size: 12, weight: .medium))
                Spacer()
                Button { tab.goToPreviousPage() } label: { Image(systemName: "chevron.left") }
                    .disabled(tab.currentPage <= 1).help("Previous page").accessibilityLabel("Previous page")
                Button { tab.goToNextPage() } label: { Image(systemName: "chevron.right") }
                    .disabled(tab.currentPage >= tab.pageCount).help("Next page").accessibilityLabel("Next page")
                Button("Done", action: close).keyboardShortcut(.cancelAction).help("Return to the page view (Esc or ⌘4)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(.bar)
            Divider()
            ScrollView {
                Text(ReflowText.make(page: tab.pdfDocument?.page(at: tab.currentPage - 1), scale: tab.zoomFactor))
                    .textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reflowed page text")
    }
}

enum ReflowText {
    /// Joins wrapped lines into paragraphs and scales fonts relative to body text.
    static func make(page: PDFPage?, scale: Double) -> AttributedString {
        guard let page, let source = page.attributedString, source.length > 0 else {
            return AttributedString("This page has no text to reflow. Scanned pages need text recognition first.")
        }
        let base = 15 * scale
        let text = source.string as NSString
        var lines: [(String, CGFloat)] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, range, _, _ in
            guard let line else { return }
            var size: CGFloat = 0
            if range.length > 0, let font = source.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                size = font.pointSize
            }
            lines.append((line.trimmingCharacters(in: .whitespaces), size))
        }
        let sizes = lines.filter { !$0.0.isEmpty && $0.1 > 0 }.map(\.1).sorted()
        let body = sizes.isEmpty ? 11 : sizes[sizes.count / 2]
        var output = AttributedString()
        var paragraph = ""
        var paragraphSize: CGFloat = body
        func flush() {
            guard !paragraph.isEmpty else { return }
            var run = AttributedString(paragraph + "\n\n")
            let ratio = paragraphSize / max(1, body)
            run.font = .system(size: base * min(2.2, max(1, ratio)), weight: ratio >= 1.2 ? .semibold : .regular)
            output += run
            paragraph = ""
        }
        for (index, (line, size)) in lines.enumerated() {
            if line.isEmpty { flush(); continue }
            let sizeChanged = abs(size - paragraphSize) > 1.5 && !paragraph.isEmpty
            let previous = index > 0 ? lines[index - 1].0 : ""
            let endsSentence = previous.hasSuffix(".") || previous.hasSuffix(":") || previous.hasSuffix("?") || previous.hasSuffix("!")
            let bullet = line.first.map { "•-–*".contains($0) } ?? false
            if sizeChanged || bullet || (endsSentence && line.first?.isUppercase == true && previous.count < 60) { flush() }
            if paragraph.isEmpty { paragraphSize = size > 0 ? size : body }
            if paragraph.hasSuffix("-") { paragraph.removeLast(); paragraph += line }
            else { paragraph += paragraph.isEmpty ? line : " " + line }
        }
        flush()
        return output
    }
}
