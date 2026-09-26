using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Pickers;

namespace zPDF;

/// <summary>Prototype document window: open, view, one engine edit (with undo), Save As.
/// Edits apply to private working copies; the user's file changes only on Save As.</summary>
public sealed partial class MainWindow : Window
{
    private readonly Stack<string> _revisions = new();  // working copies, newest on top
    private string? _sourcePath;
    private PdfDocument? _document;
    private Engine? _engine;
    private int _page;

    public MainWindow()
    {
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1100, 900));
        Closed += (_, _) => { _document?.Dispose(); _engine?.Dispose(); DeleteRevisions(); };
    }

    private Engine Engine => _engine ??= new Engine();
    private string? CurrentPath => _revisions.TryPeek(out var top) ? top : _sourcePath;

    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add(".pdf");
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        await Run("Opening…", () =>
        {
            DeleteRevisions();
            _sourcePath = file.Path;
            _page = 0;
            Show(CurrentPath!);
            Title = $"{file.Name} — zPDF";
            return Task.CompletedTask;
        });
    }

    private async void Watermark_Click(object sender, RoutedEventArgs e) =>
        await Run("Adding watermark…", async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [new JsonObject { ["op"] = "watermark", ["text"] = "DRAFT" }]);
            _revisions.Push(edited);
            Show(edited);
        });

    private async void Undo_Click(object sender, RoutedEventArgs e) =>
        await Run("Undoing…", () =>
        {
            if (_revisions.TryPop(out var undone)) { Show(CurrentPath!); TryDelete(undone); }
            return Task.CompletedTask;
        });

    private async void SaveAs_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileSavePicker { SuggestedFileName = Path.GetFileNameWithoutExtension(_sourcePath) + " edited" };
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeChoices.Add("PDF document", [".pdf"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        await Run("Saving…", async () =>
        {
            await Engine.PublishAsync(CurrentPath!, file.Path, overwrite: true);
            StatusText.Text = $"Saved {file.Name}";
        }, keepStatus: true);
    }

    private void Previous_Click(object sender, RoutedEventArgs e) { if (_page > 0) { _page--; Render(); } }
    private void Next_Click(object sender, RoutedEventArgs e) { if (_document is { } d && _page < d.PageCount - 1) { _page++; Render(); } }

    private void Show(string path)
    {
        var next = PdfDocument.Open(path);
        _document?.Dispose();
        _document = next;
        _page = Math.Min(_page, next.PageCount - 1);
        Render();
    }

    private void Render()
    {
        if (_document is null) return;
        var scale = (Content.XamlRoot?.RasterizationScale ?? 1.0) * 96.0 / 72.0;  // 100% zoom
        var image = _document.Render(_page, scale);
        var bitmap = new WriteableBitmap(image.Width, image.Height);
        using (var stream = bitmap.PixelBuffer.AsStream()) stream.Write(image.Pixels);
        bitmap.Invalidate();
        PageImage.Source = bitmap;
        PageImage.Width = image.Width / (Content.XamlRoot?.RasterizationScale ?? 1.0);
        PageImage.Height = image.Height / (Content.XamlRoot?.RasterizationScale ?? 1.0);
        EmptyText.Visibility = Visibility.Collapsed;
        PageText.Text = $"Page {_page + 1} of {_document.PageCount}";
        UpdateCommands();
    }

    private void UpdateCommands()
    {
        var open = _document is not null;
        SaveAsButton.IsEnabled = WatermarkButton.IsEnabled = open;
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
