using System.Collections.ObjectModel;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Windows.Storage.Pickers;
using Windows.System;

namespace zPDF;

/// <summary>Prototype document window: open, view (zoom, thumbnails), one engine edit
/// with undo, Save As. Edits apply to private working copies; the user's file changes
/// only on Save As.</summary>
public sealed partial class MainWindow : Window
{
    private static readonly double[] ZoomSteps = [0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4];
    private const double ThumbnailWidth = 120;

    private readonly Stack<string> _revisions = new();  // working copies, newest on top
    private readonly ObservableCollection<Thumbnail> _thumbnails = [];
    private CancellationTokenSource? _thumbnailWork;
    private string? _sourcePath;
    private PdfDocument? _document;
    private Engine? _engine;
    private int _page;
    private double _zoom = 1;
    private bool _fitWidth = true;
    private bool _syncingSelection;

    public MainWindow()
    {
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1200, 900));
        Thumbnails.ItemsSource = _thumbnails;
        // Ctrl with the main keyboard's =/+ and − keys (OEM keys have no XAML name).
        ZoomInButton.KeyboardAccelerators.Add(new() { Modifiers = VirtualKeyModifiers.Control, Key = (VirtualKey)187 });
        ZoomOutButton.KeyboardAccelerators.Add(new() { Modifiers = VirtualKeyModifiers.Control, Key = (VirtualKey)189 });
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
    private double RasterScale => Content.XamlRoot?.RasterizationScale ?? 1.0;

    // ---------------------------------------------------------------- file

    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        // Windows App SDK pickers also work when zPDF runs as administrator
        // (the classic WinRT pickers silently show nothing there).
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add(".pdf");  // shows only PDFs (the 1.8 picker labels it "All Files")
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        await Run("Opening…", () =>
        {
            DeleteRevisions();
            _sourcePath = file.Path;
            _page = 0;
            _fitWidth = true;
            Show(CurrentPath!, newDocument: true);
            Title = $"{Path.GetFileName(file.Path)} — zPDF";
            return Task.CompletedTask;
        });
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
            StatusText.Text = $"Saved {Path.GetFileName(file.Path)}";
        }, keepStatus: true);
    }

    // ---------------------------------------------------------------- edit

    private async void Watermark_Click(object sender, RoutedEventArgs e) =>
        await Run("Adding watermark…", async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [new JsonObject { ["op"] = "watermark", ["text"] = "DRAFT" }]);
            _revisions.Push(edited);
            Show(edited, newDocument: false);
        });

    private async void Undo_Click(object sender, RoutedEventArgs e) =>
        await Run("Undoing…", () =>
        {
            if (_revisions.TryPop(out var undone)) { Show(CurrentPath!, newDocument: false); TryDelete(undone); }
            return Task.CompletedTask;
        });

    // ---------------------------------------------------------------- view

    private void ZoomIn_Click(object sender, RoutedEventArgs e) => SetZoom(ZoomSteps.FirstOrDefault(z => z > _zoom + 0.001, ZoomSteps[^1]));
    private void ZoomOut_Click(object sender, RoutedEventArgs e) => SetZoom(ZoomSteps.LastOrDefault(z => z < _zoom - 0.001, ZoomSteps[0]));
    private void ActualSize_Click(object sender, RoutedEventArgs e) => SetZoom(1);

    private void FitWidth_Click(object sender, RoutedEventArgs e)
    {
        _fitWidth = true;
        Render();
    }

    private void PageScroller_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_fitWidth && Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > 1) Render();
    }

    private void SetZoom(double zoom)
    {
        _fitWidth = false;
        _zoom = Math.Clamp(zoom, ZoomSteps[0], ZoomSteps[^1]);
        Render();
    }

    private void Previous_Click(object sender, RoutedEventArgs e) => GoTo(_page - 1);
    private void Next_Click(object sender, RoutedEventArgs e) => GoTo(_page + 1);

    private void Thumbnails_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_syncingSelection && Thumbnails.SelectedItem is Thumbnail thumb) GoTo(thumb.Index);
    }

    private void GoTo(int page)
    {
        if (_document is null || page < 0 || page >= _document.PageCount || page == _page) return;
        _page = page;
        Render();
        PageScroller.ChangeView(null, 0, null, disableAnimation: true);
    }

    // ---------------------------------------------------------------- drawing

    private void Show(string path, bool newDocument)
    {
        var next = PdfDocument.Open(path);
        _document?.Dispose();
        _document = next;
        _page = Math.Min(_page, next.PageCount - 1);
        Render();
        _ = RenderThumbnailsAsync(next);
    }

    /// <summary>Draws the current page at the current zoom, sharp at any display scale.</summary>
    private void Render()
    {
        if (_document is null) return;
        var (width, height) = _document.PageSize(_page);
        if (_fitWidth)
        {
            var available = Math.Max(200, PageScroller.ActualWidth - 48 - 20);  // padding + scrollbar
            _zoom = Math.Clamp(available / (width * 96 / 72), ZoomSteps[0], ZoomSteps[^1]);
        }
        var dips = _zoom * 96 / 72;  // device-independent pixels per point
        var image = _document.Render(_page, dips * RasterScale);
        PageImage.Source = ToBitmap(image);
        PageImage.Width = width * dips;
        PageImage.Height = height * dips;
        EmptyText.Visibility = Visibility.Collapsed;
        Thumbnails.Visibility = Visibility.Visible;
        PageText.Text = $"Page {_page + 1} of {_document.PageCount}";
        ZoomText.Text = $"{_zoom * 100:0}%";
        _syncingSelection = true;
        Thumbnails.SelectedIndex = _page < _thumbnails.Count ? _page : -1;
        _syncingSelection = false;
        UpdateCommands();
    }

    /// <summary>Renders the sidebar off the UI thread; restarts when the document changes.</summary>
    private async Task RenderThumbnailsAsync(PdfDocument document)
    {
        _thumbnailWork?.Cancel();
        var work = _thumbnailWork = new CancellationTokenSource();
        _thumbnails.Clear();
        for (var i = 0; i < document.PageCount; i++)
        {
            var (w, h) = document.PageSize(i);
            _thumbnails.Add(new Thumbnail(i, ThumbnailWidth, Math.Round(ThumbnailWidth * h / w)));
        }
        _syncingSelection = true;
        Thumbnails.SelectedIndex = _page;
        _syncingSelection = false;
        var scale = RasterScale;
        foreach (var thumb in _thumbnails.ToList())
        {
            if (work.IsCancellationRequested) return;
            RenderedPage? image;
            try
            {
                var (w, _) = document.PageSize(thumb.Index);
                image = await Task.Run(() => document.Render(thumb.Index, ThumbnailWidth / w * scale), work.Token);
            }
            catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException or InvalidDataException)
            {
                return;  // the document was replaced or closed; a newer pass takes over
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

    private void UpdateCommands()
    {
        var open = _document is not null;
        SaveAsButton.IsEnabled = WatermarkButton.IsEnabled = open;
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
