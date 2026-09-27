using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Windows.Storage.Pickers;
using Windows.Foundation;
using Windows.System;

namespace zPDF;

/// <summary>A text block or page object from the engine's page_content query.</summary>
public sealed record ContentItem(int Page, string Kind, string Id, int? Block, double[] Box, string Text, JsonNode? Runs, string Align);

/// <summary>Editing page content: text blocks in place, moving/arranging/deleting
/// objects, adding text and images, and find &amp; replace in the content.</summary>
public sealed partial class MainWindow
{
    private readonly Dictionary<int, (string Digest, List<ContentItem> Items)> _content = [];
    private int _contentGeneration;
    private ContentItem? _contentSelection;
    private ContentItem? _contentEditing;
    private PageSlot? _contentEditorSlot;
    private Point _contentMoveStart;
    private bool _contentMoving;
    private PageSlot? _contentPressSlot;
    private string? _pendingImageFile;

    private bool IsEditingContent => _tool is CommentTool.EditContent;

    private void EditContent_Click(object sender, RoutedEventArgs e)
    {
        SetTool(_tool == CommentTool.EditContent ? CommentTool.Select : CommentTool.EditContent);
        if (IsEditingContent)
        {
            _ = LoadContentAsync(_page);
            ShowTransient("Click text to edit it; click an image or drawing to select it. Esc when done.");
        }
        RefreshMarks();
    }

    /// <summary>Called whenever the document changes: page content must be re-read.</summary>
    private void ResetContent()
    {
        _content.Clear();
        _contentGeneration++;
        _contentSelection = null;
        CloseContentEditor(commit: false);
    }

    private async Task<List<ContentItem>?> LoadContentAsync(int page)
    {
        if (_content.TryGetValue(page, out var cached)) return cached.Items;
        var generation = _contentGeneration;
        if (CurrentPath is not { } path) return null;
        JsonNode result;
        try { result = await Engine.QueryAsync(path, "page_content", new JsonObject { ["pages"] = new JsonArray(page) }, _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return null; }
        if (generation != _contentGeneration) return null;
        var data = result["pages"]![0]!;
        var items = new List<ContentItem>();
        foreach (var block in data["blocks"]!.AsArray())
        {
            if (block!["editable"]?.GetValue<bool>() == false) continue;
            items.Add(new ContentItem(page, "text", $"block:{block["id"]}", block["id"]!.GetValue<int>(),
                                      block["bbox"]!.AsArray().Select(v => v!.GetValue<double>()).ToArray(), block["text"]?.GetValue<string>() ?? "",
                                      block["runs"]?.DeepClone(), block["align"]?.GetValue<string>() ?? "left"));
        }
        foreach (var obj in data["objects"]!.AsArray())
        {
            if (obj!["movable"]?.GetValue<bool>() == false) continue;
            items.Add(new ContentItem(page, obj["kind"]!.GetValue<string>(), obj["id"]!.GetValue<string>(), null,
                                      obj["bbox"]!.AsArray().Select(v => v!.GetValue<double>()).ToArray(), "", null, "left"));
        }
        _content[page] = (data["digest"]!.GetValue<string>(), items);
        RefreshMarks();
        return items;
    }

    private static Rect BoxRect(PageInfo info, double[] box) =>
        info.ToView(new Rect(new Point(box[0], box[1]), new Point(box[2], box[3])));

    private ContentItem? ContentAt(int page, Point point)
    {
        if (!_content.TryGetValue(page, out var content) || Info(page) is not { } info) return null;
        // Text first; then the smallest object under the point (images over large background paths).
        var text = content.Items.Where(i => i.Kind == "text").FirstOrDefault(i => Inflate(BoxRect(info, i.Box), 2).Contains(point));
        if (text is not null) return text;
        return content.Items.Where(i => i.Kind != "text" && Inflate(BoxRect(info, i.Box), 2).Contains(point))
                            .OrderBy(i => (i.Box[2] - i.Box[0]) * (i.Box[3] - i.Box[1])).FirstOrDefault();
    }

    private static Rect Inflate(Rect r, double by) => new(r.X - by, r.Y - by, r.Width + 2 * by, r.Height + 2 * by);

    /// <summary>Dotted outlines of editable text (and images) while editing, plus the selection.</summary>
    private IEnumerable<(int Page, Rect Rect, Mark Mark)> ContentMarks()
    {
        if (!IsEditingContent) yield break;
        foreach (var (page, (_, items)) in _content)
        {
            if (_infos.GetValueOrDefault(page) is not { } info) continue;
            foreach (var item in items.Where(i => i.Kind is "text" or "image"))
                yield return (page, BoxRect(info, item.Box), Mark.ContentOutline);
        }
        if (_contentSelection is { } sel && _infos.GetValueOrDefault(sel.Page) is { } selInfo)
            yield return (sel.Page, Inflate(BoxRect(selInfo, sel.Box), 2), Mark.CommentSelection);
    }

    // ---------------------------------------------------------------- pointer

    private bool ContentPointerPressed(PageSlot slot, Point point)
    {
        if (!IsEditingContent) return false;
        CloseContentEditor(commit: true);
        if (!_content.ContainsKey(slot.Index)) { _ = LoadContentAsync(slot.Index); return true; }
        var hit = ContentAt(slot.Index, point);
        if (hit is { Kind: "text" })
        {
            _contentSelection = null;
            OpenContentEditor(slot, hit);
            return true;
        }
        _contentSelection = hit;
        _contentPressSlot = hit is null ? null : slot;
        _contentMoveStart = point;
        _contentMoving = false;
        RefreshMarks();
        UpdateContentCommands();
        return true;
    }

    private bool ContentPointerMoved(PageSlot slot, Point point)
    {
        if (!IsEditingContent || _contentPressSlot is not { } pressSlot || _contentSelection is not { } sel || Info(sel.Page) is not { } info) return IsEditingContent;
        if (!_contentMoving && Distance(point, _contentMoveStart) < 3) return true;
        _contentMoving = true;
        var rect = BoxRect(info, sel.Box);
        var (dx, dy) = (point.X - _contentMoveStart.X, point.Y - _contentMoveStart.Y);
        pressSlot.SetDraft(new Draft(DraftShape.Rectangle, [new Point(rect.Left + dx, rect.Top + dy), new Point(rect.Right + dx, rect.Bottom + dy)],
                                     Microsoft.UI.ColorHelper.FromArgb(255, 0, 103, 192)));
        return true;
    }

    private bool ContentPointerReleased(PageSlot slot, Point point)
    {
        if (!IsEditingContent) return false;
        if (_contentPressSlot is { } pressSlot)
        {
            pressSlot.SetDraft(null);
            _contentPressSlot = null;
            if (_contentMoving && _contentSelection is { } sel && Info(sel.Page) is { } info)
            {
                _contentMoving = false;
                var from = info.ToPage(_contentMoveStart);
                var to = info.ToPage(point);
                _ = EditContentAsync("Moving…", sel.Page, new JsonObject
                {
                    ["op"] = "object_transform", ["ids"] = new JsonArray(sel.Id),
                    ["matrix"] = new JsonArray(1, 0, 0, 1, Math.Round(to.X - from.X, 3), Math.Round(to.Y - from.Y, 3)),
                });
            }
        }
        return true;
    }

    // ---------------------------------------------------------------- editing text in place

    private void OpenContentEditor(PageSlot slot, ContentItem block)
    {
        if (Info(block.Page) is not { } info) return;
        var rect = Inflate(BoxRect(info, block.Box), 2);
        var size = block.Runs?.AsArray().FirstOrDefault()?["size"]?.GetValue<double>() ?? 11;
        var box = new TextBox
        {
            Text = block.Text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 0, MinWidth = 0,
            Padding = new Thickness(2, 0, 2, 0), FontSize = Math.Clamp(size * slot.Width / slot.PointWidth, 8, 72),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, "Edit text");
        box.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Escape) { CloseContentEditor(commit: false); e.Handled = true; }
            else if (e.Key == VirtualKey.Enter && InputKeyboardSourceIsControlDown()) { CloseContentEditor(commit: true); e.Handled = true; }
        };
        box.LostFocus += (_, _) => DispatcherQueue.TryEnqueue(() => { if (_contentEditing == block) CloseContentEditor(commit: true); });
        _contentEditing = block;
        _contentEditorSlot = slot;
        slot.SetEditor(box, new Rect(rect.X, rect.Y, Math.Max(rect.Width, 60), Math.Max(rect.Height, 16)));
        DispatcherQueue.TryEnqueue(() => box.Focus(FocusState.Programmatic));
        StatusText.Text = "Editing text — click outside or press Ctrl+Enter to finish, Esc to cancel.";
    }

    private static bool InputKeyboardSourceIsControlDown() =>
        Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void CloseContentEditor(bool commit)
    {
        if (_contentEditing is not { } block || _contentEditorSlot is not { } slot) return;
        var text = (slot.Editor.Element as TextBox)?.Text ?? block.Text;
        _contentEditing = null;
        _contentEditorSlot = null;
        slot.SetEditor(null, null);
        StatusText.Text = "";
        if (!commit || text == block.Text) return;
        var first = block.Runs?.AsArray().FirstOrDefault();
        var run = new JsonObject
        {
            ["text"] = text, ["size"] = first?["size"]?.GetValue<double>() ?? 11,
            ["color"] = first?["color"]?.DeepClone() ?? new JsonArray(0, 0, 0),
            ["font"] = new JsonObject { ["original"] = first?["font"]?.GetValue<string>() },
        };
        _ = EditContentAsync("Updating text…", block.Page, new JsonObject
        {
            ["op"] = "edit_text_block", ["block"] = block.Block, ["runs"] = new JsonArray(run), ["align"] = block.Align,
        });
    }

    /// <summary>One content edit (with the page's digest, so a stale view is refused).</summary>
    private Task EditContentAsync(string status, int page, JsonObject op)
    {
        if (!_content.TryGetValue(page, out var content)) return Task.CompletedTask;
        op["page"] = page;
        op["digest"] = content.Digest;
        return Run(status, async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [op], _password);
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
            if (IsEditingContent) _ = LoadContentAsync(page);
        });
    }

    // ---------------------------------------------------------------- object commands

    private void UpdateContentCommands()
    {
        var selected = IsEditingContent && _contentSelection is not null;
        ObjectCommands.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
        ReplaceImageButton.Visibility = _contentSelection?.Kind == "image" ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ObjectArrange_Click(object sender, RoutedEventArgs e)
    {
        if (_contentSelection is not { } sel || sender is not FrameworkElement { Tag: string how }) return;
        var op = how is "front" or "back"
            ? new JsonObject { ["op"] = "object_arrange", ["ids"] = new JsonArray(sel.Id), ["to"] = how }
            : new JsonObject { ["op"] = "object_step", ["ids"] = new JsonArray(sel.Id), ["direction"] = how };
        _ = EditContentAsync("Arranging…", sel.Page, op);
    }

    private void ObjectDelete_Click(object sender, RoutedEventArgs e) => DeleteSelectedObject();

    private bool DeleteSelectedObject()
    {
        if (!IsEditingContent || _contentSelection is not { } sel) return false;
        _contentSelection = null;
        UpdateContentCommands();
        _ = EditContentAsync("Deleting…", sel.Page, new JsonObject { ["op"] = "object_delete", ["ids"] = new JsonArray(sel.Id) });
        return true;
    }

    private async void ReplaceImage_Click(object sender, RoutedEventArgs e)
    {
        if (_contentSelection is not { Kind: "image" } sel) return;
        var picker = new FileOpenPicker(AppWindow.Id);
        foreach (var t in new[] { ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff" }) picker.FileTypeFilter.Add(t);
        if (await picker.PickSingleFileAsync() is not { } file) return;
        await EditContentAsync("Replacing image…", sel.Page, new JsonObject { ["op"] = "image_replace", ["id"] = sel.Id, ["image"] = file.Path });
    }

    // ---------------------------------------------------------------- adding text and images

    private void AddText_Click(object sender, RoutedEventArgs e)
    {
        SetTool(CommentTool.AddText);
        ShowTransient("Click where the new text should start.");
    }

    private async Task AddTextAtAsync(int page, Point point)
    {
        SetTool(CommentTool.Select);
        if (await InfoAsync(page) is not { } info) return;
        var text = new TextBox { Header = "Text", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 80 };
        var size = Number("Size", 12, 4, 200);
        var family = Choice("Font", ["Sans serif", "Serif", "Monospace"]);
        var bold = new CheckBox { Content = "Bold" };
        if (!await AskAsync("Add Text", Stack(text, Row(size, family), bold), "Add") || text.Text.Trim().Length == 0) return;
        var at = info.ToPage(point);
        await Run("Adding text…", async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [new JsonObject
            {
                ["op"] = "add_text", ["page"] = page, ["point"] = new JsonArray(Math.Round(at.X, 2), Math.Round(at.Y, 2)),
                ["runs"] = new JsonArray(new JsonObject
                {
                    ["text"] = text.Text, ["size"] = size.Value, ["color"] = new JsonArray(0, 0, 0),
                    ["font"] = new JsonObject { ["family"] = new[] { "sans", "serif", "mono" }[Math.Max(0, family.SelectedIndex)], ["bold"] = bold.IsChecked == true },
                }),
            }], _password);
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
        });
    }

    private async void AddImage_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        foreach (var t in new[] { ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff" }) picker.FileTypeFilter.Add(t);
        if (await picker.PickSingleFileAsync() is not { } file) return;
        _pendingImageFile = file.Path;
        SetTool(CommentTool.AddImage);
        ShowTransient("Click where the image should go (drag to set its size).");
    }

    private async Task AddImageAtAsync(int page, Rect box)
    {
        SetTool(CommentTool.Select);
        if (_pendingImageFile is not { } path || await InfoAsync(page) is not { } info) return;
        _pendingImageFile = null;
        if (box.Width < 8 || box.Height < 8)
        {
            var (w, h) = SignatureArt.Size(await File.ReadAllBytesAsync(path));
            var width = Math.Min(220, info.Width * 0.6);
            box = new Rect(box.X, box.Y, width, width * h / Math.Max(1, w));
        }
        await Run("Adding image…", async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [new JsonObject
            {
                ["op"] = "image_add", ["page"] = page, ["image"] = path, ["rect"] = ToJson(PdfRect(info, box)),
            }], _password);
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
        });
    }

    private async void FindReplace_Click(object sender, RoutedEventArgs e)
    {
        var find = Text("Find");
        var replace = Text("Replace with");
        var matchCase = new CheckBox { Content = "Match case" };
        var whole = new CheckBox { Content = "Whole words only" };
        var note = new TextBlock { Text = "Changes the page content itself (not a comment). The replacement uses each word's original font when it can.", TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };
        if (!await AskAsync("Find & Replace in Content", Stack(find, replace, matchCase, whole, note), "Replace All") || find.Text.Length == 0) return;
        await Run("Replacing…", async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [new JsonObject
            {
                ["op"] = "replace_text", ["find"] = find.Text, ["replace"] = replace.Text,
                ["match_case"] = matchCase.IsChecked == true, ["whole_word"] = whole.IsChecked == true,
            }], _password);
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
            StatusText.Text = "Replaced. Undo reverts every replacement at once.";
        }, keepStatus: true);
    }
}
