using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace zPDF;

/// <summary>Convert and tools: export, OCR, reduce file size, PDF/A.</summary>
public sealed partial class MainWindow
{
    private static readonly (string Format, string Label, string Extension)[] ExportFormats =
    [
        ("docx", "Word document", ".docx"), ("xlsx", "Excel workbook", ".xlsx"), ("pptx", "PowerPoint presentation", ".pptx"),
        ("html", "Web page (HTML)", ".html"), ("md", "Markdown", ".md"), ("rtf", "Rich Text (RTF)", ".rtf"),
        ("xml", "XML", ".xml"), ("epub", "EPUB book", ".epub"),
    ];

    private async void Export_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string format } || _document is not { } document) return;
        await FlushFieldsAsync();
        if (format is "png" or "jpg") { await ExportImagesAsync(format); return; }
        if (format == "txt") { await ExportTextAsync(); return; }
        var (_, label, extension) = ExportFormats.First(f => f.Format == format);
        var scope = Choice("Pages", document.PageCount > 1 ? ["All pages", "Current page", "Selected pages"] : ["All pages"]);
        var layout = format is "docx" or "html" ? Choice("Layout", ["Flowing (easy to edit)", "Exact (keeps positions)"]) : null;
        var content = layout is null ? Stack(scope) : Stack(scope, layout);
        if (!await AskAsync($"Export to {label}", content, "Export…")) return;
        var pages = scope.SelectedIndex switch { 1 => [_page], 2 => TargetPages(), _ => Enumerable.Range(0, document.PageCount).ToList() };
        var picker = new FileSavePicker(AppWindow.Id) { SuggestedFileName = Path.GetFileNameWithoutExtension(_sourcePath), DefaultFileExtension = extension };
        picker.FileTypeChoices.Add(label, [extension]);
        if (await picker.PickSaveFileAsync() is not { } file) return;
        var options = new JsonObject();
        if (layout is not null) options["layout_mode"] = layout.SelectedIndex == 1 ? "preserve" : "reflow";
        var progress = new Progress<string>(text => StatusText.Text = text);
        var existed = File.Exists(file.Path) && new FileInfo(file.Path).Length > 0;
        var exported = await Run($"Exporting to {label}…", async () =>
        {
            // The exporter reads an unencrypted snapshot of what's on screen.
            var source = CurrentPath!;
            string? snapshot = null;
            if (_password is not null)
            {
                snapshot = await Engine.TransformAsync(source, [new JsonObject { ["op"] = "set_security", ["mode"] = "None" }, new JsonObject { ["op"] = "apply_security" }], _password);
                source = snapshot;
            }
            try
            {
                var result = await Exporter.ExportAsync(source, format, pages, file.Path, options, progress, CancellationToken.None);
                var notes = result.Notices.Count > 0 ? $" — notes: {string.Join(", ", result.Notices)}" : "";
                StatusText.Text = $"Exported {Path.GetFileName(result.Path)} ({result.Bytes / 1024.0:0} KB){notes}";
            }
            finally
            {
                if (snapshot is not null) TryDelete(snapshot);
            }
        }, keepStatus: true);
        // The save picker creates an empty file; don't leave it behind when nothing was exported.
        if (!exported && !existed && File.Exists(file.Path) && new FileInfo(file.Path).Length == 0) TryDelete(file.Path);
    }

    private async Task ExportTextAsync()
    {
        var picker = new FileSavePicker(AppWindow.Id) { SuggestedFileName = Path.GetFileNameWithoutExtension(_sourcePath), DefaultFileExtension = ".txt" };
        picker.FileTypeChoices.Add("Plain text", [".txt"]);
        if (await picker.PickSaveFileAsync() is not { } file || _document is not { } document) return;
        await Run("Exporting text…", async () =>
        {
            var text = new StringBuilder();
            for (var page = 0; page < document.PageCount; page++)
            {
                if (await InfoAsync(page) is { } info) text.Append(info.Text.ReplaceLineEndings(Environment.NewLine));
                text.Append(Environment.NewLine).Append('\f').Append(Environment.NewLine);
            }
            await File.WriteAllTextAsync(file.Path, text.ToString(), new UTF8Encoding(true));
            StatusText.Text = $"Exported {Path.GetFileName(file.Path)}";
        }, keepStatus: true);
    }

    private async Task ExportImagesAsync(string format)
    {
        if (_document is null || CurrentPath is not { } path) return;
        var dpi = Choice("Resolution", ["150 dpi", "300 dpi", "600 dpi", "72 dpi"]);
        var scope = Choice("Pages", ["All pages", "Current page", "Selected pages"]);
        if (!await AskAsync($"Export Pages as {format.ToUpperInvariant()}", Stack(dpi, scope), "Choose Folder…")) return;
        var folderPicker = new FolderPicker(AppWindow.Id);
        if (await folderPicker.PickSingleFolderAsync() is not { } folder) return;
        var resolution = new[] { 150, 300, 600, 72 }[Math.Max(0, dpi.SelectedIndex)];
        var pages = scope.SelectedIndex switch { 1 => [_page], 2 => TargetPages(), _ => Enumerable.Range(0, _document.PageCount).ToList() };
        var stem = Path.GetFileNameWithoutExtension(_sourcePath);
        var password = _password;
        await Run("Exporting images…", async () =>
        {
            var done = 0;
            using var copy = PdfDocument.Open(path, password);
            foreach (var page in pages)
            {
                StatusText.Text = $"Exporting page {page + 1} ({++done} of {pages.Count})…";
                var target = Path.Combine(folder.Path, $"{stem} page {page + 1}.{format}");
                await Task.Run(() => SaveImage(copy.Render(page, resolution / 72.0), target, format, resolution));
            }
            StatusText.Text = $"Exported {pages.Count} image{(pages.Count == 1 ? "" : "s")} to {Path.GetFileName(folder.Path)}";
        }, keepStatus: true);
    }

    private static void SaveImage(RenderedPage page, string path, string format, double dpi = 96)
    {
        using var bitmap = new System.Drawing.Bitmap(page.Width, page.Height, System.Drawing.Imaging.PixelFormat.Format32bppRgb);
        var data = bitmap.LockBits(new System.Drawing.Rectangle(0, 0, page.Width, page.Height), System.Drawing.Imaging.ImageLockMode.WriteOnly,
                                   System.Drawing.Imaging.PixelFormat.Format32bppRgb);
        try
        {
            for (var row = 0; row < page.Height; row++)
                System.Runtime.InteropServices.Marshal.Copy(page.Pixels, row * page.Width * 4, data.Scan0 + row * data.Stride, page.Width * 4);
        }
        finally { bitmap.UnlockBits(data); }
        bitmap.SetResolution((float)dpi, (float)dpi);
        bitmap.Save(path, format == "jpg" ? System.Drawing.Imaging.ImageFormat.Jpeg : System.Drawing.Imaging.ImageFormat.Png);
    }

    // ---------------------------------------------------------------- OCR

    private async void RecognizeText_Click(object sender, RoutedEventArgs e)
    {
        if (_document is not { } document || CurrentPath is not { } path) return;
        var engine = OcrEngine.TryCreateFromUserProfileLanguages();
        if (engine is null)
        {
            StatusText.Text = "Windows has no OCR language installed. Add one in Settings ▸ Time & language ▸ Language.";
            return;
        }
        var all = new CheckBox { Content = "Also pages that already have text" };
        var scope = Choice("Pages", ["All pages", "Current page", "Selected pages"]);
        var note = new TextBlock { Text = $"Recognizes text in scanned pages with Windows ({engine.RecognizerLanguage.DisplayName}) and adds an invisible, searchable text layer.", TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };
        if (!await AskAsync("Recognize Text (OCR)", Stack(note, scope, all), "Recognize")) return;
        var pages = scope.SelectedIndex switch { 1 => [_page], 2 => TargetPages(), _ => Enumerable.Range(0, document.PageCount).ToList() };
        var password = _password;
        await Run("Recognizing text…", async () =>
        {
            var results = new JsonArray();
            using var copy = PdfDocument.Open(path, password);
            var done = 0;
            foreach (var page in pages)
            {
                StatusText.Text = $"Recognizing page {page + 1} ({++done} of {pages.Count})…";
                if (all.IsChecked != true && await InfoAsync(page) is { } existing && existing.Boxes.Count(b => !b.IsEmpty) > 20) continue;
                var (width, height) = copy.PageSize(page);
                var scale = Math.Min(300 / 72.0, (OcrEngine.MaxImageDimension - 1) / Math.Max(width, height));
                var image = await Task.Run(() => copy.Render(page, scale));
                using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(image.Pixels.AsBuffer(), BitmapPixelFormat.Bgra8, image.Width, image.Height, BitmapAlphaMode.Ignore);
                var ocr = await engine.RecognizeAsync(bitmap);
                var lines = new JsonArray();
                foreach (var line in ocr.Lines)
                {
                    var words = new JsonArray();
                    foreach (var word in line.Words)
                    {
                        var r = word.BoundingRect;  // pixels, top-left origin → points in upright page space, bottom-left origin
                        words.Add(new JsonObject
                        {
                            ["t"] = word.Text,
                            ["b"] = new JsonArray(r.X / scale, height - (r.Y + r.Height) / scale, (r.X + r.Width) / scale, height - r.Y / scale),
                        });
                    }
                    if (words.Count > 0) lines.Add(words);
                }
                if (lines.Count > 0) results.Add(new JsonObject { ["page"] = page, ["lines"] = lines });
            }
            if (results.Count == 0) { StatusText.Text = "No text was found to recognize (the pages already have text, or are blank)."; return; }
            var edited = await Engine.TransformAsync(CurrentPath!, [new JsonObject { ["op"] = "ocr_text_layer", ["pages"] = results }], _password);
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
            StatusText.Text = $"Recognized text on {results.Count} page{(results.Count == 1 ? "" : "s")}. It's searchable and selectable now.";
        }, keepStatus: true);
    }

    // ---------------------------------------------------------------- reduce size, PDF/A

    private async void ReduceSize_Click(object sender, RoutedEventArgs e)
    {
        var preset = Choice("Quality", ["High (225 dpi images)", "Medium (150 dpi)", "Small (96 dpi)"], 1);
        var extras = new CheckBox { Content = "Also remove metadata, thumbnails and private data" };
        if (!await AskAsync("Reduce File Size", Stack(preset, extras), "Reduce")) return;
        var before = new FileInfo(CurrentPath!).Length;
        var op = new JsonObject { ["op"] = "optimize", ["preset"] = new[] { "high", "medium", "low" }[Math.Max(0, preset.SelectedIndex)] };
        if (extras.IsChecked == true) op["remove"] = new JsonObject { ["metadata"] = true, ["thumbnails"] = true, ["private_data"] = true };
        if (!await EditDocumentAsync("Reducing file size…", op)) return;
        var after = new FileInfo(CurrentPath!).Length;
        StatusText.Text = after < before
            ? $"Reduced from {FormatSize(before)} to {FormatSize(after)} ({100 - after * 100 / before}% smaller). Save to keep it."
            : extras.IsChecked == true ? "Metadata and private data removed; the file size didn't shrink further. Save to keep it."
            : "This document is already compact; nothing more to reduce.";
    }

    private async void ConvertPdfA_Click(object sender, RoutedEventArgs e)
    {
        var level = Choice("Standard", ["PDF/A-2b (recommended)", "PDF/A-3b (allows attachments)", "PDF/A-2u", "PDF/A-3u"]);
        if (!await AskAsync("Save as PDF/A (archival)", Stack(level, new TextBlock { Text = "Fonts are embedded, colours are given a profile and features PDF/A forbids (scripts, transparency groups without a profile…) are removed. Save afterwards to keep it.", TextWrapping = TextWrapping.Wrap, Opacity = 0.75 }), "Convert")) return;
        var levels = new[] { "2b", "3b", "2u", "3u" };
        var chosen = levels[Math.Max(0, level.SelectedIndex)];
        if (!await EditDocumentAsync("Converting to PDF/A…", new JsonObject { ["op"] = "convert_pdfa", ["level"] = chosen })) return;
        try
        {
            var report = await Engine.QueryAsync(CurrentPath!, "validate_standard", new JsonObject { ["standard"] = $"PDF/A-{chosen}" }, _password);
            if (report["compliant"]?.GetValue<bool>() == true)
            {
                StatusText.Text = $"The document now conforms to PDF/A-{chosen}. Save to keep it.";
                return;
            }
            var issues = report["issues"]?.AsArray() ?? [];
            StatusText.Text = $"Converted, but {issues.Count} issue{(issues.Count == 1 ? "" : "s")} remain for PDF/A-{chosen}. Save to keep the conversion.";
            await AskAsync($"PDF/A-{chosen}: {issues.Count} issue{(issues.Count == 1 ? "" : "s")} remain", Stack(issues.Take(100).Select(i => (UIElement)new TextBlock
            {
                Text = IssueText(i), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
            }).ToArray()), "OK");
        }
        catch (EngineException error) { StatusText.Text = error.Message; }
    }

    private static string IssueText(JsonNode? issue) => issue switch
    {
        JsonValue v => v.ToString(),
        JsonObject o => string.Join(" — ", new[] { o["message"] ?? o["title"], o["rule"] ?? o["clause"], o["detail"] }
                                               .Select(x => x?.ToString()).Where(x => !string.IsNullOrWhiteSpace(x))) is { Length: > 0 } text ? text : o.ToJsonString(),
        _ => "",
    };
}
