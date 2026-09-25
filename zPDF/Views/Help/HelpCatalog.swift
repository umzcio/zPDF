import Foundation

/// In-app help pages. Each page describes a shipped workflow; pages for tools
/// that are not available in this build are hidden automatically.
struct HelpTopic: Identifiable, Hashable {
    let id: HelpTopicID
    let title: String
    let symbol: String
    let category: String
    let summary: String
    let body: [String]
    let shortcuts: [(String, String)]
    let keywords: String
    /// Tool whose availability gates this page (nil = always shown).
    let tool: ToolID?

    static func == (lhs: HelpTopic, rhs: HelpTopic) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func matches(_ query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        let haystack = ([title, summary, keywords, category] + body).joined(separator: " ").lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
}

enum HelpCatalog {
    static var topics: [HelpTopic] {
        all.filter { $0.tool?.isImplemented ?? true }
    }

    static func topic(_ id: HelpTopicID) -> HelpTopic? { all.first { $0.id == id } }

    static let gettingStarted = HelpTopicID("getting-started")

    static let all: [HelpTopic] = [
        HelpTopic(id: gettingStarted, title: "Getting Started", symbol: "sparkles", category: "Basics",
                  summary: "Open PDFs, find tools and save your work.",
                  body: [
                    "Open a PDF with File ▸ Open (⌘O), by dragging it onto the zPDF icon, or from the Home screen. Each document opens in its own tab.",
                    "All tools (⌃⌘S) opens the tools drawer on the left. Pick a tool to show its controls; the star next to a tool pins it to the quick tools beside the page.",
                    "Panels such as Pages, Bookmarks, Attachments and Layers open from the rail on the right edge of the window.",
                    "Edits apply to a private working copy. Nothing changes on disk until you choose File ▸ Save (⌘S) or Save As (⇧⌘S). Every change can be undone with ⌘Z."
                  ],
                  shortcuts: [("Open", "⌘O"), ("Save", "⌘S"), ("All tools", "⌃⌘S"), ("Find", "⌘F"), ("Document Properties", "⌘D")],
                  keywords: "open save tabs home undo start", tool: nil),
        HelpTopic(id: HelpTopicID("navigation"), title: "Navigating Documents", symbol: "arrow.left.arrow.right", category: "Basics",
                  summary: "Move between pages, views and documents.",
                  body: [
                    "Use the page field in the toolbar or Go to Page (⇧⌘N). The arrow keys, Page Up/Down, Home and End move through pages when the page has focus.",
                    "Previous View (⌘[) and Next View (⌘]) retrace where you have been, including zoom changes.",
                    "When a document defines page labels (for example i, ii, iii), the status bar shows the label alongside the page number."
                  ],
                  shortcuts: [("Previous page", "⌘Page Up"), ("Next page", "⌘Page Down"), ("Previous view", "⌘["), ("Next view", "⌘]")],
                  keywords: "page go to label next previous", tool: nil),
        HelpTopic(id: HelpTopicID("bookmarks"), title: "Bookmarks", symbol: "bookmark", category: "Navigation Panels",
                  summary: "Create, rename, nest and reorder bookmarks.",
                  body: [
                    "Open the Bookmarks panel from the right-hand rail. Click a bookmark to jump to it.",
                    "New Bookmark (⌘B) adds a bookmark for the current view, using selected text as its title when there is a selection. Type a name and press Return.",
                    "Double-click a bookmark to rename it. Drag bookmarks to reorder them, or drop one onto another to nest it. Delete removes the selected bookmarks.",
                    "Right-click for more: set the destination to the current view, bold or italic text, and color.",
                    "New Bookmarks from Headings builds a nested outline from text that is larger than the body text.",
                    "Each change is one Undo step and is written into the PDF when you save."
                  ],
                  shortcuts: [("New bookmark", "⌘B"), ("Delete", "⌫"), ("Go to bookmark", "Return")],
                  keywords: "outline toc table of contents nest drag headings", tool: nil),
        HelpTopic(id: HelpTopicID("attachments"), title: "Attachments", symbol: "paperclip", category: "Navigation Panels",
                  summary: "Embed files in a PDF and extract them.",
                  body: [
                    "The Attachments panel lists files embedded in the PDF, including files attached as comments.",
                    "Add File or drag files onto the list to embed them. Open shows an attachment; Save As writes a copy anywhere you choose.",
                    "Edit Description changes the text other viewers show with the file. Delete removes the attachment; Save keeps the change.",
                    "Advanced Search can include the text of attached PDFs."
                  ],
                  shortcuts: [], keywords: "embedded files attach extract", tool: nil),
        HelpTopic(id: HelpTopicID("layers"), title: "Layers", symbol: "square.3.layers.3d", category: "Navigation Panels",
                  summary: "Show, hide and flatten optional content.",
                  body: [
                    "Some PDFs (maps, CAD drawings, multilingual documents) group content into layers. Click the eye to show or hide a layer.",
                    "Visibility changes become the document's default layer state, so they are saved and other viewers open the same way. Undo reverts them.",
                    "Flatten Layers merges visible layers into the page and removes hidden ones. Locked layers can't be toggled."
                  ],
                  shortcuts: [], keywords: "optional content ocg visibility flatten", tool: nil),
        HelpTopic(id: HelpTopicID("destinations"), title: "Named Destinations", symbol: "mappin.and.ellipse", category: "Navigation Panels",
                  summary: "Named views that links can target.",
                  body: [
                    "Named destinations are views that links in other documents or web pages can open by name (for example report.pdf#nameddest=summary).",
                    "New Destination saves the current page and position under a name. Renaming updates bookmarks and links that use the old name.",
                    "Select a destination to go to it; sort by name or page."
                  ],
                  shortcuts: [], keywords: "named destination link anchor", tool: nil),
        HelpTopic(id: HelpTopicID("content"), title: "Content Panel", symbol: "list.bullet.indent", category: "Navigation Panels",
                  summary: "Article threads, page objects and 3D models.",
                  body: [
                    "Articles lists article threads — linked boxes that carry a story across columns and pages. Read steps through a thread box by box.",
                    "Page Content lists the objects on the current page in drawing order (text, images, paths). Click one to show it.",
                    "3D Models lists 3D annotations and their views. zPDF can't display or rotate 3D content."
                  ],
                  shortcuts: [], keywords: "article thread beads 3d model tree objects", tool: nil),
        HelpTopic(id: HelpTopicID("properties"), title: "Document Properties", symbol: "info.circle", category: "Documents",
                  summary: "Title, author, fonts, security and initial view.",
                  body: [
                    "File ▸ Document Properties (⌘D) shows information about the PDF.",
                    "Description: edit the title, author, subject and keywords. zPDF keeps the document information and XMP metadata in sync.",
                    "Security summarizes restrictions set by the PDF. Fonts lists every font and whether it is embedded.",
                    "Initial View sets how the document opens: navigation panel, page layout, magnification, opening page and window options.",
                    "Custom holds your own name–value properties, and Additional Metadata shows the raw XMP. Advanced sets binding, language and print defaults."
                  ],
                  shortcuts: [("Document Properties", "⌘D")], keywords: "metadata title author xmp fonts initial view custom", tool: nil),
        HelpTopic(id: HelpTopicID("viewing"), title: "Page Display", symbol: "rectangle.split.2x1", category: "Viewing",
                  summary: "Layouts, cover page, split view and new windows.",
                  body: [
                    "View ▸ Page Display switches between single page, scrolling and two-page views. Show Cover Page keeps the first page alone in two-page views, like a book.",
                    "Window ▸ Split View shows two independently scrolling panes of the same document. Window ▸ New Window opens the document in another window that stays in sync with your edits.",
                    "Full Screen Mode (⌘L) presents pages one at a time on a plain background. Arrow keys or clicks advance; Esc exits. Auto-advance and transitions are in Settings ▸ Full Screen.",
                    "Reflow (⌘4) shows the current page as resizable text."
                  ],
                  shortcuts: [("Full Screen Mode", "⌘L"), ("Reflow", "⌘4"), ("Fit width", "⌘2"), ("Fit page", "⌥⌘0")],
                  keywords: "two up cover page split window full screen presentation reflow", tool: nil),
        HelpTopic(id: HelpTopicID("rulers"), title: "Rulers, Grid and Guides", symbol: "ruler", category: "Viewing",
                  summary: "Align content with rulers, a grid and guides.",
                  body: [
                    "View ▸ Rulers (⌘R) shows rulers measured from the page's top-left corner. Drag from a ruler onto the page to create a guide; drag a guide back onto the ruler to remove it.",
                    "View ▸ Grid (⌘U) overlays a grid; Snap to Grid (⇧⌘U) makes the Measure tool snap to it. Units, spacing, subdivisions and colors are in Settings ▸ Units & Guides.",
                    "Guides and the grid are only drawn on screen. They are never printed or saved."
                  ],
                  shortcuts: [("Rulers", "⌘R"), ("Grid", "⌘U"), ("Snap to grid", "⇧⌘U"), ("Guides", "⌘;")],
                  keywords: "ruler grid guide snap units", tool: nil),
        HelpTopic(id: HelpTopicID("reading-tools"), title: "Loupe, Pan & Zoom and Auto-Scroll", symbol: "plus.magnifyingglass", category: "Viewing",
                  summary: "Magnify details and read hands-free.",
                  body: [
                    "View ▸ Loupe Tool magnifies the area under the pointer at 2×–6× without changing the page zoom.",
                    "View ▸ Pan & Zoom Window shows the whole page with the visible area outlined. Drag the outline to pan; use the slider to zoom.",
                    "View ▸ Automatically Scroll (⇧⌘H) scrolls continuously. Press 1–9 to set the speed, − to reverse and Esc to stop."
                  ],
                  shortcuts: [("Automatically scroll", "⇧⌘H")], keywords: "loupe magnify pan zoom auto scroll", tool: nil),
        HelpTopic(id: HelpTopicID("colors"), title: "Night Mode and Document Colors", symbol: "circle.lefthalf.filled", category: "Viewing",
                  summary: "Invert pages or use high-contrast colors.",
                  body: [
                    "Settings ▸ Accessibility ▸ Page colors replaces how pages look on screen: Night inverts pages while keeping hues recognizable; high-contrast presets and custom colors map text and background to colors you choose.",
                    "Only the screen changes. Printing, sharing and saved files keep the original colors."
                  ],
                  shortcuts: [], keywords: "night dark invert high contrast replace document colors", tool: nil),
        HelpTopic(id: HelpTopicID("search"), title: "Search", symbol: "magnifyingglass", category: "Search",
                  summary: "Find text in one document, all open documents or folders.",
                  body: [
                    "⌘F searches the current document from the toolbar.",
                    "Edit ▸ Advanced Search (⇧⌘F) searches the current document, all open documents, or every PDF in a folder, and lists each match with its context. Double-click a result to open the page.",
                    "Options: whole words, case sensitive, regular expressions, stemming (finds run, runs, running) and proximity (all words within a number of words of each other). Bookmarks, comments and attached PDFs can be included.",
                    "Build an index for a folder to search it instantly. Indexes are stored privately on this Mac and are refreshed when files change."
                  ],
                  shortcuts: [("Find", "⌘F"), ("Advanced Search", "⇧⌘F"), ("Next match", "⌘G")],
                  keywords: "find regex regular expression proximity stemming index folder", tool: nil),
        HelpTopic(id: HelpTopicID("print"), title: "Printing", symbol: "printer", category: "Output",
                  summary: "Print with layouts, comments, posters and booklets.",
                  body: [
                    "File ▸ Print (⌘P) opens zPDF's print options with a live preview. Printing always includes your current edits.",
                    "Choose all pages, the current page, a range, or a selected area (File ▸ Print Selected Area, then drag a rectangle).",
                    "Comments & Forms controls whether markups and form fields print.",
                    "Page Sizing: Fit, Actual Size, Shrink Oversized Pages, Custom Scale, Poster (tiles with overlap, cut marks and labels), Multiple pages per sheet, and Booklet (saddle-stitch; print double-sided on the short edge).",
                    "Save frequently used settings as presets. Save as PDF writes the print layout as a new file."
                  ],
                  shortcuts: [("Print", "⌘P")], keywords: "print booklet poster n-up multiple scale preset", tool: nil),
        HelpTopic(id: HelpTopicID("share"), title: "Share", symbol: "square.and.arrow.up", category: "Output",
                  summary: "Send a copy with Mail, AirDrop, Messages and more.",
                  body: [
                    "The Share button in the toolbar, File ▸ Share or the Share tool sends a copy of the document that includes your current edits. The file on disk is not changed and doesn't need to be saved first.",
                    "Copy Document copies the PDF file to the clipboard so you can paste it into Finder or another app."
                  ],
                  shortcuts: [], keywords: "share mail airdrop messages send copy", tool: .share),
        HelpTopic(id: HelpTopicID("measure"), title: "Measuring", symbol: "ruler", category: "Tools",
                  summary: "Distance, perimeter and area with a drawing scale.",
                  body: [
                    "Open the Measure tool and choose Distance, Perimeter or Area. Click points on the page; double-click or press Return to finish a perimeter or area. Hold Shift for 45° angles, press Delete to remove the last point and Esc to cancel.",
                    "The pointer snaps to line ends, midpoints, intersections and paths in the drawing (choose which in the Measure tool or Settings ▸ Measuring).",
                    "Set the scale (for example 1 in = 10 ft) or Calibrate by drawing over a known length. Save Scale in Document stores it in the PDF so other viewers measure the same way; pages that already define a scale use it automatically.",
                    "Measurements are saved as standard PDF measurement annotations. Export CSV saves every measurement as a spreadsheet file."
                  ],
                  shortcuts: [], keywords: "measure distance area perimeter scale calibrate snap csv", tool: .measureObjects),
        HelpTopic(id: HelpTopicID("accessibility"), title: "Accessibility", symbol: "accessibility", category: "Tools",
                  summary: "Check and fix accessibility; tags and reading order.",
                  body: [
                    "Run Full Check reviews tags, title, language, reading order, alternate text, tables, lists, headings, forms and more. Items marked manual need a person to verify them.",
                    "Fix buttons repair what zPDF can: autotag the document, set the title and language, add form-field descriptions, set the tab order, tag annotations and add bookmarks.",
                    "Autotag builds tags from the page layout (headings, paragraphs, lists, simple tables, figures). It's best effort: review complex tables and multi-column pages in the Tags editor.",
                    "Edit Tags shows the tag tree; change a tag's type, alternate text, actual text or language, move it, or delete it. Show Reading Order numbers tagged content on the page; drag items in the list to reorder.",
                    "Alternate Text for Figures lists every figure with a preview so you can describe it.",
                    "Identify as PDF/UA adds the PDF/UA-1 identifier once the document passes the checks."
                  ],
                  shortcuts: [], keywords: "a11y tags reading order alt text screen reader pdf/ua autotag", tool: .accessibilityCheck),
        HelpTopic(id: HelpTopicID("read-aloud"), title: "Read Out Loud", symbol: "speaker.wave.2", category: "Tools",
                  summary: "Have pages read to you with word highlighting.",
                  body: [
                    "View ▸ Read Out Loud reads the current page (⇧⌘V) or from the current page to the end (⇧⌘B). Pause or resume with ⇧⌘C and stop with ⇧⌘E.",
                    "The voice, speed and word highlighting are in Settings ▸ Reading. When no voice is chosen, zPDF uses one that matches the document's language."
                  ],
                  shortcuts: [("Read page", "⇧⌘V"), ("Read to end", "⇧⌘B"), ("Pause", "⇧⌘C"), ("Stop", "⇧⌘E")],
                  keywords: "speech voice read aloud tts", tool: nil),
        HelpTopic(id: HelpTopicID("action-wizard"), title: "Action Wizard", symbol: "wand.and.stars", category: "Tools",
                  summary: "Automate repeatable steps on one or many files.",
                  body: [
                    "An action is an ordered list of steps (for example: remove JavaScript, add a watermark, set the initial view). Create actions from the steps available in zPDF, or start from a built-in example.",
                    "Run an action on the current document (one Undo step) or on a list of files and folders, saving results to an output folder. Batch runs show progress, can be cancelled and end with a report. Source files are never changed.",
                    "Custom commands are single saved steps — such as your standard watermark — that appear in the tools list for one-click use.",
                    "The JavaScript inspector lists every script in the document so you can read or delete it. zPDF never runs document JavaScript."
                  ],
                  shortcuts: [], keywords: "automation batch action wizard javascript custom command", tool: .actionWizard),
        HelpTopic(id: HelpTopicID("settings"), title: "Settings and Shortcuts", symbol: "gearshape", category: "Basics",
                  summary: "Preferences, keyboard shortcuts and default app.",
                  body: [
                    "zPDF ▸ Settings (⌘,) groups preferences by category. Use the search field to find a setting.",
                    "Keyboard Shortcuts lists every command. Click a shortcut and press new keys to change it; conflicts are shown and resolved, and Restore Defaults resets them.",
                    "General ▸ Default PDF app makes zPDF open PDFs when you double-click them in Finder. Finder's Services menu also offers “Open in zPDF”."
                  ],
                  shortcuts: [("Settings", "⌘,")], keywords: "preferences shortcuts keys default app services", tool: nil),
        HelpTopic(id: HelpTopicID("xfa"), title: "XFA Forms", symbol: "exclamationmark.triangle", category: "Documents",
                  summary: "What zPDF can do with XFA forms.",
                  body: [
                    "Dynamic XFA forms describe their pages in XML that only Adobe software renders. zPDF shows the PDF's fallback pages (often a “please wait” message) and can't fill or edit XFA forms.",
                    "Hybrid XFA forms also contain ordinary PDF pages; zPDF displays those read-only. Where available, Convert to AcroForm saves a copy without XFA that zPDF can edit."
                  ],
                  shortcuts: [], keywords: "xfa livecycle dynamic form", tool: nil)
    ]
}

/// "What's New" content for this version.
enum WhatsNew {
    static let version = "0.2"
    static let items: [(String, String, String)] = [
        ("bookmark", "Editable navigation panels", "Create, rename, nest and reorder bookmarks; manage attachments, layers and named destinations."),
        ("printer", "A real print dialog", "Posters, booklets, multiple pages per sheet, custom scale, comments and forms, presets and a live preview — always with your current edits."),
        ("accessibility", "Accessibility tools", "Full Check with fixes, autotagging, a tags editor, reading order, alternate text, Read Out Loud and Reflow."),
        ("ruler", "Measuring", "Distance, perimeter and area with scales, calibration, snapping and CSV export."),
        ("magnifyingglass", "Advanced Search", "Search folders and open documents with regular expressions, stemming and proximity, or build an index."),
        ("wand.and.stars", "Action Wizard", "Automate multi-step jobs on many files, save custom commands, and inspect document JavaScript."),
        ("rectangle.split.2x1", "More ways to view", "Full screen presentations, split view, cover pages, rulers, grids, guides, a loupe, auto-scroll and night mode."),
        ("keyboard", "Your shortcuts", "Rebind any command in Settings ▸ Keyboard Shortcuts.")
    ]
}
