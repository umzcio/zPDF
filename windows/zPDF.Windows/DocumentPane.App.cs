using System.Net.Http;
using System.Net.Http.Json;
using System.Reflection;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace zPDF;

/// <summary>App-level features: redo, windows, preferences, Report a Bug, About.</summary>
public sealed partial class DocumentPane
{
    private const string FeedbackEndpoint = "https://zpdf-feedback.umontana.workers.dev/v1/reports";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(60) };
    private readonly Stack<string> _redo = new();  // undone revisions, newest on top
    private static string? _lastError;

    public static string Version =>
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0";

    private static string AuthorName => AppSettings.Current.AuthorName is { Length: > 0 } name ? name : Environment.UserName;

    // ---------------------------------------------------------------- undo history

    /// <summary>A new working revision. Anything that could be redone is dropped.</summary>
    private void PushRevision(string path)
    {
        _revisions.Push(path);
        while (_redo.TryPop(out var dropped)) if (dropped != _savedPath) TryDelete(dropped);
    }

    private async void Redo_Click(object sender, RoutedEventArgs e) => await RedoAsync();

    private async Task RedoAsync()
    {
        if (!_redo.TryPeek(out _)) return;
        await Run("Redoing…", () =>
        {
            if (!_redo.TryPop(out var redone)) return Task.CompletedTask;
            _revisions.Push(redone);
            Show(PdfDocument.Open(redone, _password), keepPosition: true);
            return Task.CompletedTask;
        });
    }

    // ---------------------------------------------------------------- windows

    private void NewWindow_Click(object sender, RoutedEventArgs e) => App.OpenWindow(null);

    /// <summary>App commands Home's menus run through a pane: preferences, shortcuts, bug, updates, about.</summary>
    public void RunAppCommand(string command)
    {
        var args = new RoutedEventArgs();
        switch (command)
        {
            case "preferences": Preferences_Click(this, args); break;
            case "shortcuts": KeyboardShortcuts_Click(this, args); break;
            case "bug": ReportBug_Click(this, args); break;
            case "updates": CheckUpdates_Click(this, args); break;
            case "about": About_Click(this, args); break;
        }
    }
    private void NewTab_Click(object sender, RoutedEventArgs e) => _ = Host.OpenFileAsync();
    private void CloseTab_Click(object sender, RoutedEventArgs e) => _ = Host.CloseTabAsync(this);

    /// <summary>Opens a file here, or in a new window when this one already has a document.</summary>
    private async Task OpenHereOrNewAsync(string path)
    {
        if (Host.FindTab(path) is { } open) { Host.Select(open); return; }  // already open: show it
        if (_document is not null)
        {
            if (AppSettings.Current.OpenInTabs) Host.AddTab(path);
            else App.OpenWindow(path);
            return;
        }
        if (await ConfirmDiscardAsync()) await OpenAsync(path);
    }

    // ---------------------------------------------------------------- preferences

    private async void Preferences_Click(object sender, RoutedEventArgs e)
    {
        var settings = AppSettings.Current;
        var author = Text("Your name (on comments, replies and marks)", settings.AuthorName, Environment.UserName);
        var zoom = Choice("Open documents at", ["Fit width", "Actual size (100%)"], settings.FitWidthOnOpen ? 0 : 1);
        var layouts = new[] { "single", "continuous", "facing" };
        var layout = Choice("Default page layout", ["Single Page", "Continuous", "Facing Pages"], Math.Max(0, Array.IndexOf(layouts, settings.DefaultViewMode)));
        var fields = new CheckBox { Content = "Highlight form fields", IsChecked = settings.HighlightFields };
        var windows = new CheckBox { Content = "Open files in tabs (clear to open each in its own window)", IsChecked = settings.OpenInTabs };
        var clear = new Button { Content = "Clear Recent Files" };
        clear.Click += (_, _) => { settings.ClearRecent(); ShowStartRecents(); clear.IsEnabled = false; };
        var defaults = new Button { Content = FileAssociation.IsRegistered() ? "Choose zPDF as the Default PDF App…" : "Make zPDF Available for PDFs…" };
        defaults.Click += async (_, _) =>
        {
            try
            {
                FileAssociation.Register();
                await FileAssociation.OpenDefaultAppsSettingsAsync();
                defaults.Content = "Choose zPDF as the Default PDF App…";
            }
            catch (Exception error) when (error is UnauthorizedAccessException or IOException or InvalidOperationException or System.Security.SecurityException)
            {
                StatusText.Text = $"Couldn't register zPDF for PDFs: {error.Message}";
            }
        };
        var defaultsNote = new TextBlock
        {
            Text = "zPDF appears in \"Open with\". Windows lets only you choose the default app, so this opens Settings ▸ Default apps.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.75,
        };
        if (!await AskAsync("Preferences", Stack(author, zoom, layout, fields, windows, clear, defaults, defaultsNote), "Save")) return;
        settings.AuthorName = author.Text.Trim();
        settings.FitWidthOnOpen = zoom.SelectedIndex == 0;
        settings.DefaultViewMode = layouts[Math.Max(0, layout.SelectedIndex)];
        settings.HighlightFields = fields.IsChecked == true;
        settings.OpenInTabs = windows.IsChecked == true;
        settings.Save();
        _highlightFields = settings.HighlightFields;
        HighlightFieldsButton.IsOn = _highlightFields;
        RefreshMarks();
    }

    // ---------------------------------------------------------------- Report a Bug

    /// <summary>Remembers the latest error for the next report's diagnostics.</summary>
    public void ShowProblem(string message) => StatusText.Text = message;

    public static void NoteError(string message) => _lastError = message.Length > 500 ? message[..500] : message;

    private async void ReportBug_Click(object sender, RoutedEventArgs e) => await ReportBugAsync();

    private async Task ReportBugAsync()
    {
        var kind = Choice("Type", ["Bug", "Suggestion"]);
        var title = Text("Title", "", "Short summary");
        var description = new TextBox { Header = "What happened?", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 90 };
        var steps = new TextBox { Header = "Steps to reproduce (optional)", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 60 };
        var expected = Text("Expected result (optional)");
        var email = Text("Email (optional) — only the zPDF team sees it", "", "you@example.com");
        var diagnostics = new CheckBox { Content = "Include diagnostics", IsChecked = true };
        var os = Environment.OSVersion.Version;
        var osText = $"Windows {(os.Build >= 22000 ? "11" : "10")} ({os.Major}.{os.Minor}.{os.Build})";
        var diagText = new TextBlock
        {
            Text = $"zPDF {Version} · {osText} · {System.Runtime.InteropServices.RuntimeInformation.OSArchitecture} · {System.Globalization.CultureInfo.CurrentCulture.Name}" +
                   (_lastError is { } last ? $"\nLast error: {last}" : ""),
            TextWrapping = TextWrapping.Wrap, Opacity = 0.75, IsTextSelectionEnabled = true,
        };
        var screenshot = new CheckBox { Content = "Attach a screenshot of the zPDF window (anyone who can see the report can see it)" };
        var privacy = new TextBlock { Text = "Reports never include your PDFs, file names or document text.", Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = "Report a Bug",
            Content = new ScrollViewer { Content = Stack(kind, title, description, steps, expected, email, diagnostics, diagText, screenshot, privacy), MaxHeight = 560 },
            PrimaryButtonText = "Send Report", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
        };
        var png = await WindowScreenshotAsync();  // taken before the dialog covers the window
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (title.Text.Trim().Length == 0 || description.Text.Trim().Length == 0)
            {
                args.Cancel = true;
                dialog.Title = "Report a Bug — add a title and a description";
            }
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var body = new JsonObject
        {
            ["kind"] = kind.SelectedIndex == 1 ? "suggestion" : "bug", ["title"] = title.Text.Trim(), ["description"] = description.Text.Trim(),
        };
        if (steps.Text.Trim() is { Length: > 0 } s) body["steps"] = s;
        if (expected.Text.Trim() is { Length: > 0 } x) body["expected"] = x;
        if (email.Text.Trim() is { Length: > 0 } m) body["email"] = m;
        if (diagnostics.IsChecked == true)
        {
            var diag = new JsonObject
            {
                ["appVersion"] = Version, ["build"] = "windows", ["macOS"] = osText, ["os"] = "Windows",
                ["chip"] = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture.ToString(),
                ["locale"] = System.Globalization.CultureInfo.CurrentCulture.Name,
            };
            if (_lastError is { } lastSeen) diag["lastError"] = lastSeen;
            body["diagnostics"] = diag;
        }
        if (screenshot.IsChecked == true && png is not null) body["screenshot"] = new JsonObject { ["mime"] = "image/png", ["base64"] = Convert.ToBase64String(png) };
        StatusText.Text = "Sending report…";
        try
        {
            using var response = await Http.PostAsJsonAsync(FeedbackEndpoint, body);
            var reply = await response.Content.ReadFromJsonAsync<JsonNode>();
            if (!response.IsSuccessStatusCode || reply?["issue"]?["number"] is not JsonValue number)
            {
                StatusText.Text = reply?["error"]?["message"]?.GetValue<string>() ?? "The report couldn't be sent right now. Please try again later.";
                return;
            }
            StatusText.Text = $"Thanks — your report was sent (#{number}).";
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            StatusText.Text = "The report couldn't be sent. Check your internet connection and try again.";
        }
    }

    private async Task<byte[]?> WindowScreenshotAsync()
    {
        try
        {
            var target = new RenderTargetBitmap();
            await target.RenderAsync(Content);
            var pixels = await target.GetPixelsAsync();
            using var stream = new InMemoryRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)target.PixelWidth, (uint)target.PixelHeight, 96, 96, pixels.ToArray());
            await encoder.FlushAsync();
            var bytes = new byte[stream.Size];
            await stream.AsStreamForRead().ReadExactlyAsync(bytes);
            return bytes;
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            return null;
        }
    }

    // ---------------------------------------------------------------- updates

    private async void CheckUpdates_Click(object sender, RoutedEventArgs e) => await Updates.CheckAsync(this, quiet: false);

    public async Task InfoAsync(string title, string message) =>
        await new ContentDialog { XamlRoot = Content.XamlRoot, Title = title, Content = message, CloseButtonText = "OK" }.ShowAsync();

    public async Task<bool> ConfirmAsync(string title, string message, string action) =>
        await new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = title, Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = action, CloseButtonText = "Not Now", DefaultButton = ContentDialogButton.Primary,
        }.ShowAsync() == ContentDialogResult.Primary;

    /// <summary>Before an update restarts zPDF: offer to save unsaved changes.</summary>
    // ---------------------------------------------------------------- About

    private async void About_Click(object sender, RoutedEventArgs e)
    {
        var text = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
            Text = $"zPDF {Version} for Windows (preview)\n\nA PDF editor: read, comment, fill and sign, edit, redact, organize, convert and protect PDFs.\n\n" +
                   "Built on PDFium (BSD-3-Clause), QPDF (Apache-2.0), pikepdf (MPL-2.0), fontTools (MIT), pdf417gen (MIT), cryptography (Apache-2.0/BSD), " +
                   "Python (PSF), the Windows App SDK (MIT) and .NET (MIT). zPDF is licensed under the Apache License 2.0.\n\n" +
                   "License texts are in the EngineRuntime and licenses folders next to zPDF.exe.",
        };
        var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "About zPDF", Content = text, CloseButtonText = "OK" };
        await dialog.ShowAsync();
    }
}
