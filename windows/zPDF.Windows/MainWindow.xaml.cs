using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace zPDF;

/// <summary>A window of document tabs. Each tab is a DocumentPane (the whole document UI);
/// the window only hosts them and asks about unsaved changes when closing.</summary>
public sealed partial class MainWindow : Window
{
    private bool _closeConfirmed;

    public MainWindow(string? path = null)
    {
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1200, 900));
        if (File.Exists(Path.Combine(AppContext.BaseDirectory, "zPDF.ico"))) AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "zPDF.ico"));
        AppWindow.Closing += AppWindow_Closing;
        Closed += (_, _) => { foreach (var pane in Panes) pane.Release(); };
        var first = AddTab(path);
        _ = Updates.CheckInBackgroundAsync(first);
    }

    public IEnumerable<DocumentPane> Panes => Tabs.TabItems.OfType<TabViewItem>().Select(t => (DocumentPane)t.Content);
    public DocumentPane? ActivePane => (Tabs.SelectedItem as TabViewItem)?.Content as DocumentPane;

    /// <summary>A new tab, optionally opening `path` in it; it becomes the selected tab.</summary>
    public DocumentPane AddTab(string? path)
    {
        var pane = new DocumentPane(this);
        var tab = new TabViewItem { Content = pane, Header = "New Tab", IconSource = new SymbolIconSource { Symbol = Symbol.Document } };
        Tabs.TabItems.Add(tab);
        Tabs.SelectedItem = tab;
        if (path is not null) _ = pane.OpenAsync(path);
        return pane;
    }

    public DocumentPane? FindTab(string path) =>
        Panes.FirstOrDefault(p => p.FilePath is { } open && string.Equals(Path.GetFullPath(open), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase));

    public void Select(DocumentPane pane)
    {
        if (TabOf(pane) is { } tab) Tabs.SelectedItem = tab;
        Activate();
    }

    /// <summary>A pane's title or unsaved state changed.</summary>
    public void PaneChanged(DocumentPane pane)
    {
        if (TabOf(pane) is { } tab)
        {
            tab.Header = pane.DocumentTitle;
            ToolTipService.SetToolTip(tab, pane.FilePath ?? pane.DocumentTitle);
        }
        if (pane == ActivePane) UpdateTitle();
    }

    /// <summary>Full screen hides the tab strip too.</summary>
    public void SetTabStripVisible(bool visible)
    {
        foreach (var tab in Tabs.TabItems.OfType<TabViewItem>())
            tab.Visibility = visible || ReferenceEquals(tab, Tabs.SelectedItem) ? Visibility.Visible : Visibility.Collapsed;
        Tabs.IsAddTabButtonVisible = visible;
        if (Tabs.SelectedItem is TabViewItem selected) selected.IsClosable = visible;
    }

    /// <summary>Closes `pane`'s tab after asking about unsaved changes; the last tab closes the window.</summary>
    public async Task CloseTabAsync(DocumentPane pane)
    {
        if (TabOf(pane) is not { } tab) return;
        Tabs.SelectedItem = tab;
        if (pane.HasUnsavedChanges && !await pane.ConfirmCloseAsync()) return;
        pane.Release();
        Tabs.TabItems.Remove(tab);
        if (Tabs.TabItems.Count == 0)
        {
            _closeConfirmed = true;
            Close();
        }
    }

    private TabViewItem? TabOf(DocumentPane pane) => Tabs.TabItems.OfType<TabViewItem>().FirstOrDefault(t => ReferenceEquals(t.Content, pane));

    private void UpdateTitle() => Title = ActivePane is { IsEmpty: false } pane ? $"{pane.DocumentTitle} — zPDF" : "zPDF";

    private void Tabs_AddTabButtonClick(TabView sender, object args) => AddTab(null);

    private void Tabs_TabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args)
    {
        if (args.Tab.Content is DocumentPane pane) _ = CloseTabAsync(pane);
    }

    private void Tabs_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateTitle();

    private void NextTab_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => Step(1, args);
    private void PreviousTab_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => Step(-1, args);

    private void Step(int by, KeyboardAcceleratorInvokedEventArgs args)
    {
        var count = Tabs.TabItems.Count;
        if (count > 1) Tabs.SelectedIndex = ((Tabs.SelectedIndex + by) % count + count) % count;
        args.Handled = true;
    }

    private void CloseTab_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (ActivePane is { } pane) _ = CloseTabAsync(pane);
        args.Handled = true;
    }

    /// <summary>Closing the window asks about each tab with unsaved changes, in turn.</summary>
    private async void AppWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_closeConfirmed || !Panes.Any(p => p.HasUnsavedChanges)) return;
        args.Cancel = true;
        foreach (var pane in Panes.Where(p => p.HasUnsavedChanges).ToList())
        {
            if (TabOf(pane) is { } tab) Tabs.SelectedItem = tab;
            await Task.Yield();  // let the tab's content load so its dialog has a XamlRoot
            if (!await pane.ConfirmCloseAsync()) return;
        }
        _closeConfirmed = true;
        Close();
    }
}
