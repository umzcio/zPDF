using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace zPDF;

/// <summary>Article threads (reading flows across columns and pages) and embedded 3D or
/// rich-media content: listed, and a click goes to the page.</summary>
public sealed partial class DocumentPane
{
    private async void ArticlesAndMedia_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        JsonNode articles, models;
        try
        {
            articles = await Engine.QueryAsync(CurrentPath, "articles", password: _password);
            models = await Engine.QueryAsync(CurrentPath, "models_3d", password: _password);
        }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        var threads = articles["threads"]?.AsArray() ?? [];
        var items = models["items"]?.AsArray() ?? [];
        var panel = new StackPanel { Spacing = 6, MinWidth = 440 };
        ContentDialog? dialog = null;
        Button Jump(string text, int page) {
            var button = new Button { Content = text, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
            button.Click += (_, _) => { dialog?.Hide(); GoTo(page); };
            return button;
        }
        panel.Children.Add(new TextBlock { Text = $"Articles ({threads.Count})", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        if (threads.Count == 0) panel.Children.Add(Note("This document has no article threads."));
        foreach (var thread in threads)
        {
            var pages = (thread!["beads"]?.AsArray() ?? []).Select(b => b!["page"]).OfType<JsonValue>().Select(p => p.GetValue<int>()).Distinct().ToList();
            var by = thread["author"]?.GetValue<string>() is { Length: > 0 } author ? $" · {author}" : "";
            var where = pages.Count == 0 ? "" : $" — page{(pages.Count == 1 ? "" : "s")} {string.Join(", ", pages.Take(12).Select(p => p + 1))}";
            if (pages.Count > 0) panel.Children.Add(Jump($"{thread["title"]}{by}{where}", pages[0]));
            else panel.Children.Add(new TextBlock { Text = $"{thread["title"]}{by}" });
        }
        panel.Children.Add(new TextBlock { Text = $"3D and rich media ({items.Count})", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Margin = new Thickness(0, 12, 0, 0) });
        if (items.Count == 0) panel.Children.Add(Note("This document has no 3D models or rich media."));
        foreach (var item in items)
        {
            var views = item!["views"]?.AsArray().Count ?? 0;
            var detail = $"{item["name"]} ({item["format"] ?? item["subtype"]}{(views > 0 ? $", {views} view{(views == 1 ? "" : "s")}" : "")}) — page {item["page"]!.GetValue<int>() + 1}";
            panel.Children.Add(Jump(detail, item["page"]!.GetValue<int>()));
        }
        if (items.Count > 0) panel.Children.Add(Note("zPDF shows where 3D content is; it can't display the models themselves."));
        dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Articles & 3D Content", Content = new ScrollViewer { Content = panel, MaxHeight = 520 }, CloseButtonText = "Close" };
        await dialog.ShowAsync();
    }
}
