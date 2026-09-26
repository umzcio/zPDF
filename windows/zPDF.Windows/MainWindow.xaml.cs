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
public sealed partial class MainWindow : Window
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
    private PdfDocument? _document;
    private (double Width, double Height)[] _pageSizes = [];
    private Engine? _engine;
    private int _page;
    private double _zoom = 1;
    private int _generation;  // bumps when zoom or document changes; stale renders are dropped
    private bool _fitWidth = true;
    private bool _syncingSelection;
    private bool _closeConfirmed;

    public MainWindow()
    {
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1200, 900));
        Thumbnails.ItemsSource = _thumbnails;
        Pages.ItemsSource = _slots;
        // Ctrl with the main keyboard's =/+ and − keys (OEM keys have no XAML name).
        ZoomInButton.KeyboardAccelerators.Add(new() { Modifiers = VirtualKeyModifiers.Control, Key = (VirtualKey)187 });
        ZoomOutButton.KeyboardAccelerators.Add(new() { Modifiers = VirtualKeyModifiers.Control, Key = (VirtualKey)189 });
        AppWindow.Closing += AppWindow_Closing;
        Closed += (_, _) =>
        {
            _thumbnailWork?.Cancel();
            _document?.Dispose();
            _engine?.Dispose();
            DeleteRevisions();
        };
    }

    private Engine Engine => _engine ??= new Engine();
    private string? CurrentPath => _revisions.TryPeek(out var top) ? top : _sourcePath;
    private bool IsEdited => _document is not null && CurrentPath != _savedPath;
    private double RasterScale => Content.XamlRoot?.RasterizationScale ?? 1.0;
    private double Dips => _zoom * 96 / 72;  // device-independent pixels per PDF point

    // ---------------------------------------------------------------- file

    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        if (!await ConfirmDiscardAsync()) return;
        // Windows App SDK pickers also work when zPDF runs as administrator
        // (the classic WinRT pickers silently show nothing there).
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add(".pdf");  // shows only PDFs (the 1.8 picker labels it "All Files")
        var file = await picker.PickSingleFileAsync();
        if (file is not null) await OpenAsync(file.Path);
    }

    /// <summary>Opens a PDF (from the picker, the command line or a drop).</summary>
    public Task OpenAsync(string path) => Run("Opening…", () =>
    {
        var document = PdfDocument.Open(path);  // throws before anything is replaced
        DeleteRevisions();
        _sourcePath = _savedPath = path;
        _page = 0;
        _fitWidth = true;
        Show(document, keepPosition: false);
        return Task.CompletedTask;
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
        if (await ConfirmDiscardAsync()) await OpenAsync(pdf.Path);
    }

    private async void Save_Click(object sender, RoutedEventArgs e) => await SaveAsync();

    private async Task<bool> SaveAsync()
    {
        if (!IsEdited || _sourcePath is null) return true;
        var saved = false;
        await Run("Saving…", async () =>
        {
            await Engine.PublishAsync(CurrentPath!, _sourcePath, overwrite: true);
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
            await Engine.PublishAsync(CurrentPath!, file.Path, overwrite: true);
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
            ContentDialogResult.Secondary => true,
            _ => false,
        };
    }

    private async void AppWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_closeConfirmed || !IsEdited) return;
        args.Cancel = true;
        if (await ConfirmDiscardAsync())
        {
            _closeConfirmed = true;
            Close();
        }
    }

    // ---------------------------------------------------------------- edit

    private async void Watermark_Click(object sender, RoutedEventArgs e) =>
        await Run("Adding watermark…", async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [new JsonObject { ["op"] = "watermark", ["text"] = "DRAFT" }]);
            _revisions.Push(edited);
            Show(PdfDocument.Open(edited), keepPosition: true);
        });

    private async void Undo_Click(object sender, RoutedEventArgs e) =>
        await Run("Undoing…", () =>
        {
            if (!_revisions.TryPop(out var undone)) return Task.CompletedTask;
            Show(PdfDocument.Open(CurrentPath!), keepPosition: true);
            if (undone != _savedPath) TryDelete(undone);
            return Task.CompletedTask;
        });

    // ---------------------------------------------------------------- view

    private void ZoomIn_Click(object sender, RoutedEventArgs e) => SetZoom(ZoomSteps.FirstOrDefault(z => z > _zoom + 0.001, ZoomSteps[^1]));
    private void ZoomOut_Click(object sender, RoutedEventArgs e) => SetZoom(ZoomSteps.LastOrDefault(z => z < _zoom - 0.001, ZoomSteps[0]));
    private void ActualSize_Click(object sender, RoutedEventArgs e) => SetZoom(1);

    private void FitWidth_Click(object sender, RoutedEventArgs e)
    {
        _fitWidth = true;
        Relayout(keepPage: true);
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
        UpdateCurrentPage();
        RenderVisible();
    }

    private void Previous_Click(object sender, RoutedEventArgs e) => GoTo(_page - 1);
    private void Next_Click(object sender, RoutedEventArgs e) => GoTo(_page + 1);

    private void Thumbnails_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_syncingSelection && Thumbnails.SelectedItem is Thumbnail thumb) GoTo(thumb.Index);
    }

    private void GoTo(int page)
    {
        if (_document is null || page < 0 || page >= _document.PageCount) return;
        _page = page;
        PageScroller.ChangeView(null, PageTop(page), null, disableAnimation: true);
        UpdateStatus();
    }

    // ---------------------------------------------------------------- layout and drawing

    /// <summary>Replaces the shown document (after open, edit or undo).</summary>
    private void Show(PdfDocument document, bool keepPosition)
    {
        var offset = PageScroller.VerticalOffset;
        _document?.Dispose();
        _document = document;
        _pageSizes = Enumerable.Range(0, document.PageCount).Select(document.PageSize).ToArray();
        _page = Math.Min(_page, document.PageCount - 1);
        _slots.Clear();
        for (var i = 0; i < document.PageCount; i++) _slots.Add(new PageSlot(i));
        EmptyText.Visibility = Visibility.Collapsed;
        Thumbnails.Visibility = Visibility.Visible;
        Relayout(keepPage: false);
        PageScroller.ChangeView(null, keepPosition ? offset : 0, null, disableAnimation: true);
        _ = RenderThumbnailsAsync(document);
    }

    /// <summary>Sizes every page for the current zoom and re-renders what is visible.</summary>
    private void Relayout(bool keepPage)
    {
        if (_document is null) return;
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
        if (keepPage) PageScroller.ChangeView(null, PageTop(_page), null, disableAnimation: true);
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
        // The page under the top third of the view is the current one.
        var probe = PageScroller.VerticalOffset + PageScroller.ViewportHeight / 3;
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
        var generation = _generation;
        var scale = Dips * RasterScale;
        for (var i = Math.Max(0, first - 1); i <= Math.Min(_slots.Count - 1, last + 1); i++)
        {
            var slot = _slots[i];
            if (slot.RenderedFor == generation) continue;
            slot.RenderedFor = generation;
            _ = RenderSlotAsync(document, slot, scale, generation);
        }
    }

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
            _thumbnails.Add(new Thumbnail(i, ThumbnailWidth, Math.Round(ThumbnailWidth * h / w)));
        }
        SyncThumbnailSelection();
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
        _syncingSelection = true;
        Thumbnails.SelectedIndex = _page < _thumbnails.Count ? _page : -1;
        if (Thumbnails.SelectedItem is not null) Thumbnails.ScrollIntoView(Thumbnails.SelectedItem);
        _syncingSelection = false;
    }

    private void UpdateStatus()
    {
        if (_document is null) return;
        PageText.Text = $"Page {_page + 1} of {_document.PageCount}";
        ZoomText.Text = $"{_zoom * 100:0}%";
        Title = $"{(IsEdited ? "• " : "")}{Path.GetFileName(_sourcePath)} — zPDF";
        SyncThumbnailSelection();
        UpdateCommands();
    }

    private void UpdateCommands()
    {
        var open = _document is not null;
        SaveAsButton.IsEnabled = WatermarkButton.IsEnabled = open;
        SaveButton.IsEnabled = IsEdited;
        ZoomInButton.IsEnabled = open && _zoom < ZoomSteps[^1] - 0.001;
        ZoomOutButton.IsEnabled = open && _zoom > ZoomSteps[0] + 0.001;
        FitWidthButton.IsEnabled = ActualSizeButton.IsEnabled = open;
        UndoButton.IsEnabled = _revisions.Count > 0;
        PreviousButton.IsEnabled = open && _page > 0;
        NextButton.IsEnabled = open && _page < _document!.PageCount - 1;
    }

    private async Task Run(string status, Func<Task> action, bool keepStatus = false)
    {
        StatusText.Text = status;
        OpenButton.IsEnabled = false;
        try
        {
            await action();
            if (!keepStatus) StatusText.Text = "";
        }
        catch (Exception error) when (error is EngineException or IOException or InvalidDataException or UnauthorizedAccessException)
        {
            StatusText.Text = error.Message;
        }
        finally
        {
            OpenButton.IsEnabled = true;
            UpdateStatus();
            UpdateCommands();
        }
    }

    private void DeleteRevisions()
    {
        while (_revisions.TryPop(out var path)) TryDelete(path);
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
