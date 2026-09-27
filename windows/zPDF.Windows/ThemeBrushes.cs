using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace zPDF;

/// <summary>Theme.xaml brushes for UI built in code, for the theme the element is actually
/// shown in (Application.Current.Resources[key] always answers for the app's theme, so a
/// dark window would get light cards).</summary>
internal static class ThemeBrushes
{
    public static Brush Get(FrameworkElement scope, string key)
    {
        var theme = new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast ? "HighContrast"
            : scope.ActualTheme == ElementTheme.Dark ? "Dark" : "Light";
        foreach (var dictionary in Application.Current.Resources.MergedDictionaries)
            if (dictionary.ThemeDictionaries.TryGetValue(theme, out var themed) && themed is ResourceDictionary d && d.TryGetValue(key, out var brush) && brush is Brush b)
                return b;
        return (Brush)Application.Current.Resources[key];
    }
}
