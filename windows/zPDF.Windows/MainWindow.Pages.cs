using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;

namespace zPDF;

/// <summary>Page and document tools: insert, replace, duplicate, crop, header &amp;
/// footer, Bates numbering, watermark, background, extract, split and combine.</summary>
public sealed partial class MainWindow
{
    // ---------------------------------------------------------------- small dialog helpers

    private static NumberBox Number(string header, double value, double min, double max, double step = 1) => new()
    {
        Header = header, Value = value, Minimum = min, Maximum = max, SmallChange = step, LargeChange = step * 10,
        SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, MinWidth = 120,
    };

    private static TextBox Text(string header, string value = "", string placeholder = "") =>
        new() { Header = header, Text = value, PlaceholderText = placeholder, MinWidth = 160 };

    private static ComboBox Choice(string header, IEnumerable<string> items, int selected = 0)
    {
        var combo = new ComboBox { Header = header, ItemsSource = items.ToList(), SelectedIndex = selected, MinWidth = 160 };
        return combo;
    }

    /// <summary>Which pages a design/crop tool applies to.</summary>
    private ComboBox Scope() => Choice("Apply to", _document is { PageCount: > 1 }
        ? ["All pages", "Current page", "Selected pages"] : ["All pages"]);

    private JsonNode? ScopePages(ComboBox scope) => scope.SelectedIndex switch
    {
        1 => new JsonArray(_page),
        2 => ToJson(TargetPages()),
        _ => null,
    };

    private async Task<bool> AskAsync(string title, UIElement content, string action)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = title, PrimaryButtonText = action, CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            Content = new ScrollViewer { Content = content, MaxHeight = 520, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private static StackPanel Stack(params UIElement[] children)
    {
        var stack = new StackPanel { Spacing = 12, MinWidth = 360 };
        foreach (var child in children) stack.Children.Add(child);
        return stack;
    }

    private static StackPanel Row(params UIElement[] children)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        foreach (var child in children) row.Children.Add(child);
        return row;
    }

    /// <summary>One edit of the open document as one undo step.</summary>
    private Task EditDocumentAsync(string status, JsonObject op, int? focus = null) =>
        ApplyAsync(status, op, focus is { } f ? [f] : [_page], focus);

    // ---------------------------------------------------------------- Pages menu

    private void InsertBlank_Click(object sender, RoutedEventArgs e) =>
        _ = EditDocumentAsync("Inserting a page…", new JsonObject { ["op"] = "insert_blank_pages", ["at"] = _page + 1, ["like"] = _page }, _page + 1);

    private async void InsertFromFile_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add(".pdf");
        if (await picker.PickSingleFileAsync() is not { } file) return;
        var where = Choice("Insert", ["After the current page", "Before the current page", "At the end", "At the beginning"]);
        if (!await AskAsync($"Insert {Path.GetFileName(file.Path)}", Stack(where), "Insert")) return;
        var at = where.SelectedIndex switch { 1 => _page, 2 => _document!.PageCount, 3 => 0, _ => _page + 1 };
        await EditDocumentAsync("Inserting pages…", new JsonObject { ["op"] = "insert_pages", ["path"] = file.Path, ["at"] = at }, at);
    }

    private async void InsertImages_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        foreach (var type in new[] { ".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif" }) picker.FileTypeFilter.Add(type);
        var files = await picker.PickMultipleFilesAsync();
        if (files is not { Count: > 0 }) return;
        var at = _page + 1;
        await EditDocumentAsync(files.Count == 1 ? "Inserting an image…" : $"Inserting {files.Count} images…", new JsonObject
        {
            ["op"] = "insert_images", ["images"] = ToJson(files.Select(f => f.Path)), ["at"] = at, ["page_size"] = "letter",
        }, at);
    }

    private async void ReplacePages_Click(object sender, RoutedEventArgs e)
    {
        var targets = TargetPages();
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add(".pdf");
        if (await picker.PickSingleFileAsync() is not { } file) return;
        var first = Number("Starting with page", 1, 1, 9999);
        var label = targets.Count == 1 ? $"page {targets[0] + 1}" : $"{targets.Count} selected pages";
        if (!await AskAsync($"Replace {label}", Stack(new TextBlock { Text = $"Replace {label} with pages of {Path.GetFileName(file.Path)}.", TextWrapping = TextWrapping.Wrap }, first), "Replace")) return;
        var start = (int)first.Value - 1;
        await EditDocumentAsync("Replacing pages…", new JsonObject
        {
            ["op"] = "replace_pages", ["path"] = file.Path, ["targets"] = ToJson(targets),
            ["source_pages"] = ToJson(Enumerable.Range(start, targets.Count)),
        }, targets[0]);
    }

    private void DuplicatePages_Click(object sender, RoutedEventArgs e)
    {
        var pages = TargetPages();
        _ = EditDocumentAsync("Duplicating…", new JsonObject { ["op"] = "duplicate_pages", ["pages"] = ToJson(pages) }, pages[^1] + 1);
    }

    private async void CropPages_Click(object sender, RoutedEventArgs e)
    {
        var top = Number("Top (in)", 0, 0, 20, 0.05);
        var bottom = Number("Bottom (in)", 0, 0, 20, 0.05);
        var left = Number("Left (in)", 0, 0, 20, 0.05);
        var right = Number("Right (in)", 0, 0, 20, 0.05);
        var white = new CheckBox { Content = "Remove white margins instead" };
        var reset = new CheckBox { Content = "Undo earlier cropping (show the whole page)" };
        var scope = Scope();
        if (!await AskAsync("Crop Pages", Stack(Row(top, bottom), Row(left, right), white, reset, scope), "Crop")) return;
        var op = new JsonObject { ["op"] = "crop_pages", ["pages"] = ScopePages(scope) };
        if (reset.IsChecked == true) op["reset"] = true;
        else if (white.IsChecked == true) op["remove_white_margins"] = true;
        else op["margins"] = ToJson(new[] { left.Value, bottom.Value, right.Value, top.Value }.Select(v => double.IsNaN(v) ? 0 : v * 72));
        await EditDocumentAsync("Cropping…", op);
    }

    // ---------------------------------------------------------------- Page Design menu

    private async void HeaderFooter_Click(object sender, RoutedEventArgs e)
    {
        var positions = new[] { "top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right" };
        var boxes = positions.Select(p => Text(p.Replace('-', ' ').Replace("top", "Header").Replace("bottom", "Footer"))).ToArray();
        boxes[4].Text = "Page <<page>> of <<pages>>";
        var size = Number("Font size", 10, 4, 72);
        var scope = Scope();
        var help = new TextBlock
        {
            Text = "Use <<page>>, <<pages>> and <<date>> for the page number, page count and today's date.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.75,
        };
        if (!await AskAsync("Header & Footer", Stack(help, Row(boxes[0], boxes[1], boxes[2]), Row(boxes[3], boxes[4], boxes[5]), size, scope), "Apply")) return;
        var items = new JsonObject();
        for (var i = 0; i < positions.Length; i++) if (boxes[i].Text.Trim().Length > 0) items[positions[i]] = boxes[i].Text;
        if (items.Count == 0) { StatusText.Text = "Type something for at least one position."; return; }
        await EditDocumentAsync("Adding header & footer…", new JsonObject
        {
            ["op"] = "header_footer", ["items"] = items, ["size"] = size.Value, ["pages"] = ScopePages(scope),
        });
    }

    private async void Bates_Click(object sender, RoutedEventArgs e)
    {
        var prefix = Text("Prefix", "", "e.g. ABC-");
        var suffix = Text("Suffix");
        var start = Number("Start at", 1, 0, 999999999);
        var digits = Number("Digits", 6, 1, 12);
        var anchor = Choice("Position", ["Bottom right", "Bottom center", "Bottom left", "Top right", "Top center", "Top left"]);
        if (!await AskAsync("Bates Numbering", Stack(Row(prefix, suffix), Row(start, digits), anchor), "Apply")) return;
        var anchors = new[] { "bottom-right", "bottom-center", "bottom-left", "top-right", "top-center", "top-left" };
        await EditDocumentAsync("Numbering pages…", new JsonObject
        {
            ["op"] = "bates", ["prefix"] = prefix.Text, ["suffix"] = suffix.Text, ["start"] = (int)start.Value,
            ["digits"] = (int)digits.Value, ["anchor"] = anchors[Math.Max(0, anchor.SelectedIndex)],
        });
    }

    private async void WatermarkOptions_Click(object sender, RoutedEventArgs e)
    {
        var text = Text("Text", "DRAFT");
        var size = Number("Size", 72, 6, 400);
        var angle = Number("Angle (°)", 45, -180, 180, 5);
        var opacity = Number("Opacity (%)", 30, 5, 100, 5);
        var colour = Choice("Colour", Palette.Select(p => p.Name), 4);
        var behind = new CheckBox { Content = "Behind the page content" };
        var scope = Scope();
        if (!await AskAsync("Watermark", Stack(text, Row(size, angle), Row(opacity, colour), behind, scope), "Apply")) return;
        if (text.Text.Trim().Length == 0) return;
        var c = Palette[Math.Max(0, colour.SelectedIndex)].Color;
        await EditDocumentAsync("Adding watermark…", new JsonObject
        {
            ["op"] = "watermark", ["text"] = text.Text, ["size"] = size.Value, ["angle"] = angle.Value,
            ["opacity"] = opacity.Value / 100, ["color"] = new JsonArray(c.R, c.G, c.B), ["under"] = behind.IsChecked == true,
            ["pages"] = ScopePages(scope),
        });
    }

    private async void RemoveWatermarks_Click(object sender, RoutedEventArgs e) =>
        await EditDocumentAsync("Removing watermarks…", new JsonObject { ["op"] = "remove_overlays", ["kind"] = "Watermark" });

    private async void Background_Click(object sender, RoutedEventArgs e)
    {
        var colour = Choice("Colour", ["Light yellow", "Light blue", "Light green", "Light grey", "Cream"]);
        var scope = Scope();
        if (!await AskAsync("Page Background", Stack(colour, scope), "Apply")) return;
        var colours = new[] { new[] { 255, 252, 220 }, [225, 238, 255], [228, 247, 228], [238, 238, 238], [253, 246, 227] };
        await EditDocumentAsync("Adding background…", new JsonObject
        {
            ["op"] = "background", ["color"] = new JsonArray(colours[Math.Max(0, colour.SelectedIndex)].Select(v => (JsonNode)v).ToArray()),
            ["pages"] = ScopePages(scope),
        });
    }

    // ---------------------------------------------------------------- Document menu (new files)

    private async Task<string?> AskSavePathAsync(string suggested)
    {
        var picker = new FileSavePicker(AppWindow.Id) { SuggestedFileName = suggested, DefaultFileExtension = ".pdf" };
        picker.FileTypeChoices.Add("PDF document", [".pdf"]);
        return (await picker.PickSaveFileAsync())?.Path;
    }

    private async void ExtractPages_Click(object sender, RoutedEventArgs e)
    {
        var pages = TargetPages();
        var name = $"{Path.GetFileNameWithoutExtension(_sourcePath)} ({(pages.Count == 1 ? $"page {pages[0] + 1}" : $"{pages.Count} pages")})";
        if (await AskSavePathAsync(name) is not { } destination) return;
        await Run("Extracting pages…", async () =>
        {
            var output = await Engine.TransformAsync(CurrentPath!, [new JsonObject { ["op"] = "keep_pages", ["pages"] = ToJson(pages) }], _password);
            await Engine.PublishAsync(output, destination, overwrite: true);
            TryDelete(output);
            StatusText.Text = $"Saved {Path.GetFileName(destination)}";
        }, keepStatus: true);
    }

    private async void SplitDocument_Click(object sender, RoutedEventArgs e)
    {
        if (_document is not { } document) return;
        var every = Number("Pages per file", Math.Max(1, Math.Min(10, document.PageCount / 2)), 1, Math.Max(1, document.PageCount));
        if (!await AskAsync("Split Document", Stack(new TextBlock { Text = $"{document.PageCount} pages into files of:", TextWrapping = TextWrapping.Wrap }, every), "Choose Folder…")) return;
        var folderPicker = new FolderPicker(AppWindow.Id);
        if (await folderPicker.PickSingleFolderAsync() is not { } folder) return;
        var size = Math.Max(1, (int)every.Value);
        var count = (document.PageCount + size - 1) / size;
        var stem = Path.GetFileNameWithoutExtension(_sourcePath);
        await Run("Splitting…", async () =>
        {
            for (var part = 0; part < count; part++)
            {
                StatusText.Text = $"Writing part {part + 1} of {count}…";
                var pages = Enumerable.Range(part * size, Math.Min(size, document.PageCount - part * size));
                var output = await Engine.TransformAsync(CurrentPath!, [new JsonObject { ["op"] = "keep_pages", ["pages"] = ToJson(pages) }], _password);
                await Engine.PublishAsync(output, Path.Combine(folder.Path, $"{stem} part {part + 1}.pdf"), overwrite: false);
                TryDelete(output);
            }
            StatusText.Text = $"Saved {count} files in {Path.GetFileName(folder.Path)}";
        }, keepStatus: true);
    }

    private async void CombineFiles_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add(".pdf");
        var picked = await picker.PickMultipleFilesAsync();
        if (picked is not { Count: > 0 }) return;
        var files = new List<string>();
        if (CurrentPath is not null) files.Add(CurrentPath);
        files.AddRange(picked.Select(f => f.Path));
        var order = new ListView { SelectionMode = ListViewSelectionMode.Single, CanReorderItems = true, AllowDrop = true, MaxHeight = 320 };
        var names = files.Select((f, i) => i == 0 && CurrentPath is not null ? $"{Path.GetFileName(_sourcePath)} (open document)" : Path.GetFileName(f)).ToList();
        var items = new System.Collections.ObjectModel.ObservableCollection<string>(names);
        order.ItemsSource = items;
        var includeOpen = new CheckBox { Content = "Include the open document", IsChecked = CurrentPath is not null, IsEnabled = CurrentPath is not null };
        if (!await AskAsync("Combine Files", Stack(new TextBlock { Text = "Drag to change the order.", Opacity = 0.75 }, order, includeOpen), "Combine…")) return;
        var ordered = items.Select(n => files[names.IndexOf(n)])
                           .Where(f => includeOpen.IsChecked == true || f != CurrentPath).ToList();
        if (ordered.Count < 2) { StatusText.Text = "Choose at least two PDFs to combine."; return; }
        if (await AskSavePathAsync("Combined") is not { } destination) return;
        await Run("Combining…", async () =>
        {
            var ops = new JsonArray();
            foreach (var path in ordered.Skip(1)) ops.Add(new JsonObject { ["op"] = "insert_pages", ["path"] = path });
            var first = ordered[0];
            var output = await Engine.TransformAsync(first, ops, first == CurrentPath ? _password : null);
            await Engine.PublishAsync(output, destination, overwrite: true);
            TryDelete(output);
            StatusText.Text = $"Saved {Path.GetFileName(destination)}";
        }, keepStatus: true);
    }
}
