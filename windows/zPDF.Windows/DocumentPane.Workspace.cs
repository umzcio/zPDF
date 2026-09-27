using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace zPDF;

/// <summary>The Mac app's workspace (zPDF/Views/Document, Views/Tools, Views/Inspector): the
/// "All tools" drawer, tool panels opened inside it, document panels on the right with their
/// icon rail, the page field, search popover and status bar details.</summary>
public sealed partial class DocumentPane
{
    // ---------------------------------------------------------------- tool catalogue

    /// <summary>A tool in All tools (Mac zPDF/Models/ToolID.swift: same names, groups, order).</summary>
    private sealed record ToolDef(string Id, string Name, string Glyph, string Group, string Description, Action Open);

    private static readonly string[] ToolGroups = ["Create & Edit", "Share & Review", "Protect & Optimize", "Forms & Signatures", "Advanced"];

    private List<ToolDef>? _tools;
    private string? _openTool;

    private List<ToolDef> Tools => _tools ??=
    [
        new("comment", "Comment", "", "Share & Review", "Annotate with highlights and notes", () => ShowPanel("Comment", CommentBox, alsoPanel: "Comments")),
        new("fillSign", "Fill forms", "", "Forms & Signatures", "Complete existing form fields", () => ShowPanel("Fill forms", FillBox)),
        new("organize", "Organize Pages", "", "Create & Edit", "Reorder, rotate, delete, or extract pages", () => ShowGenerated("Organize Pages", OrganizeSections(), alsoPanel: "Pages")),
        new("combine", "Combine Files", "", "Create & Edit", "Merge multiple files into one PDF", () => CombineFiles_Click(this, new RoutedEventArgs())),
        new("reduce", "Reduce File Size", "", "Create & Edit", "Reduce file size for sharing", () => ReduceSize_Click(this, new RoutedEventArgs())),
        new("export", "Export PDF", "", "Create & Edit", "Convert to Word, Excel, HTML, Markdown or images", () => ShowGenerated("Export PDF", ExportSections())),
        new("create", "Create PDF", "", "Create & Edit", "Convert files or scans to PDF", () => ShowGenerated("Create PDF", CreateSections())),
        new("edit", "Edit PDF", "", "Create & Edit", "Change text, images, and pages", () => ShowPanel("Edit PDF", EditBox)),
        new("share", "Share", "\uE72D", "Share & Review", "Send a link or a copy of the file", () => Share_Click(this, new RoutedEventArgs())),
        new("protect", "Protect", "", "Protect & Optimize", "Encrypt and restrict editing", () => ShowGenerated("Protect", ProtectSections())),
        new("redact", "Redact", "", "Protect & Optimize", "Permanently remove sensitive content", () => ShowPanel("Redact", RedactBox)),
        new("optimize", "Optimize PDF", "", "Protect & Optimize", "Tune size, fonts, and images", () => ShowGenerated("Optimize PDF", OptimizeSections())),
        new("certificates", "Certificates", "", "Protect & Optimize", "Encrypt and validate with certificates", () => ShowGenerated("Certificates", SignSections())),
        new("prepareForm", "Prepare Form", "", "Forms & Signatures", "Add fillable fields to any document", () => { ShowPanel("Prepare Form", PrepareBox); if (!IsPreparingForm) PrepareForm_Click(this, new RoutedEventArgs()); }),
        new("signCertificate", "Sign with Certificate", "", "Forms & Signatures", "Apply a digital ID signature", () => ShowGenerated("Sign with Certificate", SignSections(), alsoPanel: "Signatures")),
        new("compare", "Compare Files", "", "Advanced", "Spot differences between versions", () => ShowGenerated("Compare Files", CompareSections())),
        new("ocr", "Scan & OCR", "", "Advanced", "Recognize text in scanned documents", () => ShowGenerated("Scan & OCR", OcrSections())),
        new("measure", "Measure Objects", "", "Advanced", "Distance, area, and perimeter tools", () => ShowPanel("Measure Objects", MeasureBox)),
        new("printProduction", "Print Production", "", "Advanced", "Preflight and output previews", () => ShowGenerated("Print Production", PrintSections())),
        new("actionWizard", "Action Wizard", "", "Advanced", "Automate repeatable tasks", () => ShowGenerated("Action Wizard", AutomationSections())),
        new("accessibility", "Accessibility Check", "", "Advanced", "Verify reading order and tags", () => ShowGenerated("Accessibility Check", AccessibilitySections())),
        new("archive", "Archive (PDF/A)", "", "Advanced", "Convert for long-term preservation", () => ShowGenerated("Archive (PDF/A)", ArchiveSections())),
        new("bates", "Bates Numbering", "", "Advanced", "Add legal index numbers to pages", () => Bates_Click(this, new RoutedEventArgs())),
    ];

    /// <summary>The drawer's open state is remembered (Mac preference sidebarVisible, default on).</summary>
    private void SetDrawerShown(bool shown)
    {
        AllToolsUnderline.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        if (AppSettings.Current.ToolsDrawerVisible == shown) return;
        AppSettings.Current.ToolsDrawerVisible = shown;
        AppSettings.Current.Save();
    }

    private void InitializeWorkspace()
    {
        StatusText.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) => UpdateReadyText());
        BuildToolList("");
        FillStaticPanels();
        UpdateReadyText();
    }

    /// <summary>All tools: group headers (UPPERCASE, muted) and rows (accent icon, name).</summary>
    private void BuildToolList(string filter)
    {
        ToolListItems.Children.Clear();
        foreach (var group in ToolGroups)
        {
            var tools = Tools.Where(t => t.Group == group && (filter.Length == 0
                || t.Name.Contains(filter, StringComparison.OrdinalIgnoreCase) || t.Description.Contains(filter, StringComparison.OrdinalIgnoreCase))).ToList();
            if (tools.Count == 0) continue;
            ToolListItems.Children.Add(Section(group));
            foreach (var tool in tools)
            {
                var row = new Button { Style = (Style)Application.Current.Resources["ZRow"], MinHeight = 38 };
                var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
                content.Children.Add(new FontIcon { Glyph = tool.Glyph, FontSize = 17, Width = 24, Foreground = ThemeBrushes.Get(this, "ZAccent") });
                content.Children.Add(new TextBlock { Text = tool.Name, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
                row.Content = content;
                ToolTipService.SetToolTip(row, tool.Description);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, tool.Name);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(row, tool.Description);
                row.Click += (_, _) => OpenTool(tool.Id);
                ToolListItems.Children.Add(row);
            }
        }
        if (ToolListItems.Children.Count == 0)
            ToolListItems.Children.Add(new TextBlock { Text = "No tools match.", FontSize = 12, Foreground = ThemeBrushes.Get(this, "ZMuted"), Margin = new Thickness(4, 12, 0, 0) });
    }

    private void ToolSearch_TextChanged(object sender, TextChangedEventArgs e) => BuildToolList(ToolSearchBox.Text.Trim());

    /// <summary>Opens a tool: its panel replaces the tool list in the drawer (Mac AppState.openTool).</summary>
    private void OpenTool(string id)
    {
        if (_document is null || Tools.FirstOrDefault(t => t.Id == id) is not { } tool) return;
        tool.Open();
    }

    private void OpenToolMenu_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string id }) OpenTool(id);
    }

    private void MenuTool_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string name } || !Enum.TryParse<CommentTool>(name, out var tool)) return;
        if (tool == CommentTool.Redact) OpenTool("redact");
        SetTool(tool);
    }

    private void QuickFillForms_Click(object sender, RoutedEventArgs e) => OpenTool("fillSign");

    private void AllToolsButton_Click(object sender, RoutedEventArgs e)
    {
        if (ToolsDrawer.Visibility == Visibility.Visible) CloseDrawer();
        else ShowToolList();
    }

    private void AllTools_Click(object sender, RoutedEventArgs e) => ShowToolList();

    private void ShowToolList()
    {
        LeaveToolModes();
        _openTool = null;
        ToolPanelHost.Visibility = Visibility.Collapsed;
        ToolList.Visibility = ToolsDrawer.Visibility = Visibility.Visible;
        SetDrawerShown(true);
    }

    private void BackToTools_Click(object sender, RoutedEventArgs e) => ShowToolList();
    private void CloseDrawer_Click(object sender, RoutedEventArgs e) => CloseDrawer();

    private void CloseDrawer()
    {
        LeaveToolModes();
        _openTool = null;
        ToolsDrawer.Visibility = Visibility.Collapsed;
        SetDrawerShown(false);
    }

    /// <summary>Leaving a panel ends the mode it started (Prepare Form, Edit, Redact, Measure…).</summary>
    private void LeaveToolModes()
    {
        if (_tool is not (CommentTool.Select or CommentTool.Highlight or CommentTool.Underline or CommentTool.Text)) SetTool(CommentTool.Select);
    }

    private void ShowPanel(string title, FrameworkElement box, string? alsoPanel = null)
    {
        foreach (var panel in new FrameworkElement[] { GeneratedPanel, CommentBox, EditBox, FillBox, PrepareBox, RedactBox, MeasureBox })
            panel.Visibility = panel == box ? Visibility.Visible : Visibility.Collapsed;
        if (_openTool != title) LeaveToolModes();
        _openTool = title;
        ToolPanelTitle.Text = title;
        ToolList.Visibility = Visibility.Collapsed;
        ToolPanelHost.Visibility = ToolsDrawer.Visibility = Visibility.Visible;
        SetDrawerShown(true);
        if (alsoPanel is not null) ShowDocPanel(alsoPanel, toggle: false);
    }

    private void ShowGenerated(string title, IEnumerable<UIElement> content, string? alsoPanel = null)
    {
        GeneratedPanel.Children.Clear();
        foreach (var element in content) GeneratedPanel.Children.Add(element);
        ShowPanel(title, GeneratedPanel, alsoPanel);
    }

    // ---------------------------------------------------------------- panel building blocks

    /// <summary>Mac PanelSection title: UPPERCASE, 10.5 pt semibold, muted.</summary>
    private static TextBlock Section(string title) =>
        new() { Text = title.ToUpperInvariant(), Style = (Style)Application.Current.Resources["ZSectionLabel"] };

    /// <summary>Mac PanelRow: a muted icon and a title; runs an existing command.</summary>
    private Button PanelRow(string title, string glyph, RoutedEventHandler action, string? tag = null)
    {
        var button = new Button { Style = (Style)Application.Current.Resources["ZRow"], Tag = tag };
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 13, Width = 18, Foreground = ThemeBrushes.Get(this, "ZMuted") });
        content.Children.Add(new TextBlock { Text = title, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap });
        button.Content = content;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, title.TrimEnd('…'));
        button.Click += action;
        return button;
    }

    /// <summary>Mac PanelNote: small muted text on an inset box.</summary>
    private Border PanelNote(string text) => new()
    {
        Background = ThemeBrushes.Get(this, "ZInset"), CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 8, 10, 8),
        BorderBrush = ThemeBrushes.Get(this, "ZHairline"), BorderThickness = new Thickness(1), Margin = new Thickness(0, 10, 0, 0),
        Child = new TextBlock { Text = text, FontSize = 11, TextWrapping = TextWrapping.Wrap, Foreground = ThemeBrushes.Get(this, "ZMuted") },
    };

    private static void AddAll(Panel panel, params UIElement[] children)
    {
        foreach (var child in children) panel.Children.Add(child);
    }

    // ---------------------------------------------------------------- panels (Mac Views/Inspector, Views/Panels)

    /// <summary>Rows for the panels whose live controls are in XAML (Comment, Edit, Fill, Prepare, Redact, Measure).</summary>
    private void FillStaticPanels()
    {
        AddAll(CommentReviewRows,
            PanelRow("Import Comments…", "", ImportComments_Click),
            PanelRow("Export Comments…", "", ExportComments_Click),
            PanelRow("Compare Comments…", "", CompareComments_Click),
            PanelRow("Flatten Comments…", "", FlattenComments_Click));
        AddAll(EditRows,
            Section("Crop pages"),
            PanelRow("Crop Pages…", "", CropPages_Click),
            Section("Page design"),
            PanelRow("Header & Footer…", "", HeaderFooter_Click),
            PanelRow("Watermark…", "", WatermarkOptions_Click),
            PanelRow("Background…", "", Background_Click),
            PanelRow("Bates Numbering…", "", Bates_Click),
            PanelRow("Remove Watermarks", "", RemoveWatermarks_Click),
            Section("Find & replace"),
            PanelRow("Find and Replace…", "", FindReplace_Click));
        AddAll(FillAddRows,
            PanelRow("Text", "", AddFillText_Click),
            PanelRow("Today's date", "", AddDate_Click),
            PanelRow("Check mark ✓", "", AddMark_Click, "✓"),
            PanelRow("Cross ✗", "", AddMark_Click, "✗"),
            PanelRow("Dot ●", "", AddMark_Click, "●"));
        AddAll(FillSignRows,
            PanelRow("Add Signature", "", AddSignature_Click),
            PanelRow("Add Initials", "", AddInitials_Click),
            PanelRow("New Signature…", "", NewSignature_Click, "signature"),
            PanelRow("New Initials…", "", NewSignature_Click, "initials"),
            PanelRow("Clear Saved Signatures", "", ClearSavedSignatures_Click));
        AddAll(FillFormRows,
            PanelRow("Clear Form…", "", ResetForm_Click),
            PanelRow("Flatten Fields…", "", FlattenForm_Click));
        AddAll(PrepareFieldRows,
            PanelRow("Properties…", "", FieldProperties_Click),
            PanelRow("Delete Field", "", DeleteField_Click),
            PanelRow("Duplicate Across Pages…", "", DuplicateFieldPages_Click));
        AddAll(PrepareFormRows,
            PanelRow("Detect Fields on This Page", "", DetectFields_Click),
            PanelRow("Tab Order…", "", TabOrder_Click),
            PanelRow("Calculation Order…", "", CalculationOrder_Click),
            PanelRow("Recalculate Fields", "", RecalculateForm_Click),
            PanelRow("Update Barcodes", "", UpdateBarcodes_Click),
            PanelRow("Convert to Standard Form…", "", ConvertXfaForm_Click),
            PanelRow("Flatten Fields…", "", FlattenForm_Click));
        AddAll(RedactHiddenRows, PanelRow("Remove Hidden Information…", "", RemoveHidden_Click));
        AddAll(RedactSearchRows, PanelRow("Search & Redact…", "", SearchRedact_Click));
        AddAll(MeasureRows,
            PanelRow("Set Scale…", "", SetScale_Click),
            PanelRow("Measurements…", "", Measurements_Click));
    }

    private IEnumerable<UIElement> OrganizeSections() =>
    [
        Section("Insert"),
        PanelRow("Blank Page", "", InsertBlank_Click),
        PanelRow("Pages from File…", "", InsertFromFile_Click),
        PanelRow("Images…", "", InsertImages_Click),
        PanelRow("Replace Pages…", "", ReplacePages_Click),
        PanelRow("Duplicate Pages", "", DuplicatePages_Click),
        Section("Rotate"),
        PanelRow("Rotate Clockwise", "", RotateRight_Click),
        PanelRow("Rotate Counterclockwise", "", RotateLeft_Click),
        PanelRow("Delete Pages", "", DeletePages_Click),
        Section("Page setup"),
        PanelRow("Number Pages…", "", PageLabels_Click),
        PanelRow("Set Page Boxes…", "", SetPageBoxes_Click),
        PanelRow("Change Page Size…", "", ResizePages_Click),
        PanelRow("Scale Page Content…", "", ScalePages_Click),
        PanelRow("Page Transitions…", "", PageTransitions_Click),
        Section("Split, combine and compress"),
        PanelRow("Extract Pages…", "", ExtractPages_Click),
        PanelRow("Split Document…", "", SplitDocument_Click),
        PanelRow("Split by File Size…", "", SplitBySize_Click),
        PanelRow("Combine Files…", "", CombineFiles_Click),
        PanelRow("Reduce File Size…", "", ReduceSize_Click),
        PanelNote("Select pages in the Pages panel first; drag thumbnails to reorder them."),
    ];

    private IEnumerable<UIElement> ExportSections() =>
    [
        Section("Documents"),
        PanelRow("Word", "", Export_Click, "docx"),
        PanelRow("Excel", "", Export_Click, "xlsx"),
        PanelRow("PowerPoint", "", Export_Click, "pptx"),
        PanelRow("Web Page (HTML)", "", Export_Click, "html"),
        PanelRow("Markdown", "", Export_Click, "md"),
        PanelRow("Rich Text (RTF)", "", Export_Click, "rtf"),
        PanelRow("XML", "", Export_Click, "xml"),
        PanelRow("EPUB Book", "", Export_Click, "epub"),
        PanelRow("Plain Text", "", Export_Click, "txt"),
        Section("Images"),
        PanelRow("Pages as PNG", "", Export_Click, "png"),
        PanelRow("Pages as JPEG", "", Export_Click, "jpg"),
        PanelRow("Extract All Images…", "", ExtractImages_Click),
        Section("Attachments"),
        PanelRow("Extract Attachments…", "", ExtractEmbedded_Click),
    ];

    private IEnumerable<UIElement> CreateSections() =>
    [
        Section("Create from"),
        PanelRow("Images…", "", CreateFromImages_Click),
        PanelRow("Blank PDF…", "", CreateBlank_Click),
        PanelRow("Combine Files…", "", CombineFiles_Click),
        PanelRow("PDF Portfolio…", "", CreatePortfolio_Click),
    ];

    private IEnumerable<UIElement> ProtectSections() =>
    [
        Section("Encryption"),
        PanelRow("Protect with Password…", "", Protect_Click),
        PanelRow("Remove Security", "", RemoveSecurity_Click),
        Section("Sanitize"),
        PanelRow("Remove Hidden Information…", "", RemoveHidden_Click),
        PanelRow("Redact…", "", (_, _) => OpenTool("redact")),
        PanelNote("Redaction is permanent. Remove hidden information too: metadata, comments, attachments and thumbnails can hold what you're removing."),
    ];

    private IEnumerable<UIElement> OptimizeSections() =>
    [
        Section("Reduce file size"),
        PanelRow("Reduce File Size…", "", ReduceSize_Click),
        Section("Audit space usage"),
        PanelRow("Space Usage…", "", SpaceUsage_Click),
        PanelNote("Fast Web View (linearizing) is a step in Action Wizard's batch processing."),
    ];

    private IEnumerable<UIElement> SignSections() =>
    [
        Section("Sign"),
        PanelRow("Sign with Digital ID…", "", SignDigital_Click),
        PanelRow("Certify Document…", "", Certify_Click),
        Section("Digital IDs"),
        PanelRow("Manage Digital IDs…", "", ManageIds_Click),
        Section("Validation"),
        PanelRow("Validate Signatures…", "", ValidateSignatures_Click),
        PanelRow("Add Long-Term Validation…", "", AddLtv_Click),
        PanelRow("View Signed Version…", "", ViewSignedVersion_Click),
        PanelRow("Clear Signature…", "", ClearSignature_Click),
    ];

    private IEnumerable<UIElement> CompareSections() =>
    [
        Section("Compare"),
        PanelRow("Compare with Another PDF…", "", Compare_Click),
        PanelRow("Compare Comments…", "", CompareComments_Click),
        PanelNote("Changes appear in the Changes panel on the right; click one to go to it."),
    ];

    private IEnumerable<UIElement> OcrSections() =>
    [
        Section("Recognize text"),
        PanelRow("Recognize Text…", "", RecognizeText_Click),
        Section("Recognized text"),
        PanelRow("Text Layer Status…", "", TextStatus_Click),
        PanelRow("Remove Recognized Text…", "", RemoveOcrLayer_Click),
        PanelNote("Straighten and clean-up options are in Recognize Text; they change scanned pages only."),
    ];

    private IEnumerable<UIElement> PrintSections() =>
    [
        Section("Preflight"),
        PanelRow("Preflight…", "", Preflight_Click),
        PanelRow("Output Preview…", "", OutputPreview_Click),
        Section("Print production"),
        PanelRow("Printer Marks…", "", PrinterMarks_Click),
        PanelRow("Save as PDF/X-4…", "", ConvertPdfX_Click),
        Section("Print layout"),
        PanelRow("Booklet…", "", Booklet_Click),
        PanelRow("Multiple Pages per Sheet…", "", NUp_Click),
        PanelRow("Poster (Tile Pages)…", "", Poster_Click),
        PanelRow("Print Selected Area…", "", PrintArea_Click),
    ];

    private IEnumerable<UIElement> AutomationSections() =>
    [
        Section("Actions"),
        PanelRow("Batch Process Files…", "", Batch_Click),
        Section("JavaScript"),
        PanelRow("Document JavaScript…", "", DocumentJavaScript_Click),
    ];

    private IEnumerable<UIElement> AccessibilitySections() =>
    [
        Section("Accessibility Check"),
        PanelRow("Run Accessibility Check…", "", AccessibilityCheck_Click),
        Section("Prepare"),
        PanelRow("Autotag Document", "", Autotag_Click),
        PanelRow("Bookmarks from Headings…", "", BookmarksFromHeadings_Click),
        Section("Tags and reading order"),
        PanelRow("Edit Tags…", "", TagsEditor_Click),
        PanelRow("Reading Order (This Page)…", "", ReadingOrder_Click),
        PanelRow("Alternate Text for Figures…", "", AltText_Click),
        Section("PDF/UA"),
        PanelRow("Identify as PDF/UA…", "", MarkPdfUa_Click),
    ];

    private IEnumerable<UIElement> ArchiveSections() =>
    [
        Section("Standards"),
        PanelRow("Save as PDF/A…", "", ConvertPdfA_Click),
        PanelRow("Save as PDF/E…", "", ConvertPdfE_Click),
        PanelRow("Standards Status…", "", StandardsStatus_Click),
    ];

    // ---------------------------------------------------------------- document panels (right)

    private string _docPanel = "Pages";
    private bool _docPanelChosen;

    private static readonly Dictionary<string, string> DocPanelTitles = new()
    {
        ["Comments"] = "Comments", ["Pages"] = "Pages", ["Bookmarks"] = "Bookmarks", ["Attachments"] = "Attachments", ["Layers"] = "Layers",
        ["Destinations"] = "Destinations", ["Signatures"] = "Signatures", ["Content"] = "Content", ["Changes"] = "Changes",
    };

    private void RailButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string kind }) ShowDocPanel(kind);
    }

    private void DocPanelMenu_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string kind }) ShowDocPanel(kind, toggle: false);
    }

    private void CloseDocPanel_Click(object sender, RoutedEventArgs e)
    {
        Sidebar.Visibility = Visibility.Collapsed;
        RefreshDocPanel();
    }

    /// <summary>Shows a document panel; the rail button of the open panel closes it again.</summary>
    private void ShowDocPanel(string kind, bool toggle = true)
    {
        _docPanelChosen = true;
        if (toggle && _docPanel == kind && Sidebar.Visibility == Visibility.Visible) Sidebar.Visibility = Visibility.Collapsed;
        else
        {
            _docPanel = kind;
            Sidebar.Visibility = _document is null ? Visibility.Collapsed : Visibility.Visible;
            if (kind is "Destinations" or "Signatures" or "Content") _ = LoadInfoPanelAsync(kind);
        }
        RefreshDocPanel();
    }

    /// <summary>Which list the document panel shows, and which rail button is lit.</summary>
    private void RefreshDocPanel()
    {
        var open = Sidebar.Visibility == Visibility.Visible;
        var kind = _docPanel;
        DocPanelTitle.Text = DocPanelTitles.GetValueOrDefault(kind, kind);
        Thumbnails.Visibility = kind == "Pages" ? Visibility.Visible : Visibility.Collapsed;
        ChangeList.Visibility = kind == "Changes" ? Visibility.Visible : Visibility.Collapsed;
        AttachmentsPanel.Visibility = kind == "Attachments" ? Visibility.Visible : Visibility.Collapsed;
        LayersPanel.Visibility = kind == "Layers" ? Visibility.Visible : Visibility.Collapsed;
        InfoPanel.Visibility = kind is "Destinations" or "Signatures" or "Content" ? Visibility.Visible : Visibility.Collapsed;
        var hasOutline = (OutlineTree.ItemsSource as System.Collections.ICollection)?.Count > 0;
        OutlineTree.Visibility = kind == "Bookmarks" && hasOutline ? Visibility.Visible : Visibility.Collapsed;
        NoBookmarksText.Visibility = kind == "Bookmarks" && !hasOutline ? Visibility.Visible : Visibility.Collapsed;
        UpdateCommentsPanel();
        foreach (var button in PanelRail.Children.OfType<ToggleButton>())
            button.IsChecked = open && button.Tag as string == kind;
    }

    /// <summary>Destinations, Signatures and Content: a summary and their commands.</summary>
    private async Task LoadInfoPanelAsync(string kind)
    {
        InfoPanelBody.Children.Clear();
        if (CurrentPath is not { } path) return;
        void Line(string text, bool muted = false) => InfoPanelBody.Children.Add(new TextBlock
        {
            Text = text, FontSize = 12, TextWrapping = TextWrapping.Wrap,
            Foreground = muted ? ThemeBrushes.Get(this, "ZMuted") : ThemeBrushes.Get(this, "ZText"),
        });
        try
        {
            switch (kind)
            {
                case "Destinations":
                {
                    var items = (await Engine.QueryAsync(path, "destinations", password: _password))["items"]?.AsArray() ?? [];
                    if (items.Count == 0) Line("This document has no named destinations.", muted: true);
                    foreach (var item in items.Take(200))
                    {
                        var page = item!["page"] is JsonValue p && p.TryGetValue<int>(out var n) ? n : -1;
                        var go = PanelRow($"{item["name"]}{(page >= 0 ? $"  ·  p. {page + 1}" : "")}", "", (_, _) => { if (page >= 0) GoTo(page); });
                        InfoPanelBody.Children.Add(go);
                    }
                    InfoPanelBody.Children.Add(PanelRow("Manage Destinations…", "", NamedDestinations_Click));
                    break;
                }
                case "Signatures":
                {
                    var items = ((await Engine.QueryAsync(path, "signatures", password: _password))["signatures"]?.AsArray() ?? [])
                        .Where(s => s!["signed"]?.GetValue<bool>() == true).ToList();
                    if (items.Count == 0) Line("This document has no digital signatures.", muted: true);
                    foreach (var s in items)
                    {
                        var ok = s!["integrity"]?.GetValue<bool>() == true;
                        Line($"{(ok ? "✓" : "✗")} {s["name"]}");
                        Line($"{s["time"]}", muted: true);
                    }
                    InfoPanelBody.Children.Add(PanelRow("Validate Signatures…", "", ValidateSignatures_Click));
                    InfoPanelBody.Children.Add(PanelRow("Sign with Digital ID…", "", SignDigital_Click));
                    break;
                }
                default:
                {
                    var threads = (await Engine.QueryAsync(path, "articles", password: _password))["threads"]?.AsArray() ?? [];
                    var models = (await Engine.QueryAsync(path, "models_3d", password: _password))["items"]?.AsArray() ?? [];
                    Line($"{threads.Count} article thread{(threads.Count == 1 ? "" : "s")} · {models.Count} 3D or media item{(models.Count == 1 ? "" : "s")}", muted: true);
                    InfoPanelBody.Children.Add(PanelRow("Articles & 3D Content…", "", ArticlesAndMedia_Click));
                    InfoPanelBody.Children.Add(PanelRow("Edit Tags…", "", TagsEditor_Click));
                    break;
                }
            }
        }
        catch (EngineException error) { Line(error.Message, muted: true); }
    }

    // ---------------------------------------------------------------- tool toggles

    /// <summary>Every tool toggle (quick tools and panel tiles); SetTool lights the current one.</summary>
    private IEnumerable<ToggleButton> ToolToggles()
    {
        foreach (var root in new FrameworkElement[] { ToolStrip, CommentBox, EditBox, RedactBox, MeasureBox })
            foreach (var toggle in Descendants(root).OfType<ToggleButton>())
                if (toggle.Tag is string name && Enum.TryParse<CommentTool>(name, out _)) yield return toggle;
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        var children = root switch
        {
            Panel panel => panel.Children.Cast<DependencyObject>(),
            Border border when border.Child is not null => [border.Child],
            ContentControl { Content: DependencyObject content } => [content],
            _ => [],
        };
        foreach (var child in children)
        {
            yield return child;
            foreach (var inner in Descendants(child)) yield return inner;
        }
    }

    // ---------------------------------------------------------------- page field, find, zoom, status

    private void PageBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || _document is null) return;
        e.Handled = true;
        var text = PageBox.Text.Trim();
        // A page label ("iv") or a page number.
        var index = Enumerable.Range(0, _document.PageCount).FirstOrDefault(i => _document.PageLabel(i) == text, -1);
        if (index < 0 && int.TryParse(text, out var number)) index = Math.Clamp(number, 1, _document.PageCount) - 1;
        if (index >= 0) GoTo(index);
        PageScroller.Focus(FocusState.Programmatic);
        UpdateStatus();
    }

    private void PageBox_LostFocus(object sender, RoutedEventArgs e) => UpdateStatus();

    private void FirstPage_Click(object sender, RoutedEventArgs e) => GoTo(0);
    private void LastPage_Click(object sender, RoutedEventArgs e) { if (_document is not null) GoTo(_document.PageCount - 1); }

    private bool _findOpen;

    private void FindFlyout_Opened(object sender, object e)
    {
        _findOpen = true;
        FindBox.Focus(FocusState.Programmatic);
        FindBox.SelectAll();
    }

    private void FindFlyout_Closed(object sender, object e)
    {
        _findOpen = false;
        ClearFind();
    }

    private void ZoomButton_Click(object sender, RoutedEventArgs e) => FlyoutBase.ShowAttachedFlyout(ZoomButton);

    /// <summary>For --xamlcheck: removes one part of the pane ("none" keeps everything).</summary>
    public void RemoveForCheck(string part)
    {
        var body = (Grid)ToolsDrawer.Parent;
        switch (part)
        {
            case "accelerators": RootGrid.KeyboardAccelerators.Clear(); break;
            case "menu": RootGrid.Children.Remove(AppMenu); break;
            case "toolbar": RootGrid.Children.Remove(Toolbar); break;
            case "status": RootGrid.Children.Remove(StatusBar); break;
            case "body": RootGrid.Children.Remove(body); break;
            case "drawer": body.Children.Remove(ToolsDrawer); break;
            case "canvas": body.Children.Remove((FrameworkElement)PageScroller.Parent); break;
            case "sidebar": body.Children.Remove(Sidebar); break;
            case "rail": body.Children.Remove(RailColumn); break;
            case "alltools": Toolbar.Children.Remove((FrameworkElement)AllToolsButton.Parent); break;
            case "viewcontrols": Toolbar.Children.Remove(ViewControls); break;
            case "right": Toolbar.Children.Remove((FrameworkElement)FindButton.Parent); break;
            case "pagebox": ViewControls.Children.Remove(PageBox); break;
            case "rotate": ViewControls.Children.Remove(RotateButton); break;
            case "find": ((Panel)FindButton.Parent).Children.Remove(FindButton); break;
            case "share": ((Panel)ShareButton.Parent).Children.Remove(ShareButton); break;
        }
    }

    /// <summary>For --xamlcheck: the pane's big sections, to show one at a time.</summary>
    public IEnumerable<FrameworkElement> LayoutSections() =>
        [AppMenu, Toolbar, StatusBar, RailColumn, QuickTools, PageScroller, ToolList, ToolsDrawer, ToolPanelHost, CommentBox, EditBox, FillBox, PrepareBox, RedactBox, MeasureBox, Sidebar];

    /// <summary>For --screenshot: "tools" shows All tools; anything else opens that tool.</summary>
    public void ShowForScreenshot(string step)
    {
        if (step == "tools") ShowToolList();
        else OpenTool(step);
    }

    /// <summary>The status line's resting text: "Ready", "Unsaved changes" or "No document".</summary>
    private void UpdateReadyText()
    {
        ReadyText.Visibility = StatusText.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        ReadyText.Text = _document is null ? "No document" : IsEdited ? "Unsaved changes" : "Ready";
        if (_sourcePath is { } path && File.Exists(path))
        {
            var bytes = new FileInfo(path).Length;
            FileSizeText.Text = bytes >= 1 << 20 ? $"{bytes / 1048576.0:0.0} MB" : $"{Math.Max(1, bytes / 1024)} KB";
            FileSizeInfo.Visibility = Visibility.Visible;
        }
        else FileSizeInfo.Visibility = Visibility.Collapsed;
    }

    // ---------------------------------------------------------------- share

    private Windows.ApplicationModel.DataTransfer.DataTransferManager? _share;

    /// <summary>Share (Mac: the toolbar's share button): the Windows share sheet with the saved file.</summary>
    private async void Share_Click(object sender, RoutedEventArgs e)
    {
        if (_sourcePath is not { } path || !File.Exists(path)) return;
        if (IsEdited && !await ConfirmAsync("Share the saved version?",
                "Your latest changes aren't saved yet. Share the file as it was last saved, or cancel and save first.", "Share Saved Version")) return;
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(Host);
        if (_share is null)
        {
            _share = Windows.ApplicationModel.DataTransfer.DataTransferManagerInterop.GetForWindow(hwnd);
            _share.DataRequested += async (_, args) =>
            {
                var deferral = args.Request.GetDeferral();
                try
                {
                    if (_sourcePath is not { } current) return;
                    var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(current);
                    args.Request.Data.Properties.Title = Path.GetFileName(current);
                    args.Request.Data.SetStorageItems([file]);
                }
                finally { deferral.Complete(); }
            };
        }
        Windows.ApplicationModel.DataTransfer.DataTransferManagerInterop.ShowShareUIForWindow(hwnd);
    }
}
