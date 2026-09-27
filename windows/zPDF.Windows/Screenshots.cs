using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace zPDF;

/// <summary>`zPDF.exe --screenshot input.pdf folder`: renders the window in its main states
/// (Home, a document, All tools, tool panels, dark mode) to PNGs, for comparing the look
/// with the Mac app. Needs a desktop session.</summary>
internal static class Screenshots
{
    public static async Task CaptureAsync(MainWindow window, string input, string folder)
    {
        Directory.CreateDirectory(folder);
        var log = Path.Combine(folder, "steps.txt");
        void Step(string text) => File.AppendAllText(log, $"{DateTime.Now:HH:mm:ss.fff} {text}\n");
        Step("start");
        window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1440, 900));
        await Task.Delay(1500);
        await SaveAsync(window, Path.Combine(folder, "1-home.png"));
        Step("home saved");
        var pane = window.AddTab(input);
        Step("tab added");
        for (var i = 0; i < 100 && pane.IsEmpty; i++) await Task.Delay(100);
        Step($"document loaded: {!pane.IsEmpty}");
        await Task.Delay(2500);
        await SaveAsync(window, Path.Combine(folder, "2-document.png"));
        Step("document saved");
        foreach (var (step, name) in new[] { ("tools", "3-all-tools"), ("comment", "4-comment"), ("protect", "5-protect"), ("fillSign", "6-fill-forms"), ("edit", "7-edit") })
        {
            pane.ShowForScreenshot(step);
            await Task.Delay(900);
            await SaveAsync(window, Path.Combine(folder, name + ".png"));
            Step(name);
        }
        if (window.Content is FrameworkElement root)
        {
            root.RequestedTheme = ElementTheme.Dark;
            pane.ShowForScreenshot("protect");
            await Task.Delay(900);
            await SaveAsync(window, Path.Combine(folder, "8-dark-protect.png"));
            window.ShowHome();
            await Task.Delay(900);
            await SaveAsync(window, Path.Combine(folder, "9-dark-home.png"));
        }
    }

    private static async Task SaveAsync(Window window, string path)
    {
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(window.Content);
        var pixels = await bitmap.GetPixelsAsync();
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96,
                             System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.ToArray(pixels));
        await encoder.FlushAsync();
        stream.Seek(0);
        using var file = File.Create(path);
        await stream.AsStreamForRead().CopyToAsync(file);
    }
}
