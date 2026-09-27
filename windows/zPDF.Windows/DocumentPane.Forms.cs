using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Foundation;
using Windows.System;

namespace zPDF;

/// <summary>One widget of a form field (a field can have several, e.g. radio buttons).</summary>
public sealed record FormWidget(FormField Field, int Page, double[] Rect, string? Export);

/// <summary>A form field as the engine describes it (form_fields).</summary>
public sealed class FormField
{
    public required string Name { get; init; }
    public required string Kind { get; init; }   // text, checkbox, radio, combo, list, button, signature, barcode
    public string Tooltip { get; init; } = "";
    public bool ReadOnly { get; init; }
    public bool Multiline { get; init; }
    public bool Password { get; init; }
    public bool Editable { get; init; }          // combo with free text
    public bool Required { get; init; }
    public int? MaxLength { get; init; }
    public double FontSize { get; init; }
    public JsonNode? Value { get; init; }
    public List<(string Label, string Export)> Options { get; init; } = [];
    public List<FormWidget> Widgets { get; } = [];
    public string Text => Value is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";
}

/// <summary>Filling in forms. Typed values collect in memory (drawn over their widgets
/// at once) and are written into the PDF in one engine call — one undo step — after a
/// pause, or before any other action.</summary>
public sealed partial class DocumentPane
{
    private List<FormField> _fields = [];
    private readonly Dictionary<string, JsonNode> _pendingValues = [];
    private int _fieldsGeneration;
    private FormWidget? _editing;
    private PageSlot? _editorSlot;
    private CancellationTokenSource? _flushTimer;
    private bool _highlightFields = true;

    private bool HasPendingFields => _pendingValues.Count > 0;

    // ---------------------------------------------------------------- loading

    private async Task RefreshFieldsAsync()
    {
        var generation = ++_fieldsGeneration;
        if (CurrentPath is not { } path) return;
        JsonNode result;
        try { result = await Engine.QueryAsync(path, "form_fields", password: _password); }
        catch (EngineException) { return; }
        if (generation != _fieldsGeneration) return;
        var fields = new List<FormField>();
        foreach (var node in result["fields"]!.AsArray())
        {
            var field = new FormField
            {
                Name = node!["name"]!.GetValue<string>(), Kind = node["kind"]!.GetValue<string>(),
                Tooltip = node["tooltip"]?.GetValue<string>() ?? "", ReadOnly = node["readonly"]?.GetValue<bool>() ?? false,
                Multiline = node["multiline"]?.GetValue<bool>() ?? false, Password = node["password"]?.GetValue<bool>() ?? false,
                Editable = node["editable"]?.GetValue<bool>() ?? false, Required = node["required"]?.GetValue<bool>() ?? false,
                MaxLength = node["max_length"] is JsonValue m && m.TryGetValue<int>(out var max) ? max : null,
                FontSize = node["font_size"]?.GetValue<double>() ?? 0, Value = node["value"]?.DeepClone(),
                Options = node["options"]?.AsArray().Select(o => (o!["label"]!.GetValue<string>(), o["export"]!.GetValue<string>())).ToList() ?? [],
            };
            if (node["hidden"]?.GetValue<bool>() == true) continue;
            foreach (var w in node["widgets"]!.AsArray())
            {
                if (w!["page"] is not JsonValue p || !p.TryGetValue<int>(out var page) || page < 0) continue;
                field.Widgets.Add(new FormWidget(field, page, w["rect"]!.AsArray().Select(v => v!.GetValue<double>()).ToArray(),
                                                 w["export"]?.GetValue<string>()));
            }
            if (field.Widgets.Count > 0) fields.Add(field);
        }
        _fields = fields;
        HighlightFieldsItem.IsEnabled = _fields.Count > 0;
        RefreshMarks();
        RefreshFieldOverlays();
    }

    /// <summary>Fillable widgets in reading order: page, then top to bottom, left to right.</summary>
    private List<FormWidget> TabOrder() =>
        _fields.Where(f => !f.ReadOnly && f.Kind is "text" or "checkbox" or "radio" or "combo" or "list")
               .SelectMany(f => f.Kind == "radio" ? f.Widgets.Take(1) : f.Widgets)
               .OrderBy(w => w.Page).ThenByDescending(w => Math.Round(w.Rect[3] / 4)).ThenBy(w => w.Rect[0]).ToList();

    private FormWidget? WidgetAt(int page, Point point)
    {
        if (_fields.Count == 0 || Info(page) is not { } info) return null;
        foreach (var field in _fields)
        {
            if (field.ReadOnly || field.Kind is "button" or "signature" or "barcode") continue;
            foreach (var widget in field.Widgets.Where(w => w.Page == page))
                if (WidgetRect(info, widget).Contains(point)) return widget;
        }
        return null;
    }

    private static Rect WidgetRect(PageInfo info, FormWidget widget) =>
        info.ToView(new Rect(new Point(widget.Rect[0], widget.Rect[1]), new Point(widget.Rect[2], widget.Rect[3])));

    /// <summary>The light-blue field highlights (added to the page marks).</summary>
    private IEnumerable<(int Page, Rect Rect)> FieldMarks()
    {
        if (!_highlightFields && !IsPreparingForm) yield break;
        foreach (var field in _fields)
        {
            if (field.ReadOnly || field.Kind is "button" or "barcode") continue;
            foreach (var widget in field.Widgets)
                if (_infos.GetValueOrDefault(widget.Page) is { } info) yield return (widget.Page, WidgetRect(info, widget));
        }
    }

    // ---------------------------------------------------------------- clicking fields

    /// <summary>Select tool: a click on a fillable widget edits it. True when handled.</summary>
    private bool FieldPointerPressed(PageSlot slot, Point point)
    {
        if (_tool != CommentTool.Select || WidgetAt(slot.Index, point) is not { } widget) return false;
        switch (widget.Field.Kind)
        {
            case "checkbox":
                CommitEditor();
                SetPending(widget.Field, JsonValue.Create(!IsChecked(widget.Field)));
                FocusToggle(widget);
                break;
            case "radio":
                CommitEditor();
                var export = widget.Export ?? "";
                if (CurrentText(widget.Field) != export) SetPending(widget.Field, JsonValue.Create(export));
                FocusToggle(widget);
                break;
            default:
                OpenEditor(widget);
                break;
        }
        return true;
    }

    private bool IsChecked(FormField field)
    {
        var value = _pendingValues.TryGetValue(field.Name, out var pending) ? pending : field.Value;
        return value switch
        {
            JsonValue v when v.TryGetValue<bool>(out var b) => b,
            JsonValue v when v.TryGetValue<string>(out var s) => s is not ("" or "Off"),
            _ => false,
        };
    }

    private string CurrentText(FormField field) =>
        _pendingValues.TryGetValue(field.Name, out var pending) && pending is JsonValue v && v.TryGetValue<string>(out var s) ? s : field.Text;

    // ---------------------------------------------------------------- inline editor

    /// <summary>`fromKeyboard`: reached with Tab, so a dropdown doesn't pop open by itself (opening
    /// its popup while the Tab key is still being handled crashed WinUI); Alt+Down or F4 opens it.</summary>
    private void OpenEditor(FormWidget widget, bool fromKeyboard = false)
    {
        CommitEditor();
        if (Info(widget.Page) is not { } info) return;
        var slot = _slots[widget.Page];
        var rect = WidgetRect(info, widget);
        FrameworkElement editor;
        if (widget.Field.Kind is "combo" or "list")
        {
            var combo = new ComboBox
            {
                IsEditable = widget.Field.Editable, MinWidth = 0,
                ItemsSource = widget.Field.Options.Select(o => o.Label).ToList(),
            };
            var current = CurrentText(widget.Field);
            var index = widget.Field.Options.FindIndex(o => o.Export == current || o.Label == current);
            if (index >= 0) combo.SelectedIndex = index;
            else if (widget.Field.Editable) combo.Text = current;
            combo.SelectionChanged += (_, _) =>
            {
                if (combo.SelectedIndex >= 0) SetPending(widget.Field, JsonValue.Create(widget.Field.Options[combo.SelectedIndex].Export));
            };
            combo.DropDownClosed += (_, _) => CommitEditor();
            editor = combo;
            // Tab / Shift+Tab move to the next field here too (the combo would take the key otherwise).
            combo.PreviewKeyDown += (_, e) =>
            {
                if (e.Key != VirtualKey.Tab || combo.IsDropDownOpen || _editing != widget) return;
                e.Handled = true;
                var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
                DispatcherQueue.TryEnqueue(() => MoveToField(widget, shift ? -1 : 1));
            };
            DispatcherQueue.TryEnqueue(() =>
            {
                combo.Focus(fromKeyboard ? FocusState.Keyboard : FocusState.Programmatic);
                if (!fromKeyboard) combo.IsDropDownOpen = !widget.Field.Editable;
            });
        }
        else
        {
            var box = new TextBox
            {
                Text = CurrentText(widget.Field), AcceptsReturn = widget.Field.Multiline,
                TextWrapping = widget.Field.Multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
                MinHeight = 0, MinWidth = 0, Padding = new Thickness(3, 1, 3, 1),
                FontSize = Math.Clamp((widget.Field.FontSize > 0 ? widget.Field.FontSize : Math.Min(11, rect.Height * 0.7)) * slot.Width / slot.PointWidth, 8, 48),
            };
            // A full accent outline while typing (the default focus cue is a thin underline).
            box.Resources["TextControlBorderBrushFocused"] = ThemeBrushes.Get(this, "ZAccent");
            box.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(2);
            if (widget.Field.MaxLength is { } max) box.MaxLength = max;
            box.KeyDown += Editor_KeyDown;
            box.LostFocus += (_, _) => DispatcherQueue.TryEnqueue(() => { if (_editing == widget) CommitEditor(); });
            editor = box;
            DispatcherQueue.TryEnqueue(() => { box.Focus(FocusState.Programmatic); box.SelectAll(); });
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(editor, widget.Field.Tooltip.Length > 0 ? widget.Field.Tooltip : widget.Field.Name);
        _editing = widget;
        _editorSlot = slot;
        _flushTimer?.Cancel();  // never write the PDF (and replace the view) while typing
        slot.SetEditor(editor, rect);
        StatusText.Text = widget.Field.Tooltip.Length > 0 ? widget.Field.Tooltip.Trim() : widget.Field.Name;
    }

    private void Editor_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_editing is not { } widget) return;
        switch (e.Key)
        {
            case VirtualKey.Enter when !widget.Field.Multiline:
                CommitEditor();
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                CloseEditor(commit: false);
                e.Handled = true;
                break;
            case VirtualKey.Tab:
                var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
                    .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
                DispatcherQueue.TryEnqueue(() => MoveToField(widget, shift ? -1 : 1));  // not while this box handles its key
                e.Handled = true;
                break;
        }
    }

    /// <summary>Tab / Shift+Tab: the next fillable field in reading order.</summary>
    private void MoveToField(FormWidget from, int step)
    {
        var order = TabOrder();
        var index = order.FindIndex(w => w.Field == from.Field);
        CommitEditor();
        if (order.Count == 0) return;
        var target = Math.Max(0, index) + step;
        if (target < 0 || target >= order.Count)
        {
            // Past the last (or before the first) field: back to the page, and the next Tab goes on to
            // the rest of the window instead of into the fields again (no keyboard trap).
            _focusedToggle = null;
            RefreshMarks();
            PageScroller.Focus(FocusState.Keyboard);
            // After the focus change settles (its LostFocus events would clear the flag).
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => _leftForm = true);
            return;
        }
        var next = order[target];
        EnsureVisible(next);
        if (next.Field.Kind is "checkbox" or "radio") FocusToggle(next);
        else OpenEditor(next, fromKeyboard: true);
    }

    private FormWidget? _focusedToggle;
    private bool _leftForm;  // Tab went past the last field; the next Tab leaves the page

    /// <summary>The same widget in the current field list (fields reload after each write).</summary>
    private FormWidget LiveWidget(FormWidget widget) =>
        _fields.Contains(widget.Field) ? widget
            : _fields.Where(f => f.Name == widget.Field.Name).SelectMany(f => f.Widgets)
                     .FirstOrDefault(w => w.Page == widget.Page && w.Rect.SequenceEqual(widget.Rect) && w.Export == widget.Export) ?? widget;

    /// <summary>A checkbox or radio button is the keyboard target: Space toggles it,
    /// Tab / Shift+Tab move on. Focus goes to the page so no toolbar button takes the key.</summary>
    private void FocusToggle(FormWidget widget)
    {
        _focusedToggle = widget;
        PageScroller.Focus(FocusState.Programmatic);
        StatusText.Text = $"{(widget.Field.Tooltip.Length > 0 ? widget.Field.Tooltip.Trim() : widget.Field.Name)} — Space to toggle, Tab for the next field";
    }

    /// <summary>Tab/Shift+Tab and Space for a checkbox or radio that has the keyboard. Handled
    /// before focus navigation and the scroll view (which would otherwise take these keys).</summary>
    private void Root_PreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // Esc leaves full screen before any focused control (a scroller, a field) can take it.
        if (e.Key == VirtualKey.Escape && IsFullScreen && !DialogOpen())
        {
            SetFullScreen(false);
            e.Handled = true;
            return;
        }
        // Enter finishes a perimeter or area wherever focus is (a toolbar button would take it).
        if (_measureSlot is not null && e.Key == VirtualKey.Enter)
        {
            FinishMeasurement();
            e.Handled = true;
            return;
        }
        // Tab from the page itself goes into the document's form fields (from the current page).
        if (e.Key == VirtualKey.Tab && _leftForm) { _leftForm = false; return; }  // just left the form: Tab moves on
        if (e.Key == VirtualKey.Tab && _focusedToggle is null && _editing is null && _document is not null
            && ReferenceEquals(FocusManager.GetFocusedElement(XamlRoot), PageScroller) && TabOrder() is { Count: > 0 } order)
        {
            var back = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (!back)
            {
                var first = order.FirstOrDefault(w => w.Page >= _page) ?? order[0];
                EnsureVisible(first);
                if (first.Field.Kind is "checkbox" or "radio") FocusToggle(first);
                else OpenEditor(first, fromKeyboard: true);
                e.Handled = true;
                return;
            }
        }
        if (_focusedToggle is null || _editing is not null || FindBox.FocusState != FocusState.Unfocused) return;
        var widget = _focusedToggle = LiveWidget(_focusedToggle);
        if (e.Key == VirtualKey.Tab)
        {
            e.Handled = true;
            var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            _focusedToggle = null;
            MoveToField(widget, shift ? -1 : 1);
        }
        else if (e.Key == VirtualKey.Space)
        {
            e.Handled = ToggleFocusedField();
        }
    }

    private void EnsureVisible(FormWidget widget)
    {
        if (Info(widget.Page) is not { } info) { GoTo(widget.Page); return; }
        var slot = _slots[widget.Page];
        var rect = WidgetRect(info, widget);
        var scale = slot.Width / slot.PointWidth;
        var top = PageTop(widget.Page) + rect.Top * scale;
        if (top < PageScroller.VerticalOffset + 20 || top + rect.Height * scale > PageScroller.VerticalOffset + PageScroller.ViewportHeight - 20)
        {
            _page = widget.Page;
            ScrollTo(widget.Page, top - PageScroller.ViewportHeight / 3);
        }
    }

    private void CommitEditor() => CloseEditor(commit: true);

    private void CloseEditor(bool commit)
    {
        if (_editing is not { } widget || _editorSlot is not { } slot) return;
        var element = slot.Editor.Element;
        _editing = null;
        _editorSlot = null;
        slot.SetEditor(null, null);
        // The field's hint was only for while it was being filled in.
        if (StatusText.Text == (widget.Field.Tooltip.Length > 0 ? widget.Field.Tooltip.Trim() : widget.Field.Name)) StatusText.Text = "";
        if (commit && element is TextBox box && box.Text != CurrentText(widget.Field)) SetPending(widget.Field, JsonValue.Create(box.Text));
        else if (commit && element is ComboBox { IsEditable: true } combo && combo.SelectedIndex < 0 && combo.Text != CurrentText(widget.Field))
            SetPending(widget.Field, JsonValue.Create(combo.Text));
        else ScheduleFlush();
        PageScroller.Focus(FocusState.Programmatic);
    }

    private void SetPending(FormField field, JsonNode value)
    {
        _pendingValues[field.Name] = value;
        RefreshFieldOverlays();
        UpdateStatus();
        ScheduleFlush();
    }

    private void RefreshFieldOverlays()
    {
        var byPage = new Dictionary<int, List<FieldOverlay>>();
        foreach (var field in _fields)
        {
            if (!_pendingValues.TryGetValue(field.Name, out var value)) continue;
            foreach (var widget in field.Widgets)
            {
                if (_infos.GetValueOrDefault(widget.Page) is not { } info) { _ = InfoAsync(widget.Page); continue; }
                var check = field.Kind is "checkbox" or "radio";
                var on = field.Kind == "radio" ? (value as JsonValue)?.GetValue<string>() == widget.Export : IsChecked(field);
                var text = value is JsonValue v && v.TryGetValue<string>(out var s)
                    ? field.Password ? new string('•', s.Length) : field.Options.FirstOrDefault(o => o.Export == s).Label ?? s
                    : "";
                if (!byPage.TryGetValue(widget.Page, out var list)) byPage[widget.Page] = list = [];
                list.Add(new FieldOverlay(WidgetRect(info, widget), text, check, on, field.FontSize));
            }
        }
        foreach (var slot in _slots) slot.SetFieldOverlays(byPage.TryGetValue(slot.Index, out var list) ? list : []);
    }

    // ---------------------------------------------------------------- writing values into the PDF

    /// <summary>Writes pending values after a short pause (never while an editor is open).</summary>
    private async void ScheduleFlush()
    {
        _flushTimer?.Cancel();
        var timer = _flushTimer = new CancellationTokenSource();
        try { await Task.Delay(1500, timer.Token); }
        catch (TaskCanceledException) { return; }
        if (_editing is null) await FlushFieldsAsync();
    }

    /// <summary>Writes every pending value in one engine call (one undo step).</summary>
    private async Task FlushFieldsAsync()
    {
        CommitEditor();
        _flushTimer?.Cancel();
        if (!HasPendingFields || CurrentPath is null) return;
        var values = new JsonObject();
        foreach (var (name, value) in _pendingValues) values[name] = value.DeepClone();
        var written = false;
        await Run("Saving form entries…", flushFields: false, action: async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [new JsonObject { ["op"] = "fill_fields", ["values"] = values }], _password);
            PushRevision(edited);
            _pendingValues.Clear();
            written = true;
            // Reloading the view drops per-page state; keep the checkbox or radio that has the keyboard.
            var toggle = _focusedToggle;
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
            if (toggle is not null && _editing is null)
            {
                _focusedToggle = toggle;
                PageScroller.Focus(FocusState.Programmatic);
            }
        });
        if (!written)
        {
            // The engine refused (e.g. a value fails the field's format): keep the entries.
            RefreshFieldOverlays();
        }
    }

    private void DiscardPendingFields()
    {
        CloseEditor(commit: false);
        _flushTimer?.Cancel();
        _pendingValues.Clear();
        RefreshFieldOverlays();
    }

    // ---------------------------------------------------------------- toolbar

    private void HighlightFields_Toggled(object sender, RoutedEventArgs e)
    {
        _highlightFields = HighlightFieldsButton.IsOn;
        RefreshMarks();
    }

    private void HighlightFieldsMenu_Click(object sender, RoutedEventArgs e) => HighlightFieldsButton.IsOn = !HighlightFieldsButton.IsOn;

    private async void ResetForm_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = "Reset the form?", Content = "Every field goes back to its default value. You can undo this.",
            PrimaryButtonText = "Reset", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        DiscardPendingFields();
        await Run("Resetting form…", async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [new JsonObject { ["op"] = "reset_form" }], _password);
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
        });
    }

    private void Space_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (FindBox.FocusState != FocusState.Unfocused || DialogOpen()) return;
        args.Handled = ToggleFocusedField();
    }

    /// <summary>Space toggles a checkbox or radio reached with Tab.</summary>
    private bool ToggleFocusedField()
    {
        if (_focusedToggle is null) return false;
        var widget = _focusedToggle = LiveWidget(_focusedToggle);
        if (widget.Field.Kind == "checkbox") SetPending(widget.Field, JsonValue.Create(!IsChecked(widget.Field)));
        else if (widget.Export is { } export) SetPending(widget.Field, JsonValue.Create(export));
        return true;
    }
}
