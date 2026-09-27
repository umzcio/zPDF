using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace zPDF;

/// <summary>The Home screen: recent and starred PDFs as cards (a rendered first page, name,
/// when it was last opened and its size, a star), with Open File and Combine PDFs.</summary>
public sealed partial class HomeView : UserControl
{
    private bool _starred;
    private int _generation;

    public event Action<string>? OpenRequested;
    public event Action? OpenFileRequested;
    public event Action? CombineRequested;

    public HomeView()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
    }

    private void Open_Click(object sender, RoutedEventArgs e) => OpenFileRequested?.Invoke();
    private void Combine_Click(object sender, RoutedEventArgs e) => CombineRequested?.Invoke();

    private void Filter_Click(object sender, RoutedEventArgs e)
    {
        _starred = sender == StarredFilter;
        Refresh();
    }

    /// <summary>Rebuilds the cards (recent files change whenever a document is opened).</summary>
    public void Refresh()
    {
        var settings = AppSettings.Current;
        var starred = settings.StarredFiles.Where(File.Exists).ToList();
        var recent = settings.RecentFiles.Where(File.Exists).ToList();
        RecentCount.Text = recent.Count.ToString();
        StarredCount.Text = starred.Count.ToString();
        RecentFilter.IsChecked = !_starred;
        StarredFilter.IsChecked = _starred;
        ListTitle.Text = _starred ? "Starred files" : "Recent files";
        var files = _starred ? starred : recent;
        EmptyState.Visibility = files.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyTitle.Text = _starred ? "No starred PDFs" : "No files yet";
        EmptyDetail.Text = _starred ? "Star a file to keep it here." : "PDFs you open appear here.";
        Cards.Items.Clear();
        var generation = ++_generation;
        foreach (var path in files) Cards.Items.Add(Card(path, settings.StarredFiles.Contains(path, StringComparer.OrdinalIgnoreCase), generation));
    }

    private FrameworkElement Card(string path, bool isStarred, int generation)
    {
        var res = Application.Current.Resources;
        var well = new Grid { Height = 118, Background = ThemeBrushes.Get(this, "ZWindow") };
        var placeholder = new FontIcon { Glyph = "", FontSize = 34, Foreground = ThemeBrushes.Get(this, "ZAccent") };
        well.Children.Add(placeholder);
        var image = new Image { Stretch = Stretch.Uniform, Margin = new Thickness(0, 8, 0, 0) };
        well.Children.Add(image);
        _ = LoadThumbnailAsync(path, image, placeholder, generation);

        var info = new FileInfo(path);
        var opened = AppSettings.Current.LastOpened.TryGetValue(path, out var when) ? when : info.LastWriteTime;
        var size = info.Length >= 1 << 20 ? $"{info.Length / 1048576.0:0.0} MB" : $"{Math.Max(1, info.Length / 1024)} KB";
        var name = new TextBlock { Text = Path.GetFileName(path), FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        var detail = new TextBlock { Text = $"Last opened {Relative(opened)} · {size}", FontSize = 11, Foreground = ThemeBrushes.Get(this, "ZMuted"), TextTrimming = TextTrimming.CharacterEllipsis };
        var star = new Button
        {
            Width = 28, Height = 28, Padding = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center,
            Content = new FontIcon { Glyph = isStarred ? "" : "", FontSize = 13, Foreground = isStarred ? ThemeBrushes.Get(this, "ZStar") : ThemeBrushes.Get(this, "ZMuted") },
        };
        ToolTipService.SetToolTip(star, isStarred ? "Remove from Starred" : "Star");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(star, isStarred ? $"Unstar {Path.GetFileName(path)}" : $"Star {Path.GetFileName(path)}");
        star.Click += (_, _) =>
        {
            var list = AppSettings.Current.StarredFiles;
            if (list.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase)) == 0) list.Add(path);
            AppSettings.Current.Save();
            Refresh();
        };
        var footer = new Grid { Padding = new Thickness(10, 8, 4, 8) };
        footer.ColumnDefinitions.Add(new ColumnDefinition());
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel { Spacing = 2 };
        text.Children.Add(name);
        text.Children.Add(detail);
        footer.Children.Add(text);
        Grid.SetColumn(star, 1);
        footer.Children.Add(star);
        var body = new StackPanel();
        body.Children.Add(well);
        body.Children.Add(footer);
        var card = new Button
        {
            Width = 190, Padding = new Thickness(0), CornerRadius = new CornerRadius(10), HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = ThemeBrushes.Get(this, "ZSurface"), BorderBrush = ThemeBrushes.Get(this, "ZHairline"), BorderThickness = new Thickness(1), Content = body,
        };
        ToolTipService.SetToolTip(card, path);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, $"Open {Path.GetFileName(path)}, last opened {Relative(opened)}, {size}");
        card.Click += (_, _) => OpenRequested?.Invoke(path);
        return card;
    }

    /// <summary>The first page, rendered small off the UI thread (password-protected files keep the icon).</summary>
    private async Task LoadThumbnailAsync(string path, Image image, FontIcon placeholder, int generation)
    {
        try
        {
            var page = await Task.Run(() =>
            {
                using var document = PdfDocument.Open(path);
                var (w, h) = document.PageSize(0);
                return document.Render(0, Math.Min(150 / w, 110 / h) * 1.5);
            });
            if (generation != _generation) return;
            var bitmap = new WriteableBitmap(page.Width, page.Height);
            using (var stream = System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsStream(bitmap.PixelBuffer)) stream.Write(page.Pixels);
            bitmap.Invalidate();
            image.Source = bitmap;
            placeholder.Visibility = Visibility.Collapsed;
        }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException) { }
    }

    /// <summary>As on the Mac cards: "just now", "5 minutes ago", "2 days ago", "last week", "2 weeks ago".</summary>
    private static string Relative(DateTime when)
    {
        var age = DateTime.Now - when;
        static string Ago(int n, string unit) => $"{n} {unit}{(n == 1 ? "" : "s")} ago";
        return age.TotalMinutes < 1 ? "just now"
            : age.TotalHours < 1 ? Ago((int)age.TotalMinutes, "minute")
            : age.TotalDays < 1 ? Ago((int)age.TotalHours, "hour")
            : age.TotalDays < 2 ? "yesterday"
            : age.TotalDays < 7 ? Ago((int)age.TotalDays, "day")
            : age.TotalDays < 14 ? "last week"
            : age.TotalDays < 60 ? Ago((int)(age.TotalDays / 7), "week")
            : $"on {when:d}";
    }
}
