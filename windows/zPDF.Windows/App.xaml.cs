using Microsoft.UI.Xaml;

namespace zPDF;

public partial class App : Application
{
    private static readonly List<MainWindow> Windows = [];

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // `zPDF.exe file.pdf` (Open With, or a double-click once zPDF is the default).
        var file = Environment.GetCommandLineArgs().Skip(1)
            .FirstOrDefault(a => a.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) && File.Exists(a));
        OpenWindow(file is null ? null : Path.GetFullPath(file));
    }

    /// <summary>A new document window, optionally opening `path`.</summary>
    public static void OpenWindow(string? path)
    {
        var window = new MainWindow();
        Windows.Add(window);
        window.Closed += (_, _) => Windows.Remove(window);
        window.Activate();
        if (path is not null) _ = window.OpenAsync(path);
    }
}
