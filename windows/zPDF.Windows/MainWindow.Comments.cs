using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;

namespace zPDF;

public enum CommentTool
{
    Select, Highlight, Underline, StrikeOut, Text, FreeText, Ink, Square, Circle, Line, Arrow, Stamp, Redact, Place, SignBox,
    MeasureDistance, MeasurePerimeter, MeasureArea, EditContent, AddText, AddImage, PrepareForm, Link,
}

/// <summary>A comment as the engine reports it (comment_threads).</summary>
public sealed record CommentRecord(int Page, int Index, string Subtype, double[] Rect, string Author, string Contents,
                                   (int Page, int Index)? ReplyTo, string? State, string Modified, string Subject = "");

/// <summary>A top-level comment in the Comments panel, with its replies and status.</summary>
public sealed class CommentItem(CommentRecord record, IReadOnlyList<CommentRecord> replies, string? status)
{
    public CommentRecord Record { get; } = record;
    public IReadOnlyList<CommentRecord> Replies { get; } = replies;
    public string Heading => $"{(Record.Subject is "Arrow" ? "Arrow" : Kind(Record.Subtype))} · page {Record.Page + 1}" + (Record.Author.Length > 0 ? $" · {Record.Author}" : "");
    public string Contents => Record.Contents;
    public Visibility HasContents => Record.Contents.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public string Footer => string.Join(" · ", new[]
    {
        status is { Length: > 0 } and not "None" ? status : null,
        Replies.Count switch { 0 => null, 1 => "1 reply", var n => $"{n} replies" },
    }.Where(s => s is not null));
    public Visibility HasFooter => Footer.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public string Summary => $"{Heading}. {Contents} {Footer}";

    public static string Kind(string subtype) => subtype switch
    {
        "Highlight" => "Highlight", "Underline" => "Underline", "StrikeOut" => "Strikethrough", "Squiggly" => "Squiggly",
        "Text" => "Note", "FreeText" => "Text box", "Square" => "Rectangle", "Circle" => "Ellipse", "Line" => "Line",
        "Ink" => "Drawing", "Polygon" => "Polygon", "PolyLine" => "Polyline", "Stamp" => "Stamp", "Caret" => "Insert text",
        "FileAttachment" => "Attachment", "Sound" => "Sound", _ => subtype,
    };
}

/// <summary>Comment tools, the Comments panel and editing existing comments.</summary>
public sealed partial class MainWindow
{
    private static readonly (string Name, Color Color)[] Palette =
    [
        ("Yellow", ColorHelper.FromArgb(255, 255, 214, 0)), ("Green", ColorHelper.FromArgb(255, 60, 180, 75)),
        ("Blue", ColorHelper.FromArgb(255, 40, 110, 230)), ("Pink", ColorHelper.FromArgb(255, 240, 80, 160)),
        ("Red", ColorHelper.FromArgb(255, 220, 30, 30)), ("Purple", ColorHelper.FromArgb(255, 130, 60, 200)),
        ("Black", ColorHelper.FromArgb(255, 20, 20, 20)),
    ];

    private readonly Dictionary<CommentTool, Color> _toolColors = new()
    {
        [CommentTool.Highlight] = Palette[0].Color, [CommentTool.Underline] = Palette[2].Color,
        [CommentTool.StrikeOut] = Palette[4].Color, [CommentTool.Text] = Palette[0].Color,
        [CommentTool.FreeText] = Palette[6].Color, [CommentTool.Ink] = Palette[2].Color,
        [CommentTool.Square] = Palette[4].Color, [CommentTool.Circle] = Palette[4].Color,
        [CommentTool.Line] = Palette[4].Color, [CommentTool.Arrow] = Palette[4].Color, [CommentTool.Stamp] = Palette[4].Color,
    };

    private readonly ObservableCollection<CommentItem> _commentItems = [];
    private List<CommentRecord> _comments = [];
    private int _commentsGeneration;
    private CommentTool _tool = CommentTool.Select;
    private (int Page, int Index)? _selectedComment;
    private PageSlot? _drawSlot;
    private readonly List<Point> _drawPoints = [];
    private Point _moveStart;
    private bool _moving;

    /// <summary>Standard stamp names (ISO 32000 12.5.6.12) and their labels.</summary>
    private static readonly (string Icon, string Label)[] Stamps =
    [
        ("Approved", "Approved"), ("Draft", "Draft"), ("Confidential", "Confidential"), ("Final", "Final"),
        ("NotApproved", "Not Approved"), ("ForComment", "For Comment"), ("Experimental", "Experimental"),
        ("Expired", "Expired"), ("AsIs", "As Is"), ("ForPublicRelease", "For Public Release"),
        ("NotForPublicRelease", "Not for Public Release"), ("Departmental", "Departmental"), ("Sold", "Sold"),
        ("TopSecret", "Top Secret"),
    ];

    private void InitializeComments()
    {
        CommentList.ItemsSource = _commentItems;
        StampChoice.ItemsSource = Stamps.Select(s => s.Label).ToList();
        StampChoice.SelectedIndex = 0;
        foreach (var (name, color) in Palette)
        {
            var swatch = new Button
            {
                Width = 28, Height = 28, Padding = new Thickness(0), CornerRadius = new CornerRadius(14),
                Background = new SolidColorBrush(color), Tag = color,
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(swatch, name);
            ToolTipService.SetToolTip(swatch, name);
            swatch.Click += Swatch_Click;
            ColorPalette.Children.Add(swatch);
        }
        UpdateColorSwatch();
    }

    private Color CurrentColor => _toolColors.GetValueOrDefault(_tool, Palette[4].Color);
    private static double[] Rgb(Color c) => [c.R / 255.0, c.G / 255.0, c.B / 255.0];

    // ---------------------------------------------------------------- tools

    private void Tool_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not ToggleButton { Tag: string name } || !Enum.TryParse<CommentTool>(name, out var tool)) return;
        // Redact with text selected marks that text; a markup tool applies to it at once.
        if (tool == CommentTool.Redact && _selection is { } redact && redact.Anchor != redact.Focus)
        {
            MarkSelectionForRedaction();
            SetTool(CommentTool.Select);
            return;
        }
        if (tool is CommentTool.Highlight or CommentTool.Underline or CommentTool.StrikeOut && _selection is { } sel && sel.Anchor != sel.Focus)
        {
            _ = MarkupSelectionAsync(tool);
            SetTool(CommentTool.Select);
            return;
        }
        SetTool(tool == _tool ? CommentTool.Select : tool);
    }

    private void SetTool(CommentTool tool)
    {
        if (tool == CommentTool.Select) { _placing = null; _placingDate = null; _signing = null; }
        if (tool != CommentTool.PrepareForm && _tool == CommentTool.PrepareForm)
        {
            _preparedWidget = null;
            FieldTypeStrip.Visibility = Visibility.Collapsed;
        }
        if (tool != CommentTool.EditContent && _tool == CommentTool.EditContent)
        {
            CloseContentEditor(commit: true);
            _contentSelection = null;
        }
        if (tool is not (CommentTool.MeasurePerimeter or CommentTool.MeasureArea) && _measureSlot is { } measuring)
        {
            measuring.SetDraft(null);
            _measureSlot = null;
            _measurePoints.Clear();
        }
        _tool = tool;
        foreach (var child in ToolStrip.Children)
            if (child is ToggleButton { Tag: string name } button) button.IsChecked = name == tool.ToString();
        if (tool != CommentTool.Select) SelectComment(null);
        UpdateColorSwatch();
        UpdateContentCommands();
        RefreshMarks();
    }

    private void Swatch_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: Color color }) return;
        ColorFlyout.Hide();
        if (_tool == CommentTool.Select && _selectedComment is { } selected)
        {
            _ = ApplyCommentsAsync("Changing color…", [Change("update", selected, new JsonObject { ["color"] = ToJson(Rgb(color)) })], selected);
            return;
        }
        _toolColors[_tool == CommentTool.Select ? CommentTool.Highlight : _tool] = color;
        UpdateColorSwatch();
    }

    private void UpdateColorSwatch() =>
        ColorSwatch.Background = new SolidColorBrush(_toolColors.GetValueOrDefault(_tool == CommentTool.Select ? CommentTool.Highlight : _tool, Palette[0].Color));

    // ---------------------------------------------------------------- pointer (called from the viewing handlers first)

    /// <summary>True when a comment tool (or a selected comment) takes this press.</summary>
    private bool CommentPointerPressed(PageSlot slot, Point point)
    {
        if (_tool == CommentTool.Select)
        {
            if (_selectedComment is { } current && current.Page == slot.Index && CornerAt(slot, point) is var corner and >= 0)
            {
                _resizeCorner = corner;
                _moveStart = point;
                _moving = false;
                _drawSlot = slot;
                return true;
            }
            _resizeCorner = -1;
            var hit = CommentAt(slot.Index, point);
            SelectComment(hit);
            if (hit is null) return false;
            _moveStart = point;
            _moving = false;
            _drawSlot = slot;
            return true;
        }
        if (_tool is CommentTool.Highlight or CommentTool.Underline or CommentTool.StrikeOut) return false;  // text selection
        _drawSlot = slot;
        _drawPoints.Clear();
        _drawPoints.Add(point);
        return true;
    }

    private bool CommentPointerMoved(PageSlot slot, Point point)
    {
        if (_drawSlot is null) return false;
        if (_tool == CommentTool.Select)
        {
            if (_selectedComment is not { } sel || RecordAt(sel) is not { } record || Info(sel.Page) is not { } info) return true;
            if (!_moving && Distance(point, _moveStart) < 3) return true;
            _moving = true;
            var rect = ViewRect(info, record);
            if (_resizeCorner >= 0)
            {
                var resized = ResizedRect(rect, point);
                _drawSlot.SetDraft(new Draft(DraftShape.Rectangle, [new Point(resized.Left, resized.Top), new Point(resized.Right, resized.Bottom)], ColorHelper.FromArgb(255, 0, 103, 192)));
                return true;
            }
            var (dx, dy) = (point.X - _moveStart.X, point.Y - _moveStart.Y);
            _drawSlot.SetDraft(new Draft(DraftShape.Rectangle, [new Point(rect.Left + dx, rect.Top + dy), new Point(rect.Right + dx, rect.Bottom + dy)],
                                         ColorHelper.FromArgb(255, 0, 103, 192)));
            return true;
        }
        if (_tool == CommentTool.Ink) _drawPoints.Add(point);
        else if (_drawPoints.Count == 1) _drawPoints.Add(point);
        else _drawPoints[^1] = point;
        if (_tool is CommentTool.MeasurePerimeter or CommentTool.MeasureArea) return true;  // clicks, not drags
        var shape = _tool switch
        {
            CommentTool.Ink => DraftShape.Polyline,
            CommentTool.Circle => DraftShape.Ellipse,
            CommentTool.Line or CommentTool.Arrow or CommentTool.MeasureDistance => DraftShape.Line,
            _ => DraftShape.Rectangle,
        };
        if (_tool is not (CommentTool.Text or CommentTool.Stamp or CommentTool.Place or CommentTool.AddText)) _drawSlot.SetDraft(new Draft(shape, _drawPoints.ToList(), CurrentColor));
        return true;
    }

    private bool CommentPointerReleased(PageSlot slot, Point point)
    {
        if (_drawSlot is not { } target) return _tool is CommentTool.Highlight or CommentTool.Underline or CommentTool.StrikeOut && FinishMarkup();
        _drawSlot = null;
        target.SetDraft(null);
        if (_tool == CommentTool.Select)
        {
            if (_moving && _selectedComment is { } sel && RecordAt(sel) is { } record && Info(sel.Page) is { } info)
            {
                _moving = false;
                var rect = ViewRect(info, record);
                if (_resizeCorner >= 0)
                {
                    var resized = ResizedRect(rect, point);
                    _resizeCorner = -1;
                    if (resized.Width >= 4 && resized.Height >= 4)
                        _ = ApplyCommentsAsync("Resizing comment…", [Change("update", sel, new JsonObject { ["rect"] = ToJson(PdfRect(info, resized)) })], sel);
                    return true;
                }
                var (dx, dy) = (point.X - _moveStart.X, point.Y - _moveStart.Y);
                var moved = new Rect(rect.Left + dx, rect.Top + dy, rect.Width, rect.Height);
                _ = ApplyCommentsAsync("Moving comment…", [Change("update", sel, new JsonObject { ["rect"] = ToJson(PdfRect(info, moved)) })], sel);
            }
            return true;
        }
        var points = _drawPoints.ToList();
        if (points.Count == 1) points.Add(point);
        if (_tool == CommentTool.Redact) { RedactPointerReleased(target, new Rect(points[0], points[^1])); return true; }
        if (_tool == CommentTool.Place) { _ = PlaceAtAsync(target.Index, points[^1]); return true; }
        if (_tool == CommentTool.AddText) { _ = AddTextAtAsync(target.Index, points[0]); return true; }
        if (_tool == CommentTool.Link) { _ = LinkGestureAsync(target.Index, points[0], points[^1]); return true; }
        if (_tool == CommentTool.AddImage) { _ = AddImageAtAsync(target.Index, new Rect(points[0], points[^1])); return true; }
        if (_tool is CommentTool.MeasureDistance or CommentTool.MeasurePerimeter or CommentTool.MeasureArea)
            return MeasurePointerReleased(target, points[0], points[^1]);
        if (_tool == CommentTool.SignBox) { _ = FinishSignBoxAsync(target.Index, new Rect(points[0], points[^1])); return true; }
        _ = CreateCommentAsync(target.Index, points);
        return true;
    }

    /// <summary>Highlight/underline/strikethrough: the drag selected text; mark it.</summary>
    private bool FinishMarkup()
    {
        if (_selection is not { } sel || sel.Anchor == sel.Focus) return false;
        _ = MarkupSelectionAsync(_tool);
        return true;
    }

    private async Task MarkupSelectionAsync(CommentTool tool)
    {
        if (_selection is not { } sel || Info(sel.Page) is not { } info) return;
        var rects = info.RectsFor(Math.Min(sel.Anchor, sel.Focus), Math.Max(sel.Anchor, sel.Focus));
        if (rects.Count == 0) return;
        var quads = new JsonArray();
        foreach (var rect in rects)
        {
            // QuadPoints per line: top-left, top-right, bottom-left, bottom-right (PDF space).
            var r = PdfRect(info, rect);
            foreach (var v in new[] { r[0], r[3], r[2], r[3], r[0], r[1], r[2], r[1] }) quads.Add(v);
        }
        var text = info.TextOf(Math.Min(sel.Anchor, sel.Focus), Math.Max(sel.Anchor, sel.Focus));
        _selection = null;
        RefreshMarks();
        await AddAsync(sel.Page, new JsonObject
        {
            ["subtype"] = tool.ToString(), ["quads"] = quads, ["color"] = ToJson(Rgb(_toolColors[tool])),
            ["contents"] = text.Length > 500 ? text[..500] : text,
        });
    }

    private async Task CreateCommentAsync(int page, List<Point> points)
    {
        if (await InfoAsync(page) is not { } info) return;
        var color = ToJson(Rgb(CurrentColor));
        var (a, b) = (points[0], points[^1]);
        var box = new Rect(a, b);
        JsonObject annot;
        switch (_tool)
        {
            case CommentTool.Text:
                if (await AskTextAsync("Add Note", "", "Note") is not { } note) return;
                annot = new JsonObject { ["subtype"] = "Text", ["rect"] = ToJson(PdfRect(info, new Rect(a.X, a.Y, 22, 22))), ["contents"] = note, ["color"] = color };
                break;
            case CommentTool.FreeText:
                if (box.Width < 20 || box.Height < 12) box = new Rect(a.X, a.Y, 200, 40);
                if (await AskTextAsync("Add Text Box", "", "Text") is not { Length: > 0 } text) return;
                annot = new JsonObject { ["subtype"] = "FreeText", ["rect"] = ToJson(PdfRect(info, box)), ["contents"] = text, ["color"] = color, ["font_size"] = 12 };
                break;
            case CommentTool.Stamp:
                annot = new JsonObject
                {
                    ["subtype"] = "Stamp", ["rect"] = ToJson(PdfRect(info, new Rect(a.X - 75, a.Y - 22, 150, 45))),
                    ["icon"] = Stamps[Math.Max(0, StampChoice.SelectedIndex)].Icon,
                };
                break;
            case CommentTool.Ink:
                if (points.Count < 2) return;
                var ink = new JsonArray();
                foreach (var p in points) { var q = info.ToPage(p); ink.Add(q.X); ink.Add(q.Y); }
                annot = new JsonObject { ["subtype"] = "Ink", ["ink"] = new JsonArray(ink), ["color"] = color, ["width"] = 2 };
                break;
            case CommentTool.Line or CommentTool.Arrow:
                if (Distance(a, b) < 4) return;
                var (pa, pb) = (info.ToPage(a), info.ToPage(b));
                annot = new JsonObject
                {
                    ["subtype"] = "Line", ["line"] = ToJson([pa.X, pa.Y, pb.X, pb.Y]), ["color"] = color, ["width"] = 2,
                    ["line_endings"] = ToJson(_tool == CommentTool.Arrow ? ["None", "OpenArrow"] : ["None", "None"]),
                    ["subject"] = _tool == CommentTool.Arrow ? "Arrow" : "Line",
                };
                break;
            default:  // rectangle, ellipse
                if (box.Width < 4 || box.Height < 4) return;
                annot = new JsonObject { ["subtype"] = _tool.ToString(), ["rect"] = ToJson(PdfRect(info, box)), ["color"] = color, ["width"] = 2 };
                break;
        }
        await AddAsync(page, annot);
    }

    private Task AddAsync(int page, JsonObject annot)
    {
        annot["author"] = AuthorName;
        var index = _document?.AnnotationCount(page) ?? 0;  // appended after every existing annotation
        return ApplyCommentsAsync($"Adding {CommentItem.Kind(annot["subtype"]!.GetValue<string>()).ToLowerInvariant()}…",
                                  [new JsonObject { ["action"] = "add", ["page"] = page, ["annot"] = annot }], (page, index));
    }

    // ---------------------------------------------------------------- engine round trip

    private static JsonObject Change(string action, (int Page, int Index) target, JsonObject? annot = null)
    {
        var change = new JsonObject { ["action"] = action, ["page"] = target.Page, ["index"] = target.Index };
        if (annot is not null) change["annot"] = annot;
        return change;
    }

    private static JsonArray ToJson(IEnumerable<double> values) => new(values.Select(v => (JsonNode)Math.Round(v, 3)).ToArray());
    private static JsonArray ToJson(IEnumerable<string> values) => new(values.Select(v => (JsonNode)v).ToArray());

    /// <summary>One comment change as one undo step; reselects `select` when it still exists.</summary>
    private Task ApplyCommentsAsync(string status, JsonObject[] changes, (int Page, int Index)? select) =>
        Run(status, async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [new JsonObject { ["op"] = "comment_edits", ["items"] = new JsonArray(changes) }], _password);
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
            _pendingCommentSelection = select;
        });

    private (int Page, int Index)? _pendingCommentSelection;

    /// <summary>Reloads the comment list from the engine (after open and every edit).</summary>
    private async Task RefreshCommentsAsync()
    {
        var generation = ++_commentsGeneration;
        var path = CurrentPath;
        if (path is null) return;
        List<CommentRecord> records = [];
        try
        {
            var result = await Engine.QueryAsync(path, "comment_threads", password: _password);
            if (generation != _commentsGeneration) return;
            var pages = result["pages"]!.AsArray();
            for (var p = 0; p < pages.Count; p++)
            {
                foreach (var item in pages[p]!.AsArray())
                {
                    var irt = item!["irt"] as JsonArray;
                    records.Add(new CommentRecord(
                        p, item["index"]!.GetValue<int>(), item["subtype"]?.GetValue<string>() ?? "",
                        item["rect"]!.AsArray().Select(v => v!.GetValue<double>()).ToArray(),
                        item["author"]?.GetValue<string>() ?? "", item["contents"]?.GetValue<string>() ?? "",
                        irt is { Count: 2 } ? (irt[0]!.GetValue<int>(), irt[1]!.GetValue<int>()) : null,
                        item["state"]?.GetValue<string>(), item["modified"]?.GetValue<string>() ?? "",
                        item["subject"]?.GetValue<string>() ?? ""));
                }
            }
        }
        catch (EngineException error)
        {
            StatusText.Text = error.Message;
            return;
        }
        _comments = records;
        _commentItems.Clear();
        foreach (var top in records.Where(r => r.ReplyTo is null))
        {
            var thread = records.Where(r => r.ReplyTo == (top.Page, top.Index)).ToList();
            var status = thread.LastOrDefault(r => r.State is not null)?.State;
            _commentItems.Add(new CommentItem(top, thread.Where(r => r.State is null).ToList(), status));
        }
        if (_pendingCommentSelection is { } pending && RecordAt(pending) is not null) SelectComment(pending);
        else SelectComment(null);
        _pendingCommentSelection = null;
        UpdateCommentsPanel();
    }

    private void UpdateCommentsPanel()
    {
        var comments = SidebarTabs.SelectedItem == CommentsTab;
        CommentList.Visibility = comments && _commentItems.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        NoCommentsText.Visibility = comments && _commentItems.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        SetTabLabel(CommentsTab, _commentItems.Count > 0 ? $"Comments ({_commentItems.Count})" : "Comments");
    }

    // ---------------------------------------------------------------- selection and hit-testing

    private CommentRecord? RecordAt((int Page, int Index) key) => _comments.FirstOrDefault(c => c.Page == key.Page && c.Index == key.Index);

    private static Rect ViewRect(PageInfo info, CommentRecord record) =>
        info.ToView(new Rect(new Point(record.Rect[0], record.Rect[1]), new Point(record.Rect[2], record.Rect[3])));

    /// <summary>PDF user-space rectangle [x0, y0, x1, y1] for a view rectangle.</summary>
    private static double[] PdfRect(PageInfo info, Rect view)
    {
        var corners = new[] { info.ToPage(new Point(view.Left, view.Top)), info.ToPage(new Point(view.Right, view.Bottom)),
                              info.ToPage(new Point(view.Left, view.Bottom)), info.ToPage(new Point(view.Right, view.Top)) };
        return [corners.Min(c => c.X), corners.Min(c => c.Y), corners.Max(c => c.X), corners.Max(c => c.Y)];
    }

    /// <summary>The top-most visible comment under `point` (replies are not on the page).</summary>
    private (int Page, int Index)? CommentAt(int page, Point point)
    {
        if (Info(page) is not { } info) return null;
        foreach (var record in _comments.Where(c => c.Page == page && c.ReplyTo is null).Reverse())
        {
            var rect = ViewRect(info, record);
            rect = new Rect(rect.X - 2, rect.Y - 2, rect.Width + 4, rect.Height + 4);
            if (rect.Contains(point)) return (record.Page, record.Index);
        }
        return null;
    }

    private void SelectComment((int Page, int Index)? key)
    {
        _selectedComment = key;
        var item = key is { } k ? _commentItems.FirstOrDefault(i => i.Record.Page == k.Page && i.Record.Index == k.Index) : null;
        if (!ReferenceEquals(CommentList.SelectedItem, item)) CommentList.SelectedItem = item;
        if (item is not null) CommentList.ScrollIntoView(item);
        RefreshMarks();
    }

    /// <summary>The dashed outline around the selected comment (added to the page marks).</summary>
    /// <summary>Corners of the selected comment (view points) that drag to resize it.
    /// Sticky notes and replies keep their icon size.</summary>
    private List<Point> ResizeCorners()
    {
        if (_tool != CommentTool.Select || _selectedComment is not { } sel || RecordAt(sel) is not { } record
            || record.Subtype is "Text" or "Popup" || _infos.GetValueOrDefault(sel.Page) is not { } info) return [];
        var r = ViewRect(info, record);
        return [new(r.Left, r.Top), new(r.Right, r.Top), new(r.Right, r.Bottom), new(r.Left, r.Bottom)];
    }

    private IEnumerable<(int Page, Point Corner)> CommentHandles()
    {
        if (_selectedComment is not { } sel) yield break;
        foreach (var corner in ResizeCorners()) yield return (sel.Page, corner);
    }

    /// <summary>The corner under `point` (within a few screen pixels), or -1.</summary>
    private int CornerAt(PageSlot slot, Point point)
    {
        var tolerance = 6 / Math.Max(0.1, slot.Width / slot.PointWidth);
        var corners = ResizeCorners();
        for (var i = 0; i < corners.Count; i++)
            if (Math.Abs(corners[i].X - point.X) <= tolerance && Math.Abs(corners[i].Y - point.Y) <= tolerance) return i;
        return -1;
    }

    private int _resizeCorner = -1;

    /// <summary>The selected comment's box with corner `_resizeCorner` dragged to `point`.</summary>
    private Rect ResizedRect(Rect rect, Point point)
    {
        var opposite = _resizeCorner switch
        {
            0 => new Point(rect.Right, rect.Bottom), 1 => new Point(rect.Left, rect.Bottom),
            2 => new Point(rect.Left, rect.Top), _ => new Point(rect.Right, rect.Top),
        };
        return new Rect(opposite, point);
    }

    private IEnumerable<(int Page, Rect Rect)> CommentMarks()
    {
        if (_selectedComment is { } sel && RecordAt(sel) is { } record && _infos.GetValueOrDefault(sel.Page) is { } info)
        {
            var rect = ViewRect(info, record);
            yield return (sel.Page, new Rect(rect.X - 3, rect.Y - 3, rect.Width + 6, rect.Height + 6));
        }
    }

    // ---------------------------------------------------------------- panel and commands

    private void CommentList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not CommentItem item) return;
        SetTool(CommentTool.Select);
        var key = (item.Record.Page, item.Record.Index);
        SelectComment(key);
        if (Info(item.Record.Page) is { } info)
        {
            var rect = ViewRect(info, item.Record);
            var scale = _slots[item.Record.Page].Width / _slots[item.Record.Page].PointWidth;
            _page = item.Record.Page;
            ScrollTo(_page, PageTop(_page) + rect.Top * scale - PageScroller.ViewportHeight / 3);
            UpdateStatus();
        }
        else GoTo(item.Record.Page);
    }

    /// <summary>Right-click selects the comment under the pointer, so the menu acts on it.</summary>
    private void CommentList_RightTapped(object sender, Microsoft.UI.Xaml.Input.RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is CommentItem item)
            SelectComment((item.Record.Page, item.Record.Index));
    }

    private (int Page, int Index)? TargetComment(object sender) =>
        (sender as FrameworkElement)?.DataContext is CommentItem item ? (item.Record.Page, item.Record.Index) : _selectedComment;

    private async void ReplyComment_Click(object sender, RoutedEventArgs e)
    {
        if (TargetComment(sender) is not { } target) return;
        if (await AskTextAsync("Reply", "", "Reply") is not { Length: > 0 } text) return;
        await ApplyCommentsAsync("Replying…", [Change("reply", target, new JsonObject { ["contents"] = text, ["author"] = AuthorName })], target);
    }

    private async void EditComment_Click(object sender, RoutedEventArgs e) => await EditSelectedCommentAsync(TargetComment(sender));

    private async Task EditSelectedCommentAsync((int Page, int Index)? target)
    {
        if (target is not { } key || RecordAt(key) is not { } record) return;
        if (await AskTextAsync($"Edit {CommentItem.Kind(record.Subtype)}", record.Contents, "Text") is not { } text || text == record.Contents) return;
        await ApplyCommentsAsync("Saving comment…", [Change("update", key, new JsonObject { ["contents"] = text })], key);
    }

    private async void SetStatus_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuFlyoutItem { Tag: string state } || TargetComment(sender) is not { } target) return;
        await ApplyCommentsAsync("Setting status…", [new JsonObject
        {
            ["action"] = "status", ["page"] = target.Page, ["index"] = target.Index, ["state"] = state, ["author"] = AuthorName,
        }], target);
    }

    private void DeleteComment_Click(object sender, RoutedEventArgs e) => _ = DeleteCommentAsync(TargetComment(sender));

    private void DeleteCommentAccelerator_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        _ = DeleteCommentAsync(_selectedComment);
    }

    /// <summary>Delete with a comment selected on the page deletes it; Enter edits its text.</summary>
    private void PageDelete_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_contentEditing is null && FindBox.FocusState == FocusState.Unfocused && (DeleteSelectedObject() || DeletePreparedField())) { args.Handled = true; return; }
        if (_selectedComment is null || FindBox.FocusState != FocusState.Unfocused) return;
        args.Handled = true;
        _ = DeleteCommentAsync(_selectedComment);
    }

    private void PageEnter_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (IsPreparingForm && _preparedWidget is not null && FindBox.FocusState == FocusState.Unfocused)
        {
            args.Handled = true;
            _ = EditFieldPropertiesAsync();
            return;
        }
        if (_tool is CommentTool.MeasurePerimeter or CommentTool.MeasureArea && _measurePoints.Count > 0)
        {
            args.Handled = true;
            FinishMeasurement();
            SetTool(CommentTool.Select);
            return;
        }
        if (_selectedComment is null || FindBox.FocusState != FocusState.Unfocused) return;
        args.Handled = true;
        _ = EditSelectedCommentAsync(_selectedComment);
    }

    private Task DeleteCommentAsync((int Page, int Index)? target)
    {
        if (target is not { } key || RecordAt(key) is null) return Task.CompletedTask;
        _selectedComment = null;
        return ApplyCommentsAsync("Deleting comment…", [Change("delete", key)], null);
    }

    private async Task<string?> AskTextAsync(string title, string text, string label)
    {
        var box = new TextBox
        {
            Text = text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 96, MaxHeight = 320, Header = label,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = title, Content = box, PrimaryButtonText = "OK", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        dialog.Opened += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        return await dialog.ShowAsync() == ContentDialogResult.Primary ? box.Text : null;
    }
}
