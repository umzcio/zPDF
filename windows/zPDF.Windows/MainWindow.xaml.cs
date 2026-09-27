using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Windows.Storage.Pickers;

namespace zPDF;

/// <summary>A window of document tabs, as on the Mac: the Home button and tabs sit in the title
/// bar; below them is Home or the selected tab's DocumentPane (the whole document UI).
/// Closing the last tab returns to Home; closing the window asks about unsaved changes.</summary>
public sealed partial class MainWindow : Window
{
    private bool _closeConfirmed;
    private bool _updatesStarted;

    /// <summary>--xamlcheck: records progress through AddTab.</summary>
    public static Action<string>? Trace;

    public MainWindow(string? path = null)
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(DragRegion);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 860));
        if (File.Exists(Path.Combine(AppContext.BaseDirectory, "zPDF.ico"))) AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "zPDF.ico"));
        AppWindow.Closing += AppWindow_Closing;
        Closed += (_, _) => { foreach (var pane in Panes) pane.Release(); };
        Home.OpenRequested += OpenPath;
        Home.OpenFileRequested += () => _ = OpenFileAsync();
        Home.CombineRequested += () => _ = CombineFromHomeAsync();
        if (path is not null) AddTab(path);
        else ShowHome();
    }

    public IEnumerable<DocumentPane> Panes => Tabs.TabItems.OfType<TabViewItem>().Select(t => (DocumentPane)t.Tag);
    public DocumentPane? ActivePane => (Tabs.SelectedItem as TabViewItem)?.Tag as DocumentPane;

    /// <summary>A new tab, optionally opening `path` in it; it becomes the selected tab.</summary>
    public DocumentPane AddTab(string? path, Action<DocumentPane>? prepare = null)
    {
        var pane = new DocumentPane(this);
        prepare?.Invoke(pane);
        Trace?.Invoke("pane created");
        var tab = new TabViewItem { Tag = pane, Header = "New Tab", MaxWidth = 220, IconSource = new SymbolIconSource { Symbol = Symbol.Document } };
        Tabs.TabItems.Add(tab);
        Trace?.Invoke("tab added");
        Tabs.SelectedItem = tab;
        Trace?.Invoke("tab selected");
        ShowPane(pane);
        Trace?.Invoke("pane shown");
        if (path is not null) _ = pane.OpenAsync(path);
        if (!_updatesStarted)
        {
            _updatesStarted = true;
            _ = Updates.CheckInBackgroundAsync(pane);
        }
        return pane;
    }

    /// <summary>Opens `path` (its tab if it's already open).</summary>
    public void OpenPath(string path)
    {
        if (FindTab(path) is { } open) Select(open);
        else AddTab(path);
    }

    /// <summary>The "+" button and Home's Open File (the Mac "+" opens a file too).</summary>
    public async Task OpenFileAsync()
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add(".pdf");
        if (await picker.PickSingleFileAsync() is { } file) OpenPath(file.Path);
    }

    /// <summary>Home ▸ Combine PDFs: runs in a new tab, which opens the result (or closes if cancelled).</summary>
    private async Task CombineFromHomeAsync()
    {
        var pane = AddTab(null);
        if (!await pane.CombineIntoThisTabAsync()) await CloseTabAsync(pane);
    }

    public DocumentPane? FindTab(string path) =>
        Panes.FirstOrDefault(p => p.FilePath is { } open && string.Equals(Path.GetFullPath(open), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase));

    public void Select(DocumentPane pane)
    {
        if (TabOf(pane) is { } tab) Tabs.SelectedItem = tab;
        Activate();
    }

    public void ShowHome()
    {
        Tabs.SelectedItem = null;
        ContentHost.Children.Clear();
        ContentHost.Children.Add(Home);
        Home.Refresh();
        HomeIcon.Glyph = "";  // filled house while Home shows
        UpdateTitle();
    }

    private void ShowPane(DocumentPane pane)
    {
        if (ContentHost.Children.Count == 1 && ReferenceEquals(ContentHost.Children[0], pane)) return;
        ContentHost.Children.Clear();
        ContentHost.Children.Add(pane);
        HomeIcon.Glyph = "";
    }

    private void Home_Click(object sender, RoutedEventArgs e) => ShowHome();

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
    public void SetTabStripVisible(bool visible) => Tabs.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Closes `pane`'s tab after asking about unsaved changes; the last tab returns to Home.</summary>
    public async Task CloseTabAsync(DocumentPane pane)
    {
        if (TabOf(pane) is not { } tab) return;
        Tabs.SelectedItem = tab;
        if (pane.HasUnsavedChanges && !await pane.ConfirmCloseAsync()) return;
        pane.Release();
        Tabs.TabItems.Remove(tab);
        if (Tabs.TabItems.Count == 0) ShowHome();
    }

    private TabViewItem? TabOf(DocumentPane pane) => Tabs.TabItems.OfType<TabViewItem>().FirstOrDefault(t => ReferenceEquals(t.Tag, pane));

    private void UpdateTitle() => Title = ActivePane is { IsEmpty: false } pane ? $"{pane.DocumentTitle} — zPDF" : "zPDF";

    private void Tabs_AddTabButtonClick(TabView sender, object args) => _ = OpenFileAsync();

    private void Tabs_TabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args)
    {
        if (args.Tab.Tag is DocumentPane pane) _ = CloseTabAsync(pane);
    }

    private void Tabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        Trace?.Invoke("selection changed");
        if (ActivePane is { } pane) ShowPane(pane);
        Trace?.Invoke("selection handled");
        UpdateTitle();
    }

    private void NextTab_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => Step(1, args);
    private void PreviousTab_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => Step(-1, args);

    private void Step(int by, KeyboardAcceleratorInvokedEventArgs args)
    {
        var count = Tabs.TabItems.Count;
        if (count > 1) Tabs.SelectedIndex = ((Math.Max(0, Tabs.SelectedIndex) + by) % count + count) % count;
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
