using System.Collections.ObjectModel;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;

namespace zPDF;

/// <summary>An outline entry shown in the Bookmarks tree.</summary>
public sealed class OutlineNode(OutlineItem item, bool expanded)
{
    public string Title { get; } = item.Title;
    public int? TargetPage { get; } = item.TargetPage;
    public string? Uri { get; } = item.Uri;
    public bool Expanded { get; } = expanded;
    public ObservableCollection<OutlineNode> Children { get; } = new(item.Children.Select(c => new OutlineNode(c, false)));
}

/// <summary>Reading and navigation: find, text selection and copy, links, bookmarks,
/// go to page, document properties, keyboard paging.</summary>
public sealed partial class MainWindow : IPageHost
{
    private readonly Dictionary<int, PageInfo> _infos = [];
    private readonly Dictionary<int, Task<PageInfo?>> _infoLoads = [];
    private readonly List<(int Page, int First, int Last)> _hits = [];
    private CancellationTokenSource? _findWork;
    private int _hitIndex = -1;
    private (int Page, int Anchor, int Focus)? _selection;
    private bool _selecting;
    private Point _pressPoint;
    private PageSlot? _pressSlot;

    // ---------------------------------------------------------------- page info

    /// <summary>Cached text/links for a page; loads it in the background on first use.</summary>
    private PageInfo? Info(int page)
    {
        if (_infos.TryGetValue(page, out var info)) return info;
        _ = InfoAsync(page);
        return null;
    }

    private Task<PageInfo?> InfoAsync(int page)
    {
        if (_infos.TryGetValue(page, out var cached)) return Task.FromResult<PageInfo?>(cached);
        if (_infoLoads.TryGetValue(page, out var pending)) return pending;
        var document = _document;
        if (document is null) return Task.FromResult<PageInfo?>(null);
        var load = LoadInfoAsync(document, page);
        _infoLoads[page] = load;
        return load;
    }

    private async Task<PageInfo?> LoadInfoAsync(PdfDocument document, int page)
    {
        try
        {
            var info = await Task.Run(() => document.LoadPageInfo(page));
            if (document != _document) return null;
            _infos[page] = info;
            return info;
        }
        catch (Exception error) when (error is ObjectDisposedException or InvalidDataException or ArgumentOutOfRangeException)
        {
            return null;
        }
        finally
        {
            if (document == _document) _infoLoads.Remove(page);
        }
    }

    /// <summary>Called when the shown document changes: drop per-page state.</summary>
    private void ResetViewingState()
    {
        _infos.Clear();
        _infoLoads.Clear();
        _selection = null;
        _findWork?.Cancel();
        _hits.Clear();
        _hitIndex = -1;
        if (FindBar.Visibility == Visibility.Visible && FindBox.Text.Length > 0) _ = FindAsync(keepIndex: true);
        LoadOutline();
    }

    // ---------------------------------------------------------------- pointer: selection and links

    public InputSystemCursorShape CursorAt(PageSlot slot, Point point)
    {
        if (Info(slot.Index) is not { } info) return InputSystemCursorShape.Arrow;
        if (info.LinkAt(point) is not null && !_selecting) return InputSystemCursorShape.Hand;
        return info.IsOverText(point) || _selecting ? InputSystemCursorShape.IBeam : InputSystemCursorShape.Arrow;
    }

    public void PagePointerPressed(PageSlot slot, Point point, PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(null).Properties.IsLeftButtonPressed) return;
        _pressSlot = slot;
        _pressPoint = point;
        _selecting = false;
        if (Info(slot.Index) is { } info && info.CharIndexAt(point) is var index and >= 0 && info.LinkAt(point) is null)
        {
            _selection = (slot.Index, index, index);
            _selecting = true;
        }
        else
        {
            ClearSelection();
        }
        e.Handled = true;
    }

    public void PagePointerMoved(PageSlot slot, Point point, PointerRoutedEventArgs e)
    {
        if (_pressSlot is null || !e.GetCurrentPoint(null).Properties.IsLeftButtonPressed) return;
        if (Info(_pressSlot.Index) is not { } info) return;
        // Positions are relative to the page that captured the pointer.
        var index = info.CharIndexAt(point, slack: 40);
        if (!_selecting && Distance(point, _pressPoint) > 3)
        {
            var start = info.CharIndexAt(_pressPoint, slack: 40);
            if (start < 0) return;
            _selection = (_pressSlot.Index, start, start);
            _selecting = true;
        }
        if (_selecting && _selection is { } sel && index >= 0 && index != sel.Focus)
        {
            _selection = sel with { Focus = index };
            RefreshMarks();
        }
    }

    public async void PagePointerReleased(PageSlot slot, Point point, PointerRoutedEventArgs e)
    {
        var pressed = _pressSlot;
        _pressSlot = null;
        var wasClick = pressed == slot && Distance(point, _pressPoint) <= 3;
        if (_selection is { } sel && sel.Anchor == sel.Focus && wasClick) ClearSelection();
        _selecting = false;
        if (!wasClick || Info(slot.Index)?.LinkAt(point) is not { } link) return;
        if (link.TargetPage is { } target) GoTo(target);
        else if (link.Uri is { } uri) await OpenWebLinkAsync(uri);
    }

    private static double Distance(Point a, Point b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    private async Task OpenWebLinkAsync(string uri)
    {
        if (!Uri.TryCreate(uri, UriKind.Absolute, out var parsed) || parsed.Scheme is not ("http" or "https" or "mailto"))
        {
            StatusText.Text = "zPDF only opens web and email links.";
            return;
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Open this link?",
            Content = new TextBlock { Text = parsed.ToString(), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
            PrimaryButtonText = "Open",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await Launcher.LaunchUriAsync(parsed);
    }

    private void ClearSelection()
    {
        if (_selection is null) return;
        _selection = null;
        RefreshMarks();
    }

    private void Copy_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_selection is not { } sel || Info(sel.Page) is not { } info) return;
        var text = info.TextOf(Math.Min(sel.Anchor, sel.Focus), Math.Max(sel.Anchor, sel.Focus));
        if (text.Length == 0) return;
        var package = new DataPackage();
        package.SetText(text.Replace("\r\n", "\n").Replace("\n", Environment.NewLine));
        Clipboard.SetContent(package);
        StatusText.Text = text.Length > 60 ? $"Copied {text.Length} characters" : "Copied";
        args.Handled = true;
    }

    private void SelectAll_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_document is null || Info(_page) is not { Boxes.Length: > 0 } info) return;
        _selection = (_page, 0, info.Boxes.Length - 1);
        RefreshMarks();
        args.Handled = true;
    }

    // ---------------------------------------------------------------- find

    private void Find_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { ShowFind(); args.Handled = true; }
    private void Find_Click(object sender, RoutedEventArgs e) => ShowFind();

    private void ShowFind()
    {
        if (_document is null) return;
        FindBar.Visibility = Visibility.Visible;
        if (_selection is { } sel && Info(sel.Page) is { } info)
        {
            var text = info.TextOf(Math.Min(sel.Anchor, sel.Focus), Math.Max(sel.Anchor, sel.Focus)).Trim();
            if (text.Length is > 0 and < 100 && !text.Contains('\n')) FindBox.Text = text;
        }
        FindBox.Focus(FocusState.Programmatic);
        FindBox.SelectAll();
    }

    private void CloseFind_Click(object sender, RoutedEventArgs e) => CloseFind();

    private void CloseFind()
    {
        FindBar.Visibility = Visibility.Collapsed;
        _findWork?.Cancel();
        _hits.Clear();
        _hitIndex = -1;
        FindCountText.Text = "";
        RefreshMarks();
    }

    private void Escape_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (FindBar.Visibility == Visibility.Visible) CloseFind();
        else ClearSelection();
        args.Handled = true;
    }

    private void FindBox_TextChanged(object sender, TextChangedEventArgs e) => _ = FindAsync(keepIndex: false);
    private void MatchCase_Click(object sender, RoutedEventArgs e) => _ = FindAsync(keepIndex: false);

    private void FindBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        StepFind(shift ? -1 : 1);
        e.Handled = true;
    }

    private void FindNext_Click(object sender, RoutedEventArgs e) => StepFind(1);
    private void FindPrevious_Click(object sender, RoutedEventArgs e) => StepFind(-1);
    private void FindNext_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { StepFind(1); args.Handled = true; }
    private void FindPrevious_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { StepFind(-1); args.Handled = true; }

    /// <summary>Searches every page (text is loaded in the background); results stream in.</summary>
    private async Task FindAsync(bool keepIndex)
    {
        _findWork?.Cancel();
        var work = _findWork = new CancellationTokenSource();
        var query = FindBox.Text;
        var comparison = MatchCaseBox.IsChecked == true ? StringComparison.Ordinal : StringComparison.CurrentCultureIgnoreCase;
        var previous = keepIndex && _hitIndex >= 0 && _hitIndex < _hits.Count ? _hits[_hitIndex] : ((int, int, int)?)null;
        _hits.Clear();
        _hitIndex = -1;
        if (string.IsNullOrWhiteSpace(query) || _document is not { } document)
        {
            FindCountText.Text = "";
            RefreshMarks();
            return;
        }
        FindCountText.Text = "Searching…";
        // Start at the current page so the first match is the nearest one ahead.
        var order = Enumerable.Range(_page, document.PageCount - _page).Concat(Enumerable.Range(0, _page)).ToList();
        var found = new SortedDictionary<int, List<(int, int, int)>>();
        foreach (var page in order)
        {
            var info = await InfoAsync(page);
            if (work.IsCancellationRequested || document != _document) return;
            if (info is null) continue;
            var matches = new List<(int, int, int)>();
            for (var at = info.Text.IndexOf(query, comparison); at >= 0; at = info.Text.IndexOf(query, at + Math.Max(1, query.Length), comparison))
            {
                var end = Math.Min(info.CharAt.Length - 1, at + query.Length - 1);
                matches.Add((page, info.CharAt[at], info.CharAt[end]));
            }
            if (matches.Count == 0) continue;
            found[page] = matches;
            _hits.Clear();
            foreach (var list in found.Values) _hits.AddRange(list);
            if (_hitIndex < 0)
            {
                _hitIndex = previous is { } p && _hits.IndexOf(p) is var i and >= 0 ? i : _hits.FindIndex(h => h.Page >= _page);
                if (_hitIndex < 0) _hitIndex = 0;
                ShowHit();
            }
            else
            {
                RefreshMarks();
            }
            FindCountText.Text = $"{_hitIndex + 1} of {_hits.Count}";
        }
        if (work.IsCancellationRequested) return;
        if (_hits.Count == 0) FindCountText.Text = "No matches";
        else
        {
            // Pages found later may sort before the current hit; keep it current.
            FindCountText.Text = $"{_hitIndex + 1} of {_hits.Count}";
            RefreshMarks();
        }
    }

    private void StepFind(int step)
    {
        if (FindBar.Visibility != Visibility.Visible) { ShowFind(); return; }
        if (_hits.Count == 0) return;
        _hitIndex = (_hitIndex + step + _hits.Count) % _hits.Count;
        ShowHit();
        FindCountText.Text = $"{_hitIndex + 1} of {_hits.Count}";
    }

    /// <summary>Scrolls the current match into view (a little below the top) and highlights it.</summary>
    private void ShowHit()
    {
        if (_hitIndex < 0 || _hitIndex >= _hits.Count || _infos.GetValueOrDefault(_hits[_hitIndex].Page) is not { } info) return;
        var (page, first, last) = _hits[_hitIndex];
        var rects = info.RectsFor(first, last);
        if (rects.Count > 0)
        {
            var slot = _slots[page];
            var scale = slot.Width / slot.PointWidth;
            var y = PageTop(page) + rects[0].Top * scale;
            var visibleTop = PageScroller.VerticalOffset;
            var visibleBottom = visibleTop + PageScroller.ViewportHeight;
            if (y < visibleTop + 40 || y > visibleBottom - 80)
            {
                _page = page;
                ScrollTo(page, y - PageScroller.ViewportHeight / 3);
            }
            var x = rects[0].Left * scale + ViewMargin + Math.Max(0, (PageScroller.ExtentWidth - slot.Width - 2 * ViewMargin) / 2);
            if (x < PageScroller.HorizontalOffset || x > PageScroller.HorizontalOffset + PageScroller.ViewportWidth - 40)
                PageScroller.ChangeView(Math.Max(0, x - PageScroller.ViewportWidth / 3), null, null, disableAnimation: true);
        }
        RefreshMarks();
        UpdateStatus();
    }

    /// <summary>Pushes selection and find highlights to the pages that show them.</summary>
    private void RefreshMarks()
    {
        var marks = new Dictionary<int, List<(Rect, Mark)>>();
        void Add(int page, IEnumerable<Rect> rects, Mark mark)
        {
            if (!marks.TryGetValue(page, out var list)) marks[page] = list = [];
            list.AddRange(rects.Select(r => (r, mark)));
        }
        for (var i = 0; i < _hits.Count; i++)
        {
            var (page, first, last) = _hits[i];
            if (_infos.GetValueOrDefault(page) is { } info) Add(page, info.RectsFor(first, last), i == _hitIndex ? Mark.CurrentFindHit : Mark.FindHit);
        }
        if (_selection is { } sel && sel.Anchor != sel.Focus && _infos.GetValueOrDefault(sel.Page) is { } selInfo)
            Add(sel.Page, selInfo.RectsFor(Math.Min(sel.Anchor, sel.Focus), Math.Max(sel.Anchor, sel.Focus)), Mark.Selection);
        else if (_selection is { } one && _infos.GetValueOrDefault(one.Page) is { } oneInfo && _selecting)
            Add(one.Page, oneInfo.RectsFor(one.Anchor, one.Anchor), Mark.Selection);
        foreach (var slot in _slots) slot.SetMarks(marks.TryGetValue(slot.Index, out var list) ? list : []);
    }

    // ---------------------------------------------------------------- bookmarks

    private void SidebarTabs_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs? args)
    {
        var bookmarks = sender.SelectedItem == BookmarksTab;
        Thumbnails.Visibility = bookmarks ? Visibility.Collapsed : Visibility.Visible;
        var hasOutline = (OutlineTree.ItemsSource as System.Collections.ICollection)?.Count > 0;
        OutlineTree.Visibility = bookmarks && hasOutline ? Visibility.Visible : Visibility.Collapsed;
        NoBookmarksText.Visibility = bookmarks && OutlineTree.Visibility != Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
    }

    private void LoadOutline()
    {
        var items = _document?.Outline() ?? [];
        // Expand the top level when it's short, like most readers.
        OutlineTree.ItemsSource = new ObservableCollection<OutlineNode>(items.Select(i => new OutlineNode(i, items.Count <= 12)));
        SidebarTabs_SelectionChanged(SidebarTabs, null);
    }

    private async void OutlineTree_ItemInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is not OutlineNode node) return;
        if (node.TargetPage is { } page) GoTo(page);
        else if (node.Uri is { } uri) await OpenWebLinkAsync(uri);
    }

    // ---------------------------------------------------------------- go to page, properties, paging

    private void GoToPage_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { _ = GoToPageAsync(); args.Handled = true; }
    private void GoToPage_Click(object sender, RoutedEventArgs e) => _ = GoToPageAsync();

    private async Task GoToPageAsync()
    {
        if (_document is null) return;
        var box = new NumberBox
        {
            Minimum = 1, Maximum = _document.PageCount, Value = _page + 1,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline,
            Header = $"Page (1–{_document.PageCount})",
        };
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = "Go to Page", Content = box,
            PrimaryButtonText = "Go", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
        };
        dialog.Opened += (_, _) => box.Focus(FocusState.Programmatic);
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && !double.IsNaN(box.Value))
            GoTo((int)Math.Clamp(box.Value, 1, _document.PageCount) - 1);
    }

    private void Properties_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { _ = ShowPropertiesAsync(); args.Handled = true; }
    private void Properties_Click(object sender, RoutedEventArgs e) => _ = ShowPropertiesAsync();

    private async Task ShowPropertiesAsync()
    {
        if (_document is null || _sourcePath is null) return;
        var (info, version, encrypted, permissions) = _document.Properties();
        var file = new FileInfo(_sourcePath);
        var (w, h) = _pageSizes.Length > 0 ? _pageSizes[_page] : (0, 0);
        var rows = new List<(string, string)>
        {
            ("File", file.Name), ("Location", file.DirectoryName ?? ""),
            ("File size", file.Exists ? FormatSize(file.Length) : "—"),
            ("Title", info["Title"]), ("Author", info["Author"]), ("Subject", info["Subject"]), ("Keywords", info["Keywords"]),
            ("Created", PdfDate(info["CreationDate"])), ("Modified", PdfDate(info["ModDate"])),
            ("Application", info["Creator"]), ("PDF producer", info["Producer"]), ("PDF version", version),
            ("Pages", _document.PageCount.ToString()),
            ("Page size", $"{w / 72:0.##} × {h / 72:0.##} in ({w * 25.4 / 72:0} × {h * 25.4 / 72:0} mm)"),
            ("Security", encrypted ? $"Password protected (permissions 0x{permissions:X})" : "None"),
        };
        var grid = new Grid { ColumnSpacing = 16, RowSpacing = 6 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        foreach (var (label, value) in rows)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var row = grid.RowDefinitions.Count - 1;
            var name = new TextBlock { Text = label, Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] };
            var text = new TextBlock { Text = string.IsNullOrWhiteSpace(value) ? "—" : value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
            Grid.SetRow(name, row); Grid.SetRow(text, row); Grid.SetColumn(text, 1);
            grid.Children.Add(name); grid.Children.Add(text);
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = "Document Properties",
            Content = new ScrollViewer { Content = grid, MaxHeight = 480 }, CloseButtonText = "Close",
        };
        await dialog.ShowAsync();
    }

    private static string FormatSize(long bytes) =>
        bytes >= 1 << 20 ? $"{bytes / 1048576.0:0.#} MB ({bytes:N0} bytes)" : $"{bytes / 1024.0:0.#} KB ({bytes:N0} bytes)";

    /// <summary>PDF date "D:20240131120000+01'00'" → local display.</summary>
    private static string PdfDate(string value)
    {
        var digits = new string(value.TrimStart('D', ':').TakeWhile(char.IsDigit).ToArray());
        if (digits.Length < 8) return value;
        digits = digits.PadRight(14, '0');
        return DateTime.TryParseExact(digits[..14], "yyyyMMddHHmmss", null, System.Globalization.DateTimeStyles.None, out var date)
            ? date.ToString("g") : value;
    }

    private void PageDown_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => ScrollBy(args, 0.9);
    private void PageUp_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => ScrollBy(args, -0.9);

    private void ScrollBy(KeyboardAcceleratorInvokedEventArgs args, double screens)
    {
        if (_document is null || FindBox.FocusState != FocusState.Unfocused) return;
        PageScroller.ChangeView(null, PageScroller.VerticalOffset + screens * PageScroller.ViewportHeight, null, disableAnimation: true);
        args.Handled = true;
    }

    private void Home_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) { GoTo(0); args.Handled = true; }

    private void End_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_document is null) return;
        PageScroller.ChangeView(null, PageScroller.ScrollableHeight, null, disableAnimation: true);
        args.Handled = true;
    }

    // ---------------------------------------------------------------- passwords

    /// <summary>Opens a PDF, asking for its password when it has one.</summary>
    private async Task<(PdfDocument Document, string? Password)?> OpenWithPasswordAsync(string path)
    {
        string? password = null;
        var prompt = "This document is password protected. Enter its password to open it.";
        while (true)
        {
            try { return (PdfDocument.Open(path, password), password); }
            catch (PasswordRequiredException)
            {
                var box = new PasswordBox { PlaceholderText = "Password" };
                var dialog = new ContentDialog
                {
                    XamlRoot = Content.XamlRoot, Title = Path.GetFileName(path),
                    Content = new StackPanel { Spacing = 12, Children = { new TextBlock { Text = prompt, TextWrapping = TextWrapping.Wrap }, box } },
                    PrimaryButtonText = "Open", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
                };
                dialog.Opened += (_, _) => box.Focus(FocusState.Programmatic);
                if (await dialog.ShowAsync() != ContentDialogResult.Primary) return null;
                password = box.Password;
                prompt = "That password isn't correct. Try again.";
            }
        }
    }
}
