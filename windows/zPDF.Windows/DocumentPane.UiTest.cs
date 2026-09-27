using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Windows.Foundation;

namespace zPDF;

/// <summary>`zPDF.exe --uitest input.pdf log.txt`: drives a real window through edits,
/// undo/redo, a measurement and a checkbox, logging PASS/FAIL lines, then exits
/// (exit code = failures). Run it in a desktop session.</summary>
public sealed partial class DocumentPane
{
    public async Task<int> RunUiTestAsync(string input, string logPath)
    {
        var log = new List<string>();
        var failures = 0;
        void Check(string name, bool ok, string detail = "")
        {
            if (!ok) failures++;
            log.Add($"{(ok ? "PASS" : "FAIL")} {name}{(detail.Length > 0 ? $" — {detail}" : "")}");
        }
        string Text() => _document?.LoadPageInfo(0).Text ?? "";
        string State() => $"revisions={_revisions.Count} redo={_redo.Count} status='{StatusText.Text}'";
        try
        {
            await OpenAsync(input);
            Check("open", _document is not null, $"{_document?.PageCount} pages");

            // Edit, undo, redo.
            var before = Text();
            var edited = await EditDocumentAsync("Replacing…", new JsonObject { ["op"] = "replace_text", ["find"] = "Employee", ["replace"] = "Worker", ["match_case"] = true });
            Check("replace", edited && Text().Contains("Worker") && _revisions.Count == 1, State());
            await UndoAsync();
            Check("undo", Text() == before && _redo.Count == 1 && _revisions.Count == 0, State());
            Check("redo enabled", RedoItem.IsEnabled, State());
            await RedoAsync();
            Check("redo", Text().Contains("Worker") && _redo.Count == 0 && _revisions.Count == 1, State());
            await UndoAsync();
            await UndoAsync();  // nothing more to undo: must not throw
            await RedoAsync();
            Check("undo+redo again", Text().Contains("Worker"), State());

            // Measurement.
            var annotations = _document!.AnnotationCount(0);
            await AddMeasurementAsync(0, "distance", [new Point(72, 72), new Point(216, 72)]);
            Check("measure distance", _document.AnnotationCount(0) == annotations + 1, $"{annotations} → {_document.AnnotationCount(0)}; {State()}");
            await UndoAsync();

            // Checkbox keeps the keyboard after its value is written.
            await RefreshFieldsAsync();
            var box = TabOrder().FirstOrDefault(w => w.Field.Kind == "checkbox");
            if (box is null) log.Add("SKIP checkbox — no checkbox in this document");
            else
            {
                var was = IsChecked(box.Field);
                FocusToggle(box);
                ToggleFocusedField();
                await FlushFieldsAsync();
                await RefreshFieldsAsync();
                Check("checkbox keeps focus after write", _focusedToggle is not null, State());
                if (_focusedToggle is { } focused) Check("checkbox toggled", IsChecked(LiveWidget(focused).Field) != was);
                ToggleFocusedField();
                await FlushFieldsAsync();
                await RefreshFieldsAsync();
                Check("checkbox toggles back", _focusedToggle is { } again && IsChecked(LiveWidget(again).Field) == was);
            }

            // Tab from a text field into a dropdown (this crashed WinUI when the dropdown opened
            // itself), and Tab past the last field leaves the form.
            var order = TabOrder();
            var before2 = order.FindIndex(w => w.Field.Kind == "text" && order.IndexOf(w) + 1 < order.Count && order[order.IndexOf(w) + 1].Field.Kind == "combo");
            if (before2 < 0) log.Add("SKIP text → dropdown — none in this document");
            else
            {
                OpenEditor(order[before2], fromKeyboard: true);
                await Task.Delay(300);
                MoveToField(order[before2], 1);
                await Task.Delay(600);
                Check("tab into dropdown", _editing?.Field.Kind == "combo", $"editing {_editing?.Field.Name}");
                CloseEditor(commit: false);
            }
            if (order.Count > 0)
            {
                MoveToField(order[^1], 1);
                await Task.Delay(300);
                Check("tab leaves form", _leftForm && _editing is null, $"leftForm={_leftForm} editing={_editing?.Field.Name}");
                _leftForm = false;
            }

            // Tabs: a second tab opens and closes; the same file isn't opened twice.
            var second = Host.AddTab(null);
            Check("new tab", Host.Panes.Count() == 2 && Host.ActivePane == second);
            await Host.CloseTabAsync(second);
            Check("close tab", Host.Panes.Count() == 1 && Host.ActivePane == this);
            Check("find open tab", Host.FindTab(input) == this);

            // Page Display: Two Page View pairs pages; Single Page shows one; Next steps by row.
            var n = _document.PageCount;
            SetViewMode(PageViewMode.Facing, cover: false);
            await Task.Delay(300);
            Check("facing rows", _rows.Count == (n + 1) / 2 && (n < 2 || PageTop(1) == PageTop(0)), $"{_rows.Count} rows for {n} pages");
            GoTo(0);
            StepPage(1);
            Check("facing next", n < 3 || _page == 2, $"page {_page}");
            SetViewMode(PageViewMode.Facing, cover: true);
            Check("cover page alone", _rows[0] is [-1, 0], string.Join(" ", _rows.Select(r => $"[{string.Join(",", r)}]")));
            SetViewMode(PageViewMode.Single, cover: false);
            await Task.Delay(300);
            Check("single page extent", PageScroller.ExtentHeight < _slots[_page].Height + 2 * ViewMargin + 40, $"extent {PageScroller.ExtentHeight:0}, page {_slots[_page].Height:0}");
            var at = _page;
            StepPage(1);
            Check("single next", n < 2 || _page == at + 1, $"{at} → {_page}");
            SetViewMode(PageViewMode.Continuous);
            await Task.Delay(300);
            Check("continuous extent", n < 2 || PageScroller.ExtentHeight > _slots[0].Height + _slots[1].Height, $"extent {PageScroller.ExtentHeight:0}");

            // Organize Pages shows the page grid in place of the page view.
            OpenTool("organize");
            await Task.Delay(300);
            Check("organize grid", OrganizeGrid.Visibility == Visibility.Visible && PageScroller.Visibility == Visibility.Collapsed && OrganizeGrid.Items.Count == n, $"grid {OrganizeGrid.Visibility}, scroller {PageScroller.Visibility}, items {OrganizeGrid.Items.Count}, tool {_openTool}");
            ShowToolList();
            Check("organize closes", OrganizeGrid.Visibility == Visibility.Collapsed && PageScroller.Visibility == Visibility.Visible);

            // Preflight and reading order queries parse.
            var preflight = await Engine.QueryAsync(CurrentPath!, "preflight", new JsonObject { ["profile"] = "commercial" }, _password);
            Check("preflight", preflight["results"] is JsonArray, $"{preflight["results"]?.AsArray().Count} results");
        }
        catch (Exception error)
        {
            failures++;
            log.Add($"FAIL exception — {error}");
        }
        log.Add($"{failures} failure(s)");
        await File.WriteAllLinesAsync(logPath, log);
        return failures;
    }
}
