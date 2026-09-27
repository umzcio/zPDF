using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace zPDF;

/// <summary>Document structure: editing bookmarks, bookmarks from headings, named destinations,
/// the document properties editor (description, initial view, custom, XMP, fonts, security) and page boxes.</summary>
public sealed partial class DocumentPane
{
    /// <summary>One bookmark in the flat editing list: its engine item (without children) and nesting depth.</summary>
    private sealed class BookmarkRow(JsonObject node, int depth)
    {
        public JsonObject Node { get; } = node;
        public int Depth { get; set; } = depth;
    }

    private static string? JString(JsonNode? node) => node is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    private static int? JInt(JsonNode? node) => node is JsonValue v && v.TryGetValue<int>(out var i) ? i : null;
    private static bool JBool(JsonNode? node) => node is JsonValue v && v.TryGetValue<bool>(out var b) && b;

    private static Button ActionButton(string label, Action action)
    {
        var button = new Button { Content = label };
        button.Click += (_, _) => action();
        return button;
    }

    /// <summary>ISO 8601 (the engine's dates) → local display.</summary>
    private static string IsoDate(string? value) =>
        value is null ? "—" : DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)
            ? date.ToLocalTime().ToString("g") : value;

    private static string NormalizeLines(string value) => value.Replace("\r\n", "\n").Replace('\r', '\n');

    // ---------------------------------------------------------------- bookmarks

    /// <summary>Edit Bookmarks: add for the current page, rename, retarget, delete, move and nest; saved as one step.</summary>
    private async void EditBookmarks_Click(object sender, RoutedEventArgs e)
    {
        if (_document is null || CurrentPath is null) return;
        JsonNode outline;
        try { outline = await Engine.QueryAsync(CurrentPath, "outline", password: _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        var rows = new List<BookmarkRow>();
        void Flatten(JsonArray items, int depth)
        {
            foreach (var item in items.OfType<JsonObject>())
            {
                var node = (JsonObject)item.DeepClone();
                node.Remove("children");
                rows.Add(new BookmarkRow(node, depth));
                if (item["children"] is JsonArray children) Flatten(children, depth + 1);
            }
        }
        Flatten(outline["items"]?.AsArray() ?? [], 0);
        JsonArray Build()
        {
            var root = new JsonArray();
            var stack = new List<JsonArray> { root };
            foreach (var row in rows)
            {
                var node = (JsonObject)row.Node.DeepClone();
                if (JString(node["dest_name"]) is not null) node.Remove("page");  // keep named-destination targets named
                var children = new JsonArray();
                node["children"] = children;
                var depth = Math.Min(row.Depth, stack.Count - 1);
                stack.RemoveRange(depth + 1, stack.Count - depth - 1);
                stack[depth].Add(node);
                stack.Add(children);
            }
            return root;
        }
        var before = Build().ToJsonString();

        var list = new ListView { Height = 300, MinWidth = 460, SelectionMode = ListViewSelectionMode.Single };
        var title = Text("Title");
        title.Width = 300;
        var page = Number("Page", _page + 1, 1, _document.PageCount);
        var loading = false;
        string Label(BookmarkRow row) => (JString(row.Node["title"]) is { Length: > 0 } t ? t : "Untitled") +
            (JInt(row.Node["page"]) is { } p ? $"  ·  p. {p + 1}" : JString(row.Node["uri"]) is { } uri ? $"  ·  {uri}" : "");
        int Selected() => list.SelectedIndex;
        void Sync()
        {
            loading = true;
            var row = Selected() >= 0 ? rows[Selected()] : null;
            title.Text = row is null ? "" : JString(row.Node["title"]) ?? "";
            title.IsEnabled = page.IsEnabled = row is not null;
            page.Value = row is not null && JInt(row.Node["page"]) is { } p ? p + 1 : double.NaN;
            loading = false;
        }
        void Refresh(int select)
        {
            loading = true;
            list.Items.Clear();
            foreach (var row in rows)
                list.Items.Add(new ListViewItem { Content = Label(row), Padding = new Thickness(12 + row.Depth * 20, 4, 12, 4) });
            list.SelectedIndex = Math.Min(select, rows.Count - 1);
            loading = false;
            Sync();
        }
        int End(int i)
        {
            var j = i + 1;
            while (j < rows.Count && rows[j].Depth > rows[i].Depth) j++;
            return j;
        }
        void Move(int from, int count, int to)
        {
            var block = rows.GetRange(from, count);
            rows.RemoveRange(from, count);
            rows.InsertRange(to, block);
        }
        list.SelectionChanged += (_, _) => { if (!loading) Sync(); };
        title.TextChanged += (_, _) =>
        {
            if (loading || Selected() < 0) return;
            rows[Selected()].Node["title"] = title.Text;
            ((ListViewItem)list.Items[Selected()]).Content = Label(rows[Selected()]);
        };
        page.ValueChanged += (_, _) =>
        {
            if (loading || Selected() < 0 || double.IsNaN(page.Value)) return;
            var node = rows[Selected()].Node;
            foreach (var key in new[] { "uri", "dest_name", "fit", "left", "top", "zoom", "action" }) node.Remove(key);
            node["page"] = (int)Math.Clamp(page.Value, 1, _document.PageCount) - 1;
            ((ListViewItem)list.Items[Selected()]).Content = Label(rows[Selected()]);
        };
        var add = ActionButton("Add", () =>
        {
            var i = Selected();
            var at = i >= 0 ? End(i) : rows.Count;
            rows.Insert(at, new BookmarkRow(new JsonObject { ["title"] = "Untitled", ["page"] = _page }, i >= 0 ? rows[i].Depth : 0));
            Refresh(at);
            title.Focus(FocusState.Programmatic);
            title.SelectAll();
        });
        var delete = ActionButton("Delete", () =>
        {
            var i = Selected();
            if (i < 0) return;
            rows.RemoveRange(i, End(i) - i);
            Refresh(Math.Min(i, rows.Count - 1));
        });
        var up = ActionButton("Up", () =>
        {
            var i = Selected();
            if (i < 0) return;
            var k = i - 1;
            while (k >= 0 && rows[k].Depth > rows[i].Depth) k--;
            if (k < 0 || rows[k].Depth != rows[i].Depth) return;
            Move(i, End(i) - i, k);
            Refresh(k);
        });
        var down = ActionButton("Down", () =>
        {
            var i = Selected();
            if (i < 0) return;
            var next = End(i);
            if (next >= rows.Count || rows[next].Depth != rows[i].Depth) return;
            var size = End(next) - next;
            Move(next, size, i);
            Refresh(i + size);
        });
        var outdent = ActionButton("Outdent", () =>
        {
            var i = Selected();
            if (i < 0 || rows[i].Depth == 0) return;
            var end = End(i);
            for (var j = i; j < end; j++) rows[j].Depth--;
            Refresh(i);
        });
        var indent = ActionButton("Indent", () =>
        {
            var i = Selected();
            if (i <= 0 || rows[i - 1].Depth < rows[i].Depth) return;
            var end = End(i);
            for (var j = i; j < end; j++) rows[j].Depth++;
            Refresh(i);
        });
        ToolTipService.SetToolTip(add, $"Add a bookmark for page {_page + 1} after the selected one");
        ToolTipService.SetToolTip(indent, "Make it a child of the bookmark above");
        Refresh(0);
        var content = Stack(list, Row(add, delete, up, down, outdent, indent), Row(title, page),
                            Note("Changing the page makes the bookmark open that whole page."));
        if (!await AskAsync("Edit Bookmarks", content, "Save")) return;
        var items = Build();
        if (items.ToJsonString() == before) return;
        await EditDocumentAsync("Saving bookmarks…", new JsonObject { ["op"] = "set_outline", ["items"] = items });
    }

    /// <summary>Bookmarks from Headings: text larger than the body text becomes nested bookmarks.</summary>
    private async void BookmarksFromHeadings_Click(object sender, RoutedEventArgs e)
    {
        if (_document is null || CurrentPath is null) return;
        var existing = _document.Outline().Count > 0;
        var mode = Choice("Existing bookmarks", ["Replace them", "Keep them and add the new ones after"]);
        mode.Visibility = existing ? Visibility.Visible : Visibility.Collapsed;
        var note = Note("Lines in a larger font than the body text become bookmarks, nested by size (up to three levels).");
        if (!await AskAsync("Bookmarks from Headings", Stack(note, mode), "Create")) return;
        await EditDocumentAsync("Finding headings…", new JsonObject
        {
            ["op"] = "outline_from_headings", ["replace"] = !existing || mode.SelectedIndex == 0,
        });
    }

    // ---------------------------------------------------------------- named destinations

    /// <summary>Named Destinations: add one for the current page, rename (links follow) or delete; saved as one step.</summary>
    private async void NamedDestinations_Click(object sender, RoutedEventArgs e)
    {
        if (_document is null || CurrentPath is null) return;
        JsonNode result;
        try { result = await Engine.QueryAsync(CurrentPath, "destinations", password: _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        var items = result["items"]!.AsArray().OfType<JsonObject>()
            .Select(i => (Name: JString(i["name"]) ?? "", Page: JInt(i["page"]))).ToList();
        var ops = new JsonArray();
        var list = new ListView { Height = 260, MinWidth = 440, SelectionMode = ListViewSelectionMode.Single };
        var name = Text("Name");
        var message = Note("");
        void Refresh(string? select)
        {
            items.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
            list.Items.Clear();
            foreach (var (n, p) in items) list.Items.Add($"{n}  ·  {(p is { } x ? $"page {x + 1}" : "no page")}");
            list.SelectedIndex = select is null ? -1 : items.FindIndex(d => d.Name == select);
        }
        string Suggested()
        {
            var index = items.Count + 1;
            while (items.Any(d => d.Name == $"Destination {index}")) index++;
            return $"Destination {index}";
        }
        bool Valid(string value)
        {
            message.Text = value.Length == 0 ? "Enter a destination name."
                : items.Any(d => d.Name == value) ? $"A destination named “{value}” already exists." : "";
            return message.Text.Length == 0;
        }
        list.SelectionChanged += (_, _) => { if (list.SelectedIndex >= 0) name.Text = items[list.SelectedIndex].Name; };
        var add = ActionButton($"Add for Page {_page + 1}", () =>
        {
            var value = name.Text.Trim();
            if (!Valid(value)) return;
            ops.Add(new JsonObject { ["op"] = "add_destination", ["name"] = value, ["page"] = _page });
            items.Add((value, _page));
            Refresh(value);
        });
        var rename = ActionButton("Rename", () =>
        {
            if (list.SelectedIndex < 0) return;
            var (old, page) = items[list.SelectedIndex];
            var value = name.Text.Trim();
            if (value == old || !Valid(value)) return;
            ops.Add(new JsonObject { ["op"] = "rename_destination", ["old"] = old, ["new"] = value });
            items[list.SelectedIndex] = (value, page);
            Refresh(value);
        });
        var delete = ActionButton("Delete", () =>
        {
            if (list.SelectedIndex < 0) return;
            ops.Add(new JsonObject { ["op"] = "remove_destinations", ["names"] = new JsonArray(items[list.SelectedIndex].Name) });
            items.RemoveAt(list.SelectedIndex);
            Refresh(null);
            name.Text = Suggested();
        });
        var go = ActionButton("Go To", () =>
        {
            if (list.SelectedIndex >= 0 && items[list.SelectedIndex].Page is { } p) GoTo(p);
        });
        name.Text = Suggested();
        Refresh(null);
        var content = Stack(list, name, Row(add, rename, delete, go), message,
                            Note("Renaming a destination updates the links and bookmarks that use it."));
        if (!await AskAsync("Named Destinations", content, "Save") || ops.Count == 0) return;
        await ApplyOpsAsync("Updating destinations…", ops);
    }

    // ---------------------------------------------------------------- document properties editor

    private static readonly string[] ViewModes = ["default", "UseOutlines", "UseThumbs", "UseAttachments", "UseOC"];
    private static readonly string[] ViewLayouts = ["default", "SinglePage", "OneColumn", "TwoPageLeft", "TwoColumnLeft", "TwoPageRight", "TwoColumnRight"];
    private static readonly (string Key, string Label)[] ViewFlags =
    [
        ("DisplayDocTitle", "Show the document title (not the file name) in the title bar"),
        ("FitWindow", "Resize the window to the first page"), ("CenterWindow", "Center the window on screen"),
        ("HideToolbar", "Hide the toolbar"), ("HideMenubar", "Hide the menu bar"), ("HideWindowUI", "Hide window controls"),
    ];

    /// <summary>Document Properties editor: description, initial view, custom properties and XMP (one undo
    /// step), plus the fonts used and a security summary.</summary>
    private async void EditProperties_Click(object sender, RoutedEventArgs e)
    {
        if (_document is null || CurrentPath is null) return;
        JsonNode props, security, fonts;
        string? fontError = null;
        try
        {
            props = await Engine.QueryAsync(CurrentPath, "document_properties", password: _password);
            security = await Engine.QueryAsync(CurrentPath, "security_info", password: _password);
        }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        try { fonts = await Engine.QueryAsync(CurrentPath, "fonts", password: _password); }
        catch (EngineException error) { fonts = new JsonObject(); fontError = error.Message; }

        // Description
        var info = props["info"] as JsonObject;
        string Field(string key) => JString(info?[key]) ?? "";
        static string OrDash(string value) => value.Length > 0 ? value : "—";
        var title = Text("Title", Field("title"));
        var author = Text("Author", Field("author"));
        var subject = Text("Subject", Field("subject"));
        var keywords = Text("Keywords", Field("keywords"), "Separate with commas");
        var facts = new List<string>
        {
            $"PDF {JString(props["version"])} · {JInt(props["page_count"])} pages",
            $"Created {IsoDate(JString(info?["creationdate"]))} · Modified {IsoDate(JString(info?["moddate"]))}",
            $"Application: {OrDash(Field("creator"))} · Producer: {OrDash(Field("producer"))}",
        };
        var standards = new List<string>();
        if (JBool(props["tagged"])) standards.Add("Tagged");
        if (JString(props["pdfa"]) is { } pdfa) standards.Add(pdfa);
        if (JBool(props["pdfua"])) standards.Add("PDF/UA-1");
        if (JBool(props["linearized"])) standards.Add("Fast Web View");
        if (standards.Count > 0) facts.Add(string.Join(" · ", standards));
        var description = Stack(title, author, subject, keywords, Note(string.Join("\n", facts)));

        // Initial view
        var view = props["initial_view"] as JsonObject;
        var prefs = view?["viewer_preferences"] as JsonObject;
        var open = view?["open"] as JsonObject;
        var modeNow = JString(view?["page_mode"]);
        var fullNow = modeNow == "FullScreen";
        if (fullNow) modeNow = JString(prefs?["NonFullScreenPageMode"]);
        var modeIndex = Math.Max(0, Array.IndexOf(ViewModes, modeNow));
        var layoutIndex = Math.Max(0, Array.IndexOf(ViewLayouts, JString(view?["page_layout"])));
        List<string> zooms = ["default", "fit_page", "fit_width", "fit_height", "fit_visible", "50", "75", "100", "125", "150", "200", "400"];
        List<string> zoomLabels = ["Default", "Fit page", "Fit width", "Fit height", "Fit visible", "50%", "75%", "100%", "125%", "150%", "200%", "400%"];
        var zoomNow = open?["zoom"] is JsonValue z
            ? z.TryGetValue<string>(out var named) ? named : z.GetValue<double>().ToString("0.#", CultureInfo.InvariantCulture)
            : "default";
        if (!zooms.Contains(zoomNow)) { zooms.Add(zoomNow); zoomLabels.Add(zoomNow + "%"); }
        var zoomIndex = zooms.IndexOf(zoomNow);
        var openPageNow = (JInt(open?["page"]) ?? 0) + 1;
        var mode = Choice("Show", ["Page only", "Bookmarks panel and page", "Pages panel and page", "Attachments panel and page", "Layers panel and page"], modeIndex);
        var layout = Choice("Page layout", ["Default", "Single page", "Continuous", "Two-up", "Two-up continuous", "Two-up (cover page)", "Two-up continuous (cover page)"], layoutIndex);
        var zoom = Choice("Magnification", zoomLabels, zoomIndex);
        var openPage = Number("Open to page", openPageNow, 1, _document.PageCount);
        var fullScreen = new CheckBox { Content = "Open in full screen mode", IsChecked = fullNow };
        var flags = ViewFlags.Select(f => new CheckBox { Content = f.Label, IsChecked = JBool(prefs?[f.Key]) }).ToArray();
        var initial = Stack([Row(mode, layout), Row(zoom, openPage), fullScreen, .. flags,
                             Note("How the document opens in PDF readers. Some readers ignore these settings.")]);

        // Custom properties and XMP
        var customNow = (props["custom"] as JsonObject)?.ToDictionary(p => p.Key, p => JString(p.Value) ?? "") ?? new Dictionary<string, string>();
        var custom = new TextBox
        {
            Header = "Custom properties, one per line (Name: value)", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            Height = 200, Text = string.Join("\r", customNow.Select(p => $"{p.Key}: {p.Value}")),
        };
        var customPane = Stack(custom, Note("Names start with a letter and use letters, digits, - or _."));
        var xmpNow = JString(props["xmp"]) ?? "";
        var xmp = new TextBox
        {
            Header = "XMP metadata packet", AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, Height = 320,
            FontFamily = new FontFamily("Consolas"), FontSize = 12, Text = xmpNow,
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(xmp, ScrollBarVisibility.Auto);
        ScrollViewer.SetVerticalScrollBarVisibility(xmp, ScrollBarVisibility.Auto);
        var xmpPane = Stack(xmp, Note("Replaces the whole packet. Title, author, subject and keywords from the Description tab are applied after it."));

        // Fonts
        var fontPane = new StackPanel { Spacing = 10 };
        var fontItems = fonts["items"]?.AsArray().OfType<JsonObject>().ToList() ?? [];
        if (fontError is not null) fontPane.Children.Add(Note("Fonts couldn't be read: " + fontError));
        else if (fontItems.Count == 0) fontPane.Children.Add(Note("This document uses no fonts."));
        foreach (var font in fontItems)
        {
            var embedded = JBool(font["embedded"]);
            var state = embedded ? (JBool(font["subset"]) ? "Embedded subset" : "Embedded") : "Not embedded";
            if (embedded && JString(font["embedded_type"]) is { } kind) state += $" ({kind})";
            var pages = font["pages"]?.AsArray().Select(JInt).OfType<int>().Select(p => (p + 1).ToString()).ToList() ?? [];
            var entry = new StackPanel();
            entry.Children.Add(new TextBlock { Text = JString(font["name"]) ?? "(unnamed)", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], IsTextSelectionEnabled = true });
            entry.Children.Add(Note($"{JString(font["type"])} · {state} · Encoding: {JString(font["encoding"])}" +
                                    (pages.Count > 0 ? $" · {(pages.Count == 1 ? "Page" : "Pages")} {string.Join(", ", pages)}{(pages.Count >= 50 ? "…" : "")}" : "")));
            fontPane.Children.Add(entry);
        }

        // Security
        var lines = new List<string>();
        if (JBool(security["encrypted"]))
        {
            lines.Add($"Encrypted with {JString(security["method"])} ({JInt(security["bits"])}-bit, revision {JInt(security["revision"])}).");
            lines.Add(JBool(security["owner_password_matched"]) ? "Opened with the permissions password: everything is allowed." : "Opened with the open password.");
            var permissions = security["permissions"] as JsonObject;
            var names = new (string Key, string Label)[]
            {
                ("print_lowres", "Printing"), ("print_highres", "High-quality printing"), ("modify_other", "Changing the document"),
                ("modify_annotation", "Commenting"), ("modify_form", "Filling in forms"), ("modify_assembly", "Inserting, deleting and rotating pages"),
                ("extract", "Copying text and images"), ("accessibility", "Content access for accessibility"),
            };
            foreach (var (key, label) in names) lines.Add($"{label}: {(JBool(permissions?[key]) ? "Allowed" : "Not allowed")}");
        }
        else lines.Add("No security. Anyone can open, print, copy and change this document.");
        var marker = JString(security["marker"]?["mode"]);
        if (marker == "Password") lines.Add("Password security will be applied when you save.");
        else if (marker == "Certificate") lines.Add("Certificate security will be applied when you save.");
        else if (marker == "None" && JBool(security["encrypted"])) lines.Add("Security will be removed when you save.");
        else if (marker == "Preserve") lines.Add("The original security is kept when you save.");
        if (JBool(security["signed"])) lines.Add("This document is digitally signed; changes are saved after the signatures.");
        var securityPane = new TextBlock { Text = string.Join("\n", lines), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, LineHeight = 22 };

        var pivot = new Pivot { Width = 640, Height = 480 };
        foreach (var (header, pane) in new (string, UIElement)[]
                 { ("Description", description), ("Initial View", initial), ("Custom", customPane), ("XMP", xmpPane), ("Fonts", fontPane), ("Security", securityPane) })
            pivot.Items.Add(new PivotItem { Header = header, Content = new ScrollViewer { Content = pane, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 8, 16, 8) } });
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = "Document Properties", Content = pivot,
            PrimaryButtonText = "OK", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
        };
        dialog.Resources["ContentDialogMaxWidth"] = 720.0;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        var ops = new JsonArray();
        if (NormalizeLines(xmp.Text) != NormalizeLines(xmpNow)) ops.Add(new JsonObject { ["op"] = "set_xmp", ["xmp"] = NormalizeLines(xmp.Text) });
        var changed = new JsonObject();
        foreach (var (key, box) in new[] { ("title", title), ("author", author), ("subject", subject), ("keywords", keywords) })
            if (box.Text != Field(key)) changed[key] = box.Text.Trim();
        var customNew = new Dictionary<string, string>();
        foreach (var line in custom.Text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var colon = line.IndexOf(':');
            if (colon <= 0) { StatusText.Text = $"“{line}” isn't a custom property. Write it as Name: value."; return; }
            customNew[line[..colon].Trim()] = line[(colon + 1)..].Trim();
        }
        var customChanged = new JsonObject();
        foreach (var (key, value) in customNew)
            if (customNow.GetValueOrDefault(key) != value) customChanged[key] = value;
        var removed = customNow.Keys.Where(k => !customNew.ContainsKey(k)).Select(k => (JsonNode)k).ToArray();
        if (changed.Count > 0 || customChanged.Count > 0 || removed.Length > 0)
        {
            var metadata = new JsonObject { ["op"] = "set_metadata" };
            if (changed.Count > 0) metadata["info"] = changed;
            if (customChanged.Count > 0) metadata["custom"] = customChanged;
            if (removed.Length > 0) metadata["remove_custom"] = new JsonArray(removed);
            ops.Add(metadata);
        }
        string? OrNull(string value) => value == "default" ? null : value;
        var viewOp = new JsonObject { ["op"] = "set_initial_view", ["page_layout"] = "keep", ["page_mode"] = "keep" };
        var viewChanged = false;
        var viewPrefs = new JsonObject();
        if (layout.SelectedIndex != layoutIndex)
        {
            viewOp["page_layout"] = OrNull(ViewLayouts[Math.Max(0, layout.SelectedIndex)]);
            viewChanged = true;
        }
        var full = fullScreen.IsChecked == true;
        var pageMode = ViewModes[Math.Max(0, mode.SelectedIndex)];
        if (full != fullNow || mode.SelectedIndex != modeIndex)
        {
            viewOp["page_mode"] = full ? "FullScreen" : OrNull(pageMode);
            if (full) viewPrefs["NonFullScreenPageMode"] = OrNull(pageMode);
            viewChanged = true;
        }
        var page = double.IsNaN(openPage.Value) ? openPageNow : (int)Math.Clamp(openPage.Value, 1, _document.PageCount);
        if (page != openPageNow || zoom.SelectedIndex != zoomIndex)
        {
            var value = zooms[Math.Max(0, zoom.SelectedIndex)];
            viewOp["open_page"] = page - 1;
            viewOp["open_zoom"] = double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var percent) ? (JsonNode)percent : value;
            viewChanged = true;
        }
        for (var i = 0; i < ViewFlags.Length; i++)
            if ((flags[i].IsChecked == true) != JBool(prefs?[ViewFlags[i].Key])) viewPrefs[ViewFlags[i].Key] = flags[i].IsChecked == true;
        if (viewPrefs.Count > 0) { viewOp["viewer_preferences"] = viewPrefs; viewChanged = true; }
        if (viewChanged) ops.Add(viewOp);
        if (ops.Count == 0) return;
        await ApplyOpsAsync("Changing document properties…", ops, "Document properties changed. Save to keep them.");
    }

    // ---------------------------------------------------------------- page boxes

    private static readonly string[] PageBoxNames = ["CropBox", "TrimBox", "BleedBox", "ArtBox", "MediaBox"];

    /// <summary>Set Page Boxes: margins (inches, inward from the media box) for the crop, trim, bleed, art or
    /// media box on a page scope, or remove a trim/bleed/art box.</summary>
    private async void SetPageBoxes_Click(object sender, RoutedEventArgs e)
    {
        if (_document is null || CurrentPath is null) return;
        JsonNode result;
        try { result = await Engine.QueryAsync(CurrentPath, "page_boxes", new JsonObject { ["pages"] = new JsonArray(_page) }, _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        var current = result["pages"]![0]!;
        double[] Box(string key) => current[key]!.AsArray().Select(v => v!.GetValue<double>()).ToArray();
        var media = Box("media");
        var crop = Box("crop");
        double[] Margins(double[] r) =>
            [Math.Max(0, r[0] - media[0]), Math.Max(0, r[1] - media[1]), Math.Max(0, media[2] - r[2]), Math.Max(0, media[3] - r[3])];
        var values = PageBoxNames.ToDictionary(n => n, n => n == "MediaBox" ? new double[4] : Margins(crop));
        var edited = new HashSet<string>();
        var removed = new HashSet<string>();
        var box = Choice("Box", ["Crop box: the visible page area", "Trim box: the finished size after trimming", "Bleed box: the printed area beyond the trim",
                                 "Art box: the meaningful content area", "Media box: the physical page"]);
        var edges = new[] { "Left", "Bottom", "Right", "Top" }.Select(h => Number(h + " (in)", 0, 0, 200, 0.125)).ToArray();
        var remove = new CheckBox { Content = "Remove this box (readers then use the crop box)" };
        var mediaNote = Note("Shrinking the media box clips the page. Use Resize Pages to scale the content instead.");
        var scope = Scope();
        var loading = false;
        string BoxName() => PageBoxNames[Math.Max(0, box.SelectedIndex)];
        void Load()
        {
            loading = true;
            var name = BoxName();
            for (var i = 0; i < 4; i++) { edges[i].Value = Math.Round(values[name][i] / 72, 3); edges[i].IsEnabled = !removed.Contains(name); }
            remove.Visibility = name is "TrimBox" or "BleedBox" or "ArtBox" ? Visibility.Visible : Visibility.Collapsed;
            remove.IsChecked = removed.Contains(name);
            mediaNote.Visibility = name == "MediaBox" ? Visibility.Visible : Visibility.Collapsed;
            loading = false;
        }
        for (var i = 0; i < 4; i++)
        {
            var index = i;
            edges[i].ValueChanged += (s, _) =>
            {
                if (loading || double.IsNaN(s.Value)) return;
                values[BoxName()][index] = s.Value * 72;
                edited.Add(BoxName());
            };
        }
        remove.Checked += (_, _) => { if (!loading) { removed.Add(BoxName()); Load(); } };
        remove.Unchecked += (_, _) => { if (!loading) { removed.Remove(BoxName()); Load(); } };
        box.SelectionChanged += (_, _) => Load();
        Load();
        var content = Stack(box, Row(edges[3], edges[0]), Row(edges[2], edges[1]), remove, mediaNote, scope,
                            Note($"Margins are measured inward from the media box of page {_page + 1}. Trim, bleed and art boxes start from its crop box."));
        if (!await AskAsync("Set Page Boxes", content, "Apply")) return;
        var boxes = new JsonObject();
        foreach (var name in PageBoxNames.Where(n => edited.Contains(n) && !removed.Contains(n)))
            boxes[name] = new JsonObject { ["margins"] = ToJson(values[name]) };
        if (boxes.Count == 0 && removed.Count == 0) return;
        await EditDocumentAsync("Setting page boxes…", new JsonObject
        {
            ["op"] = "set_page_boxes", ["boxes"] = boxes,
            ["remove"] = new JsonArray(removed.Select(n => (JsonNode)n).ToArray()), ["pages"] = ScopePages(scope),
        });
    }
}
