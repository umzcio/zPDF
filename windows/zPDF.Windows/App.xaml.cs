using Microsoft.UI.Xaml;

namespace zPDF;

public partial class App : Application
{
    private static readonly List<MainWindow> Windows = [];

    public App()
    {
        InitializeComponent();
        // An unexpected error in one command shouldn't close every document: log it, say so in
        // the status bar and keep it for Report a Bug.
        UnhandledException += (_, e) =>
        {
            e.Handled = true;
            Report(e.Exception);
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            e.SetObserved();
            Report(e.Exception);
        };
    }

    private static void Report(Exception error)
    {
        DocumentPane.NoteError($"{error.GetType().Name}: {error.Message}");
        try
        {
            var folder = AppSettings.DataFolder;
            Directory.CreateDirectory(folder);
            var log = Path.Combine(folder, "errors.log");
            if (File.Exists(log) && new FileInfo(log).Length > 1 << 20) File.Delete(log);
            File.AppendAllText(log, $"{DateTime.Now:O} {DocumentPane.Version}\n{error}\n\n");
        }
        catch (Exception logging) when (logging is IOException or UnauthorizedAccessException) { }
        var pane = Windows.LastOrDefault()?.ActivePane;
        pane?.DispatcherQueue.TryEnqueue(() => pane.ShowProblem("Something went wrong with that command. Undo is available if it changed anything; details are kept for Report a Bug."));
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (Environment.GetCommandLineArgs().Skip(1).ToArray() is ["--uitest", var input, var log])
        {
            var test = new MainWindow();
            test.Activate();
            var failures = await test.ActivePane!.RunUiTestAsync(Path.GetFullPath(input), Path.GetFullPath(log));
            Environment.Exit(failures);
            return;
        }
        // `zPDF.exe file.pdf` (Open With, or a double-click once zPDF is the default).
        var file = Environment.GetCommandLineArgs().Skip(1)
            .FirstOrDefault(a => a.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) && File.Exists(a));
        OpenWindow(file is null ? null : Path.GetFullPath(file));
    }

    /// <summary>A new document window, optionally opening `path`.</summary>
    public static void OpenWindow(string? path)
    {
        var window = new MainWindow(path);
        Windows.Add(window);
        window.Closed += (_, _) => Windows.Remove(window);
        window.Activate();
    }
}
