using System.Collections.ObjectModel;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json.Nodes;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Windows.Storage.Pickers;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.System;

namespace zPDF;

/// <summary>Prototype document window: open, continuous view (zoom, thumbnails), one
/// engine edit with undo, Save / Save As. Edits apply to private working copies; the
/// user's file changes only when they save.</summary>
public sealed partial class DocumentPane : UserControl
{
    private static readonly double[] ZoomSteps = [0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4];
    private const double ThumbnailWidth = 120, PageSpacing = 16, ViewMargin = 24;
    private const int KeepRendered = 2;  // pages beyond the visible ones that keep their images

    private readonly Stack<string> _revisions = new();  // working copies, newest on top
    private readonly ObservableCollection<PageSlot> _slots = [];
    private readonly ObservableCollection<Thumbnail> _thumbnails = [];
    private CancellationTokenSource? _thumbnailWork;
    private string? _sourcePath;
    private string? _savedPath;  // the revision the user's file currently matches
    private string? _password;   // the open password, for encrypted documents
    private PdfDocument? _document;
    private (double Width, double Height)[] _pageSizes = [];
    private Engine? _engine;
    private int _page;
    private double _zoom = 1;
    private int _generation;  // bumps when zoom or document changes; stale renders are dropped
    private bool _fitWidth = true;
    private bool _syncingSelection;
    private List<int>? _reselect;  // thumbnails to select once the sidebar is rebuilt
    private bool _rebuilding;      // Show() is replacing the page list
    // While zoom or navigation scrolls the view, the page it is keeping in place;
    // intermediate scroll events must not change the current page.
    private (int Page, double Offset, DateTime Started)? _pendingAnchor;

    /// <summary>One document in a tab of `host`.</summary>
    public DocumentPane(MainWindow host)
    {
        Host = host;
        InitializeComponent();
        Thumbnails.ItemsSource = _thumbnails;
        InitializeComments();
        AttachmentList.ItemsSource = _attachments;
        LayerList.ItemsSource = _layers;
        Pages.ItemsSource = _slots;
        // Ctrl with the main keyboard's =/+ and − keys (OEM keys have no XAML name).
        ZoomInButton.KeyboardAccelerators.Add(new() { Modifiers = VirtualKeyModifiers.Control, Key = (VirtualKey)187 });
        ZoomOutButton.KeyboardAccelerators.Add(new() { Modifiers = VirtualKeyModifiers.Control, Key = (VirtualKey)189 });
        HoistToolbarAccelerators();
        InitializeWorkspace();
        ShowStartRecents();
    }

    public MainWindow Host { get; }
    private AppWindow AppWindow => Host.AppWindow;

    /// <summary>The tab's title: the file name, with • while there are unsaved changes.</summary>
    public string DocumentTitle { get; private set; } = "New Tab";
    public string? FilePath => _sourcePath;
    public bool IsEmpty => _document is null;
    public bool HasUnsavedChanges => IsEdited;

    /// <summary>Asks about unsaved changes before the tab or window closes. True to close.</summary>
    public Task<bool> ConfirmCloseAsync() => ConfirmDiscardAsync();

    /// <summary>The tab closed: stop work and delete the working revisions.</summary>
    public void Release()
    {
        _thumbnailWork?.Cancel();
        _document?.Dispose();
        _document = null;
        _engine?.Dispose();
        _engine = null;
        DeleteRevisions();
    }

    private Engine Engine => _engine ??= new Engine();
    private string? CurrentPath => _revisions.TryPeek(out var top) ? top : _sourcePath;
    private bool IsEdited => _document is not null && (CurrentPath != _savedPath || HasPendingFields || _security is not null);
    private double RasterScale => Content.XamlRoot?.RasterizationScale ?? 1.0;
    private double Dips => _zoom * 96 / 72;  // device-independent pixels per PDF point

    // ---------------------------------------------------------------- file

    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        // Windows App SDK pickers also work when zPDF runs as administrator
        // (the classic WinRT pickers silently show nothing there).
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add(".pdf");  // shows only PDFs (the 1.8 picker labels it "All Files")
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        await OpenHereOrNewAsync(file.Path);
    }

    /// <summary>Opens a PDF (from the picker, the command line or a drop).</summary>
    public Task OpenAsync(string path) => Run("Opening…", async () =>
    {
        if (await OpenWithPasswordAsync(path) is not { } opened) return;  // cancelled; nothing replaced
        DeleteRevisions();
        _sourcePath = _savedPath = path;
        _password = opened.Password;
        AppSettings.Current.AddRecent(path);
        RefreshRecentMenu();
        _security = null;
        _page = 0;
        _fitWidth = AppSettings.Current.FitWidthOnOpen;
        if (!_fitWidth) _zoom = 1;
        _highlightFields = AppSettings.Current.HighlightFields;
        HighlightFieldsButton.IsOn = _highlightFields;
        Show(opened.Document, keepPosition: false);
        NoteOpenedSecurity();
    });

    private void Root_DragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Open";
        }
    }

    private async void Root_Drop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var pdf = items.OfType<StorageFile>().FirstOrDefault(f => f.FileType.Equals(".pdf", StringComparison.OrdinalIgnoreCase));
        if (pdf is null) { StatusText.Text = "Drop a PDF file to open it."; return; }
        await OpenHereOrNewAsync(pdf.Path);
    }

    private async void Save_Click(object sender, RoutedEventArgs e) => await SaveAsync();

    private async Task<bool> SaveAsync()
    {
        if (!IsEdited || _sourcePath is null) return true;
        var saved = false;
        await Run("Saving…", async () =>
        {
            var candidate = await FinalCandidateAsync();
            await Engine.PublishAsync(candidate, _sourcePath, overwrite: true);
            if (candidate != CurrentPath) TryDelete(candidate);
            NoteSavedSecurity();
            _savedPath = CurrentPath;
            saved = true;
            StatusText.Text = $"Saved {Path.GetFileName(_sourcePath)}";
        }, keepStatus: true);
        return saved;
    }

    private async void SaveAs_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileSavePicker(AppWindow.Id)
        {
            SuggestedFileName = Path.GetFileNameWithoutExtension(_sourcePath) + " edited",
            DefaultFileExtension = ".pdf",
        };
        picker.FileTypeChoices.Add("PDF document", [".pdf"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        await Run("Saving…", async () =>
        {
            var candidate = await FinalCandidateAsync();
            await Engine.PublishAsync(candidate, file.Path, overwrite: true);
            if (candidate != CurrentPath) TryDelete(candidate);
            NoteSavedSecurity();
            // The window now edits the new file, like Save As elsewhere.
            _sourcePath = file.Path;
            _savedPath = CurrentPath;
            StatusText.Text = $"Saved {Path.GetFileName(file.Path)}";
        }, keepStatus: true);
    }

    /// <summary>Save / Don't Save / Cancel for unsaved changes. True to go ahead.</summary>
    private async Task<bool> ConfirmDiscardAsync()
    {
        if (!IsEdited) return true;
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = $"Save changes to {Path.GetFileName(_sourcePath)}?",
            Content = "Your changes will be lost if you don't save them.",
            PrimaryButtonText = "Save",
            SecondaryButtonText = "Don't Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        return await dialog.ShowAsync() switch
        {
            ContentDialogResult.Primary => await SaveAsync(),
            ContentDialogResult.Secondary => DiscardAndContinue(),
            _ => false,
        };
    }

    private bool DiscardAndContinue()
    {
        DiscardPendingFields();
        return true;
    }

    // ---------------------------------------------------------------- edit

    private async void Watermark_Click(object sender, RoutedEventArgs e) =>
        await Run("Adding watermark…", async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [new JsonObject { ["op"] = "watermark", ["text"] = "DRAFT" }], _password);
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
        });

    private async void Undo_Click(object sender, RoutedEventArgs e) => await UndoAsync();

    private async Task UndoAsync()
    {
        if (HasPendingFields || _editing is not null)
        {
            DiscardPendingFields();  // the latest change is the unsaved form entries
            UpdateStatus();
            return;
        }
        await Run("Undoing…", () =>
        {
            if (!_revisions.TryPop(out var undone)) return Task.CompletedTask;
            _redo.Push(undone);
            Show(PdfDocument.Open(CurrentPath!, _password), keepPosition: true);
            return Task.CompletedTask;
        });
    }

    // ---------------------------------------------------------------- pages

    /// <summary>The pages the page tools act on: the selected thumbnails, else the current page.</summary>
    private List<int> TargetPages()
    {
        var selected = Thumbnails.SelectedItems.OfType<Thumbnail>().Select(t => t.Index).Order().ToList();
        return selected.Count > 0 ? selected : [_page];
    }

    private void RotateLeft_Click(object sender, RoutedEventArgs e) => _ = RotateAsync(-90);
    private void RotateRight_Click(object sender, RoutedEventArgs e) => _ = RotateAsync(90);

    private Task RotateAsync(int angle)
    {
        var pages = TargetPages();
        return ApplyAsync(angle < 0 ? "Rotating left…" : "Rotating right…",
            new JsonObject { ["op"] = "rotate_pages", ["pages"] = ToJson(pages), ["angle"] = angle }, pages);
    }

    private void DeleteAccelerator_Invoked(Microsoft.UI.Xaml.Input.KeyboardAccelerator sender,
                                           Microsoft.UI.Xaml.Input.KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        _ = DeletePagesAsync();
    }

    private void DeletePages_Click(object sender, RoutedEventArgs e) => _ = DeletePagesAsync();

    private async Task DeletePagesAsync()
    {
        if (_document is null) return;
        var pages = TargetPages();
        if (pages.Count >= _document.PageCount)
        {
            StatusText.Text = "A PDF must keep at least one page.";
            return;
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = pages.Count == 1 ? $"Delete page {pages[0] + 1}?" : $"Delete {pages.Count} pages?",
            Content = "You can undo this until you save.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        _page = Math.Min(pages[0], _document.PageCount - pages.Count - 1);
        await ApplyAsync("Deleting…", new JsonObject { ["op"] = "delete_pages", ["pages"] = ToJson(pages) }, [_page]);
    }

    private void MoveEarlier_Click(object sender, RoutedEventArgs e) => _ = MoveAsync(-1);
    private void MoveLater_Click(object sender, RoutedEventArgs e) => _ = MoveAsync(1);

    /// <summary>Moves the selected pages one place earlier or later, as a block.</summary>
    private Task MoveAsync(int step)
    {
        if (_document is null) return Task.CompletedTask;
        var pages = TargetPages();
        var order = Enumerable.Range(0, _document.PageCount).ToList();
        if (step < 0 ? pages[0] == 0 : pages[^1] == order.Count - 1) return Task.CompletedTask;
        var moving = new HashSet<int>(pages);
        foreach (var index in step < 0 ? pages : Enumerable.Reverse(pages))
        {
            var at = order.IndexOf(index);
            var swap = at + step;
            if (swap < 0 || swap >= order.Count || moving.Contains(order[swap])) continue;
            (order[at], order[swap]) = (order[swap], order[at]);
        }
        var moved = pages.Select(p => order.IndexOf(p)).Order().ToList();
        return ReorderAsync(order, moved);
    }

    /// <summary>Thumbnails dragged to a new place: apply that order to the document.</summary>
    private void Thumbnails_DragItemsCompleted(ListViewBase sender, DragItemsCompletedEventArgs args)
    {
        var order = _thumbnails.Select(t => t.Index).ToList();
        if (order.SequenceEqual(Enumerable.Range(0, order.Count))) return;
        var moved = args.Items.OfType<Thumbnail>().Select(t => order.IndexOf(t.Index)).Order().ToList();
        _ = ReorderAsync(order, moved);
    }

    /// <summary>Applies a new page order and shows the moved pages where they landed.</summary>
    private Task ReorderAsync(List<int> order, List<int> selectAfter) =>
        ApplyAsync("Moving pages…", new JsonObject { ["op"] = "reorder_pages", ["order"] = ToJson(order) }, selectAfter,
                   focus: selectAfter[0]);

    /// <summary>One engine edit as one undo step; reselects `select` afterwards.</summary>
    /// <summary>`focus`: scroll to this page afterwards instead of keeping the scroll position.</summary>
    private Task<bool> ApplyAsync(string status, JsonObject op, List<int> select, int? focus = null) =>
        Run(status, async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [op], _password);
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: focus is null, select: select, focus: focus);
        });

    private static JsonArray ToJson(IEnumerable<int> values) => new(values.Select(v => (JsonNode)v).ToArray());

    // ---------------------------------------------------------------- view

    private void ZoomIn_Click(object sender, RoutedEventArgs e) => SetZoom(ZoomSteps.FirstOrDefault(z => z > _zoom + 0.001, ZoomSteps[^1]));
    private void ZoomOut_Click(object sender, RoutedEventArgs e) => SetZoom(ZoomSteps.LastOrDefault(z => z < _zoom - 0.001, ZoomSteps[0]));
    private void ActualSize_Click(object sender, RoutedEventArgs e) => SetZoom(1);

    private void FitWidth_Click(object sender, RoutedEventArgs e)
    {
        _fitWidth = true;
        Relayout(keepPage: true);
    }

    /// <summary>The whole current page in the window.</summary>
    private void FitPage_Click(object sender, RoutedEventArgs e)
    {
        if (_document is null || _page >= _pageSizes.Length) return;
        var (w, h) = _pageSizes[_page];
        var width = Math.Max(200, PageScroller.ActualWidth - 2 * ViewMargin - 20) / (w * 96 / 72);
        var height = Math.Max(200, PageScroller.ActualHeight - 2 * ViewMargin) / (h * 96 / 72);
        SetZoom(Math.Min(width, height));
        ScrollTo(_page, PageTop(_page) - ViewMargin / 2);
    }

    private void SetZoom(double zoom)
    {
        _fitWidth = false;
        _zoom = Math.Clamp(zoom, ZoomSteps[0], ZoomSteps[^1]);
        Relayout(keepPage: true);
    }

    private void PageScroller_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_fitWidth && Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > 1) Relayout(keepPage: true);
        else RenderVisible();
    }

    private void PageScroller_ViewChanged(object? sender, ScrollViewerViewChangedEventArgs e)
    {
        // While pages are being rebuilt the view clamps its offset against the new
        // layout; those intermediate positions say nothing about the current page.
        if (_rebuilding) return;
        if (_pendingAnchor is { } pending)
        {
            var arrived = Math.Abs(PageScroller.VerticalOffset - pending.Offset) <= 2;
            var stale = DateTime.UtcNow - pending.Started > TimeSpan.FromMilliseconds(750);  // the user scrolled instead
            if (!e.IsIntermediate && (arrived || stale)) _pendingAnchor = null;
            if (!stale)
            {
                RenderVisible();
                return;  // keep the anchored page as current while the view gets there
            }
        }
        UpdateCurrentPage();
        RenderVisible();
    }

    private void Previous_Click(object sender, RoutedEventArgs e) => GoTo(_page - 1);
    private void Next_Click(object sender, RoutedEventArgs e) => GoTo(_page + 1);

    private void Thumbnails_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_syncingSelection && Thumbnails.SelectedItems.Count == 1 && Thumbnails.SelectedItem is Thumbnail thumb) GoTo(thumb.Index);
    }

    private void GoTo(int page)
    {
        if (_document is null || page < 0 || page >= _document.PageCount) return;
        _page = page;
        ScrollTo(page, PageTop(page));
        UpdateStatus();
    }

    private void ScrollTo(int page, double offset)
    {
        offset = Math.Clamp(offset, 0, Math.Max(0, PageScroller.ExtentHeight - PageScroller.ViewportHeight));
        _pendingAnchor = (page, offset, DateTime.UtcNow);
        PageScroller.ChangeView(null, offset, null, disableAnimation: true);
    }

    /// <summary>The point that defines the current page: a third of the way down the view.</summary>
    private double ReadingLine => PageScroller.VerticalOffset + ReadingDepth;

    private double ReadingDepth => Math.Min(PageScroller.ViewportHeight / 3,
                                            _slots.Count > 0 ? _slots.Min(s => s.Height) / 2 + ViewMargin : 0);

    // ---------------------------------------------------------------- layout and drawing

    /// <summary>Replaces the shown document (after open, edit or undo).</summary>
    private void Show(PdfDocument document, bool keepPosition, List<int>? select = null, int? focus = null)
    {
        _reselect = select;
        // Anchor edits like zoom: the current page and where the reading line falls on it,
        // since an edit can change page heights (rotation) and, in Fit Width, the zoom.
        var anchor = _page;
        var within = 0.0;
        var atTop = PageScroller.VerticalOffset <= 1;
        if (keepPosition && anchor < _slots.Count && _slots[anchor].Height > 0)
            within = Math.Clamp((ReadingLine - PageTop(anchor)) / _slots[anchor].Height, 0, 1);
        if (_document is not null && _document.PageCount != document.PageCount) _redactions.Clear();
        _document?.Dispose();
        _document = document;
        _pageSizes = Enumerable.Range(0, document.PageCount).Select(document.PageSize).ToArray();
        _page = Math.Min(_page, document.PageCount - 1);
        var targetPage = _page;
        _rebuilding = true;
        try
        {
            _slots.Clear();
            for (var i = 0; i < document.PageCount; i++) _slots.Add(new PageSlot(i) { Host = this, PointWidth = _pageSizes[i].Width });
            ResetViewingState();
            EmptyText.Visibility = Visibility.Collapsed;
            if (!_docPanelChosen) ShowDocPanel(_docPanel, toggle: false);  // Pages, the first time
            else RefreshDocPanel();
            Relayout(keepPage: false);
            if (focus is { } page && page < document.PageCount)
            {
                _page = page;
                ScrollTo(page, PageTop(page));
            }
            else if (keepPosition && !atTop)
            {
                _page = Math.Min(anchor, document.PageCount - 1);
                ScrollTo(_page, PageTop(_page) + within * _slots[_page].Height - ReadingDepth);
            }
            else
            {
                _page = targetPage;
                ScrollTo(_page, 0);
            }
        }
        finally
        {
            _rebuilding = false;
        }
        UpdateStatus();
        QuickTools.Visibility = IsFullScreen ? Visibility.Collapsed : Visibility.Visible;
        _ = RenderThumbnailsAsync(document);
        _ = RefreshCommentsAsync();
        _ = RefreshFieldsAsync();
        _ = RefreshAttachmentsAsync();
        _ = RefreshLayersAsync();
    }

    /// <summary>Sizes every page for the current zoom and re-renders what is visible.</summary>
    private void Relayout(bool keepPage)
    {
        if (_document is null) return;
        // Where the reading line falls inside the current page, as a fraction of its height.
        var anchor = _page;
        var within = 0.0;
        var atTop = PageScroller.VerticalOffset <= 1;
        if (keepPage && _slots.Count > 0 && _slots[anchor].Height > 0)
            within = Math.Clamp((ReadingLine - PageTop(anchor)) / _slots[anchor].Height, 0, 1);
        if (_fitWidth)
        {
            var widest = _pageSizes.Max(s => s.Width);
            var available = Math.Max(200, PageScroller.ActualWidth - 2 * ViewMargin - 20);  // scrollbar
            _zoom = Math.Clamp(available / (widest * 96 / 72), ZoomSteps[0], ZoomSteps[^1]);
        }
        _generation++;
        foreach (var slot in _slots)
        {
            var (w, h) = _pageSizes[slot.Index];
            slot.Width = Math.Round(w * Dips);
            slot.Height = Math.Round(h * Dips);
        }
        Pages.UpdateLayout();
        PageScroller.UpdateLayout();
        if (keepPage)
        {
            _page = anchor;
            // At the very top (e.g. the first fit after opening) stay at the top.
            var target = atTop ? 0 : PageTop(anchor) + within * _slots[anchor].Height - ReadingDepth;
            ScrollTo(anchor, target);
        }
        UpdateStatus();
        RenderVisible();
    }

    private double PageTop(int page)
    {
        var top = ViewMargin;
        for (var i = 0; i < page; i++) top += _slots[i].Height + PageSpacing;
        return top;
    }

    private (int First, int Last) VisibleRange()
    {
        if (_slots.Count == 0) return (0, -1);
        double top = PageScroller.VerticalOffset, bottom = top + PageScroller.ViewportHeight;
        int first = -1, last = -1;
        var y = ViewMargin;
        for (var i = 0; i < _slots.Count; i++)
        {
            var end = y + _slots[i].Height;
            if (end >= top && y <= bottom) { if (first < 0) first = i; last = i; }
            y = end + PageSpacing;
        }
        return first < 0 ? (0, 0) : (first, last);
    }

    private void UpdateCurrentPage()
    {
        if (_slots.Count == 0) return;
        // At the bottom of the document the last page is current (its top may never
        // reach the reading line); otherwise the page under the reading line is.
        if (PageScroller.VerticalOffset >= PageScroller.ScrollableHeight - 1 && PageScroller.ScrollableHeight > 0)
        {
            if (_page != _slots.Count - 1) { _page = _slots.Count - 1; UpdateStatus(); }
            return;
        }
        var probe = ReadingLine;
        var y = ViewMargin;
        var page = _slots.Count - 1;
        for (var i = 0; i < _slots.Count; i++)
        {
            y += _slots[i].Height + PageSpacing;
            if (probe < y) { page = i; break; }
        }
        if (page == _page) return;
        _page = page;
        UpdateStatus();
    }

    /// <summary>Renders visible pages (off the UI thread) and releases far-away images.</summary>
    private void RenderVisible()
    {
        if (_document is not { } document) return;
        var (first, last) = VisibleRange();
        foreach (var slot in _slots)
        {
            if (slot.Index < first - KeepRendered || slot.Index > last + KeepRendered) { slot.Image = null; slot.RenderedFor = -1; }
        }
#if DEBUG
        // After this layout pass settles; measuring now would see the previous zoom.
        var checkPage = first;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => CheckLayout(checkPage));
#endif
        var generation = _generation;
        var scale = Dips * RasterScale;
        for (var i = Math.Max(0, first - 1); i <= Math.Min(_slots.Count - 1, last + 1); i++)
        {
            _ = Info(i);
            if (IsEditingContent) _ = LoadContentAsync(i);
            if (_tool == CommentTool.Link) _ = LoadLinksAsync(i);
            var slot = _slots[i];
            if (slot.RenderedFor == generation) continue;
            slot.RenderedFor = generation;
            _ = RenderSlotAsync(document, slot, scale, generation);
        }
    }

#if DEBUG
    /// <summary>Debug builds: report if computed page positions disagree with the real layout.</summary>
    private void CheckLayout(int page)
    {
        if (Pages.ContainerFromIndex(page) is not UIElement container || PageScroller.Content is not UIElement content) return;
        var actual = container.TransformToVisual(content).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
        var mismatch = Math.Abs(actual - PageTop(page)) > 2;
        if (mismatch)
            StatusText.Text = $"Layout check: page {page + 1} is at {actual:0}, expected {PageTop(page):0}";
        else if (StatusText.Text.StartsWith("Layout check:", StringComparison.Ordinal))
            StatusText.Text = "";
    }
#endif

    private async Task RenderSlotAsync(PdfDocument document, PageSlot slot, double scale, int generation)
    {
        RenderedPage page;
        try { page = await Task.Run(() => document.Render(slot.Index, scale)); }
        catch (Exception error) when (error is ObjectDisposedException or InvalidDataException or OutOfMemoryException)
        {
            return;  // replaced, closed or too large; a newer pass takes over
        }
        if (generation != _generation || document != _document) return;
        slot.Image = ToBitmap(page);
    }

    /// <summary>Renders the sidebar off the UI thread; restarts when the document changes.</summary>
    private async Task RenderThumbnailsAsync(PdfDocument document)
    {
        _thumbnailWork?.Cancel();
        var work = _thumbnailWork = new CancellationTokenSource();
        _thumbnails.Clear();
        for (var i = 0; i < _pageSizes.Length; i++)
        {
            var (w, h) = _pageSizes[i];
            _thumbnails.Add(new Thumbnail(i, ThumbnailWidth, Math.Round(ThumbnailWidth * h / w), document.PageLabel(i)));
        }
        if (_reselect is { Count: > 1 } reselect)
        {
            _syncingSelection = true;
            foreach (var index in reselect.Where(i => i < _thumbnails.Count)) Thumbnails.SelectedItems.Add(_thumbnails[index]);
            _syncingSelection = false;
        }
        else
        {
            SyncThumbnailSelection();
        }
        _reselect = null;
        var scale = RasterScale;
        foreach (var thumb in _thumbnails.ToList())
        {
            if (work.IsCancellationRequested) return;
            RenderedPage image;
            try
            {
                var width = _pageSizes[thumb.Index].Width;
                image = await Task.Run(() => document.Render(thumb.Index, ThumbnailWidth / width * scale), work.Token);
            }
            catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException or InvalidDataException)
            {
                return;
            }
            if (work.IsCancellationRequested) return;
            thumb.Image = ToBitmap(image);
        }
    }

    private static WriteableBitmap ToBitmap(RenderedPage image)
    {
        var bitmap = new WriteableBitmap(image.Width, image.Height);
        using (var stream = bitmap.PixelBuffer.AsStream()) stream.Write(image.Pixels);
        bitmap.Invalidate();
        return bitmap;
    }

    private void SyncThumbnailSelection()
    {
        if (Thumbnails.SelectedItems.Count > 1) return;  // keep the user's multi-page selection
        _syncingSelection = true;
        Thumbnails.SelectedIndex = _page < _thumbnails.Count ? _page : -1;
        if (Thumbnails.SelectedItem is not null) Thumbnails.ScrollIntoView(Thumbnails.SelectedItem);
        _syncingSelection = false;
    }

    private void UpdateStatus()
    {
        if (_document is null) return;
        var label = _document.PageLabel(_page);
        // As on the Mac: "Page 4 of 12", or "Page iv (4 of 12)" with page labels.
        PageText.Text = label.Length > 0 && label != (_page + 1).ToString()
            ? $"Page {label} ({_page + 1} of {_document.PageCount})"
            : $"Page {_page + 1} of {_document.PageCount}";
        ZoomText.Text = ToolbarZoomText.Text = $"{_zoom * 100:0}%";
        if (PageBox.FocusState == FocusState.Unfocused) PageBox.Text = label.Length > 0 ? label : $"{_page + 1}";
        PageCountText.Text = $"of {_document.PageCount}";
        if (_page < _pageSizes.Length) PageSizeText.Text = $"{_pageSizes[_page].Width / 72:0.00} × {_pageSizes[_page].Height / 72:0.00} in";
        UpdateReadyText();
        DocumentTitle = _sourcePath is null ? "New Tab" : $"{(IsEdited ? "• " : "")}{Path.GetFileName(_sourcePath)}";
        Host.PaneChanged(this);
        SyncThumbnailSelection();
        UpdateCommands();
    }

    /// <summary>A toolbar button's shortcut stops working once the button moves into the
    /// overflow menu (narrow windows), so every shortcut lives on the window's root instead and
    /// invokes its button (when enabled). The button still shows the shortcut in its tooltip.</summary>
    /// <summary>Menu shortcuts live on the pane's root so they work without opening the menu
    /// (and while it's collapsed); each invokes its menu item when that item and its menu
    /// are enabled. The item still shows the shortcut.</summary>
    private void HoistToolbarAccelerators()
    {
        foreach (var menu in AppMenu.Items)
            foreach (var item in MenuItems(menu.Items))
            {
                var shortcuts = item.KeyboardAccelerators.ToList();
                if (shortcuts.Count == 0) continue;
                item.KeyboardAccelerators.Clear();
                item.KeyboardAcceleratorTextOverride = ShortcutText(shortcuts[0]);
                foreach (var shortcut in shortcuts)
                {
                    var hoisted = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = shortcut.Key, Modifiers = shortcut.Modifiers };
                    hoisted.Invoked += (_, args) =>
                    {
                        if (!item.IsEnabled || !menu.IsEnabled) return;
                        args.Handled = true;
                        (new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(item) as Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)?.Invoke();
                    };
                    RootGrid.KeyboardAccelerators.Add(hoisted);
                }
            }
    }

    private static IEnumerable<MenuFlyoutItem> MenuItems(IEnumerable<MenuFlyoutItemBase> items)
    {
        foreach (var item in items)
        {
            if (item is MenuFlyoutItem leaf) yield return leaf;
            else if (item is MenuFlyoutSubItem sub) foreach (var inner in MenuItems(sub.Items)) yield return inner;
        }
    }

    private static string ShortcutText(Microsoft.UI.Xaml.Input.KeyboardAccelerator shortcut)
    {
        var parts = new List<string>();
        if (shortcut.Modifiers.HasFlag(VirtualKeyModifiers.Control)) parts.Add("Ctrl");
        if (shortcut.Modifiers.HasFlag(VirtualKeyModifiers.Shift)) parts.Add("Shift");
        if (shortcut.Modifiers.HasFlag(VirtualKeyModifiers.Menu)) parts.Add("Alt");
        parts.Add((int)shortcut.Key switch { 187 => "+", 189 => "-", _ => shortcut.Key.ToString() });
        return string.Join("+", parts);
    }

    private void UpdateCommands()
    {
        var open = _document is not null;
        SaveAsItem.IsEnabled = ExportMenu.IsEnabled = ReduceItem.IsEnabled = PrintItem.IsEnabled = PropertiesItem.IsEnabled = PrintAreaItem.IsEnabled = open;
        EditMenu.IsEnabled = ViewMenu.IsEnabled = NavigateMenu.IsEnabled = CommentMenu.IsEnabled = FormsMenu.IsEnabled = DocumentMenu.IsEnabled = open;
        FindButton.IsEnabled = ShareButton.IsEnabled = FitPageButton.IsEnabled = RotateButton.IsEnabled = PageBox.IsEnabled = open;
        SaveItem.IsEnabled = IsEdited;
        ZoomInButton.IsEnabled = open && _zoom < ZoomSteps[^1] - 0.001;
        ZoomOutButton.IsEnabled = open && _zoom > ZoomSteps[0] + 0.001;
        FitWidthButton.IsEnabled = ActualSizeButton.IsEnabled = open;
        UndoItem.IsEnabled = _revisions.Count > 0 || HasPendingFields;
        RedoItem.IsEnabled = _redo.Count > 0 && !HasPendingFields;
        PreviousButton.IsEnabled = open && _page > 0;
        NextButton.IsEnabled = open && _page < _document!.PageCount - 1;
        QuickTools.Visibility = open && !IsFullScreen ? Visibility.Visible : Visibility.Collapsed;
        AllToolsButton.IsEnabled = open;
    }

    /// <summary>Runs `action` with a status message; errors go to the status bar. True if it succeeded.</summary>
    private async Task<bool> Run(string status, Func<Task> action, bool keepStatus = false, bool flushFields = true)
    {
        // Any other action first writes form entries still waiting to be saved.
        if (flushFields && HasPendingFields) await FlushFieldsAsync();
        StatusText.Text = status;
        OpenItem.IsEnabled = false;
        try
        {
            await action();
            if (!keepStatus) StatusText.Text = "";
            return true;
        }
        catch (Exception error) when (error is EngineException or IOException or InvalidDataException or UnauthorizedAccessException)
        {
            StatusText.Text = error.Message;
            NoteError(error is EngineException engine ? $"{engine.Code}: {engine.Message}" : error.Message);
            return false;
        }
        finally
        {
            OpenItem.IsEnabled = true;
            UpdateStatus();
            UpdateCommands();
        }
    }

    private void DeleteRevisions()
    {
        while (_revisions.TryPop(out var path)) TryDelete(path);
        while (_redo.TryPop(out var path)) TryDelete(path);
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
