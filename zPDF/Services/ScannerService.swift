// Scanners (ImageCaptureCore) and Continuity Camera import.
//
// Scanning uses the system's Image Capture stack: local USB and network
// (Bonjour/shared) scanners, flatbed or document feeder, color mode and
// resolution. Each scanned page arrives as an image file in a private
// directory and becomes a PDF page. Continuity Camera ("Import from iPhone
// or iPad") arrives through the Services requestor protocol on a view.

import AppKit
import ImageCaptureCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ScannerService: NSObject {
    enum ColorMode: String, CaseIterable, Identifiable {
        case color, gray, blackAndWhite
        var id: String { rawValue }
        var title: String {
            switch self { case .color: "Color"; case .gray: "Grayscale"; case .blackAndWhite: "Black & White" }
        }
    }
    enum Source: String, CaseIterable, Identifiable {
        case flatbed, feeder
        var id: String { rawValue }
        var title: String { self == .flatbed ? "Flatbed" : "Document Feeder" }
    }

    struct Scanner: Identifiable {
        let id: String
        let name: String
        let device: ICScannerDevice
        var isNetwork: Bool
    }

    private(set) var scanners: [Scanner] = []
    private(set) var isBrowsing = false
    private(set) var status: String?
    private(set) var isScanning = false
    private(set) var scannedPages: [URL] = []
    private(set) var availableSources: [Source] = []
    var selectedID: String? { didSet { if oldValue != selectedID { openSelected() } } }
    var source: Source = .flatbed
    var colorMode: ColorMode = .color
    var resolution = 300
    var duplex = false
    private(set) var supportsDuplex = false

    @ObservationIgnored private var browser: ICDeviceBrowser?
    @ObservationIgnored private var openDevice: ICScannerDevice?
    @ObservationIgnored let work: NativeWorkDirectory?

    override init() {
        work = try? NativeWorkDirectory()
        super.init()
    }

    func start() {
        guard browser == nil else { return }
        let browser = ICDeviceBrowser()
        browser.delegate = self
        let mask = ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue | ICDeviceLocationTypeMask.bonjour.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .scanner
        browser.start()
        self.browser = browser
        isBrowsing = true
        status = "Looking for scanners…"
    }

    func stop() {
        browser?.stop()
        browser = nil
        isBrowsing = false
        openDevice?.requestCloseSession()
        openDevice = nil
    }

    private var selected: Scanner? { scanners.first { $0.id == selectedID } }

    private func openSelected() {
        openDevice?.requestCloseSession()
        openDevice = nil
        availableSources = []
        guard let scanner = selected else { return }
        scanner.device.delegate = self
        status = "Connecting to \(scanner.name)…"
        scanner.device.requestOpenSession()
    }

    func scan() {
        guard let device = openDevice, let work else { return }
        let wanted: ICScannerFunctionalUnitType = source == .feeder ? .documentFeeder : .flatbed
        if device.selectedFunctionalUnit.type != wanted {
            status = "Preparing \(source.title.lowercased())…"
            device.requestSelect(wanted)
            pendingScan = true
            return
        }
        configure(device)
        device.transferMode = .fileBased
        device.downloadsDirectory = work.url
        device.documentName = "Scan \(scannedPages.count + 1)"
        device.documentUTI = colorMode == .blackAndWhite ? UTType.png.identifier : UTType.jpeg.identifier
        isScanning = true
        status = "Scanning…"
        device.requestScan()
    }

    @ObservationIgnored private var pendingScan = false

    private func configure(_ device: ICScannerDevice) {
        let unit = device.selectedFunctionalUnit
        let supported = unit.supportedResolutions
        if supported.contains(resolution) { unit.resolution = resolution }
        else if let nearest = supported.min(by: { abs($0 - resolution) < abs($1 - resolution) }) { unit.resolution = nearest }
        switch colorMode {
        case .color: unit.pixelDataType = .RGB; unit.bitDepth = .depth8Bits
        case .gray: unit.pixelDataType = .gray; unit.bitDepth = .depth8Bits
        case .blackAndWhite: unit.pixelDataType = .BW; unit.bitDepth = .depth1Bit
        }
        let size = unit.physicalSize
        unit.measurementUnit = .inches
        unit.scanArea = NSRect(origin: .zero, size: size)
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder, feeder.supportsDuplexScanning {
            feeder.duplexScanningEnabled = duplex
        }
    }

    func clearPages() { scannedPages.removeAll() }

    func removePage(_ url: URL) { scannedPages.removeAll { $0 == url } }
}

extension ScannerService: @preconcurrency ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        let id = scanner.uuidString ?? scanner.name ?? UUID().uuidString
        guard !scanners.contains(where: { $0.id == id }) else { return }
        scanners.append(Scanner(id: id, name: scanner.name ?? "Scanner", device: scanner,
                                isNetwork: scanner.transportType?.localizedCaseInsensitiveContains("usb") != true))
        if !moreComing { status = nil }
        if selectedID == nil { selectedID = id }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        scanners.removeAll { $0.device === device }
        if selected == nil { selectedID = scanners.first?.id }
    }

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        if scanners.isEmpty { status = "No scanners found. Connect a scanner or turn it on." }
    }
}

extension ScannerService: @preconcurrency ICScannerDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error {
            status = "Couldn't connect: \(error.localizedDescription)"
            return
        }
        openDevice = device as? ICScannerDevice
        let types = (device as? ICScannerDevice)?.availableFunctionalUnitTypes.compactMap { ICScannerFunctionalUnitType(rawValue: $0.uintValue) } ?? []
        availableSources = [types.contains(.flatbed) ? Source.flatbed : nil,
                            types.contains(.documentFeeder) ? Source.feeder : nil].compactMap { $0 }
        if !availableSources.contains(source), let first = availableSources.first { source = first }
        status = "Ready"
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    func didRemove(_ device: ICDevice) {}

    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: (any Error)?) {
        supportsDuplex = (functionalUnit as? ICScannerFunctionalUnitDocumentFeeder)?.supportsDuplexScanning == true
        if let error { status = "Couldn't select the source: \(error.localizedDescription)"; pendingScan = false; return }
        if pendingScan { pendingScan = false; scan() }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        scannedPages.append(url)
        status = "Scanned \(scannedPages.count) page\(scannedPages.count == 1 ? "" : "s")"
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: (any Error)?) {
        isScanning = false
        if let error { status = "Scan failed: \(error.localizedDescription)" }
    }
}

// MARK: - Continuity Camera

/// A button whose menu offers the system's Continuity Camera items
/// ("Take Photo", "Scan Documents" from a nearby iPhone or iPad). The
/// imported image or PDF is handed to `onImport` as a pasteboard.
struct ContinuityCameraButton: NSViewRepresentable {
    var title = "Import from iPhone or iPad"
    let onImport: @MainActor (NSPasteboard) -> Void

    func makeNSView(context: Context) -> ContinuityCameraHostView {
        let view = ContinuityCameraHostView()
        view.onImport = onImport
        view.button.title = title
        return view
    }

    func updateNSView(_ view: ContinuityCameraHostView, context: Context) {
        view.onImport = onImport
        view.button.title = title
    }
}

final class ContinuityCameraHostView: NSView, @preconcurrency NSServicesMenuRequestor {
    let button = NSButton(title: "", target: nil, action: nil)
    var onImport: (@MainActor (NSPasteboard) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(showMenu(_:))
        button.toolTip = "Take a photo or scan a document with a nearby iPhone or iPad"
        button.setAccessibilityLabel("Import from iPhone or iPad")
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                                     button.topAnchor.constraint(equalTo: topAnchor),
                                     button.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { button.intrinsicContentSize }

    @objc private func showMenu(_ sender: NSButton) {
        window?.makeFirstResponder(self)
        let menu = NSMenu(title: "Continuity Camera")
        let header = NSMenuItem(title: "Choose Take Photo or Scan Documents below. Your device must be nearby and signed in to the same Apple Account.", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        // AppKit inserts the Continuity Camera items for a valid image requestor.
        let event = NSApp.currentEvent ?? NSEvent()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, Self.acceptedTypes.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    static let acceptedTypes: [NSPasteboard.PasteboardType] = [.pdf, .tiff, .png, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                                                              NSPasteboard.PasteboardType(UTType.heic.identifier)]

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let onImport else { return false }
        MainActor.assumeIsolated { onImport(pasteboard) }
        return true
    }

    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
}
