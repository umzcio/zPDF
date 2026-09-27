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
public enum Mark { Selection, FindHit, CurrentFindHit, CommentSelection }

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
}

/// <summary>One page in the continuous view: its image and an overlay for
/// selection and search highlights.</summary>
public sealed partial class PageView : Grid
{
    public static readonly DependencyProperty SlotProperty =
        DependencyProperty.Register(nameof(Slot), typeof(PageSlot), typeof(PageView), new PropertyMetadata(null, OnSlotChanged));

    private static readonly SolidColorBrush SelectionBrush = new(ColorHelper.FromArgb(0x55, 0x33, 0x88, 0xFF));
    private static readonly SolidColorBrush FindBrush = new(ColorHelper.FromArgb(0x66, 0xFF, 0xD4, 0x00));
    private static readonly SolidColorBrush CurrentFindBrush = new(ColorHelper.FromArgb(0x88, 0xFF, 0x8C, 0x00));
    private static readonly SolidColorBrush CommentSelectionBrush = new(ColorHelper.FromArgb(0xFF, 0x00, 0x67, 0xC0));

    private readonly Image _image = new() { Stretch = Stretch.Fill };
    private readonly Canvas _overlay = new() { IsHitTestVisible = false };
    private InputSystemCursorShape _cursor = InputSystemCursorShape.Arrow;

    public PageView()
    {
        Background = new SolidColorBrush(Colors.White);
        BorderThickness = new Thickness(1);
        BorderBrush = (Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"];
        Children.Add(_image);
        Children.Add(_overlay);
        PointerPressed += (_, e) => Forward(e, (h, s, p) => h.PagePointerPressed(s, p, e), capture: true);
        PointerMoved += (_, e) =>
        {
            Forward(e, (h, s, p) => h.PagePointerMoved(s, p, e));
            if (Slot?.Host is { } host && Slot is { } slot) SetCursor(host.CursorAt(slot, ToPoints(e.GetCurrentPoint(this).Position)));
        };
        PointerReleased += (_, e) => { Forward(e, (h, s, p) => h.PagePointerReleased(s, p, e)); ReleasePointerCaptures(); };
        SizeChanged += (_, _) => DrawOverlay();
    }

    public PageSlot? Slot
    {
        get => (PageSlot?)GetValue(SlotProperty);
        set => SetValue(SlotProperty, value);
    }

    private static void OnSlotChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var view = (PageView)d;
        if (e.OldValue is PageSlot old) { old.PropertyChanged -= view.Slot_PropertyChanged; old.MarksChanged -= view.DrawOverlay; old.DraftChanged -= view.DrawOverlay; }
        if (e.NewValue is PageSlot slot) { slot.PropertyChanged += view.Slot_PropertyChanged; slot.MarksChanged += view.DrawOverlay; slot.DraftChanged += view.DrawOverlay; }
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

    private void DrawOverlay()
    {
        _overlay.Children.Clear();
        if (Slot is not { } slot) return;
        var scale = PointScale;
        foreach (var (rect, mark) in slot.Marks)
        {
            var shape = new Rectangle
            {
                Width = Math.Max(1, rect.Width * scale),
                Height = Math.Max(1, rect.Height * scale),
            };
            if (mark == Mark.CommentSelection)
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
    }
}
