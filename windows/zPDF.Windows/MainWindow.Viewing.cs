using System.Collections.ObjectModel;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
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
            if (_fields.Count > 0 || _comments.Count > 0)
            {
                RefreshMarks();  // field highlights and comment outlines need the page mapping
                if (HasPendingFields) RefreshFieldOverlays();
            }
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
        ResetContent();
        _editing = null;
        _editorSlot = null;
        _focusedToggle = null;
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
        if (IsEditingContent)
            return ContentAt(slot.Index, point) is { } item ? (item.Kind == "text" ? InputSystemCursorShape.IBeam : InputSystemCursorShape.SizeAll) : InputSystemCursorShape.Arrow;
        if (_tool is not (CommentTool.Select or CommentTool.Highlight or CommentTool.Underline or CommentTool.StrikeOut))
            return InputSystemCursorShape.Cross;
        if (Info(slot.Index) is not { } info) return InputSystemCursorShape.Arrow;
        if (_tool == CommentTool.Select && CommentAt(slot.Index, point) is not null) return InputSystemCursorShape.SizeAll;
        if (info.LinkAt(point) is not null && !_selecting) return InputSystemCursorShape.Hand;
        return info.IsOverText(point) || _selecting ? InputSystemCursorShape.IBeam : InputSystemCursorShape.Arrow;
    }

    public void PagePointerPressed(PageSlot slot, Point point, PointerRoutedEventArgs e)
    {
        if (!e.GetCurrentPoint(null).Properties.IsLeftButtonPressed) return;
        if (ContentPointerPressed(slot, point)) { e.Handled = true; return; }
        if (FieldPointerPressed(slot, point)) { e.Handled = true; return; }
        CommitEditor();  // a click outside the field being edited finishes it
        _focusedToggle = null;
        if (CommentPointerPressed(slot, point)) { e.Handled = true; return; }
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
        if (ContentPointerMoved(slot, point)) return;
        if (CommentPointerMoved(slot, point)) return;
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
        if (ContentPointerReleased(slot, point)) return;
        var markup = _tool is CommentTool.Highlight or CommentTool.Underline or CommentTool.StrikeOut;
        if (!markup && CommentPointerReleased(slot, point)) { _pressSlot = null; return; }
        var pressed = _pressSlot;
        _pressSlot = null;
        if (markup && CommentPointerReleased(slot, point)) { _selecting = false; return; }
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
        ShowTransient(text.Length > 60 ? $"Copied {text.Length} characters" : "Copied");
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
        PageScroller.Focus(FocusState.Programmatic);  // not the first toolbar button
        _findWork?.Cancel();
        _hits.Clear();
        _hitIndex = -1;
        FindCountText.Text = "";
        RefreshMarks();
    }

    private void Escape_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (IsFullScreen) SetFullScreen(false);
        else if (FindBar.Visibility == Visibility.Visible) CloseFind();
        else if (IsEditingContent && _contentSelection is not null) { _contentSelection = null; UpdateContentCommands(); RefreshMarks(); }
        else if (_tool != CommentTool.Select) SetTool(CommentTool.Select);
        else if (_selectedComment is not null) SelectComment(null);
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
        foreach (var (page, rect) in FieldMarks()) Add(page, [rect], Mark.Field);
        foreach (var (page, rect) in RedactionMarks()) Add(page, [rect], Mark.Redaction);
        foreach (var (page, rect) in ChangeMarks()) Add(page, [rect], Mark.Change);
        foreach (var (page, rect, mark) in ContentMarks()) Add(page, [rect], mark);
        foreach (var (page, rect) in CommentMarks()) Add(page, [rect], Mark.CommentSelection);
        foreach (var slot in _slots) slot.SetMarks(marks.TryGetValue(slot.Index, out var list) ? list : []);
    }

    // ---------------------------------------------------------------- bookmarks

    private void SidebarTabs_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs? args)
    {
        var bookmarks = sender.SelectedItem == BookmarksTab;
        var comments = sender.SelectedItem == CommentsTab;
        var changes = sender.SelectedItem == ChangesTab;
        Thumbnails.Visibility = bookmarks || comments || changes ? Visibility.Collapsed : Visibility.Visible;
        ChangeList.Visibility = changes ? Visibility.Visible : Visibility.Collapsed;
        UpdateCommentsPanel();
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
            ("Security", encrypted ? "Password protected" : "None"),
            ("Restrictions", encrypted ? DescribePermissions(permissions) : "None"),
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

    /// <summary>PDF permission bits (ISO 32000 table 22) as plain words.</summary>
    private static string DescribePermissions(uint bits)
    {
        var denied = new List<string>();
        if ((bits & 4) == 0) denied.Add("printing");
        else if ((bits & 2048) == 0) denied.Add("high-quality printing");
        if ((bits & 8) == 0) denied.Add("changing the document");
        if ((bits & 16) == 0) denied.Add("copying text and images");
        if ((bits & 32) == 0) denied.Add("adding comments");
        if ((bits & 256) == 0) denied.Add("filling in forms");
        if ((bits & 1024) == 0) denied.Add("inserting, deleting or rotating pages");
        return denied.Count == 0 ? "None" : "Not allowed: " + string.Join(", ", denied);
    }

    /// <summary>A status message that clears itself after a few seconds (unless replaced).</summary>
    private async void ShowTransient(string message)
    {
        StatusText.Text = message;
        await Task.Delay(4000);
        if (StatusText.Text == message) StatusText.Text = "";
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

    private void Home_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_document is null) return;
        _page = 0;
        ScrollTo(0, 0);  // the very top, including the margin above page 1
        UpdateStatus();
        args.Handled = true;
    }

    private void End_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_document is null) return;
        PageScroller.ChangeView(null, PageScroller.ScrollableHeight, null, disableAnimation: true);
        args.Handled = true;
    }

    // ---------------------------------------------------------------- recent files

    private void RecentMenu_Opening(object sender, object e)
    {
        RecentMenu.Items.Clear();
        var recent = AppSettings.Current.RecentFiles;
        if (recent.Count == 0)
        {
            RecentMenu.Items.Add(new MenuFlyoutItem { Text = "No recent files", IsEnabled = false });
            return;
        }
        foreach (var path in recent)
        {
            var item = new MenuFlyoutItem { Text = Path.GetFileName(path), Tag = path };
            ToolTipService.SetToolTip(item, path);
            item.Click += RecentItem_Click;
            RecentMenu.Items.Add(item);
        }
        RecentMenu.Items.Add(new MenuFlyoutSeparator());
        var clear = new MenuFlyoutItem { Text = "Clear Recent Files" };
        clear.Click += (_, _) => { AppSettings.Current.ClearRecent(); ShowStartRecents(); };
        RecentMenu.Items.Add(clear);
    }

    private async void RecentItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string path }) return;
        if (!File.Exists(path))
        {
            AppSettings.Current.RemoveRecent(path);
            ShowStartRecents();
            StatusText.Text = $"{Path.GetFileName(path)} was moved or deleted; it's been removed from Recent.";
            return;
        }
        if (await ConfirmDiscardAsync()) await OpenAsync(path);
    }

    /// <summary>The recent-files list on the start screen.</summary>
    private void ShowStartRecents()
    {
        StartRecentList.Children.Clear();
        var recent = AppSettings.Current.RecentFiles.Take(8).ToList();
        StartRecentHeader.Visibility = recent.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var path in recent)
        {
            var button = new HyperlinkButton
            {
                Tag = path,
                Content = new StackPanel
                {
                    Children =
                    {
                        new TextBlock { Text = Path.GetFileName(path) },
                        new TextBlock
                        {
                            Text = Path.GetDirectoryName(path) ?? "", TextTrimming = TextTrimming.CharacterEllipsis,
                            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                        },
                    },
                },
            };
            AutomationProperties.SetName(button, $"Open {Path.GetFileName(path)}");
            button.Click += RecentItem_Click;
            StartRecentList.Children.Add(button);
        }
    }

    // ---------------------------------------------------------------- full screen

    private bool IsFullScreen => AppWindow.Presenter.Kind == Microsoft.UI.Windowing.AppWindowPresenterKind.FullScreen;

    private void FullScreen_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_document is null) return;
        SetFullScreen(!IsFullScreen);
        args.Handled = true;
    }

    private void FullScreen_Click(object sender, RoutedEventArgs e) => SetFullScreen(true);

    /// <summary>Reading mode: the page view only; F11 or Esc returns.</summary>
    private void SetFullScreen(bool on)
    {
        ToolStrip.Visibility = on || _document is null ? Visibility.Collapsed : Visibility.Visible;
        AppWindow.SetPresenter(on ? Microsoft.UI.Windowing.AppWindowPresenterKind.FullScreen
                                  : Microsoft.UI.Windowing.AppWindowPresenterKind.Default);
        var chrome = on ? Visibility.Collapsed : Visibility.Visible;
        Toolbar.Visibility = StatusBar.Visibility = chrome;
        Sidebar.Visibility = on || _document is null ? Visibility.Collapsed : Visibility.Visible;
        if (on) FindBar.Visibility = Visibility.Collapsed;
        if (on) StatusText.Text = "";
    }

    // ---------------------------------------------------------------- print

    private async void Print_Click(object sender, RoutedEventArgs e)
    {
        await FlushFieldsAsync();  // print what's on screen, including just-typed form entries
        if (_document is null || CurrentPath is not { } path) return;
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        if (Printing.Ask(hwnd, _document.PageCount, _page) is not { } job) return;
        var title = Path.GetFileName(_sourcePath) ?? "zPDF";
        var password = _password;
        var total = job.Pages.Count;
        var progress = new Progress<int>(done => StatusText.Text = $"Printing page {Math.Min(done + 1, total)} of {total}…");
        StatusText.Text = $"Printing page 1 of {total}…";
        string? flattened = null;
        try
        {
            // Printer device contexts don't get PDFium's form-field drawing, so a form
            // prints from a copy whose fields are flattened into the page.
            if (_fields.Count > 0)
            {
                flattened = await Engine.TransformAsync(path, [new System.Text.Json.Nodes.JsonObject { ["op"] = "flatten_form_fields" }], password);
                path = flattened;
            }
            // Its own copy, so edits while printing can't close the document under it.
            await Task.Run(() =>
            {
                using var copy = PdfDocument.Open(path, password);
                Printing.Print(copy, job, title, progress: progress);
            });
            StatusText.Text = total == 1 ? "Sent 1 page to the printer" : $"Sent {total} pages to the printer";
        }
        catch (Exception error) when (error is IOException or InvalidDataException or EngineException)
        {
            StatusText.Text = $"Printing failed: {error.Message}";
        }
        finally
        {
            if (flattened is not null) TryDelete(flattened);
        }
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
