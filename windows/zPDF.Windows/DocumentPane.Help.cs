using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace zPDF;

/// <summary>Help ▸ Keyboard Shortcuts (F1).</summary>
public sealed partial class DocumentPane
{
    private static readonly (string Group, (string Keys, string Action)[] Items)[] Shortcuts =
    [
        ("Files and tabs", [("Ctrl+O", "Open"), ("Ctrl+S", "Save"), ("Ctrl+Shift+S", "Save As"), ("Ctrl+P", "Print"), ("Ctrl+T", "New tab"),
                            ("Ctrl+W / Ctrl+F4", "Close tab"), ("Ctrl+Tab / Ctrl+Shift+Tab", "Next / previous tab"), ("Ctrl+N", "New window"),
                            ("Ctrl+D", "Document properties"), ("Ctrl+K", "Preferences")]),
        ("Viewing", [("Ctrl++ / Ctrl+−", "Zoom in / out"), ("Ctrl+0", "Fit width"), ("Ctrl+1", "Actual size"), ("F11", "Full screen (Esc leaves)"),
                     ("Page Up / Page Down", "Previous / next page"), ("Ctrl+Home / Ctrl+End", "First / last page"), ("Ctrl+G", "Go to page")]),
        ("Finding and text", [("Ctrl+F", "Find"), ("F3 / Shift+F3", "Next / previous match"), ("Ctrl+A", "Select the page's text"), ("Ctrl+C", "Copy")]),
        ("Editing", [("Ctrl+Z", "Undo"), ("Ctrl+Y / Ctrl+Shift+Z", "Redo"), ("Delete", "Delete the selected comment, object, field or pages"),
                     ("Esc", "Cancel the tool or selection"), ("Enter", "Finish a perimeter or area; field properties in Prepare Form")]),
        ("Forms", [("Tab / Shift+Tab", "Next / previous field"), ("Space", "Toggle a checkbox or radio button"), ("Enter", "Finish a text field")]),
    ];

    private async void KeyboardShortcuts_Click(object sender, RoutedEventArgs e)
    {
        var panel = new StackPanel { Spacing = 4, MinWidth = 440 };
        foreach (var (group, items) in Shortcuts)
        {
            panel.Children.Add(new TextBlock { Text = group, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Margin = new Thickness(0, 10, 0, 2) });
            foreach (var (keys, action) in items)
            {
                var row = new Grid { ColumnSpacing = 16 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var key = new TextBlock { Text = keys, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas") };
                var what = new TextBlock { Text = action, TextWrapping = TextWrapping.Wrap };
                Grid.SetColumn(what, 1);
                row.Children.Add(key);
                row.Children.Add(what);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, $"{keys}: {action}");
                panel.Children.Add(row);
            }
        }
        await new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = "Keyboard Shortcuts", CloseButtonText = "Close",
            Content = new ScrollViewer { Content = panel, MaxHeight = 540 },
        }.ShowAsync();
    }
}
