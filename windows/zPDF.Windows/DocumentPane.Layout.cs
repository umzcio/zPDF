using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Foundation;

namespace zPDF;

/// <summary>The page layouts of the Mac's View ▸ Page Display (zPDF/App/DocumentTab.swift PDFViewMode).</summary>
public enum PageViewMode { Single, Continuous, Facing }

/// <summary>Page layout: pages sit in rows (one page, or two facing pages with an optional
/// cover page alone on the right). Continuous shows every row in a scrolling column; Single
/// Page and Facing Pages show one row at a time and step between rows.</summary>
public sealed partial class DocumentPane
{
    private PageViewMode _viewMode = AppSettings.Current.DefaultViewMode switch
    {
        "single" => PageViewMode.Single, "facing" => PageViewMode.Facing, _ => PageViewMode.Continuous,
    };
    private bool _coverPage;
    private List<int[]> _rows = [];
    private int[] _rowOf = [];
    private int _shownRow;
    private DateTime _lastWheelStep;

    private bool Paged => _viewMode != PageViewMode.Continuous;
    private int Columns => _viewMode == PageViewMode.Facing ? 2 : 1;

    /// <summary>Rebuilds the rows when the page count or layout changed; -1 is an empty cell.</summary>
    private void EnsureRows(bool force = false)
    {
        if (!force && _rowOf.Length == _slots.Count) return;
        _rows = [];
        var n = _slots.Count;
        if (_viewMode != PageViewMode.Facing) for (var i = 0; i < n; i++) _rows.Add([i]);
        else
        {
            var start = 0;
            if (_coverPage && n > 0) { _rows.Add([-1, 0]); start = 1; }
            for (var i = start; i < n; i += 2) _rows.Add(i + 1 < n ? [i, i + 1] : [i]);
        }
        _rowOf = new int[n];
        for (var r = 0; r < _rows.Count; r++) foreach (var p in _rows[r]) if (p >= 0) _rowOf[p] = r;
        _shownRow = Math.Clamp(_shownRow, 0, Math.Max(0, _rows.Count - 1));
        ApplyRows();
    }

    private void ApplyRows()
    {
        if (Pages.ItemsPanelRoot is not PageRowsPanel panel) return;
        panel.Rows = _rows;
        panel.Columns = Columns;
        panel.ShownRow = Paged ? _shownRow : -1;
        panel.Spacing = PageSpacing;
        panel.InvalidateMeasure();
    }

    private double RowHeight(int row) => _rows[row].Where(p => p >= 0).Select(p => _slots[p].Height).DefaultIfEmpty(0).Max();

    private double RowTop(int row)
    {
        var top = ViewMargin;
        if (Paged) return top;
        for (var r = 0; r < row; r++) top += RowHeight(r) + PageSpacing;
        return top;
    }

    private double PageTop(int page)
    {
        EnsureRows();
        return page < _rowOf.Length ? RowTop(_rowOf[page]) : ViewMargin;
    }

    private (int First, int Last) VisibleRange()
    {
        EnsureRows();
        if (_slots.Count == 0) return (0, -1);
        if (Paged) return RowPages(_shownRow);
        double top = PageScroller.VerticalOffset, bottom = top + PageScroller.ViewportHeight;
        int first = -1, last = -1;
        var y = ViewMargin;
        for (var r = 0; r < _rows.Count; r++)
        {
            var end = y + RowHeight(r);
            if (end >= top && y <= bottom)
            {
                var (a, b) = RowPages(r);
                if (first < 0) first = a;
                last = b;
            }
            y = end + PageSpacing;
        }
        return first < 0 ? (0, 0) : (first, last);
    }

    private (int First, int Last) RowPages(int row)
    {
        var pages = _rows[Math.Clamp(row, 0, _rows.Count - 1)].Where(p => p >= 0).ToArray();
        return (pages.Min(), pages.Max());
    }

    private void UpdateCurrentPage()
    {
        EnsureRows();
        if (_slots.Count == 0) return;
        int row;
        if (Paged) row = _shownRow;
        // At the bottom of the document the last row is current (its top may never reach the
        // reading line); otherwise the row under the reading line is.
        else if (PageScroller.VerticalOffset >= PageScroller.ScrollableHeight - 1 && PageScroller.ScrollableHeight > 0) row = _rows.Count - 1;
        else
        {
            var probe = ReadingLine;
            var y = ViewMargin;
            row = _rows.Count - 1;
            for (var r = 0; r < _rows.Count; r++)
            {
                y += RowHeight(r) + PageSpacing;
                if (probe < y) { row = r; break; }
            }
        }
        if (_page < _rowOf.Length && _rowOf[_page] == row) return;  // e.g. the right-hand page of a pair
        _page = RowPages(row).First;
        UpdateStatus();
    }

    /// <summary>Single Page / Facing Pages: shows the row holding `page`.</summary>
    private void ShowRowOf(int page)
    {
        EnsureRows();
        if (!Paged || page >= _rowOf.Length || _rowOf[page] == _shownRow) return;
        _shownRow = _rowOf[page];
        ApplyRows();
        Pages.UpdateLayout();
        PageScroller.UpdateLayout();
        RenderVisible();
    }

    /// <summary>Next / Previous: a page, or a pair of facing pages.</summary>
    private void StepPage(int by, bool toBottom = false)
    {
        if (_document is null) return;
        EnsureRows();
        if (_viewMode != PageViewMode.Facing) { GoTo(_page + by, toBottom); return; }
        var row = (_page < _rowOf.Length ? _rowOf[_page] : 0) + by;
        if (row < 0 || row >= _rows.Count) return;
        GoTo(RowPages(row).First, toBottom);
    }

    private void SetViewMode(PageViewMode mode, bool? cover = null)
    {
        if (cover is { } c) _coverPage = c;
        _viewMode = mode;
        SinglePageItem.IsChecked = mode == PageViewMode.Single;
        ContinuousItem.IsChecked = mode == PageViewMode.Continuous;
        FacingItem.IsChecked = mode == PageViewMode.Facing;
        CoverPageItem.IsChecked = _coverPage;
        if (_document is null) return;
        var page = _page;
        EnsureRows(force: true);
        _shownRow = _rowOf.Length > page ? _rowOf[page] : 0;
        ApplyRows();
        Relayout(keepPage: false);
        GoTo(page);
    }

    private void ViewMode_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string mode })
            SetViewMode(mode switch { "single" => PageViewMode.Single, "facing" => PageViewMode.Facing, _ => PageViewMode.Continuous });
    }

    /// <summary>As on the Mac, showing the cover page switches a one-page layout to Facing Pages.</summary>
    private void CoverPage_Click(object sender, RoutedEventArgs e) =>
        SetViewMode(CoverPageItem.IsChecked ? PageViewMode.Facing : _viewMode, CoverPageItem.IsChecked);

    /// <summary>Single Page / Facing Pages: the wheel past the end of a page turns to the next.</summary>
    private void PageScroller_Wheel(object sender, PointerRoutedEventArgs e)
    {
        if (!Paged || _document is null) return;
        var delta = e.GetCurrentPoint(PageScroller).Properties.MouseWheelDelta;
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (delta == 0 || ctrl || DateTime.UtcNow - _lastWheelStep < TimeSpan.FromMilliseconds(350)) return;
        if (delta < 0 && PageScroller.VerticalOffset >= PageScroller.ScrollableHeight - 1) StepPage(1);
        else if (delta > 0 && PageScroller.VerticalOffset <= 1) StepPage(-1, toBottom: true);
        else return;
        _lastWheelStep = DateTime.UtcNow;
    }
}

/// <summary>Organize Pages: the page grid (Mac OrganizePagesView) replaces the page view while the tool is open.</summary>
public sealed partial class DocumentPane
{
    private void SetOrganizing(bool on)
    {
        var shown = on && _document is not null;
        OrganizeGrid.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        PageScroller.Visibility = shown ? Visibility.Collapsed : Visibility.Visible;
        QuickTools.Visibility = shown || _document is null || IsFullScreen ? Visibility.Collapsed : Visibility.Visible;  // it would cover the grid
        if (!shown) return;
        OrganizeGrid.SelectedItems.Clear();
        if (_page < _thumbnails.Count)
        {
            OrganizeGrid.SelectedItem = _thumbnails[_page];
            OrganizeGrid.ScrollIntoView(_thumbnails[_page]);
        }
    }

    private void OrganizeGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (OrganizeGrid.SelectedItems.Count == 1 && OrganizeGrid.SelectedItem is Thumbnail thumb && thumb.Index != _page) GoTo(thumb.Index);
    }

    /// <summary>A page's own buttons and right-click act on that page (it becomes the selection).</summary>
    private void SelectOrganized(object sender)
    {
        if (sender is not FrameworkElement { Tag: int index } || index >= _thumbnails.Count) return;
        if (OrganizeGrid.SelectedItems.Contains(_thumbnails[index])) return;
        OrganizeGrid.SelectedItems.Clear();
        OrganizeGrid.SelectedItem = _thumbnails[index];
    }

    private void OrganizeCell_RightTapped(object sender, RightTappedRoutedEventArgs e) => SelectOrganized(sender);

    private void OrganizeEarlier_Click(object sender, RoutedEventArgs e) { SelectOnly(sender); MoveEarlier_Click(sender, e); }
    private void OrganizeLater_Click(object sender, RoutedEventArgs e) { SelectOnly(sender); MoveLater_Click(sender, e); }
    private void OrganizeRotate_Click(object sender, RoutedEventArgs e) { SelectOnly(sender); RotateRight_Click(sender, e); }
    private void OrganizeExtract_Click(object sender, RoutedEventArgs e) { SelectOnly(sender); ExtractPages_Click(sender, e); }
    private void OrganizeDelete_Click(object sender, RoutedEventArgs e) { SelectOnly(sender); DeletePages_Click(sender, e); }

    /// <summary>A cell's buttons act on that page alone.</summary>
    private void SelectOnly(object sender)
    {
        if (sender is not FrameworkElement { Tag: int index } || index >= _thumbnails.Count) return;
        OrganizeGrid.SelectedItems.Clear();
        OrganizeGrid.SelectedItem = _thumbnails[index];
    }
}

/// <summary>Arranges page views in rows: one column, or two facing columns that meet at the
/// centre. With ShownRow set, only that row takes space; the rest are parked out of view.</summary>
public sealed partial class PageRowsPanel : Panel
{
    public IReadOnlyList<int[]>? Rows { get; set; }
    public int Columns { get; set; } = 1;
    public int ShownRow { get; set; } = -1;
    public double Spacing { get; set; } = 16;

    private IReadOnlyList<int[]> EffectiveRows =>
        Rows is { } rows && rows.Sum(r => r.Count(p => p >= 0)) == Children.Count ? rows : [.. Enumerable.Range(0, Children.Count).Select(i => new[] { i })];

    private bool Shows(int row) => ShownRow < 0 || row == ShownRow;

    protected override Size MeasureOverride(Size availableSize)
    {
        foreach (var child in Children) child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var rows = EffectiveRows;
        var columns = Columns;
        var cell = Children.Count == 0 ? 0 : Children.Max(c => c.DesiredSize.Width);
        double height = 0;
        var shown = 0;
        for (var r = 0; r < rows.Count; r++)
        {
            if (!Shows(r)) continue;
            if (shown++ > 0) height += Spacing;
            height += rows[r].Where(p => p >= 0).Select(p => Children[p].DesiredSize.Height).DefaultIfEmpty(0).Max();
        }
        return new Size(columns * cell + (columns - 1) * Spacing, height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        var rows = EffectiveRows;
        var centre = finalSize.Width / 2;
        double y = 0;
        var shown = 0;
        for (var r = 0; r < rows.Count; r++)
        {
            var row = rows[r];
            if (!Shows(r))
            {
                foreach (var p in row) if (p >= 0) Children[p].Arrange(new Rect(-100000, 0, Children[p].DesiredSize.Width, Children[p].DesiredSize.Height));
                continue;
            }
            if (shown++ > 0) y += Spacing;
            double rowHeight = 0;
            for (var c = 0; c < row.Length; c++)
            {
                if (row[c] < 0) continue;
                var size = Children[row[c]].DesiredSize;
                // A lone last page of a pair sits in the left column.
                var x = Columns == 1 ? centre - size.Width / 2
                    : c == 0 ? centre - Spacing / 2 - size.Width : centre + Spacing / 2;
                Children[row[c]].Arrange(new Rect(x, y, size.Width, size.Height));
                rowHeight = Math.Max(rowHeight, size.Height);
            }
            y += rowHeight;
        }
        return finalSize;
    }
}
