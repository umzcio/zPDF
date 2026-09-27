using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using Windows.Foundation;

namespace zPDF;

/// <summary>Prepare Form (add, move, edit and delete fields; detect fields) and comment
/// interchange (import/export FDF and XFDF, flatten).</summary>
public sealed partial class MainWindow
{
    private string _newFieldType = "text";
    private FormWidget? _preparedWidget;
    private Point _prepareStart;
    private bool _prepareMoving;
    private PageSlot? _preparePressSlot;

    private bool IsPreparingForm => _tool == CommentTool.PrepareForm;

    private void PrepareForm_Click(object sender, RoutedEventArgs e)
    {
        SetTool(IsPreparingForm ? CommentTool.Select : CommentTool.PrepareForm);
        FieldTypeStrip.Visibility = IsPreparingForm ? Visibility.Visible : Visibility.Collapsed;
        if (IsPreparingForm) ShowTransient("Choose a field type and drag on the page; click a field to select, move or edit it.");
    }

    private void FieldType_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string type }) return;
        _newFieldType = type;
        foreach (var child in FieldTypeStrip.Children)
            if (child is Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Tag: string t } toggle) toggle.IsChecked = t == type;
    }

    // ---------------------------------------------------------------- pointer

    private bool PreparePointerPressed(PageSlot slot, Point point)
    {
        if (!IsPreparingForm) return false;
        _preparePressSlot = slot;
        _prepareStart = point;
        _prepareMoving = false;
        _preparedWidget = PreparableWidgetAt(slot.Index, point);
        RefreshMarks();
        return true;
    }

    private bool PreparePointerMoved(PageSlot slot, Point point)
    {
        if (!IsPreparingForm || _preparePressSlot is not { } press) return IsPreparingForm;
        if (Distance(point, _prepareStart) < 3) return true;
        _prepareMoving = true;
        if (_preparedWidget is { } widget && Info(widget.Page) is { } info)
        {
            var rect = WidgetRect(info, widget);
            var (dx, dy) = (point.X - _prepareStart.X, point.Y - _prepareStart.Y);
            press.SetDraft(new Draft(DraftShape.Rectangle, [new Point(rect.Left + dx, rect.Top + dy), new Point(rect.Right + dx, rect.Bottom + dy)],
                                     Microsoft.UI.ColorHelper.FromArgb(255, 0, 103, 192)));
        }
        else
        {
            press.SetDraft(new Draft(DraftShape.Rectangle, [_prepareStart, point], Microsoft.UI.ColorHelper.FromArgb(255, 0, 103, 192)));
        }
        return true;
    }

    private bool PreparePointerReleased(PageSlot slot, Point point)
    {
        if (!IsPreparingForm) return false;
        if (_preparePressSlot is not { } press) return true;
        press.SetDraft(null);
        _preparePressSlot = null;
        if (Info(press.Index) is not { } info) return true;
        if (_preparedWidget is { } widget)
        {
            if (!_prepareMoving) return true;  // a click selects
            var rect = WidgetRect(info, widget);
            var moved = new Rect(rect.X + point.X - _prepareStart.X, rect.Y + point.Y - _prepareStart.Y, rect.Width, rect.Height);
            _ = EditFormAsync("Moving field…", new JsonObject
            {
                ["op"] = "update_form_field", ["name"] = widget.Field.Name, ["rect"] = ToJson(PdfRect(info, moved)),
                ["widget"] = widget.Field.Widgets.IndexOf(widget),
            });
            return true;
        }
        // A drag draws a new field; a click places one at a sensible size.
        var box = new Rect(_prepareStart, point);
        if (box.Width < 6 || box.Height < 6)
            box = _newFieldType is "checkbox" or "radio" ? new Rect(point.X, point.Y, 14, 14) : new Rect(point.X, point.Y, 160, 20);
        _ = EditFormAsync("Adding field…", new JsonObject
        {
            ["op"] = "add_form_field", ["type"] = _newFieldType, ["page"] = press.Index, ["rect"] = ToJson(PdfRect(info, box)),
        });
        return true;
    }

    /// <summary>Any widget (read-only and buttons included) under the point, for editing.</summary>
    private FormWidget? PreparableWidgetAt(int page, Point point)
    {
        if (Info(page) is not { } info) return null;
        return _fields.SelectMany(f => f.Widgets).Where(w => w.Page == page).LastOrDefault(w => WidgetRect(info, w).Contains(point));
    }

    private IEnumerable<(int Page, Rect Rect)> PrepareMarks()
    {
        if (IsPreparingForm && _preparedWidget is { } widget && _infos.GetValueOrDefault(widget.Page) is { } info)
            yield return (widget.Page, Inflate(WidgetRect(info, widget), 2));
    }

    private Task EditFormAsync(string status, JsonObject op) =>
        Run(status, async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [op], _password);
            PushRevision(edited);
            _preparedWidget = null;
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
        });

    // ---------------------------------------------------------------- field commands

    private void DeleteField_Click(object sender, RoutedEventArgs e) => DeletePreparedField();

    private bool DeletePreparedField()
    {
        if (!IsPreparingForm || _preparedWidget is not { } widget) return false;
        var op = new JsonObject { ["op"] = "delete_form_field", ["name"] = widget.Field.Name };
        if (widget.Field.Widgets.Count > 1) op["widget"] = widget.Field.Widgets.IndexOf(widget);
        _ = EditFormAsync("Deleting field…", op);
        return true;
    }

    private async void FieldProperties_Click(object sender, RoutedEventArgs e) => await EditFieldPropertiesAsync();

    private async Task EditFieldPropertiesAsync()
    {
        if (_preparedWidget is not { } widget) { StatusText.Text = "Select a field first."; return; }
        var field = widget.Field;
        var name = Text("Name", field.Name);
        var tooltip = Text("Tooltip (read by screen readers)", field.Tooltip);
        var required = new CheckBox { Content = "Required" };
        var readOnly = new CheckBox { Content = "Read-only", IsChecked = field.ReadOnly };
        var controls = new List<UIElement> { name, tooltip, required, readOnly };
        CheckBox? multiline = null;
        NumberBox? maxLength = null;
        TextBox? options = null;
        CheckBox? editable = null;
        if (field.Kind == "text")
        {
            multiline = new CheckBox { Content = "Multi-line", IsChecked = field.Multiline };
            maxLength = Number("Maximum characters (0 = no limit)", field.MaxLength ?? 0, 0, 10000);
            controls.AddRange([multiline, maxLength]);
        }
        if (field.Kind is "combo" or "list")
        {
            options = new TextBox { Header = "Options (one per line)", AcceptsReturn = true, MinHeight = 90, Text = string.Join("\r", field.Options.Select(o => o.Label)) };
            controls.Add(options);
            if (field.Kind == "combo") { editable = new CheckBox { Content = "Allow typing your own value", IsChecked = field.Editable }; controls.Add(editable); }
        }
        if (!await AskAsync($"{CommentItem.Kind(field.Kind)} Field Properties".Replace("text", "Text"), Stack([.. controls]), "Save")) return;
        var op = new JsonObject
        {
            ["op"] = "update_form_field", ["name"] = field.Name, ["tooltip"] = tooltip.Text,
            ["required"] = required.IsChecked == true, ["readonly"] = readOnly.IsChecked == true,
        };
        if (name.Text.Trim() is { Length: > 0 } newName && newName != field.Name) op["new_name"] = newName;
        if (multiline is not null) op["multiline"] = multiline.IsChecked == true;
        if (maxLength is not null && !double.IsNaN(maxLength.Value)) op["max_length"] = (int)maxLength.Value > 0 ? (int)maxLength.Value : null;
        if (options is not null)
            op["options"] = new JsonArray(options.Text.Split('\r', '\n').Select(o => o.Trim()).Where(o => o.Length > 0).Select(o => (JsonNode)o).ToArray());
        if (editable is not null) op["editable"] = editable.IsChecked == true;
        await EditFormAsync("Saving field…", op);
    }

    /// <summary>Finds form boxes on the current page (lines, boxes and labels) and adds fields.</summary>
    private async void DetectFields_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null || _document is null) return;
        await Run("Looking for fields…", async () =>
        {
            var opened = await Engine.CallAsync("open", new JsonObject { ["path"] = CurrentPath });
            var pageId = opened["pages"]![_page]!["id"]!.DeepClone();
            var found = await Engine.CallAsync("detect_fields", new JsonObject { ["ref"] = opened["ref"]!.DeepClone(), ["page_id"] = pageId });
            var fields = found["fields"]!.AsArray();
            if (fields.Count == 0) { StatusText.Text = "No new fields found on this page."; return; }
            var ops = new JsonArray();
            foreach (var f in fields)
                ops.Add(new JsonObject { ["op"] = "add_form_field", ["type"] = f!["type"]!.GetValue<string>(), ["page"] = _page, ["rect"] = f["rect"]!.DeepClone() });
            var edited = await Engine.TransformAsync(CurrentPath!, ops, _password);
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
            StatusText.Text = $"Added {fields.Count} field{(fields.Count == 1 ? "" : "s")}. Review them; Undo removes them all.";
        }, keepStatus: true);
    }

    private async void FlattenForm_Click(object sender, RoutedEventArgs e)
    {
        if (!await AskAsync("Flatten Form Fields?", new TextBlock { Text = "Field values become ordinary page content and the fields are removed. You can undo this until you save.", TextWrapping = TextWrapping.Wrap }, "Flatten")) return;
        await EditDocumentAsync("Flattening form…", new JsonObject { ["op"] = "flatten_form_fields" });
    }

    // ---------------------------------------------------------------- comment interchange

    private async void ImportComments_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        foreach (var t in new[] { ".xfdf", ".fdf", ".pdf" }) picker.FileTypeFilter.Add(t);
        if (await picker.PickSingleFileAsync() is not { } file) return;
        await EditDocumentAsync("Importing comments…", new JsonObject { ["op"] = "import_comments", ["path"] = file.Path });
    }

    private async void ExportComments_Click(object sender, RoutedEventArgs e)
    {
        var format = Choice("Format", ["XFDF (Acrobat, most apps)", "FDF"]);
        if (!await AskAsync("Export Comments", Stack(format), "Export…")) return;
        var fdf = format.SelectedIndex == 1;
        var picker = new FileSavePicker(AppWindow.Id) { SuggestedFileName = Path.GetFileNameWithoutExtension(_sourcePath) + " comments", DefaultFileExtension = fdf ? ".fdf" : ".xfdf" };
        picker.FileTypeChoices.Add(fdf ? "FDF" : "XFDF", [fdf ? ".fdf" : ".xfdf"]);
        if (await picker.PickSaveFileAsync() is not { } file) return;
        try
        {
            var result = await Engine.QueryAsync(CurrentPath!, "export_comments", new JsonObject
            {
                ["format"] = fdf ? "fdf" : "xfdf", ["file_name"] = Path.GetFileName(_sourcePath),
            }, _password);
            if (fdf) await File.WriteAllBytesAsync(file.Path, Convert.FromBase64String(result["data"]!.GetValue<string>()));
            else await File.WriteAllTextAsync(file.Path, result["text"]!.GetValue<string>());
            StatusText.Text = $"Exported {result["count"]} comment(s) to {Path.GetFileName(file.Path)}";
        }
        catch (Exception error) when (error is EngineException or IOException) { StatusText.Text = error.Message; }
    }

    private async void FlattenComments_Click(object sender, RoutedEventArgs e)
    {
        if (!await AskAsync("Flatten Comments?", new TextBlock { Text = "Comments become part of the page and can no longer be edited. You can undo this until you save.", TextWrapping = TextWrapping.Wrap }, "Flatten")) return;
        await EditDocumentAsync("Flattening comments…", new JsonObject { ["op"] = "flatten_annotations" });
    }
}
