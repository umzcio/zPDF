using Microsoft.UI.Xaml;

namespace zPDF;

public partial class App : Application
{
    private MainWindow? _window;

    public App() => InitializeComponent();

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
        // `zPDF.exe file.pdf` (Open With, or a double-click once zPDF is the default).
        var file = Environment.GetCommandLineArgs().Skip(1)
            .FirstOrDefault(a => a.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) && File.Exists(a));
        if (file is not null) await _window.OpenAsync(Path.GetFullPath(file));
    }
}
