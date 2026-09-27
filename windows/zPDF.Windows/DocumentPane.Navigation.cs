using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using Windows.Foundation;

namespace zPDF;

public sealed record AttachmentItem(string Id, string Name, string Description, long Size, int? Page)
{
    public override string ToString() => $"{Name}, {Detail}";  // screen readers read list items by ToString
    public string Detail => $"{(Size >= 1 << 20 ? $"{Size / 1048576.0:0.#} MB" : $"{Math.Max(1, Size / 1024)} KB")}{(Page is { } p ? $" · on page {p + 1}" : "")}{(Description.Length > 0 ? $" · {Description}" : "")}";
}

public sealed class LayerItem(string id, string name, bool visible, int depth)
{
    public string Id { get; } = id;
    public string Name { get; } = name;
    public bool Visible { get; set; } = visible;
    public Thickness Indent => new(depth * 16, 0, 0, 0);
    public override string ToString() => $"{Name}, {(Visible ? "shown" : "hidden")}";
}

/// <summary>Links (add, edit, remove), attachments, layers, page labels, page size, PDF/X and PDF/E.</summary>
public sealed partial class DocumentPane
{
    private readonly ObservableCollection<AttachmentItem> _attachments = [];
    private readonly ObservableCollection<LayerItem> _layers = [];
    private readonly Dictionary<int, List<(int Index, double[] Rect, string? Uri, int? Dest)>> _links = [];

    // ---------------------------------------------------------------- links

    private void LinkTool_Click(object sender, RoutedEventArgs e)
    {
        SetTool(_tool == CommentTool.Link ? CommentTool.Select : CommentTool.Link);
        if (_tool == CommentTool.Link) { _ = LoadLinksAsync(_page); ShowTransient("Drag a box to add a link; click an existing link to edit it."); }
        RefreshMarks();
    }

    private async Task LoadLinksAsync(int page)
    {
        if (_links.ContainsKey(page) || CurrentPath is null) return;
        try
        {
            var result = await Engine.QueryAsync(CurrentPath, "links", new JsonObject { ["page"] = page }, _password);
            _links[page] = result["links"]!.AsArray().Select(l => (l!["index"]!.GetValue<int>(), l["rect"]!.AsArray().Select(v => v!.GetValue<double>()).ToArray(),
                                                                 l["uri"]?.GetValue<string>(), l["dest_page"] is JsonValue d && d.TryGetValue<int>(out var p) ? p : (int?)null)).ToList();
            RefreshMarks();
        }
        catch (EngineException) { }
    }

    private IEnumerable<(int Page, Rect Rect)> LinkMarks()
    {
        if (_tool != CommentTool.Link) yield break;
        foreach (var (page, links) in _links)
            if (_infos.GetValueOrDefault(page) is { } info)
                foreach (var link in links) yield return (page, BoxRect(info, link.Rect));
    }

    /// <summary>Link tool: a click on a link edits it; a drag adds one.</summary>
    private async Task LinkGestureAsync(int page, Point from, Point to)
    {
        if (await InfoAsync(page) is not { } info) return;
        await LoadLinksAsync(page);
        var existing = Distance(from, to) < 4
            ? _links.GetValueOrDefault(page)?.LastOrDefault(l => BoxRect(info, l.Rect).Contains(to))
            : null;
        if (Distance(from, to) < 4 && existing is null) return;
        var kind = Choice("Link to", ["A web page or email address", "A page in this document"], existing?.Dest is not null ? 1 : 0);
        var uri = Text("Address", existing?.Uri ?? "https://");
        var target = Number("Page", (existing?.Dest ?? _page) + 1, 1, _document!.PageCount);
        var remove = new CheckBox { Content = "Remove this link", Visibility = existing is null ? Visibility.Collapsed : Visibility.Visible };
        if (!await AskAsync(existing is null ? "Add Link" : "Edit Link", Stack(kind, uri, target, remove), existing is null ? "Add" : "Save")) return;
        _links.Remove(page);
        if (existing is { } link && remove.IsChecked == true)
        {
            await EditDocumentAsync("Removing link…", new JsonObject { ["op"] = "link_remove", ["page"] = page, ["indexes"] = new JsonArray(link.Index) });
            return;
        }
        var op = existing is { } edit
            ? new JsonObject { ["op"] = "link_update", ["page"] = page, ["index"] = edit.Index }
            : new JsonObject { ["op"] = "link_add", ["page"] = page, ["rect"] = ToJson(PdfRect(info, new Rect(from, to))) };
        if (kind.SelectedIndex == 1) op["dest_page"] = (int)Math.Clamp(target.Value, 1, _document.PageCount) - 1;
        else
        {
            var address = uri.Text.Trim();
            if (address.Contains('@') && !address.Contains(':')) address = "mailto:" + address;
            if (!Uri.TryCreate(address, UriKind.Absolute, out var parsed) || parsed.Scheme is not ("http" or "https" or "mailto"))
            {
                StatusText.Text = "Enter a web address (https://…) or an email address.";
                return;
            }
            op["uri"] = parsed.ToString();
        }
        await EditDocumentAsync(existing is null ? "Adding link…" : "Updating link…", op);
    }

    // ---------------------------------------------------------------- attachments

    private async Task RefreshAttachmentsAsync()
    {
        _attachments.Clear();
        if (CurrentPath is null) return;
        try
        {
            var result = await Engine.QueryAsync(CurrentPath, "attachments", password: _password);
            foreach (var item in result["items"]!.AsArray())
                _attachments.Add(new AttachmentItem(item!["id"]!.GetValue<string>(), item["name"]?.GetValue<string>() ?? item["filename"]?.GetValue<string>() ?? "attachment",
                                                    item["description"]?.GetValue<string>() ?? "", item["size"] is JsonValue s && s.TryGetValue<long>(out var n) ? n : 0,
                                                    item["page"] is JsonValue p && p.TryGetValue<int>(out var page) ? page : null));
        }
        catch (EngineException) { }
        SetTabLabel(AttachmentsTab, _attachments.Count > 0 ? $"Attachments ({_attachments.Count})" : "Attachments");
    }

    private async void AddAttachment_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add("*");
        if (await picker.PickSingleFileAsync() is not { } file) return;
        await EditDocumentAsync("Attaching…", new JsonObject { ["op"] = "add_attachment", ["path"] = file.Path, ["name"] = Path.GetFileName(file.Path) });
    }

    private AttachmentItem? SelectedAttachment => AttachmentList.SelectedItem as AttachmentItem;

    private async void SaveAttachment_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedAttachment is not { } item) return;
        var picker = new FileSavePicker(AppWindow.Id) { SuggestedFileName = Path.GetFileNameWithoutExtension(item.Name) };
        var ext = Path.GetExtension(item.Name);
        picker.FileTypeChoices.Add(ext.Length > 0 ? ext.TrimStart('.').ToUpperInvariant() + " file" : "File", [ext.Length > 0 ? ext : ".bin"]);
        if (await picker.PickSaveFileAsync() is not { } file) return;
        await WriteAttachmentAsync(item, file.Path);
        StatusText.Text = $"Saved {Path.GetFileName(file.Path)}";
    }

    private async void OpenAttachment_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedAttachment is not { } item) return;
        if (!await AskAsync($"Open {item.Name}?", new TextBlock { Text = "Attachments can contain harmful software. Open it only if you trust where this PDF came from.", TextWrapping = TextWrapping.Wrap }, "Open")) return;
        var folder = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), $"zpdf-attachment-{Guid.NewGuid():N}")).FullName;
        var path = Path.Combine(folder, Path.GetFileName(item.Name));
        await WriteAttachmentAsync(item, path);
        await Windows.System.Launcher.LaunchFileAsync(await Windows.Storage.StorageFile.GetFileFromPathAsync(path));
    }

    private async Task WriteAttachmentAsync(AttachmentItem item, string path)
    {
        var data = await Engine.QueryAsync(CurrentPath!, "attachment_data", new JsonObject { ["id"] = item.Id }, _password);
        await File.WriteAllBytesAsync(path, Convert.FromBase64String(data["data"]!.GetValue<string>()));
    }

    private async void RemoveAttachment_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedAttachment is not { } item) return;
        await EditDocumentAsync("Removing attachment…", new JsonObject { ["op"] = "remove_attachments", ["ids"] = new JsonArray(item.Id) });
    }

    // ---------------------------------------------------------------- layers

    private async Task RefreshLayersAsync()
    {
        _layers.Clear();
        if (CurrentPath is null) return;
        try
        {
            var result = await Engine.QueryAsync(CurrentPath, "layers", password: _password);
            foreach (var item in result["items"]!.AsArray())
            {
                if (item!["id"] is not JsonValue id) continue;  // group labels
                _layers.Add(new LayerItem(id.ToString(), item["name"]!.GetValue<string>(), item["visible"]?.GetValue<bool>() != false, item["depth"]?.GetValue<int>() ?? 0));
            }
        }
        catch (EngineException) { }
        LayersTab.Visibility = _layers.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void LayerToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (sender is not ToggleSwitch { DataContext: LayerItem layer } toggle || toggle.IsOn == layer.Visible) return;
        layer.Visible = toggle.IsOn;
        await EditDocumentAsync(toggle.IsOn ? "Showing layer…" : "Hiding layer…",
                                new JsonObject { ["op"] = "set_layer_visibility", ["states"] = new JsonObject { [layer.Id] = toggle.IsOn } });
    }

    private async void FlattenLayers_Click(object sender, RoutedEventArgs e)
    {
        if (!await AskAsync("Flatten Layers?", new TextBlock { Text = "Visible layers become ordinary page content and hidden ones are removed.", TextWrapping = TextWrapping.Wrap }, "Flatten")) return;
        await EditDocumentAsync("Flattening layers…", new JsonObject { ["op"] = "flatten_layers" });
    }

    // ---------------------------------------------------------------- page labels, page size, PDF/X, PDF/E

    private async void PageLabels_Click(object sender, RoutedEventArgs e)
    {
        if (_document is null || CurrentPath is null) return;
        var current = (await Engine.QueryAsync(CurrentPath, "page_labels", password: _password))["ranges"]?.AsArray() ?? [];
        var start = Number("Starting at page", _page + 1, 1, _document.PageCount);
        var style = Choice("Style", ["1, 2, 3", "i, ii, iii", "I, II, III", "a, b, c", "A, B, C", "None (prefix only)"]);
        var prefix = Text("Prefix", "");
        var first = Number("First number", 1, 1, 100000);
        var reset = new CheckBox { Content = "Remove all custom page labels instead" };
        if (!await AskAsync("Page Labels", Stack(start, style, prefix, first, reset), "Apply")) return;
        JsonArray ranges;
        if (reset.IsChecked == true) ranges = [];
        else
        {
            var from = (int)start.Value - 1;
            ranges = new JsonArray(current.Where(r => r!["start"]?.GetValue<int>() != from).Select(r => r!.DeepClone()).ToArray());
            ranges.Add(new JsonObject
            {
                ["start"] = from, ["style"] = new[] { "D", "r", "R", "a", "A", null }[Math.Max(0, style.SelectedIndex)],
                ["prefix"] = prefix.Text, ["first"] = (int)first.Value,
            });
        }
        await EditDocumentAsync("Setting page labels…", new JsonObject { ["op"] = "set_page_labels", ["ranges"] = ranges });
    }

    private async void ResizePages_Click(object sender, RoutedEventArgs e)
    {
        var size = Choice("Page size", ["Letter (8.5 × 11 in)", "Legal (8.5 × 14 in)", "Tabloid (11 × 17 in)", "A4", "A3", "A5"]);
        var mode = Choice("Content", ["Scale to fit the new size", "Keep its size (add or trim margins)"]);
        var scope = Scope();
        if (!await AskAsync("Resize Pages", Stack(size, mode, scope), "Resize")) return;
        if (await EditDocumentAsync("Resizing pages…", new JsonObject
        {
            ["op"] = "resize_pages", ["size"] = new[] { "letter", "legal", "tabloid", "a4", "a3", "a5" }[Math.Max(0, size.SelectedIndex)],
            ["mode"] = mode.SelectedIndex == 1 ? "canvas" : "scale", ["pages"] = ScopePages(scope),
        })) StatusText.Text = $"Pages resized to {((string)size.SelectedItem).Split(" (")[0]}. Save to keep the change.";
    }

    private async void ConvertPdfX_Click(object sender, RoutedEventArgs e)
    {
        var note = new TextBlock { Text = "PDF/X-4 for commercial printing: fonts embedded, colours with an output intent (Generic CMYK) and page boxes set.", TextWrapping = TextWrapping.Wrap };
        if (!await AskAsync("Save as PDF/X-4", Stack(note), "Convert")) return;
        if (await EditDocumentAsync("Converting to PDF/X-4…", new JsonObject { ["op"] = "convert_pdfx", ["version"] = "PDF/X-4" }))
            await ReportStandardAsync("PDF/X-4");
    }

    private async void ConvertPdfE_Click(object sender, RoutedEventArgs e)
    {
        if (await EditDocumentAsync("Converting to PDF/E…", new JsonObject { ["op"] = "convert_pdfe" }))
            await ReportStandardAsync("PDF/E-1");
    }

    /// <summary>After a conversion: whether the document now meets `standard` (zPDF's own checks).</summary>
    private async Task ReportStandardAsync(string standard)
    {
        try
        {
            var report = await Engine.QueryAsync(CurrentPath!, "validate_standard", new JsonObject { ["standard"] = standard }, _password);
            var issues = report["issues"]?.AsArray() ?? [];
            StatusText.Text = report["compliant"]?.GetValue<bool>() == true
                ? $"The document now conforms to {standard}. Save to keep it."
                : $"Converted, but {issues.Count} issue{(issues.Count == 1 ? "" : "s")} remain for {standard}: {string.Join("; ", issues.Take(3).Select(IssueText))}";
        }
        catch (EngineException error) { StatusText.Text = error.Message; }
    }
}
