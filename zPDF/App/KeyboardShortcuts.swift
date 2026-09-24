import AppKit
import SwiftUI

/// Every menu command whose shortcut can be customized in Settings ▸
/// Keyboard Shortcuts. Defaults follow Acrobat for macOS where the key is free.
enum AppCommandID: String, CaseIterable, Identifiable, Codable {
    // File
    case open, closeTab, save, saveAs, print, documentProperties, share, newWindow
    // Edit / find
    case find, findNext, findPrevious, advancedSearch
    // View
    case allTools, zoomIn, zoomOut, actualSize, fitPage, fitWidth
    case singlePage, continuous, twoPage, coverPage
    case fullScreenMode, reflow, rulers, grid, snapToGrid, guides, loupe, panAndZoom, autoScroll
    case splitView, readingOrder
    // Read Out Loud
    case readAloudPage, readAloudToEnd, readAloudPause, readAloudStop
    // Navigate
    case previousView, nextView, previousPage, nextPage, firstPage, lastPage, goToPage, previousDocument, nextDocument
    // Document
    case addBookmark, accessibilityCheck, actionWizard, measure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Open…"
        case .closeTab: "Close Tab"
        case .save: "Save"
        case .saveAs: "Save As…"
        case .print: "Print…"
        case .documentProperties: "Document Properties…"
        case .share: "Share…"
        case .newWindow: "New Window"
        case .find: "Find in PDF…"
        case .findNext: "Next Match"
        case .findPrevious: "Previous Match"
        case .advancedSearch: "Advanced Search…"
        case .allTools: "All Tools"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .fitPage: "Fit Page"
        case .fitWidth: "Fit Width"
        case .singlePage: "Single Page View"
        case .continuous: "Enable Scrolling"
        case .twoPage: "Two Page View"
        case .coverPage: "Show Cover Page in Two Page View"
        case .fullScreenMode: "Full Screen Mode"
        case .reflow: "Reflow"
        case .rulers: "Rulers"
        case .grid: "Grid"
        case .snapToGrid: "Snap to Grid"
        case .guides: "Guides"
        case .loupe: "Loupe Tool"
        case .panAndZoom: "Pan & Zoom Window"
        case .autoScroll: "Automatically Scroll"
        case .splitView: "Split View"
        case .readingOrder: "Show Reading Order"
        case .readAloudPage: "Read This Page Only"
        case .readAloudToEnd: "Read to End of Document"
        case .readAloudPause: "Pause / Resume Reading"
        case .readAloudStop: "Stop Reading"
        case .previousView: "Previous View"
        case .nextView: "Next View"
        case .previousPage: "Previous Page"
        case .nextPage: "Next Page"
        case .firstPage: "First Page"
        case .lastPage: "Last Page"
        case .goToPage: "Go to Page…"
        case .previousDocument: "Previous Document"
        case .nextDocument: "Next Document"
        case .addBookmark: "Add Bookmark"
        case .accessibilityCheck: "Accessibility Check"
        case .actionWizard: "Action Wizard"
        case .measure: "Measure"
        }
    }

    var category: String {
        switch self {
        case .open, .closeTab, .save, .saveAs, .print, .documentProperties, .share, .newWindow: "File"
        case .find, .findNext, .findPrevious, .advancedSearch: "Find"
        case .readAloudPage, .readAloudToEnd, .readAloudPause, .readAloudStop: "Read Out Loud"
        case .previousView, .nextView, .previousPage, .nextPage, .firstPage, .lastPage, .goToPage,
             .previousDocument, .nextDocument: "Navigate"
        case .addBookmark, .accessibilityCheck, .actionWizard, .measure: "Tools"
        default: "View"
        }
    }

    var defaultBinding: ShortcutBinding? {
        switch self {
        case .open: .init("o")
        case .closeTab: .init("w")
        case .save: .init("s")
        case .saveAs: .init("s", [.command, .shift])
        case .print: .init("p")
        case .documentProperties: .init("d")
        case .find: .init("f")
        case .findNext: .init("g")
        case .findPrevious: .init("g", [.command, .shift])
        case .advancedSearch: .init("f", [.command, .shift])
        case .allTools: .init("s", [.command, .control])
        case .zoomIn: .init("=")
        case .zoomOut: .init("-")
        case .actualSize: .init("0")
        case .fitPage: .init("0", [.command, .option])
        case .fitWidth: .init("2")
        case .fullScreenMode: .init("l")
        case .reflow: .init("4")
        case .rulers: .init("r")
        case .grid: .init("u")
        case .snapToGrid: .init("u", [.command, .shift])
        case .guides: .init(";")
        case .autoScroll: .init("h", [.command, .shift])
        case .readAloudPage: .init("v", [.command, .shift])
        case .readAloudToEnd: .init("b", [.command, .shift])
        case .readAloudPause: .init("c", [.command, .shift])
        case .readAloudStop: .init("e", [.command, .shift])
        case .previousView: .init("[")
        case .nextView: .init("]")
        case .previousPage: .init(special: "pageUp")
        case .nextPage: .init(special: "pageDown")
        case .goToPage: .init("n", [.command, .shift])
        case .previousDocument: .init(special: "tab", [.control, .shift])
        case .nextDocument: .init(special: "tab", [.control])
        case .addBookmark: .init("b")
        default: nil
        }
    }
}

/// A persisted key + modifiers pair.
struct ShortcutBinding: Codable, Hashable {
    var key: String
    var special: String?
    var modifiers: [String]

    init(_ key: String, _ modifiers: EventModifiers = .command) {
        self.key = key
        self.special = nil
        self.modifiers = Self.names(modifiers)
    }

    init(special: String, _ modifiers: EventModifiers = .command) {
        self.key = ""
        self.special = special
        self.modifiers = Self.names(modifiers)
    }

    private static func names(_ modifiers: EventModifiers) -> [String] {
        var names: [String] = []
        if modifiers.contains(.control) { names.append("control") }
        if modifiers.contains(.option) { names.append("option") }
        if modifiers.contains(.shift) { names.append("shift") }
        if modifiers.contains(.command) { names.append("command") }
        return names
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains("control") { result.insert(.control) }
        if modifiers.contains("option") { result.insert(.option) }
        if modifiers.contains("shift") { result.insert(.shift) }
        if modifiers.contains("command") { result.insert(.command) }
        return result
    }

    var keyEquivalent: KeyEquivalent? {
        switch special {
        case "pageUp": return .pageUp
        case "pageDown": return .pageDown
        case "tab": return .tab
        case "home": return .home
        case "end": return .end
        case "upArrow": return .upArrow
        case "downArrow": return .downArrow
        case "leftArrow": return .leftArrow
        case "rightArrow": return .rightArrow
        case "delete": return .delete
        case "return": return .return
        case .some: return nil
        case nil: return key.first.map { KeyEquivalent($0) }
        }
    }

    var keyboardShortcut: KeyboardShortcut? {
        keyEquivalent.map { KeyboardShortcut($0, modifiers: eventModifiers) }
    }

    /// "⇧⌘F"-style label.
    var displayText: String {
        var text = ""
        if modifiers.contains("control") { text += "⌃" }
        if modifiers.contains("option") { text += "⌥" }
        if modifiers.contains("shift") { text += "⇧" }
        if modifiers.contains("command") { text += "⌘" }
        switch special {
        case "pageUp": text += "Page Up"
        case "pageDown": text += "Page Down"
        case "tab": text += "⇥"
        case "home": text += "↖"
        case "end": text += "↘"
        case "upArrow": text += "↑"
        case "downArrow": text += "↓"
        case "leftArrow": text += "←"
        case "rightArrow": text += "→"
        case "delete": text += "⌫"
        case "return": text += "↩"
        default: text += key == " " ? "Space" : key.uppercased()
        }
        return text
    }

    /// Creates a binding from a key-down event (nil for bare keys or Escape).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.contains(.command) || flags.contains(.control), event.keyCode != 53 else { return nil }
        var mods: EventModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        let specials: [UInt16: String] = [116: "pageUp", 121: "pageDown", 48: "tab", 115: "home", 119: "end",
                                         126: "upArrow", 125: "downArrow", 123: "leftArrow", 124: "rightArrow",
                                         51: "delete", 36: "return"]
        if let special = specials[event.keyCode] {
            self.init(special: special, mods)
        } else {
            guard let character = event.charactersIgnoringModifiers?.lowercased().first,
                  !character.isWhitespace || character == " " else { return nil }
            self.init(String(character), mods)
        }
    }
}

/// User overrides of command shortcuts, persisted in UserDefaults.
@MainActor @Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    static let defaultsKey = "zpdf.shortcuts.v1"
    /// System-owned shortcuts that commands must not take.
    static let reserved: Set<ShortcutBinding> = [
        .init("q"), .init("h"), .init("m"), .init(","), .init("h", [.command, .option]), .init("z"),
        .init("z", [.command, .shift]), .init("x"), .init("c"), .init("v"), .init("a"), .init("`")
    ]

    @ObservationIgnored private let defaults: UserDefaults
    /// nil value = explicitly no shortcut.
    private(set) var overrides: [AppCommandID: ShortcutBinding?] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: ShortcutBinding?].self, from: data) {
            for (key, value) in stored { if let id = AppCommandID(rawValue: key) { overrides[id] = value } }
        }
    }

    func binding(for id: AppCommandID) -> ShortcutBinding? {
        if let override = overrides[id] { return override }
        return id.defaultBinding
    }

    func shortcut(for id: AppCommandID) -> KeyboardShortcut? { binding(for: id)?.keyboardShortcut }

    /// Commands (other than `id`) already using `binding`.
    func conflicts(for binding: ShortcutBinding, excluding id: AppCommandID? = nil) -> [AppCommandID] {
        AppCommandID.allCases.filter { $0 != id && self.binding(for: $0) == binding }
    }

    func isReserved(_ binding: ShortcutBinding) -> Bool { Self.reserved.contains(binding) }

    /// Assigns `binding`, removing it from any command that had it.
    func set(_ binding: ShortcutBinding?, for id: AppCommandID) {
        if let binding {
            for other in conflicts(for: binding, excluding: id) { overrides[other] = .some(nil) }
        }
        overrides[id] = binding == id.defaultBinding ? nil : .some(binding)
        if binding == id.defaultBinding { overrides.removeValue(forKey: id) }
        persist()
    }

    func reset(_ id: AppCommandID) {
        overrides.removeValue(forKey: id)
        persist()
    }

    func resetAll() {
        overrides.removeAll()
        persist()
    }

    var isCustomized: Bool { !overrides.isEmpty }

    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

extension View {
    /// Applies the user's shortcut for a menu command.
    func zShortcut(_ id: AppCommandID) -> some View {
        keyboardShortcut(ShortcutStore.shared.shortcut(for: id))
    }
}
