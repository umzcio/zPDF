using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace zPDF;

/// <summary>Output: print layouts (booklet, n-up, poster), content scaling, split by size,
/// image and attachment extraction, space usage, OCR text layer, portfolios, comment
/// comparison, measurement export and page transitions.</summary>
public sealed partial class DocumentPane
{
    private string OutputStem => Path.GetFileNameWithoutExtension(_sourcePath) ?? "Document";

    private static string OutputSize(long bytes) => bytes switch
    {
        >= 1 << 20 => $"{bytes / 1048576.0:0.#} MB",
        >= 1024 => $"{bytes / 1024.0:0} KB",
        _ => $"{bytes} B",
    };

    /// <summary>"1–3, 5" for zero-based pages.</summary>
    private static string OutputRanges(IEnumerable<int> pages)
    {
        var parts = new List<string>();
        var sorted = pages.Distinct().Order().ToList();
        for (var i = 0; i < sorted.Count;)
        {
            var j = i;
            while (j + 1 < sorted.Count && sorted[j + 1] == sorted[j] + 1) j++;
            parts.Add(j == i ? $"{sorted[i] + 1}" : $"{sorted[i] + 1}–{sorted[j] + 1}");
            i = j + 1;
        }
        return string.Join(", ", parts);
    }

    private static TextBlock OutputLine(string text, bool bold = false) => new()
    {
        Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
        FontWeight = bold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
    };

    /// <summary>A read-only report; with `action`, true when that button was chosen.</summary>
    private async Task<bool> OutputReportAsync(string title, UIElement content, string? action = null)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = title, CloseButtonText = action is null ? "Done" : "Close",
            Content = new ScrollViewer { Content = content, MaxHeight = 520, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
        };
        if (action is not null) { dialog.PrimaryButtonText = action; dialog.DefaultButton = ContentDialogButton.Primary; }
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private static void OutputDeleteFolder(string folder)
    {
        try { Directory.Delete(folder, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static string OutputSafeName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var clean = new string(Path.GetFileName(name).Select(c => invalid.Contains(c) ? '_' : c).ToArray()).Trim();
        return clean.Length > 0 ? clean : "attachment";
    }

    // ---------------------------------------------------------------- print layouts

    /// <summary>Builds a print copy (the open document is unchanged): prepare comments and
    /// fields, keep the chosen pages, impose, then save and optionally open or print it.</summary>
    private async Task OutputLayoutAsync(string title, string suffix, UIElement[] options, Func<(double Width, double Height), JsonObject> layout)
    {
        if (_document is null || CurrentPath is null) return;
        var paper = Choice("Paper", PaperSizes.Select(p => p.Label));
        var content = Choice("Print", ["Document and markups", "Document (form fields, no comments)", "Document only (no fields or comments)"]);
        var scope = Scope();
        scope.Header = "Pages";
        var then = Choice("After saving", ["Open it", "Print it", "Just save it"]);
        if (!await AskAsync(title, Stack([.. options, paper, content, scope, then]), "Save…")) return;
        var sheet = PaperSizes[Math.Max(0, paper.SelectedIndex)];
        var ops = new JsonArray
        {
            new JsonObject { ["op"] = "print_prepare", ["comments"] = content.SelectedIndex == 0, ["fields"] = content.SelectedIndex < 2 },
        };
        if (ScopePages(scope) is { } pages) ops.Add(new JsonObject { ["op"] = "keep_pages", ["pages"] = pages });
        ops.Add(layout((sheet.Width, sheet.Height)));
        ops.Add(new JsonObject { ["op"] = "finalize" });
        if (await AskSavePathAsync($"{OutputStem} ({suffix})") is not { } destination) return;
        var saved = await Run("Preparing the print layout…", async () =>
        {
            var output = await Engine.TransformAsync(CurrentPath!, ops, _password);
            try { await Engine.PublishAsync(output, destination, overwrite: true); }
            finally { TryDelete(output); }
            StatusText.Text = $"Saved {Path.GetFileName(destination)}";
        }, keepStatus: true);
        if (!saved) return;
        if (then.SelectedIndex == 0) await OpenHereOrNewAsync(destination);
        else if (then.SelectedIndex == 1) await OutputPrintAsync(destination);
    }

    /// <summary>Prints a PDF file (a saved print layout) through the Windows print dialog.</summary>
    private async Task OutputPrintAsync(string path)
    {
        var password = _password;
        int count;
        try { using var probe = PdfDocument.Open(path, password); count = probe.PageCount; }
        catch (Exception error) when (error is IOException or InvalidDataException or PasswordRequiredException)
        {
            StatusText.Text = $"Printing failed: {error.Message}";
            return;
        }
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(Host);
        if (Printing.Ask(hwnd, count, 0) is not { } job) return;
        var total = job.Pages.Count;
        var progress = new Progress<int>(done => StatusText.Text = $"Printing sheet {Math.Min(done + 1, total)} of {total}…");
        try
        {
            await Task.Run(() =>
            {
                using var copy = PdfDocument.Open(path, password);
                Printing.Print(copy, job, Path.GetFileName(path), progress: progress);
            });
            StatusText.Text = total == 1 ? "Sent 1 sheet to the printer" : $"Sent {total} sheets to the printer";
        }
        catch (Exception error) when (error is IOException or InvalidDataException or PasswordRequiredException)
        {
            StatusText.Text = $"Printing failed: {error.Message}";
        }
    }

    private static readonly (string Label, int Cols, int Rows)[] NUpGrids = [("2", 2, 1), ("4", 2, 2), ("6", 3, 2), ("9", 3, 3), ("16", 4, 4)];

    /// <summary>Several pages per sheet (2, 4, 6, 9 or 16), in a chosen order, optionally with borders.</summary>
    private async void NUp_Click(object sender, RoutedEventArgs e)
    {
        var grid = Choice("Pages per sheet", NUpGrids.Select(g => g.Label), 1);
        var order = Choice("Page order", ["Horizontal", "Horizontal reversed", "Vertical", "Vertical reversed"]);
        var borders = new CheckBox { Content = "Print page border" };
        var rotate = new CheckBox { Content = "Auto-rotate the sheet to fit the grid", IsChecked = true };
        await OutputLayoutAsync("Multiple Pages per Sheet", "n-up", [grid, order, borders, rotate], sheet =>
        {
            var (_, cols, rows) = NUpGrids[Math.Max(0, grid.SelectedIndex)];
            return new JsonObject
            {
                ["op"] = "impose_nup", ["cols"] = cols, ["rows"] = rows,
                ["order"] = new[] { "horizontal", "horizontal_reversed", "vertical", "vertical_reversed" }[Math.Max(0, order.SelectedIndex)],
                ["borders"] = borders.IsChecked == true, ["sheet"] = new JsonArray(sheet.Width, sheet.Height), ["auto_rotate"] = rotate.IsChecked == true,
            };
        });
    }

    /// <summary>Saddle-stitch booklet: two pages per landscape side, in folding order.</summary>
    private async void Booklet_Click(object sender, RoutedEventArgs e)
    {
        var binding = Choice("Binding", ["Left", "Right"]);
        await OutputLayoutAsync("Booklet", "booklet", [binding, Note("Print double-sided, flipping on the short edge, then fold and staple. Blank pages are added to make a multiple of four.")], sheet => new JsonObject
        {
            ["op"] = "impose_booklet", ["binding"] = binding.SelectedIndex == 1 ? "right" : "left",
            ["sheet"] = new JsonArray(Math.Max(sheet.Width, sheet.Height), Math.Min(sheet.Width, sheet.Height)),
        });
    }

    /// <summary>Poster: each page enlarged and tiled across several sheets with overlap, cut marks and labels.</summary>
    private async void Poster_Click(object sender, RoutedEventArgs e)
    {
        var scale = Number("Tile scale (%)", 100, 50, 1000, 25);
        var overlap = Number("Overlap (in)", 0.25, 0, 2, 0.125);
        var marks = new CheckBox { Content = "Cut marks", IsChecked = true };
        var labels = new CheckBox { Content = "Labels (row, column, page)", IsChecked = true };
        await OutputLayoutAsync("Poster", "poster", [scale, overlap, marks, labels], sheet => new JsonObject
        {
            ["op"] = "impose_poster", ["tile"] = new JsonArray(sheet.Width, sheet.Height), ["scale"] = Math.Max(1, Finite(scale.Value, 100)),
            ["overlap"] = Math.Max(0, Finite(overlap.Value, 0.25)) * 72, ["cut_marks"] = marks.IsChecked == true, ["labels"] = labels.IsChecked == true,
        });
    }

    /// <summary>Scales the content (and comments) of every page inside unchanged page boxes.</summary>
    private async void ScalePages_Click(object sender, RoutedEventArgs e)
    {
        if (_document is null) return;
        var percent = Number("Scale (%)", 100, 1, 1000, 5);
        var center = new CheckBox { Content = "Keep content centred on the page", IsChecked = true };
        if (!await AskAsync("Scale Page Content", Stack(percent, center, Note("Every page keeps its size. To change the paper size itself, use Resize Pages.")), "Scale")) return;
        await EditDocumentAsync("Scaling pages…", new JsonObject
        {
            ["op"] = "scale_pages", ["percent"] = Math.Clamp(Finite(percent.Value, 100), 1, 1000), ["center"] = center.IsChecked == true,
        });
    }

    // ---------------------------------------------------------------- split by size

    /// <summary>Splits into files under a maximum size (estimated per page; an oversized page is its own file).</summary>
    private async void SplitBySize_Click(object sender, RoutedEventArgs e)
    {
        if (_document is null || CurrentPath is null) return;
        var megabytes = Number("Maximum size (MB)", 5, 0.01, 10000, 0.5);
        if (!await AskAsync("Split by File Size", Stack(megabytes, Note("Sizes are estimated from each page's content; a single page larger than the limit becomes its own file.")), "Choose Folder…")) return;
        JsonArray groups;
        try
        {
            var plan = await Engine.QueryAsync(CurrentPath, "split_by_size", new JsonObject { ["max_bytes"] = (long)(Math.Max(0.01, Finite(megabytes.Value, 5)) * 1_000_000) }, _password);
            groups = plan["groups"]?.AsArray() ?? [];
        }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        if (groups.Count < 2) { await InfoAsync("Split by File Size", "The whole document already fits within that size."); return; }
        if (await new FolderPicker(AppWindow.Id).PickSingleFolderAsync() is not { } folder) return;
        await Run("Splitting…", async () =>
        {
            for (var part = 0; part < groups.Count; part++)
            {
                StatusText.Text = $"Writing part {part + 1} of {groups.Count}…";
                var pages = groups[part]!.AsArray().Select(p => p!.GetValue<int>());
                var output = await Engine.TransformAsync(CurrentPath!, [new JsonObject { ["op"] = "keep_pages", ["pages"] = ToJson(pages) }], _password);
                try { await Engine.PublishAsync(output, UniquePath(Path.Combine(folder.Path, $"{OutputStem} part {part + 1}.pdf")), overwrite: false); }
                finally { TryDelete(output); }
            }
            StatusText.Text = $"Saved {groups.Count} files in {Path.GetFileName(folder.Path)}";
        }, keepStatus: true);
    }

    // ---------------------------------------------------------------- extract images and attachments

    /// <summary>Writes every embedded image, in its original encoding where possible, into a folder.</summary>
    private async void ExtractImages_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        if (await new FolderPicker(AppWindow.Id).PickSingleFolderAsync() is not { } folder) return;
        await Run("Extracting images…", async () =>
        {
            var work = Directory.CreateTempSubdirectory("zpdf-images-").FullName;
            try
            {
                var result = await Engine.QueryAsync(CurrentPath!, "extract_images", new JsonObject { ["directory"] = work }, _password);
                var count = 0;
                foreach (var image in result["images"]?.AsArray() ?? [])
                {
                    if (image?["path"]?.GetValue<string>() is not { } path || !File.Exists(path)) continue;
                    File.Copy(path, UniquePath(Path.Combine(folder.Path, $"{OutputStem}-{Path.GetFileName(path)}")));
                    count++;
                }
                var skipped = result["skipped"]?.GetValue<int>() ?? 0;
                StatusText.Text = count == 0 ? "This document has no extractable images."
                    : $"Saved {count} image{(count == 1 ? "" : "s")} in {Path.GetFileName(folder.Path)}" + (skipped > 0 ? $"; {skipped} couldn't be extracted." : "");
            }
            finally { OutputDeleteFolder(work); }
        }, keepStatus: true);
    }

    /// <summary>Writes every embedded file (portfolio and attachment list) and every page file attachment into a folder.</summary>
    private async void ExtractEmbedded_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        List<string> names;
        List<string> annotIds;
        try
        {
            var files = await Engine.QueryAsync(CurrentPath, "embedded_files", password: _password);
            names = (files["files"]?.AsArray() ?? []).Select(f => f?["name"]?.GetValue<string>()).OfType<string>().ToList();
            var all = await Engine.QueryAsync(CurrentPath, "attachments", password: _password);
            annotIds = (all["items"]?.AsArray() ?? []).Select(i => i?["id"]?.GetValue<string>()).OfType<string>().Where(id => id.StartsWith("annot:")).ToList();
        }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        if (names.Count + annotIds.Count == 0) { await InfoAsync("Extract Attachments", "This document has no embedded files or attachments."); return; }
        if (await new FolderPicker(AppWindow.Id).PickSingleFolderAsync() is not { } folder) return;
        var failures = new List<string>();
        var count = 0;
        await Run("Extracting attachments…", async () =>
        {
            var work = Directory.CreateTempSubdirectory("zpdf-embedded-").FullName;
            try
            {
                foreach (var name in names)
                {
                    try
                    {
                        var result = await Engine.QueryAsync(CurrentPath!, "extract_embedded", new JsonObject { ["name"] = name, ["directory"] = work }, _password);
                        var path = result["path"]!.GetValue<string>();
                        File.Move(path, UniquePath(Path.Combine(folder.Path, OutputSafeName(Path.GetFileName(path)))));
                        count++;
                    }
                    catch (Exception error) when (error is EngineException or IOException or UnauthorizedAccessException) { failures.Add($"{name}: {error.Message}"); }
                }
                foreach (var id in annotIds)
                {
                    try
                    {
                        var data = await Engine.QueryAsync(CurrentPath!, "attachment_data", new JsonObject { ["id"] = id }, _password);
                        var name = OutputSafeName(data["filename"]?.GetValue<string>() ?? "attachment");
                        await File.WriteAllBytesAsync(UniquePath(Path.Combine(folder.Path, name)), Convert.FromBase64String(data["data"]!.GetValue<string>()));
                        count++;
                    }
                    catch (Exception error) when (error is EngineException or IOException or UnauthorizedAccessException or FormatException) { failures.Add($"{id}: {error.Message}"); }
                }
            }
            finally { OutputDeleteFolder(work); }
            StatusText.Text = $"Saved {count} file{(count == 1 ? "" : "s")} in {Path.GetFileName(folder.Path)}";
        }, keepStatus: true);
        if (failures.Count > 0) await OutputReportAsync("Some files weren't extracted", Stack(failures.Select(f => (UIElement)OutputLine(f)).ToArray()));
    }

    // ---------------------------------------------------------------- space usage

    private static readonly Dictionary<string, string> SpaceCategoryNames = new()
    {
        ["images"] = "Images", ["content"] = "Page content", ["fonts"] = "Fonts", ["forms"] = "Form fields",
        ["annotations"] = "Comments", ["bookmarks"] = "Bookmarks", ["structure"] = "Tags (structure)",
        ["metadata"] = "Metadata", ["embedded_files"] = "Attachments", ["color"] = "Colour profiles",
        ["thumbnails"] = "Thumbnails", ["other"] = "Document overhead",
    };

    /// <summary>What takes space in the file (by category), and every image with its pixel size and effective dpi.</summary>
    private async void SpaceUsage_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        JsonNode audit, inventory;
        StatusText.Text = "Measuring space usage…";
        try
        {
            audit = await Engine.QueryAsync(CurrentPath, "space_audit", password: _password);
            inventory = await Engine.QueryAsync(CurrentPath, "image_inventory", password: _password);
        }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        StatusText.Text = "";
        var categories = (audit["categories"] as JsonObject ?? new JsonObject())
            .Select(c => (Key: c.Key, Bytes: c.Value?.GetValue<long>() ?? 0)).Where(c => c.Bytes > 0).OrderByDescending(c => c.Bytes).ToList();
        var total = audit["total"]?.GetValue<long>() ?? categories.Sum(c => c.Bytes);
        var panel = Stack(OutputLine($"File size: {OutputSize(total)}", bold: true));
        foreach (var (key, bytes) in categories)
        {
            var share = total > 0 ? 100.0 * bytes / total : 0;
            panel.Children.Add(new StackPanel
            {
                Spacing = 2,
                Children =
                {
                    OutputLine($"{SpaceCategoryNames.GetValueOrDefault(key, key)} — {OutputSize(bytes)} ({share:0.#}%)"),
                    new ProgressBar { Value = share, Maximum = 100 },
                },
            });
        }
        var images = inventory["images"]?.AsArray() ?? [];
        var dpis = images.Select(i => i?["dpi"] is JsonValue d && d.TryGetValue<int>(out var v) ? v : (int?)null).OfType<int>().ToList();
        panel.Children.Add(OutputLine(images.Count == 0 ? "No images."
            : $"{images.Count} image{(images.Count == 1 ? "" : "s")}" + (dpis.Count > 0 ? $", {dpis.Min()}–{dpis.Max()} dpi effective" : ""), bold: true));
        foreach (var image in images.Take(300))
        {
            if (image is null) continue;
            var filters = image["filters"]?.AsArray().Select(f => f?.GetValue<string>()).OfType<string>().ToList() ?? [];
            var dpi = image["dpi"] is JsonValue d && d.TryGetValue<int>(out var v) ? $", {v} dpi" : "";
            panel.Children.Add(OutputLine($"Page {(image["page"]?.GetValue<int>() ?? 0) + 1}: {image["width"]?.GetValue<int>()} × {image["height"]?.GetValue<int>()} px, " +
                                          $"{image["color"]?.GetValue<string>()}, {image["bits"]?.GetValue<int>()}-bit, " +
                                          $"{(filters.Count > 0 ? string.Join("+", filters) : "uncompressed")}, {OutputSize(image["bytes"]?.GetValue<long>() ?? 0)}{dpi}"));
        }
        if (images.Count > 300) panel.Children.Add(Note($"…and {images.Count - 300} more."));
        await OutputReportAsync("Space Usage", panel);
    }

    // ---------------------------------------------------------------- OCR text layer

    /// <summary>Which pages have text of their own, which need OCR, and which carry a recognized-text layer.</summary>
    private async void TextStatus_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        JsonArray pages;
        try { pages = (await Engine.QueryAsync(CurrentPath, "text_status", password: _password))["pages"]?.AsArray() ?? []; }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        var rows = pages.OfType<JsonNode>().Select(p => (Page: p["page"]!.GetValue<int>(), Chars: p["chars"]?.GetValue<int>() ?? 0,
                                                          Ocr: p["ocr"]?.GetValue<bool>() == true, Images: p["images"]?.GetValue<int>() ?? 0)).ToList();
        var empty = rows.Where(r => r.Chars == 0).Select(r => r.Page).ToList();
        var ocr = rows.Where(r => r.Ocr).Select(r => r.Page).ToList();
        var panel = Stack(OutputLine($"{rows.Count - empty.Count} of {rows.Count} page{(rows.Count == 1 ? " has" : "s have")} text.", bold: true),
                          OutputLine(empty.Count == 0 ? "Every page has text; OCR isn't needed."
                              : $"No text (scanned; use Recognize Text): page{(empty.Count == 1 ? "" : "s")} {OutputRanges(empty)}"),
                          OutputLine(ocr.Count == 0 ? "No recognized-text (OCR) layer." : $"Recognized-text (OCR) layer on page{(ocr.Count == 1 ? "" : "s")} {OutputRanges(ocr)}"));
        if (!await OutputReportAsync("Text Layer", panel, ocr.Count > 0 ? "Remove Recognized Text" : null)) return;
        await EditDocumentAsync("Removing recognized text…", new JsonObject { ["op"] = "remove_ocr_layer" });
    }

    /// <summary>Removes text added by OCR (the scan images stay).</summary>
    private async void RemoveOcrLayer_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        if (!await AskAsync("Remove Recognized Text?", Note("Removes the text layer added by OCR; the scanned page images stay. Text that was in the PDF originally isn't affected."), "Remove")) return;
        if (await EditDocumentAsync("Removing recognized text…", new JsonObject { ["op"] = "remove_ocr_layer" }))
            StatusText.Text = "Recognized text removed. Save to keep the change.";
    }

    // ---------------------------------------------------------------- portfolio

    /// <summary>A PDF Portfolio: a cover page plus the chosen files embedded as a collection.</summary>
    private async void CreatePortfolio_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add("*");
        var picked = await picker.PickMultipleFilesAsync();
        if (picked is not { Count: > 0 }) return;
        var title = Text("Title", "Portfolio");
        var list = string.Join("\n", picked.Take(20).Select(f => "•  " + Path.GetFileName(f.Path))) + (picked.Count > 20 ? $"\n…and {picked.Count - 20} more" : "");
        if (!await AskAsync("Create Portfolio", Stack(title, Note(list)), "Create…")) return;
        var name = title.Text.Trim() is { Length: > 0 } t ? t : "Portfolio";
        await CreateDocumentAsync(OutputSafeName(name), 612, 792,
        [
            new JsonObject
            {
                ["op"] = "create_portfolio", ["title"] = name,
                ["files"] = new JsonArray(picked.Select(f => (JsonNode)new JsonObject { ["path"] = f.Path, ["name"] = Path.GetFileName(f.Path) }).ToArray()),
            },
        ]);
    }

    // ---------------------------------------------------------------- compare comments

    /// <summary>Comments added, removed or changed in this document relative to another version of it.</summary>
    private async void CompareComments_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add(".pdf");
        if (await picker.PickSingleFileAsync() is not { } file) return;
        JsonNode result;
        StatusText.Text = "Comparing comments…";
        try { result = await Engine.QueryAsync(CurrentPath, "compare_comments", new JsonObject { ["other"] = file.Path }, _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        StatusText.Text = "";
        static string Describe(JsonNode item)
        {
            var author = item["author"]?.GetValue<string>() is { Length: > 0 } a ? $" · {a}" : "";
            var contents = item["contents"]?.GetValue<string>() is { Length: > 0 } c ? $": {c}" : "";
            return $"Page {(item["page"]?.GetValue<int>() ?? 0) + 1} · {item["subtype"]?.GetValue<string>()}{author}{contents}";
        }
        var added = result["added"]?.AsArray().OfType<JsonNode>().ToList() ?? [];
        var removed = result["removed"]?.AsArray().OfType<JsonNode>().ToList() ?? [];
        var changed = result["changed"]?.AsArray().OfType<JsonNode>().ToList() ?? [];
        var unchanged = result["unchanged"]?.GetValue<int>() ?? 0;
        var panel = Stack(OutputLine($"Compared with {Path.GetFileName(file.Path)}: {added.Count} added, {removed.Count} removed, {changed.Count} changed, {unchanged} unchanged.", bold: true));
        void Section(string heading, List<JsonNode> items, Func<JsonNode, string> line)
        {
            if (items.Count == 0) return;
            panel.Children.Add(OutputLine(heading, bold: true));
            foreach (var item in items) panel.Children.Add(OutputLine(line(item)));
        }
        Section("Added", added, Describe);
        Section("Removed", removed, Describe);
        Section("Changed", changed, item =>
        {
            var changes = item["changes"]?.AsArray().Select(c => c?.GetValue<string>()).OfType<string>() ?? [];
            var before = (item["before"] as JsonObject ?? new JsonObject())
                .Where(b => b.Value is JsonValue v && v.TryGetValue<string>(out var s) && s.Length > 0)
                .Select(b => $"{b.Key}: {b.Value!.GetValue<string>()}").Order().ToList();
            return $"{Describe(item)} — changed {string.Join(", ", changes)}" + (before.Count > 0 ? $" (was {string.Join("; ", before)})" : "");
        });
        await OutputReportAsync("Compare Comments", panel);
    }

    // ---------------------------------------------------------------- measurements

    /// <summary>The document's measurement annotations, exportable as CSV (like the Mac's MeasurementCSV).</summary>
    private async void Measurements_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        List<JsonNode> items;
        try { items = (await Engine.QueryAsync(CurrentPath, "measurements", password: _password))["items"]?.AsArray().OfType<JsonNode>().ToList() ?? []; }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        if (items.Count == 0) { await InfoAsync("Measurements", "This document has no measurements. Use Measure Distance, Perimeter or Area to add some."); return; }
        static string Kind(JsonNode item) => item["kind"]?.GetValue<string>() is { Length: > 0 } k ? char.ToUpperInvariant(k[0]) + k[1..].ToLowerInvariant() : "";
        var panel = Stack(OutputLine($"{items.Count} measurement{(items.Count == 1 ? "" : "s")}", bold: true));
        foreach (var item in items)
        {
            var ratio = item["ratio"]?.GetValue<string>() is { Length: > 0 } r ? $" (scale {r})" : "";
            var author = item["author"]?.GetValue<string>() is { Length: > 0 } a ? $" · {a}" : "";
            panel.Children.Add(OutputLine($"Page {(item["page"]?.GetValue<int>() ?? 0) + 1} · {Kind(item)} · {item["label"]?.GetValue<string>()}{ratio}{author}"));
        }
        if (!await OutputReportAsync("Measurements", panel, "Export CSV…")) return;
        var save = new FileSavePicker(AppWindow.Id) { SuggestedFileName = $"{OutputStem} measurements", DefaultFileExtension = ".csv" };
        save.FileTypeChoices.Add("CSV (comma-separated values)", [".csv"]);
        if (await save.PickSaveFileAsync() is not { } file) return;
        static string Field(string value) => value.IndexOfAny([',', '"', '\n', '\r']) >= 0 ? "\"" + value.Replace("\"", "\"\"") + "\"" : value;
        var csv = new StringBuilder("Document,Page,Type,Measurement,Scale,Author,Saved in PDF,Points\r\n");
        var document = Path.GetFileName(_sourcePath) ?? "";
        foreach (var item in items)
        {
            var points = string.Join("; ", (item["points"]?.AsArray() ?? []).OfType<JsonArray>().Where(p => p.Count >= 2)
                .Select(p => FormattableString.Invariant($"{p[0]!.GetValue<double>():0.00} {p[p.Count - 1]!.GetValue<double>():0.00}")));
            string[] row = [document, $"{(item["page"]?.GetValue<int>() ?? 0) + 1}", Kind(item), item["label"]?.GetValue<string>() ?? "",
                            item["ratio"]?.GetValue<string>() ?? "", item["author"]?.GetValue<string>() ?? "", "Yes", points];
            csv.Append(string.Join(",", row.Select(Field))).Append("\r\n");
        }
        try
        {
            await File.WriteAllTextAsync(file.Path, csv.ToString(), new UTF8Encoding(true));
            StatusText.Text = $"Saved {Path.GetFileName(file.Path)}";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { StatusText.Text = error.Message; }
    }

    // ---------------------------------------------------------------- page transitions

    private static readonly string[] TransitionStyles = ["None", "Dissolve", "Fade", "Wipe", "Push", "Cover", "Uncover", "Split", "Blinds", "Box", "Glitter", "Fly"];
    private static readonly string[] DirectionalTransitions = ["Wipe", "Push", "Cover", "Uncover", "Glitter", "Fly"];

    /// <summary>Full-screen presentation effects between pages, with optional auto-advance.</summary>
    private async void PageTransitions_Click(object sender, RoutedEventArgs e)
    {
        if (_document is null || CurrentPath is null) return;
        JsonNode? current = null;
        try { current = (await Engine.QueryAsync(CurrentPath, "page_transitions", password: _password))["pages"]?.AsArray().ElementAtOrDefault(_page); }
        catch (EngineException) { }
        var styleIndex = Math.Max(0, Array.IndexOf(TransitionStyles, current?["style"]?.GetValue<string>() ?? "Dissolve"));
        var duration = current?["duration"]?.GetValue<double>() ?? 1.0;
        var advanceSeconds = current?["advance"]?.GetValue<double>();
        var style = Choice("Transition", TransitionStyles, styleIndex);
        var direction = Choice("Direction", ["Left to right", "Bottom to top", "Right to left", "Top to bottom"]);
        var speed = Choice("Speed", ["Slow", "Medium", "Fast"], duration >= 1.5 ? 0 : duration <= 0.75 ? 2 : 1);
        var advance = new CheckBox { Content = "Advance automatically", IsChecked = advanceSeconds is not null };
        var seconds = Number("Seconds before advancing", advanceSeconds ?? 5, 0.5, 3600, 1);
        var scope = Scope();
        void Update()
        {
            var name = TransitionStyles[Math.Max(0, style.SelectedIndex)];
            direction.IsEnabled = DirectionalTransitions.Contains(name);
            speed.IsEnabled = advance.IsEnabled = name != "None";
            seconds.IsEnabled = name != "None" && advance.IsChecked == true;
        }
        style.SelectionChanged += (_, _) => Update();
        advance.Checked += (_, _) => Update();
        advance.Unchecked += (_, _) => Update();
        Update();
        if (!await AskAsync("Page Transitions", Stack(Note("Transitions play when the PDF is presented full screen in readers that support them."),
                                                        style, direction, speed, advance, seconds, scope), "Apply")) return;
        var chosen = TransitionStyles[Math.Max(0, style.SelectedIndex)];
        var op = new JsonObject { ["op"] = "set_transitions", ["duration"] = new[] { 2.0, 1.0, 0.5 }[Math.Max(0, speed.SelectedIndex)] };
        if (chosen != "None") op["style"] = chosen;
        if (DirectionalTransitions.Contains(chosen)) op["direction"] = new[] { 0, 90, 180, 270 }[Math.Max(0, direction.SelectedIndex)];
        if (chosen != "None" && advance.IsChecked == true && Finite(seconds.Value, 0) > 0) op["advance"] = seconds.Value;
        if (ScopePages(scope) is { } pages) op["pages"] = pages;
        if (await EditDocumentAsync(chosen == "None" ? "Removing page transitions…" : "Setting page transitions…", op))
            StatusText.Text = chosen == "None" ? "Page transitions removed. Save to keep the change." : "Page transitions set. Save to keep them.";
    }
}
