using System.Text.Json.Nodes;
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

            // Tabs: a second tab opens and closes; the same file isn't opened twice.
            var second = Host.AddTab(null);
            Check("new tab", Host.Panes.Count() == 2 && Host.ActivePane == second);
            await Host.CloseTabAsync(second);
            Check("close tab", Host.Panes.Count() == 1 && Host.ActivePane == this);
            Check("find open tab", Host.FindTab(input) == this);

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
