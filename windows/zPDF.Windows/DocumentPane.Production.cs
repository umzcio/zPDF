using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.Storage.Pickers;

namespace zPDF;

/// <summary>Print production (preflight, output preview, printer marks), accessibility
/// editing (alternate text, reading order) and batch processing.</summary>
public sealed partial class DocumentPane
{
    /// <summary>Several engine edits as one undo step.</summary>
    private Task<bool> ApplyOpsAsync(string status, JsonArray ops, string? done = null) =>
        Run(status, async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, ops, _password);
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
            if (done is not null) StatusText.Text = done;
        }, keepStatus: done is not null);

    private static TextBlock Note(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };

    // ---------------------------------------------------------------- preflight

    private static readonly (string Id, string Label)[] PreflightProfiles =
    [
        ("commercial", "Commercial print (PDF/X-4 readiness)"), ("digital", "Digital printing"),
        ("web", "Online publishing"), ("archive", "Archiving (PDF/A-2b readiness)"),
    ];

    private static (string Label, JsonArray Ops)? PreflightFix(string fix) => fix switch
    {
        "embed_fonts" => ("Embed fonts", [new JsonObject { ["op"] = "embed_fonts" }]),
        "downsample" => ("Downsample images to 150 dpi", [new JsonObject
        {
            ["op"] = "optimize", ["compress"] = false,
            ["images"] = new JsonObject { ["color_dpi"] = 150, ["gray_dpi"] = 150, ["jpeg_quality"] = 75, ["threshold"] = 1.0 },
        }]),
        "map_spots" => ("Convert spot colours to process", [new JsonObject { ["op"] = "map_spots_to_process" }]),
        "flatten" => ("Flatten transparency", [new JsonObject { ["op"] = "flatten_transparency", ["dpi"] = 300 }]),
        "hairlines" => ("Thicken hairlines to 0.25 pt", [new JsonObject { ["op"] = "fix_hairlines", ["min_width"] = 0.25 }]),
        "set_trim" => ("Set TrimBox", [new JsonObject { ["op"] = "set_trim_to_crop" }]),
        "flatten_annotations" => ("Flatten comments and form fields", [new JsonObject { ["op"] = "print_prepare", ["comments"] = true, ["fields"] = true }]),
        "remove_javascript" => ("Remove JavaScript", [new JsonObject { ["op"] = "remove_javascript" }]),
        "convert_pdfx" => ("Convert to PDF/X-4", [new JsonObject { ["op"] = "convert_pdfx", ["version"] = "PDF/X-4" }]),
        "convert_pdfa" => ("Convert to PDF/A-2b", [new JsonObject { ["op"] = "convert_pdfa", ["level"] = "2b" }]),
        _ => null,
    };

    private async void Preflight_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        var profile = Choice("Profile", PreflightProfiles.Select(p => p.Label));
        if (!await AskAsync("Preflight", Stack(profile, Note("Checks fonts, image resolution, colour, transparency, hairlines, page boxes and the chosen standard.")), "Check")) return;
        var id = PreflightProfiles[Math.Max(0, profile.SelectedIndex)].Id;
        JsonNode report;
        try { report = await Engine.QueryAsync(CurrentPath, "preflight", new JsonObject { ["profile"] = id }, _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }

        var results = report["results"]!.AsArray();
        var panel = new StackPanel { Spacing = 6, MinWidth = 480 };
        var errors = results.Count(r => r!["severity"]?.GetValue<string>() == "error");
        var warnings = results.Count(r => r!["severity"]?.GetValue<string>() == "warning");
        panel.Children.Add(new TextBlock
        {
            Text = errors + warnings == 0 ? "No problems found." : $"{errors} error{(errors == 1 ? "" : "s")} · {warnings} warning{(warnings == 1 ? "" : "s")}",
            Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
        });
        foreach (var result in results.Where(r => r!["severity"]?.GetValue<string>() != "pass"))
        {
            var severity = result!["severity"]?.GetValue<string>();
            var pages = result["pages"]!.AsArray().Select(p => p!.GetValue<int>() + 1).ToList();
            var where = pages.Count == 0 ? "" : pages.Count > 8 ? $" (pages {string.Join(", ", pages.Take(8))}…)" : $" (page{(pages.Count == 1 ? "" : "s")} {string.Join(", ", pages)})";
            var mark = severity switch { "error" => "✗", "warning" => "!", _ => "i" };
            var detail = result["detail"]?.GetValue<string>() is { Length: > 0 } d ? $" — {d}" : "";
            panel.Children.Add(new TextBlock { Text = $"{mark}  {result["title"]}{detail}{where}", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        }

        // One checkbox per distinct fix; PDF/X or PDF/A conversion covers its standard's rules.
        var fixes = new List<(CheckBox Box, JsonArray Ops)>();
        var seen = new HashSet<string>();
        foreach (var fix in results.Select(r => r!["fix"]?.GetValue<string>()).OfType<string>())
            if (seen.Add(fix) && PreflightFix(fix) is { } f)
                fixes.Add((new CheckBox { Content = f.Label, IsChecked = true }, f.Ops));
        if (fixes.Count > 0)
        {
            panel.Children.Add(new TextBlock { Text = "Fixes", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Margin = new Thickness(0, 12, 0, 0) });
            foreach (var (box, _) in fixes) panel.Children.Add(box);
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = $"Preflight: {report["title"]}", CloseButtonText = "Close",
            Content = new ScrollViewer { Content = panel, MaxHeight = 520 },
            PrimaryButtonText = fixes.Count > 0 ? "Apply Fixes" : "", DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var chosen = fixes.Where(f => f.Box.IsChecked == true).ToList();
        if (chosen.Count == 0) return;
        // All fixes in one step; if one fails, the others still apply (one at a time).
        await Run("Applying preflight fixes…", async () =>
        {
            var failed = new List<string>();
            var current = CurrentPath!;
            try
            {
                var all = new JsonArray();
                foreach (var (_, fixOps) in chosen) foreach (var op in fixOps) all.Add(op!.DeepClone());
                current = await Engine.TransformAsync(current, all, _password);
            }
            catch (EngineException)
            {
                foreach (var (box, fixOps) in chosen)
                {
                    try
                    {
                        var next = await Engine.TransformAsync(current, (JsonArray)fixOps.DeepClone(), _password);
                        if (current != CurrentPath) TryDelete(current);
                        current = next;
                    }
                    catch (EngineException error) { failed.Add($"{box.Content}: {error.Message}"); }
                }
            }
            if (current != CurrentPath)
            {
                PushRevision(current);
                Show(PdfDocument.Open(current, _password), keepPosition: true);
            }
            StatusText.Text = failed.Count == 0 ? "Fixes applied. Run Preflight again to confirm, then save."
                : $"{chosen.Count - failed.Count} of {chosen.Count} fixes applied. Not applied — {string.Join("; ", failed)}";
        }, keepStatus: true);
    }

    // ---------------------------------------------------------------- output preview

    private async void OutputPreview_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        JsonNode inks;
        try { inks = await Engine.QueryAsync(CurrentPath, "inks", password: _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        var panel = new StackPanel { Spacing = 6, MinWidth = 420 };
        var process = inks["process"]!.AsArray().Select(p => p!.GetValue<string>()).ToList();
        panel.Children.Add(new TextBlock { Text = "Process inks", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        panel.Children.Add(new TextBlock { Text = process.Count > 0 ? string.Join(", ", process) : "None" });
        if (inks["rgb"]?.GetValue<bool>() == true)
            panel.Children.Add(Note("Some content is in RGB; it is converted to CMYK when printed or converted to PDF/X-4."));
        var spots = new List<(CheckBox Box, string Name)>();
        var list = inks["spots"]!.AsArray();
        panel.Children.Add(new TextBlock { Text = "Spot colours", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Margin = new Thickness(0, 8, 0, 0) });
        if (list.Count == 0) panel.Children.Add(new TextBlock { Text = "None" });
        foreach (var spot in list)
        {
            var name = spot!["name"]!.GetValue<string>();
            var mappable = spot["mappable"]?.GetValue<bool>() == true;
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            if (spot["preview"] is JsonObject preview && SwatchColor(preview) is { } color)
                row.Children.Add(new Border { Width = 16, Height = 16, Background = new SolidColorBrush(color), BorderBrush = new SolidColorBrush(Microsoft.UI.Colors.Gray), BorderThickness = new Thickness(1) });
            var box = new CheckBox { Content = $"{name} (alternate {spot["alternate"]})", IsEnabled = mappable };
            row.Children.Add(box);
            panel.Children.Add(row);
            if (mappable) spots.Add((box, name));
        }
        if (spots.Count > 0) panel.Children.Add(Note("Checked spot colours are converted to their process (CMYK) equivalents."));
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = "Output Preview", CloseButtonText = "Close", Content = new ScrollViewer { Content = panel, MaxHeight = 520 },
            PrimaryButtonText = spots.Count > 0 ? "Convert to Process" : "",
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var names = spots.Where(s => s.Box.IsChecked == true).Select(s => (JsonNode)s.Name).ToArray();
        if (names.Length == 0) return;
        await EditDocumentAsync("Converting spot colours…", new JsonObject { ["op"] = "map_spots_to_process", ["names"] = new JsonArray(names) });
    }

    private static Windows.UI.Color? SwatchColor(JsonObject preview)
    {
        var values = preview["values"]?.AsArray().Select(v => v!.GetValue<double>()).ToArray();
        if (values is null) return null;
        static byte B(double v) => (byte)Math.Clamp(Math.Round(v * 255), 0, 255);
        return preview["space"]?.GetValue<string>() switch
        {
            "DeviceCMYK" when values.Length >= 4 => Windows.UI.Color.FromArgb(255, B((1 - values[0]) * (1 - values[3])), B((1 - values[1]) * (1 - values[3])), B((1 - values[2]) * (1 - values[3]))),
            "DeviceRGB" when values.Length >= 3 => Windows.UI.Color.FromArgb(255, B(values[0]), B(values[1]), B(values[2])),
            "DeviceGray" when values.Length >= 1 => Windows.UI.Color.FromArgb(255, B(values[0]), B(values[0]), B(values[0])),
            _ => null,
        };
    }

    // ---------------------------------------------------------------- printer marks

    private async void PrinterMarks_Click(object sender, RoutedEventArgs e)
    {
        var crop = new CheckBox { Content = "Trim (crop) marks", IsChecked = true };
        var bleedMarks = new CheckBox { Content = "Bleed marks", IsChecked = true };
        var registration = new CheckBox { Content = "Registration marks", IsChecked = true };
        var bars = new CheckBox { Content = "Colour bars", IsChecked = true };
        var info = new CheckBox { Content = "Page information (file, page, date)", IsChecked = true };
        var bleed = Number("Bleed (pt)", 9, 0, 72);
        var offset = Number("Mark offset (pt)", 6, 0, 36);
        var weight = Number("Line weight (pt)", 0.25, 0.05, 2, 0.05);
        var remove = new CheckBox { Content = "Remove printer marks instead" };
        var scope = Scope();
        if (!await AskAsync("Printer Marks", Stack(crop, bleedMarks, registration, bars, info, Row(bleed, offset, weight), scope, remove,
                            Note("The page grows to hold the marks outside the trim and bleed; TrimBox and BleedBox are set.")), "Apply")) return;
        var pages = ScopePages(scope);
        if (remove.IsChecked == true)
        {
            if (await EditDocumentAsync("Removing printer marks…", new JsonObject { ["op"] = "remove_printer_marks", ["pages"] = pages }))
                StatusText.Text = "Printer marks removed. Save to keep the change.";
            return;
        }
        if (await EditDocumentAsync("Adding printer marks…", new JsonObject
        {
            ["op"] = "printer_marks", ["pages"] = pages, ["crop"] = crop.IsChecked == true, ["bleed_marks"] = bleedMarks.IsChecked == true,
            ["registration"] = registration.IsChecked == true, ["color_bars"] = bars.IsChecked == true, ["page_info"] = info.IsChecked == true,
            ["bleed"] = Finite(bleed.Value, 9), ["offset"] = Finite(offset.Value, 6), ["weight"] = Finite(weight.Value, 0.25),
            ["title"] = Path.GetFileName(_sourcePath),
        })) StatusText.Text = "Printer marks added; the page grew to hold them outside the trim. Save to keep them.";
    }

    private static double Finite(double value, double fallback) => double.IsFinite(value) ? value : fallback;

    // ---------------------------------------------------------------- alternate text

    private async void AltText_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        JsonNode tree;
        try { tree = await Engine.QueryAsync(CurrentPath, "structure_tree", password: _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        if (tree["tagged"]?.GetValue<bool>() != true)
        {
            StatusText.Text = "This document isn't tagged. Use Tools ▸ Autotag Document first.";
            return;
        }
        var figures = new List<JsonNode>();
        void Walk(JsonNode node)
        {
            if (node["type"]?.GetValue<string>() is "Figure" or "Formula") figures.Add(node);
            foreach (var child in node["children"]?.AsArray() ?? []) if (child is not null) Walk(child);
        }
        Walk(tree["root"]!);
        if (figures.Count == 0) { StatusText.Text = "This document has no tagged figures."; return; }

        // Where each figure sits, from the pages' reading order, for a preview crop.
        var rects = new Dictionary<string, double[]>();
        foreach (var page in figures.Select(f => f["page"]).OfType<JsonValue>().Select(p => p.GetValue<int>()).Distinct().Take(20))
        {
            try
            {
                var order = await Engine.QueryAsync(CurrentPath, "reading_order", new JsonObject { ["page"] = page }, _password);
                foreach (var item in order["items"]!.AsArray())
                    if (item!["rect"] is JsonArray r) rects[item["id"]!.GetValue<string>()] = r.Select(v => v!.GetValue<double>()).ToArray();
            }
            catch (EngineException) { }
        }

        var panel = new StackPanel { Spacing = 14, MinWidth = 520 };
        panel.Children.Add(Note("Describe each figure for people using screen readers. Leave a description empty to remove it."));
        var edits = new List<(string Id, string Original, TextBox Box)>();
        foreach (var figure in figures.Take(200))
        {
            var id = figure["id"]!.GetValue<string>();
            var alt = (figure["alt"]?.GetValue<string>() ?? "").TrimEnd('\0');
            var page = figure["page"] is JsonValue p ? p.GetValue<int>() : (int?)null;
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            if (page is { } pg && rects.TryGetValue(id, out var rect) && await FigurePreviewAsync(pg, rect) is { } preview) row.Children.Add(preview);
            var box = new TextBox
            {
                Header = $"{figure["type"]} · page {(page is { } n ? n + 1 : "?")}", Text = alt, AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap, Width = 340, MinHeight = 60, PlaceholderText = "Describe this image",
            };
            row.Children.Add(box);
            panel.Children.Add(row);
            edits.Add((id, alt, box));
        }
        if (!await AskAsync($"Alternate Text ({figures.Count} figure{(figures.Count == 1 ? "" : "s")})", panel, "Save")) return;
        var items = new JsonArray();
        foreach (var (id, original, box) in edits)
            if (box.Text.Trim() != original.Trim()) items.Add(new JsonObject { ["id"] = id, ["alt"] = box.Text.Trim() });
        if (items.Count == 0) return;
        await ApplyOpsAsync("Saving alternate text…", [new JsonObject { ["op"] = "set_alt_text", ["items"] = items }],
                            $"Updated {items.Count} description{(items.Count == 1 ? "" : "s")}.");
    }

    private async Task<FrameworkElement?> FigurePreviewAsync(int page, double[] rect)
    {
        if (_document is null || await InfoAsync(page) is not { } info) return null;
        var view = BoxRect(info, rect);
        if (view.Width < 1 || view.Height < 1) return null;
        var scale = Math.Min(1.5, Math.Min(140 / view.Width, 140 / view.Height));
        RenderedPage image;
        try { image = _document.Render(page, scale); }
        catch (Exception) { return null; }
        var picture = new Image
        {
            Source = ToBitmap(image), Stretch = Stretch.None,
            RenderTransform = new TranslateTransform { X = -view.X * scale, Y = -view.Y * scale },
        };
        var canvas = new Canvas { Width = view.Width * scale, Height = view.Height * scale, Clip = new RectangleGeometry { Rect = new(0, 0, view.Width * scale, view.Height * scale) } };
        canvas.Children.Add(picture);
        return new Border { Child = canvas, BorderBrush = new SolidColorBrush(Microsoft.UI.Colors.Gray), BorderThickness = new Thickness(1), VerticalAlignment = VerticalAlignment.Top };
    }

    // ---------------------------------------------------------------- reading order

    private sealed record OrderItem(string Id, string Label)
    {
        public override string ToString() => Label;
    }

    private async void ReadingOrder_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        var page = _page;
        JsonNode order, tree;
        try
        {
            order = await Engine.QueryAsync(CurrentPath, "reading_order", new JsonObject { ["page"] = page }, _password);
            tree = await Engine.QueryAsync(CurrentPath, "structure_tree", password: _password);
        }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        // Parent of every tag: moves happen among siblings, carrying each tag's contents along.
        var parents = new Dictionary<string, string>();
        void Walk(JsonNode node, string parent)
        {
            var id = node["id"]?.GetValue<string>() ?? parent;
            if (id != parent) parents[id] = parent;
            foreach (var child in node["children"]?.AsArray() ?? []) if (child is not null) Walk(child, id);
        }
        Walk(tree["root"]!, "root");
        string ParentOf(string id) => parents.GetValueOrDefault(id, "root");
        bool Inside(string id, string ancestor)
        {
            for (var at = ParentOf(id); at != "root"; at = ParentOf(at)) if (at == ancestor) return true;
            return false;
        }
        var entries = order["items"]!.AsArray().Select(i =>
        {
            var text = (i!["text"]?.GetValue<string>() ?? "").Replace('\n', ' ');
            if (text.Length > 60) text = text[..60] + "…";
            return (Id: i["id"]!.GetValue<string>(), Label: $"{i["type"]}  {text}");
        }).ToList();
        if (entries.Count < 2) { StatusText.Text = entries.Count == 0 ? "This page has no tagged content. Autotag the document first." : "This page has only one tagged item."; return; }
        var onPage = entries.Select(e => e.Id).ToHashSet();
        int Depth(string id) { var d = 0; for (var at = ParentOf(id); at != "root"; at = ParentOf(at)) if (onPage.Contains(at)) d++; return d; }
        var ids = entries.Select(e => e.Id).ToList();
        var labels = entries.ToDictionary(e => e.Id, e => e.Label);
        var items = new ObservableCollection<OrderItem>();
        void Refill()
        {
            items.Clear();
            foreach (var id in ids) items.Add(new OrderItem(id, new string(' ', Depth(id) * 4) + labels[id]));
        }
        Refill();
        var list = new ListView { ItemsSource = items, SelectionMode = ListViewSelectionMode.Single, MaxHeight = 380, MinWidth = 520 };
        // A tag and everything nested in it, as a run of the list starting at `index`.
        int BlockEnd(int index) { var end = index + 1; while (end < ids.Count && Inside(ids[end], ids[index])) end++; return end; }
        var changed = new HashSet<string>();  // parents whose children were reordered
        void Move(int direction)
        {
            if (list.SelectedIndex is not (var index and >= 0)) return;
            var id = ids[index];
            var parent = ParentOf(id);
            var end = BlockEnd(index);
            var block = ids.GetRange(index, end - index);
            // The neighbouring sibling (with its contents) in that direction.
            var siblings = Enumerable.Range(0, ids.Count).Where(i => ParentOf(ids[i]) == parent).ToList();
            var at = siblings.IndexOf(index) + direction;
            if (at < 0 || at >= siblings.Count) { StatusText.Text = "That tag is already first or last within its parent."; return; }
            var other = siblings[at];
            var otherEnd = BlockEnd(other);
            ids.RemoveRange(index, block.Count);
            // Up: before the previous sibling. Down: after the next sibling and its contents.
            ids.InsertRange(direction < 0 ? other : otherEnd - block.Count, block);
            changed.Add(parent);
            Refill();
            list.SelectedIndex = ids.IndexOf(id);
        }
        var up = new Button { Content = "Move Up" };
        var down = new Button { Content = "Move Down" };
        up.Click += (_, _) => Move(-1);
        down.Click += (_, _) => Move(1);
        if (!await AskAsync($"Reading Order: Page {page + 1}", Stack(Note("Select a tag and move it up or down among the tags at its level (indented tags are inside the one above and move with it)."), list, Row(up, down)), "Save")) return;
        if (changed.Count == 0) return;
        var ops = new JsonArray();
        foreach (var parent in changed)
        {
            var group = ids.Where(i => ParentOf(i) == parent).ToList();
            if (group.Count > 1) ops.Add(new JsonObject { ["op"] = "set_reading_order", ["page"] = page, ["ids"] = new JsonArray(group.Select(i => (JsonNode)i).ToArray()) });
        }
        if (ops.Count > 0) await ApplyOpsAsync("Saving reading order…", ops, $"Reading order of page {page + 1} saved.");
    }

    // ---------------------------------------------------------------- batch processing

    private sealed record BatchStep(string Title, CheckBox Box, Func<string, JsonArray> Ops, params FrameworkElement[] Options);

    private async void Batch_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add(".pdf");
        var files = await picker.PickMultipleFilesAsync();
        if (files is not { Count: > 0 }) return;

        static JsonObject Optional(JsonObject step) => new() { ["op"] = "optional", ["step"] = step };
        static string Expand(string text, string name) => text.Replace("<<filename>>", name).Replace("<<date>>", DateTime.Now.ToShortDateString())
                                                             .Replace("<<author>>", AppSettings.Current.AuthorName);
        var watermarkText = Text("Text", "CONFIDENTIAL");
        var footer = Text("Footer", "Page <<page>> of <<pages>>");
        var batesPrefix = Text("Prefix", "");
        var title = Text("Title", "<<filename>>");
        var author = Text("Author", "");
        var quality = Choice("Quality", ["High", "Medium", "Low (smallest)"], 1);
        var pdfa = Choice("Standard", ["PDF/A-2b", "PDF/A-3b", "PDF/A-2u"]);
        var steps = new List<BatchStep>
        {
            new("Add Watermark", new CheckBox(), n => [new JsonObject { ["op"] = "watermark", ["text"] = Expand(watermarkText.Text, n), ["size"] = 60, ["opacity"] = 0.25, ["angle"] = 45, ["color"] = new JsonArray(220, 30, 30) }], watermarkText),
            new("Add Page Numbers", new CheckBox(), n => [new JsonObject { ["op"] = "header_footer", ["items"] = new JsonObject { ["bottom-center"] = Expand(footer.Text, n) }, ["size"] = 10 }], footer),
            new("Bates Numbering", new CheckBox(), n => [new JsonObject { ["op"] = "bates", ["prefix"] = Expand(batesPrefix.Text, n), ["suffix"] = "", ["start"] = 1, ["digits"] = 6, ["anchor"] = "bottom-right" }], batesPrefix),
            new("Flatten Comments and Form Fields", new CheckBox(), _ => [new JsonObject { ["op"] = "print_prepare", ["comments"] = true, ["fields"] = true }]),
            new("Flatten Layers", new CheckBox(), _ => [Optional(new JsonObject { ["op"] = "flatten_layers" })]),
            new("Remove JavaScript", new CheckBox(), _ => [new JsonObject { ["op"] = "remove_javascript" }]),
            new("Remove Hidden Information", new CheckBox(), _ => [new JsonObject { ["op"] = "sanitize" }]),
            new("Set Document Properties", new CheckBox(), n =>
            {
                var info = new JsonObject();
                if (Expand(title.Text, n) is { Length: > 0 } t) info["title"] = t;
                if (Expand(author.Text, n) is { Length: > 0 } a) info["author"] = a;
                return info.Count == 0 ? [] : [new JsonObject { ["op"] = "set_metadata", ["info"] = info }];
            }, title, author),
            new("Make Accessible (autotag, title, language, tab order)", new CheckBox(), n =>
            {
                var language = System.Globalization.CultureInfo.CurrentUICulture.Name is { Length: > 0 } l ? l : "en-US";
                return [Optional(new JsonObject { ["op"] = "autotag", ["language"] = language }),
                        new JsonObject { ["op"] = "set_title", ["title"] = n, ["display_doc_title"] = true },
                        new JsonObject { ["op"] = "set_language", ["lang"] = language },
                        new JsonObject { ["op"] = "set_field_tooltips" },
                        new JsonObject { ["op"] = "set_page_tab_order", ["order"] = "S" },
                        Optional(new JsonObject { ["op"] = "tag_annotations" })];
            }),
            new("Bookmarks from Headings", new CheckBox(), _ => [Optional(new JsonObject { ["op"] = "outline_from_headings", ["replace"] = true })]),
            new("Reduce File Size", new CheckBox(), _ => [new JsonObject { ["op"] = "optimize", ["preset"] = new[] { "high", "medium", "low" }[Math.Max(0, quality.SelectedIndex)] }], quality),
            new("Convert to PDF/A", new CheckBox(), _ => [new JsonObject { ["op"] = "convert_pdfa", ["level"] = new[] { "2b", "3b", "2u" }[Math.Max(0, pdfa.SelectedIndex)] }], pdfa),
            new("Save for Fast Web View", new CheckBox(), _ => [new JsonObject { ["op"] = "linearize" }]),
        };
        var panel = new StackPanel { Spacing = 6, MinWidth = 480 };
        panel.Children.Add(new TextBlock { Text = $"{files.Count} file{(files.Count == 1 ? "" : "s")} selected. Steps run in this order; originals are never changed.", TextWrapping = TextWrapping.Wrap });
        var saved = AppSettings.Current.SavedActions;
        var savedChoice = Choice("Saved action", new[] { "(none)" }.Concat(saved.Keys.Order()));
        if (saved.Count > 0) panel.Children.Add(savedChoice);
        savedChoice.SelectionChanged += (_, _) =>
        {
            if (savedChoice.SelectedItem is not string name || !saved.TryGetValue(name, out var action)) return;
            foreach (var step in steps)
            {
                step.Box.IsChecked = action.ContainsKey(step.Title);
                for (var i = 0; i < step.Options.Length; i++)
                    if (action.TryGetValue($"{step.Title}#{i}", out var value))
                        switch (step.Options[i])
                        {
                            case TextBox text: text.Text = value; break;
                            case ComboBox combo when int.TryParse(value, out var index): combo.SelectedIndex = index; break;
                        }
            }
        };
        foreach (var step in steps)
        {
            step.Box.Content = step.Title;
            panel.Children.Add(step.Box);
            if (step.Options.Length > 0)
            {
                var options = Row(step.Options);
                options.Margin = new Thickness(28, 0, 0, 4);
                options.Visibility = Visibility.Collapsed;
                step.Box.Checked += (_, _) => options.Visibility = Visibility.Visible;
                step.Box.Unchecked += (_, _) => options.Visibility = Visibility.Collapsed;
                panel.Children.Add(options);
            }
        }
        var suffix = Text("Add to file names", "_processed");
        panel.Children.Add(suffix);
        var saveAs = Text("Save these steps as (optional)", "", "e.g. Prepare for web");
        panel.Children.Add(saveAs);
        panel.Children.Add(Note("Tokens: <<filename>>, <<date>>, <<author>>; page numbers also take <<page>> and <<pages>>."));
        if (!await AskAsync("Batch Process", panel, "Choose Output Folder…")) return;
        var chosen = steps.Where(s => s.Box.IsChecked == true).ToList();
        if (chosen.Count == 0) { StatusText.Text = "No steps were chosen."; return; }
        if (saveAs.Text.Trim() is { Length: > 0 } actionName)
        {
            var action = new Dictionary<string, string>();
            foreach (var step in chosen)
            {
                action[step.Title] = "";
                for (var i = 0; i < step.Options.Length; i++)
                    action[$"{step.Title}#{i}"] = step.Options[i] switch { TextBox t => t.Text, ComboBox c => c.SelectedIndex.ToString(), _ => "" };
            }
            AppSettings.Current.SavedActions[actionName] = action;
            AppSettings.Current.Save();
        }
        var folderPicker = new FolderPicker(AppWindow.Id);
        if (await folderPicker.PickSingleFolderAsync() is not { } folder) return;

        var failures = new List<string>();
        var done = 0;
        for (var i = 0; i < files.Count; i++)
        {
            var source = files[i].Path;
            var name = Path.GetFileNameWithoutExtension(source);
            StatusText.Text = $"Processing {i + 1} of {files.Count}: {Path.GetFileName(source)}…";
            var ops = new JsonArray();
            foreach (var step in chosen) foreach (var op in step.Ops(name)) ops.Add(op!.DeepClone());
            string? candidate = null;
            try
            {
                if (ops.Count == 0) throw new InvalidDataException("Nothing to do for this file.");
                candidate = await Engine.TransformAsync(source, ops);
                var destination = UniquePath(Path.Combine(folder.Path, name + suffix.Text + ".pdf"));
                await Engine.PublishAsync(candidate, destination, overwrite: false);
                done++;
            }
            catch (Exception error) when (error is EngineException or IOException or InvalidDataException or UnauthorizedAccessException)
            {
                failures.Add($"{Path.GetFileName(source)}: {error.Message}");
            }
            finally
            {
                if (candidate is not null) TryDelete(candidate);
            }
        }
        StatusText.Text = $"Processed {done} of {files.Count} file{(files.Count == 1 ? "" : "s")} into {folder.Path}.";
        if (failures.Count > 0)
            await AskAsync("Some files weren't processed", Stack(failures.Select(f => (UIElement)new TextBlock { Text = f, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }).ToArray()), "OK");
    }

    private static string UniquePath(string path)
    {
        if (!File.Exists(path)) return path;
        var (folder, name, extension) = (Path.GetDirectoryName(path)!, Path.GetFileNameWithoutExtension(path), Path.GetExtension(path));
        for (var n = 2; ; n++)
            if (Path.Combine(folder, $"{name} {n}{extension}") is var candidate && !File.Exists(candidate)) return candidate;
    }
}
