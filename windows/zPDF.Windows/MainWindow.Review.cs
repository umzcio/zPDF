using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using Windows.Foundation;

namespace zPDF;

/// <summary>A difference between this document and the one it was compared with.</summary>
public sealed class ChangeItem(string kind, string oldText, string newText, int? page, IReadOnlyList<Rect> rects, int? oldPage)
{
    public string Kind { get; } = kind;               // Inserted, Deleted, Replaced, Visual
    public int? Page { get; } = page;                 // in this (the newer) document
    public IReadOnlyList<Rect> Rects { get; } = rects;
    public string Heading => $"{Kind}{(Page is { } p ? $" · page {p + 1}" : oldPage is { } o ? $" · was on page {o + 1}" : "")}";
    public string Detail => Kind switch
    {
        "Inserted" => $"+ {Clip(newText)}",
        "Deleted" => $"− {Clip(oldText)}",
        "Replaced" => $"“{Clip(oldText)}” → “{Clip(newText)}”",
        _ => newText,
    };
    public string Summary => $"{Heading}. {Detail}";
    private static string Clip(string text) => text.Length > 160 ? text[..160] + "…" : text;
}

/// <summary>Review tools: compare with another PDF, accessibility check and fixes, measuring.</summary>
public sealed partial class MainWindow
{
    private readonly ObservableCollection<ChangeItem> _changes = [];
    private ChangeItem? _shownChange;
    private readonly List<Point> _measurePoints = [];
    private PageSlot? _measureSlot;

    // ---------------------------------------------------------------- compare

    private async void Compare_Click(object sender, RoutedEventArgs e)
    {
        if (_document is not { } document) return;
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add(".pdf");
        if (await picker.PickSingleFileAsync() is not { } file) return;
        if (await OpenWithPasswordAsync(file.Path) is not { } opened) return;
        using var older = opened.Document;
        await Run("Comparing…", async () =>
        {
            var oldWords = new List<(string Key, string Text, int Page, int First, int Last)>();
            for (var p = 0; p < older.PageCount; p++)
            {
                StatusText.Text = $"Reading {Path.GetFileName(file.Path)} page {p + 1}…";
                var info = await Task.Run(() => older.LoadPageInfo(p));
                oldWords.AddRange(Words(info, p));
            }
            var newWords = new List<(string Key, string Text, int Page, int First, int Last)>();
            for (var p = 0; p < document.PageCount; p++)
            {
                StatusText.Text = $"Reading page {p + 1}…";
                if (await InfoAsync(p) is { } info) newWords.AddRange(Words(info, p));
            }
            StatusText.Text = "Finding differences…";
            var edits = await Task.Run(() => TextDiff.Diff(oldWords.Select(w => w.Key).ToArray(), newWords.Select(w => w.Key).ToArray()));
            _changes.Clear();
            foreach (var (oldStart, oldCount, newStart, newCount) in edits)
            {
                var oldText = string.Join(" ", oldWords.Skip(oldStart).Take(oldCount).Select(w => w.Text));
                var newText = string.Join(" ", newWords.Skip(newStart).Take(newCount).Select(w => w.Text));
                var kind = oldCount == 0 ? "Inserted" : newCount == 0 ? "Deleted" : "Replaced";
                var rects = new List<Rect>();
                int? page = null;
                if (newCount > 0)
                {
                    page = newWords[newStart].Page;
                    foreach (var w in newWords.Skip(newStart).Take(newCount).Where(w => w.Page == page))
                        rects.AddRange(_infos[w.Page].RectsFor(w.First, w.Last));
                }
                else if (newStart < newWords.Count) page = newWords[newStart].Page;
                _changes.Add(new ChangeItem(kind, oldText, newText, page, rects, oldCount > 0 ? oldWords[oldStart].Page : null));
            }
            // Pixel differences for page pairs (catches images, drawings and layout).
            for (var p = 0; p < Math.Min(older.PageCount, document.PageCount); p++)
            {
                StatusText.Text = $"Comparing page {p + 1} visually…";
                var (a, b) = await Task.Run(() => (older.Render(p, 0.5), document.Render(p, 0.5)));
                var share = VisualDifference(a, b);
                if (share > 0.002) _changes.Add(new ChangeItem("Visual", "", $"{share * 100:0.#}% of the page looks different", p, [], p));
            }
            if (older.PageCount != document.PageCount)
                _changes.Add(new ChangeItem("Visual", "", $"Page count changed: {older.PageCount} → {document.PageCount}", null, [], null));
            ChangesTab.Visibility = Visibility.Visible;
            ChangesTab.Text = $"Changes ({_changes.Count})";
            SidebarTabs.SelectedItem = ChangesTab;
            StatusText.Text = _changes.Count == 0
                ? $"No differences from {Path.GetFileName(file.Path)}."
                : $"{_changes.Count(c => c.Kind != "Visual")} text change(s) and {_changes.Count(c => c.Kind == "Visual")} visual difference(s) compared with {Path.GetFileName(file.Path)}.";
        }, keepStatus: true);
    }

    private static readonly Regex WordPattern = new(@"\S+", RegexOptions.Compiled);

    private static IEnumerable<(string Key, string Text, int Page, int First, int Last)> Words(PageInfo info, int page)
    {
        foreach (Match m in WordPattern.Matches(info.Text))
        {
            var first = info.CharAt[m.Index];
            var last = info.CharAt[m.Index + m.Length - 1];
            yield return (m.Value.Trim('.', ',', ';', ':').ToLowerInvariant(), m.Value, page, first, last);
        }
    }

    private static double VisualDifference(RenderedPage a, RenderedPage b)
    {
        if (a.Width != b.Width || a.Height != b.Height) return 1;
        var differing = 0;
        for (var i = 0; i < a.Pixels.Length; i += 4)
            if (Math.Abs(a.Pixels[i] - b.Pixels[i]) + Math.Abs(a.Pixels[i + 1] - b.Pixels[i + 1]) + Math.Abs(a.Pixels[i + 2] - b.Pixels[i + 2]) > 90) differing++;
        return differing / (double)(a.Width * a.Height);
    }

    private void ChangeList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not ChangeItem change || change.Page is not { } page) return;
        _shownChange = change;
        RefreshMarks();
        if (change.Rects.Count > 0 && _slots.Count > page)
        {
            var scale = _slots[page].Width / _slots[page].PointWidth;
            _page = page;
            ScrollTo(page, PageTop(page) + change.Rects[0].Top * scale - PageScroller.ViewportHeight / 3);
            UpdateStatus();
        }
        else GoTo(page);
    }

    private IEnumerable<(int Page, Rect Rect)> ChangeMarks()
    {
        if (_shownChange is { Page: { } page } change) foreach (var rect in change.Rects) yield return (page, rect);
    }

    // ---------------------------------------------------------------- accessibility

    private async void AccessibilityCheck_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        JsonNode report;
        try { report = await Engine.QueryAsync(CurrentPath, "accessibility_check", password: _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        var summary = report["summary"]!;
        var panel = new StackPanel { Spacing = 4, MinWidth = 480 };
        panel.Children.Add(new TextBlock
        {
            Text = $"{summary["passed"]} passed · {summary["failed"]} failed · {summary["manual"]} to check by hand · {summary["skipped"]} not applicable",
            Margin = new Thickness(0, 0, 0, 8),
        });
        var fixes = new List<string>();
        foreach (var group in report["items"]!.AsArray().GroupBy(i => i!["category"]!.GetValue<string>()))
        {
            panel.Children.Add(new TextBlock { Text = group.Key, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Margin = new Thickness(0, 8, 0, 0) });
            foreach (var item in group)
            {
                var status = item!["status"]!.GetValue<string>();
                var mark = status switch { "passed" => "✓", "failed" => "✗", "manual" => "?", _ => "–" };
                panel.Children.Add(new TextBlock
                {
                    Text = $"{mark}  {item["title"]}: {item["detail"]}", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                    Opacity = status is "skipped" ? 0.6 : 1,
                });
                if (item["fix"]?.GetValue<string>() is { } fix && !fixes.Contains(fix)) fixes.Add(fix);
            }
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = "Accessibility Check", Content = new ScrollViewer { Content = panel, MaxHeight = 520 },
            PrimaryButtonText = fixes.Count > 0 ? $"Fix {fixes.Count} Issue{(fixes.Count == 1 ? "" : "s")}" : "", CloseButtonText = "Close",
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var tagged = report["tagged"]?.GetValue<bool>() == true;
        var ops = new JsonArray();
        foreach (var fix in fixes)
        {
            JsonObject? op = fix switch
            {
                "autotag" => new JsonObject { ["op"] = "autotag", ["replace"] = tagged },
                "set_language" => new JsonObject { ["op"] = "set_language", ["lang"] = System.Globalization.CultureInfo.CurrentUICulture.Name },
                "set_title" => new JsonObject { ["op"] = "set_title", ["title"] = Path.GetFileNameWithoutExtension(_sourcePath) },
                "tag_annotations" => new JsonObject { ["op"] = "tag_annotations" },
                "set_page_tab_order" => new JsonObject { ["op"] = "set_page_tab_order", ["order"] = "S" },
                "field_tooltips" or "field_descriptions" => new JsonObject { ["op"] = "set_field_tooltips" },
                _ => null,
            };
            if (op is not null) ops.Add(op);
        }
        if (ops.Count == 0) return;
        await Run("Fixing accessibility issues…", async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, ops, _password);
            _revisions.Push(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
            StatusText.Text = $"Fixed {ops.Count} issue{(ops.Count == 1 ? "" : "s")}. Run the check again to review what needs a person.";
        }, keepStatus: true);
    }

    private async void Autotag_Click(object sender, RoutedEventArgs e)
    {
        var tagged = (await Engine.QueryAsync(CurrentPath!, "accessibility_check", password: _password))["tagged"]?.GetValue<bool>() == true;
        if (tagged && !await AskAsync("Replace the existing tags?", new TextBlock { Text = "This document is already tagged. Autotagging replaces its tags with new ones.", TextWrapping = TextWrapping.Wrap }, "Replace")) return;
        await EditDocumentAsync("Tagging the document…", new JsonObject { ["op"] = "autotag", ["replace"] = tagged });
    }

    // ---------------------------------------------------------------- measure

    private void MeasureTool_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string name } || !Enum.TryParse<CommentTool>(name, out var tool)) return;
        SetTool(tool);
        ShowTransient(tool == CommentTool.MeasureDistance ? "Drag to measure a distance." : "Click each point; press Enter to finish.");
    }

    private async void SetScale_Click(object sender, RoutedEventArgs e)
    {
        var paper = Number("On the page (in)", 1, 0.01, 1000, 0.25);
        var real = Number("Equals", 1, 0.0001, 1000000);
        var unit = Choice("Unit", ["in", "ft", "yd", "mi", "mm", "cm", "m", "km"]);
        if (!await AskAsync("Set Measurement Scale", Stack(Row(paper, real), unit), "Set")) return;
        var u = unit.SelectedItem as string ?? "in";
        // factor: real units per PDF point.
        var factor = real.Value / (paper.Value * 72);
        await EditDocumentAsync("Setting scale…", new JsonObject
        {
            ["op"] = "set_page_scale", ["ratio"] = $"{paper.Value:0.##} in = {real.Value:0.####} {u}", ["factor"] = factor, ["unit"] = u,
        });
    }

    private async Task<(double Factor, string Unit, string Ratio)> ScaleForAsync(int page)
    {
        try
        {
            var scales = await Engine.QueryAsync(CurrentPath!, "page_scales", password: _password);
            var entry = scales.AsArray().FirstOrDefault(s => s!["page"]?.GetValue<int>() == page);
            if (entry?["factor"] is JsonValue f && f.TryGetValue<double>(out var factor))
                return (factor, entry["unit"]?.GetValue<string>() ?? "in", entry["ratio"]?.GetValue<string>() ?? "");
        }
        catch (EngineException) { }
        return (1.0 / 72, "in", "1 in = 1 in");
    }

    /// <summary>Measure tools: distance is a drag; perimeter and area are clicks, Enter to finish.</summary>
    private bool MeasurePointerReleased(PageSlot slot, Point from, Point to)
    {
        if (_tool == CommentTool.MeasureDistance)
        {
            if (Distance(from, to) < 3) return true;
            _ = AddMeasurementAsync(slot.Index, "distance", [from, to]);
            return true;
        }
        if (_measureSlot is not null && _measureSlot != slot) { _measurePoints.Clear(); _measureSlot.SetDraft(null); }
        _measureSlot = slot;
        _measurePoints.Add(to);
        slot.SetDraft(new Draft(DraftShape.Polyline, _measurePoints.ToList(), Palette[4].Color));
        _ = ShowRunningMeasurementAsync(slot.Index);
        return true;
    }

    private async Task ShowRunningMeasurementAsync(int page)
    {
        if (await InfoAsync(page) is not { } info || _measurePoints.Count < 2) { StatusText.Text = "Click the next point; press Enter to finish."; return; }
        var (factor, unit, _) = await ScaleForAsync(page);
        var pts = _measurePoints.Select(info.ToPage).ToList();
        var length = pts.Zip(pts.Skip(1), (a, b) => Distance(a, b)).Sum() * factor;
        StatusText.Text = $"{length:0.##} {unit} so far — click the next point, Enter to finish, Esc to cancel.";
    }

    private void FinishMeasurement()
    {
        if (_measureSlot is not { } slot || _measurePoints.Count < 2) return;
        var kind = _tool == CommentTool.MeasureArea ? "area" : "perimeter";
        var points = _measurePoints.ToList();
        _measurePoints.Clear();
        slot.SetDraft(null);
        _measureSlot = null;
        if (kind == "area" && points.Count < 3) { StatusText.Text = "An area needs at least three points."; return; }
        _ = AddMeasurementAsync(slot.Index, kind, points);
    }

    private async Task AddMeasurementAsync(int page, string kind, List<Point> viewPoints)
    {
        if (await InfoAsync(page) is not { } info) return;
        var (factor, unit, ratio) = await ScaleForAsync(page);
        var pts = viewPoints.Select(info.ToPage).ToList();
        var points = new JsonArray(pts.Select(p => (JsonNode)new JsonArray(Math.Round(p.X, 2), Math.Round(p.Y, 2))).ToArray());
        await EditDocumentAsync("Adding measurement…", new JsonObject
        {
            ["op"] = "add_measurements",
            ["items"] = new JsonArray(new JsonObject
            {
                ["page"] = page, ["kind"] = kind, ["points"] = points, ["factor"] = factor, ["unit"] = unit, ["ratio"] = ratio,
                ["author"] = Environment.UserName,
            }),
        });
    }
}
