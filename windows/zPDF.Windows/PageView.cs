using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace zPDF;

/// <summary>What a page overlay rectangle shows.</summary>
public enum Mark { Selection, FindHit, CurrentFindHit, CommentSelection, Field, Redaction, Change, ContentOutline, Handle }

/// <summary>A form value typed but not yet written into the PDF, drawn over its widget.</summary>
public sealed record FieldOverlay(Rect Rect, string Text, bool IsCheck, bool Checked, double FontSize);

/// <summary>An in-progress drawing (view points), shown until the comment is created.</summary>
public sealed record Draft(DraftShape Shape, IReadOnlyList<Point> Points, Windows.UI.Color Color);
public enum DraftShape { Rectangle, Ellipse, Line, Polyline }

/// <summary>Receives pointer input from pages; positions are in page view points.</summary>
public interface IPageHost
{
    void PagePointerPressed(PageSlot slot, Point point, PointerRoutedEventArgs e);
    void PagePointerMoved(PageSlot slot, Point point, PointerRoutedEventArgs e);
    void PagePointerReleased(PageSlot slot, Point point, PointerRoutedEventArgs e);
    InputSystemCursorShape CursorAt(PageSlot slot, Point point);
    /// <summary>For screen readers: "Page N of M" and the page's text (null until loaded).</summary>
    string PageLabelFor(PageSlot slot);
    string? PageTextFor(PageSlot slot);
}

/// <summary>Exposes a page to UI Automation as a document region named "Page N of M",
/// with the page's text as its description (Narrator reads it).</summary>
internal sealed class PageViewPeer(PageView owner) : Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(owner)
{
    protected override string GetNameCore() => owner.Slot is { Host: { } host } slot ? host.PageLabelFor(slot) : "Page";
    protected override string GetFullDescriptionCore() => owner.Slot is { Host: { } host } slot ? host.PageTextFor(slot) ?? "" : "";
    protected override string GetHelpTextCore() => GetFullDescriptionCore();
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationControlType GetAutomationControlTypeCore() =>
        Microsoft.UI.Xaml.Automation.Peers.AutomationControlType.Document;
    protected override string GetClassNameCore() => "PdfPage";
    protected override bool IsContentElementCore() => true;
    protected override bool IsControlElementCore() => true;
}

/// <summary>One page in the continuous view: its image and an overlay for
/// selection and search highlights.</summary>
public sealed partial class PageView : Grid
{
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() => new PageViewPeer(this);

    public static readonly DependencyProperty SlotProperty =
        DependencyProperty.Register(nameof(Slot), typeof(PageSlot), typeof(PageView), new PropertyMetadata(null, OnSlotChanged));

    private static readonly SolidColorBrush SelectionBrush = new(ColorHelper.FromArgb(0x55, 0x33, 0x88, 0xFF));
    private static readonly SolidColorBrush FindBrush = new(ColorHelper.FromArgb(0x66, 0xFF, 0xD4, 0x00));
    private static readonly SolidColorBrush CurrentFindBrush = new(ColorHelper.FromArgb(0x88, 0xFF, 0x8C, 0x00));
    private static readonly SolidColorBrush HandleFill = new(Microsoft.UI.Colors.White);
    private static readonly SolidColorBrush CommentSelectionBrush = new(ColorHelper.FromArgb(0xFF, 0x00, 0x67, 0xC0));
    private static readonly SolidColorBrush FieldBrush = new(ColorHelper.FromArgb(0x33, 0x33, 0x88, 0xFF));
    private static readonly SolidColorBrush RedactFill = new(ColorHelper.FromArgb(0x44, 0xFF, 0x30, 0x30));
    private static readonly SolidColorBrush RedactStroke = new(ColorHelper.FromArgb(0xFF, 0xD0, 0x10, 0x10));
    private static readonly SolidColorBrush PendingBrush = new(ColorHelper.FromArgb(0xFF, 0xF4, 0xF8, 0xFF));

    private readonly Image _image = new() { Stretch = Stretch.Fill };
    private readonly Canvas _overlay = new() { IsHitTestVisible = false };
    private readonly Canvas _editorLayer = new();  // an inline field editor, when one is open
    private FrameworkElement? _editor;
    private InputSystemCursorShape _cursor = InputSystemCursorShape.Arrow;

    public PageView()
    {
        Background = new SolidColorBrush(Colors.White);
        BorderThickness = new Thickness(1);
        BorderBrush = (Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"];
        Children.Add(_image);
        // The page itself is the accessible element (PageViewPeer); its bitmap adds nothing.
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(_image, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        Children.Add(_overlay);
        Children.Add(_editorLayer);
        PointerPressed += (_, e) => Forward(e, (h, s, p) => h.PagePointerPressed(s, p, e), capture: true);
        PointerMoved += (_, e) =>
        {
            Forward(e, (h, s, p) => h.PagePointerMoved(s, p, e));
            if (Slot?.Host is { } host && Slot is { } slot) SetCursor(host.CursorAt(slot, ToPoints(e.GetCurrentPoint(this).Position)));
        };
        PointerReleased += (_, e) => { Forward(e, (h, s, p) => h.PagePointerReleased(s, p, e)); ReleasePointerCaptures(); };
        SizeChanged += (_, _) => { DrawOverlay(); PlaceEditor(); };
    }

    public PageSlot? Slot
    {
        get => (PageSlot?)GetValue(SlotProperty);
        set => SetValue(SlotProperty, value);
    }

    private static void OnSlotChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var view = (PageView)d;
        if (e.OldValue is PageSlot old)
        {
            old.PropertyChanged -= view.Slot_PropertyChanged; old.MarksChanged -= view.DrawOverlay; old.DraftChanged -= view.DrawOverlay;
            old.EditorChanged -= view.PlaceEditor;
        }
        if (e.NewValue is PageSlot slot)
        {
            slot.PropertyChanged += view.Slot_PropertyChanged; slot.MarksChanged += view.DrawOverlay; slot.DraftChanged += view.DrawOverlay;
            slot.EditorChanged += view.PlaceEditor;
        }
        view.PlaceEditor();
        view.Refresh();
    }

    private void Slot_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => Refresh();

    private void Refresh()
    {
        if (Slot is not { } slot) return;
        Width = slot.Width;
        Height = slot.Height;
        _image.Source = slot.Image;
        AutomationProperties.SetName(this, slot.Label);
        DrawOverlay();
    }

    /// <summary>View points per device-independent pixel on this page.</summary>
    private double PointScale => Slot is { PointWidth: > 0 } slot ? slot.Width / slot.PointWidth : 1;

    private Point ToPoints(Point dips) => new(dips.X / PointScale, dips.Y / PointScale);

    private void Forward(PointerRoutedEventArgs e, Action<IPageHost, PageSlot, Point> action, bool capture = false)
    {
        if (Slot is not { Host: { } host } slot) return;
        if (capture) CapturePointer(e.Pointer);
        action(host, slot, ToPoints(e.GetCurrentPoint(this).Position));
    }

    private void SetCursor(InputSystemCursorShape shape)
    {
        if (shape == _cursor) return;
        _cursor = shape;
        ProtectedCursor = InputSystemCursor.Create(shape);
    }

    private static Shape DraftShapeFor(Draft draft, double scale)
    {
        var brush = new SolidColorBrush(draft.Color);
        var points = draft.Points.Select(p => new Point(p.X * scale, p.Y * scale)).ToList();
        if (draft.Shape == DraftShape.Polyline || points.Count < 2 || draft.Shape == DraftShape.Line)
        {
            var line = new Polyline { Stroke = brush, StrokeThickness = 2 };
            foreach (var p in draft.Shape == DraftShape.Line && points.Count > 1 ? [points[0], points[^1]] : points) line.Points.Add(p);
            return line;
        }
        var (a, b) = (points[0], points[^1]);
        Shape box = draft.Shape == DraftShape.Ellipse ? new Ellipse() : new Rectangle();
        box.Stroke = brush;
        box.StrokeThickness = 2;
        box.Width = Math.Abs(b.X - a.X);
        box.Height = Math.Abs(b.Y - a.Y);
        Canvas.SetLeft(box, Math.Min(a.X, b.X));
        Canvas.SetTop(box, Math.Min(a.Y, b.Y));
        return box;
    }

    /// <summary>Shows (or removes) the slot's inline editor over its field.</summary>
    private void PlaceEditor()
    {
        var wanted = Slot?.Editor ?? (null, null);
        if (_editor != wanted.Element)
        {
            _editorLayer.Children.Clear();
            _editor = wanted.Element;
            if (_editor is not null) _editorLayer.Children.Add(_editor);
        }
        if (_editor is null || Slot?.Editor.Rect is not { } rect) return;
        var scale = PointScale;
        double width = rect.Width * scale, height = rect.Height * scale;
        if (_editor is ComboBox combo)
        {
            // The dropdown arrow takes ~32 px: at least room for a short value beside it, and a
            // usable height, centred on the field rather than hanging below it.
            var fieldHeight = height;
            width = Math.Max(width, 84);
            height = Math.Max(height, 28);
            combo.FontSize = Math.Min(combo.FontSize, height * 0.5);
            _editor.Width = width;
            _editor.Height = height;
            Canvas.SetLeft(_editor, rect.X * scale);
            Canvas.SetTop(_editor, rect.Y * scale - (height - fieldHeight) / 2);
            return;
        }
        _editor.Width = Math.Max(24, width);
        _editor.Height = Math.Max(20, height);
        Canvas.SetLeft(_editor, rect.X * scale);
        Canvas.SetTop(_editor, rect.Y * scale);
    }

    private void DrawOverlay()
    {
        _overlay.Children.Clear();
        if (Slot is not { } slot) return;
        var scale = PointScale;
        foreach (var (rect, mark) in slot.Marks)
        {
            if (mark == Mark.Handle)
            {
                // A resize handle: a fixed-size square centred on the point, at any zoom.
                var handle = new Rectangle { Width = 8, Height = 8, Fill = HandleFill, Stroke = CommentSelectionBrush, StrokeThickness = 1.5 };
                Canvas.SetLeft(handle, (rect.X + rect.Width / 2) * scale - 4);
                Canvas.SetTop(handle, (rect.Y + rect.Height / 2) * scale - 4);
                _overlay.Children.Add(handle);
                continue;
            }
            var shape = new Rectangle
            {
                Width = Math.Max(1, rect.Width * scale),
                Height = Math.Max(1, rect.Height * scale),
            };
            if (mark == Mark.Field)
            {
                shape.Fill = FieldBrush;
            }
            else if (mark == Mark.ContentOutline)
            {
                shape.Stroke = new SolidColorBrush(ColorHelper.FromArgb(0x99, 0x60, 0x60, 0x60));
                shape.StrokeThickness = 1;
                shape.StrokeDashArray = [2, 2];
            }
            else if (mark == Mark.Change)
            {
                shape.Fill = new SolidColorBrush(ColorHelper.FromArgb(0x55, 0x2E, 0xB8, 0x5C));
                shape.Stroke = new SolidColorBrush(ColorHelper.FromArgb(0xFF, 0x1E, 0x8E, 0x3E));
                shape.StrokeThickness = 1;
            }
            else if (mark == Mark.Redaction)
            {
                shape.Fill = RedactFill;
                shape.Stroke = RedactStroke;
                shape.StrokeThickness = 1.5;
            }
            else if (mark == Mark.CommentSelection)
            {
                shape.Stroke = CommentSelectionBrush;
                shape.StrokeThickness = 1.5;
                shape.StrokeDashArray = [4, 2];
            }
            else
            {
                shape.Fill = mark switch { Mark.Selection => SelectionBrush, Mark.CurrentFindHit => CurrentFindBrush, _ => FindBrush };
            }
            Canvas.SetLeft(shape, rect.X * scale);
            Canvas.SetTop(shape, rect.Y * scale);
            _overlay.Children.Add(shape);
        }
        if (slot.Draft is { Points.Count: > 0 } draft) _overlay.Children.Add(DraftShapeFor(draft, scale));
        foreach (var field in slot.FieldOverlays)
        {
            // Pending form values: covers the widget's old appearance until the engine writes it.
            var box = new Border
            {
                Width = Math.Max(1, field.Rect.Width * scale), Height = Math.Max(1, field.Rect.Height * scale),
                Background = PendingBrush, Padding = new Thickness(2 * scale, 0, 2 * scale, 0),
            };
            var size = Math.Clamp((field.FontSize > 0 ? field.FontSize : Math.Min(12, field.Rect.Height * 0.72)) * scale, 6, 72);
            box.Child = new TextBlock
            {
                Text = field.IsCheck ? (field.Checked ? "✓" : "") : field.Text, FontSize = size,
                HorizontalAlignment = field.IsCheck ? HorizontalAlignment.Center : HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.Clip,
                Foreground = new SolidColorBrush(Colors.Black),
            };
            Canvas.SetLeft(box, field.Rect.X * scale);
            Canvas.SetTop(box, field.Rect.Y * scale);
            _overlay.Children.Add(box);
        }
    }
}
