using Microsoft.UI.Xaml;

namespace zPDF;

public partial class App : Application
{
    private static readonly List<MainWindow> Windows = [];

    public App()
    {
        // Before any XAML loads: a parse or resource error says what failed, in errors.log.
        AppDomain.CurrentDomain.FirstChanceException += (_, e) =>
        {
            // ZPDF_TRACE=1: every exception, with where it came from (diagnosing startup crashes).
            if (Environment.GetEnvironmentVariable("ZPDF_TRACE") == "1")
                Log($"trace {e.Exception.GetType().Name}: {e.Exception.Message} @ {string.Join(" < ", new System.Diagnostics.StackTrace(1, false).GetFrames().Take(8).Select(f => f.GetMethod()?.DeclaringType?.Name + "." + f.GetMethod()?.Name))}");
            if (e.Exception is Microsoft.UI.Xaml.Markup.XamlParseException or System.Runtime.InteropServices.COMException { HResult: unchecked((int)0x802B000A) })
                Log($"XAML: {e.Exception.Message}");
        };
        try { InitializeComponent(); }
        catch (Exception error) { Log($"App resources failed to load: {error}"); throw; }
        DebugSettings.XamlResourceReferenceFailed += (_, e) => Log($"XAML resource: {e.Message}");
        DebugSettings.BindingFailed += (_, e) => Log($"Binding: {e.Message}");
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

    private static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(AppSettings.DataFolder);
            File.AppendAllText(Path.Combine(AppSettings.DataFolder, "errors.log"), $"{DateTime.Now:O} {message}\n");
        }
        catch (Exception logging) when (logging is IOException or UnauthorizedAccessException) { }
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
        if (Environment.GetCommandLineArgs().Skip(1).ToArray() is ["--xamlcheck", var variantLog, var variant])
        {
            // Put a pane, minus one part, in a plain window: whether it survives says which part crashes.
            var host = new MainWindow();
            var probe = new Window();
            var pane = new DocumentPane(host);
            pane.RemoveForCheck(variant);
            probe.Content = pane;
            probe.Activate();
            await Task.Delay(1500);
            File.WriteAllText(variantLog, $"ok without {variant}\n");
            Environment.Exit(0);
            return;
        }
        if (Environment.GetCommandLineArgs().Skip(1).ToArray() is ["--xamlcheck", var checkLog])
        {
            // Builds each piece of the UI on its own and records which one fails to load.
            var lines = new List<string>();
            void Try(string name, Func<object> make)
            {
                try { make(); lines.Add($"ok   {name}"); }
                catch (Exception error) { lines.Add($"FAIL {name}: {error.GetType().Name}: {error.Message}"); }
            }
            Try("Theme.xaml", () => new ResourceDictionary { Source = new Uri("ms-appx:///Theme.xaml") });
            Try("HomeView", () => new HomeView());
            MainWindow? window = null;
            Try("MainWindow", () => window = new MainWindow());
            if (window is not null) Try("DocumentPane", () => new DocumentPane(window));
            await File.WriteAllLinesAsync(checkLog, lines);
            if (window is not null)
            {
                // Show the pane section by section; the last line written names what crashes.
                window.Activate();
                await Task.Delay(800);
                File.AppendAllText(checkLog, "ok   window shown\n");
                MainWindow.Trace = text => File.AppendAllText(checkLog, $"     {text}\n");
                var pane = window.AddTab(null, p => { foreach (var section in p.LayoutSections()) section.Visibility = Visibility.Collapsed; });
                await Task.Delay(800);
                File.AppendAllText(checkLog, "ok   pane in window (sections hidden)\n");
                foreach (var section in pane.LayoutSections())
                {
                    File.AppendAllText(checkLog, $"show {section.Name}\n");
                    section.Visibility = Visibility.Visible;
                    await Task.Delay(700);
                    File.AppendAllText(checkLog, $"ok   {section.Name}\n");
                }
            }
            Environment.Exit(0);
            return;
        }
        if (Environment.GetCommandLineArgs().Skip(1).ToArray() is ["--screenshot", var shotInput, var shotFolder])
        {
            var window = new MainWindow();
            window.Activate();
            await Screenshots.CaptureAsync(window, Path.GetFullPath(shotInput), Path.GetFullPath(shotFolder));
            Environment.Exit(0);
            return;
        }
        if (Environment.GetCommandLineArgs().Skip(1).ToArray() is ["--uitest", var input, var log])
        {
            var test = new MainWindow();
            test.Activate();
            var failures = await test.AddTab(null).RunUiTestAsync(Path.GetFullPath(input), Path.GetFullPath(log));
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
