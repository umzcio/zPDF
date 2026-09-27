using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace zPDF;

/// <summary>Security chosen for the next save.</summary>
public abstract record SecurityChange
{
    public sealed record Remove : SecurityChange;
    public sealed record Password(string? User, string? Owner, JsonObject Permissions) : SecurityChange;
}

/// <summary>Protection: password security (applied when saving, like the Mac app),
/// redaction and removing hidden information.</summary>
public sealed partial class DocumentPane
{
    private SecurityChange? _security;     // null: keep the document's security as it is
    private bool _encryptedOriginal;       // the file on disk is encrypted (preserve it on save)
    private string? _preservePassword;     // opens the file on disk, to carry its encryption over
    private readonly List<(int Page, Rect Rect)> _redactions = [];  // marked, not yet applied (view points)

    private void NoteOpenedSecurity()
    {
        _security = null;
        _encryptedOriginal = _document?.Properties().Encrypted == true;
        _preservePassword = _password;
        _redactions.Clear();
    }

    /// <summary>The file to publish: the current revision with the save-time security applied.</summary>
    private async Task<string> FinalCandidateAsync()
    {
        JsonArray? ops = _security switch
        {
            SecurityChange.Password p => [
                new JsonObject { ["op"] = "set_security", ["mode"] = "Password" },
                new JsonObject
                {
                    ["op"] = "apply_security", ["user_password"] = p.User, ["owner_password"] = p.Owner,
                    ["permissions"] = p.Permissions.DeepClone(), ["method"] = "aes256",
                }],
            SecurityChange.Remove => [
                new JsonObject { ["op"] = "set_security", ["mode"] = "None" },
                new JsonObject { ["op"] = "apply_security" }],
            null when _encryptedOriginal && _sourcePath is not null && CurrentPath != _sourcePath => [
                // Carry the original encryption over exactly (including a separate
                // permissions password) instead of re-encrypting with the open password.
                new JsonObject { ["op"] = "set_security", ["mode"] = "Preserve" },
                new JsonObject { ["op"] = "apply_security", ["original"] = _sourcePath, ["original_password"] = _preservePassword ?? "" }],
            _ => null,
        };
        return ops is null ? CurrentPath! : await Engine.TransformAsync(CurrentPath!, ops, _password);
    }

    /// <summary>After a successful save: what the file on disk now is.</summary>
    private void NoteSavedSecurity()
    {
        switch (_security)
        {
            case SecurityChange.Password p:
                _encryptedOriginal = true;
                _preservePassword = p.Owner ?? p.User;
                break;
            case SecurityChange.Remove:
                _encryptedOriginal = false;
                _preservePassword = null;
                break;
        }
        _security = null;
    }

    // ---------------------------------------------------------------- protect

    private async void Protect_Click(object sender, RoutedEventArgs e)
    {
        var requireOpen = new CheckBox { Content = "Require a password to open the document" };
        var open = new PasswordBox { Header = "Open password", IsEnabled = false, Width = 200 };
        var openAgain = new PasswordBox { Header = "Confirm", IsEnabled = false, Width = 200 };
        requireOpen.Checked += (_, _) => open.IsEnabled = openAgain.IsEnabled = true;
        requireOpen.Unchecked += (_, _) => open.IsEnabled = openAgain.IsEnabled = false;
        var restrict = new CheckBox { Content = "Restrict printing and editing" };
        var owner = new PasswordBox { Header = "Permissions password", IsEnabled = false };
        var printing = Choice("Printing allowed", ["High resolution", "Low resolution", "None"]);
        var changes = Choice("Changes allowed", ["Any except extracting pages", "Commenting, filling and signing", "Filling and signing", "Inserting, deleting and rotating pages", "None"]);
        var copy = new CheckBox { Content = "Allow copying text and images", IsChecked = true };
        var access = new CheckBox { Content = "Allow screen readers to read the text", IsChecked = true };
        foreach (var control in new Control[] { owner, printing, changes, copy, access }) control.IsEnabled = false;
        restrict.Checked += (_, _) => { foreach (var c in new Control[] { owner, printing, changes, copy, access }) c.IsEnabled = true; };
        restrict.Unchecked += (_, _) => { foreach (var c in new Control[] { owner, printing, changes, copy, access }) c.IsEnabled = false; };
        var note = new TextBlock
        {
            Text = "Protection is applied when you save. Keep the passwords safe — they can't be recovered.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.75,
        };
        if (!await AskAsync("Password Protection", Stack(requireOpen, Row(open, openAgain), restrict, owner, printing, changes, copy, access, note), "Protect")) return;
        if (requireOpen.IsChecked != true && restrict.IsChecked != true) return;
        if (requireOpen.IsChecked == true && (open.Password.Length == 0 || open.Password != openAgain.Password))
        {
            StatusText.Text = open.Password.Length == 0 ? "Enter an open password." : "The open passwords don't match.";
            return;
        }
        if (restrict.IsChecked == true && owner.Password.Length == 0) { StatusText.Text = "Enter a permissions password."; return; }
        if (requireOpen.IsChecked == true && restrict.IsChecked == true && open.Password == owner.Password)
        {
            StatusText.Text = "The open password and the permissions password must be different.";
            return;
        }
        var permissions = new JsonObject
        {
            ["print"] = restrict.IsChecked == true ? new[] { "high", "low", "none" }[Math.Max(0, printing.SelectedIndex)] : "high",
            ["changes"] = restrict.IsChecked == true ? new[] { "any", "comments", "fill", "assembly", "none" }[Math.Max(0, changes.SelectedIndex)] : "any",
            ["copy"] = restrict.IsChecked != true || copy.IsChecked == true,
            ["accessibility"] = restrict.IsChecked != true || access.IsChecked == true,
        };
        _security = new SecurityChange.Password(requireOpen.IsChecked == true ? open.Password : null,
                                                restrict.IsChecked == true ? owner.Password : null, permissions);
        UpdateStatus();
        ShowTransient("Password protection will be applied when you save.");
    }

    private async void RemoveSecurity_Click(object sender, RoutedEventArgs e)
    {
        if (!_encryptedOriginal && _security is null) { ShowTransient("This document has no security to remove."); return; }
        if (_encryptedOriginal && _sourcePath is { } source && !await HasPermissionsPasswordAsync(source)) return;
        _security = _encryptedOriginal ? new SecurityChange.Remove() : null;
        UpdateStatus();
        ShowTransient(_encryptedOriginal ? "Security will be removed when you save." : "Password protection cancelled.");
    }

    /// <summary>Removing security needs the permissions (owner) password, as on the Mac: true
    /// when the document was opened with it, or the person enters it now.</summary>
    private async Task<bool> HasPermissionsPasswordAsync(string source)
    {
        try
        {
            if ((await Engine.QueryAsync(source, "security_info", password: _password))["owner_password_matched"]?.GetValue<bool>() == true) return true;
        }
        catch (EngineException) { }
        var box = new PasswordBox { Header = "Permissions password" };
        if (!await AskAsync("Remove Security", Stack(Note("Removing security needs the document's permissions password (the one that restricts printing, editing and copying)."), box), "Remove")) return false;
        try
        {
            if ((await Engine.QueryAsync(source, "check_password", password: box.Password))["owner_password_matched"]?.GetValue<bool>() == true) return true;
        }
        catch (EngineException) { }
        StatusText.Text = "That is not this document's permissions password.";
        return false;
    }

    // ---------------------------------------------------------------- redaction

    /// <summary>Redact tool: a drag marks an area; text selected with it is marked too.</summary>
    private bool RedactPointerReleased(PageSlot slot, Rect area)
    {
        if (area.Width < 3 || area.Height < 3) return false;
        _redactions.Add((slot.Index, area));
        RefreshMarks();
        UpdateRedactionCommands();
        return true;
    }

    private void MarkSelectionForRedaction()
    {
        if (_selection is not { } sel || sel.Anchor == sel.Focus || Info(sel.Page) is not { } info) return;
        foreach (var rect in info.RectsFor(Math.Min(sel.Anchor, sel.Focus), Math.Max(sel.Anchor, sel.Focus)))
            _redactions.Add((sel.Page, rect));
        _selection = null;
        RefreshMarks();
        UpdateRedactionCommands();
    }

    private IEnumerable<(int Page, Rect Rect)> RedactionMarks() => _redactions;

    private void UpdateRedactionCommands()
    {
        ApplyRedactionsButton.IsEnabled = ClearRedactionsButton.IsEnabled = _redactions.Count > 0;
        ApplyRedactionsButton.Content = _redactions.Count > 0 ? $"Apply ({_redactions.Count})" : "Apply";
    }

    private void ClearRedactions_Click(object sender, RoutedEventArgs e)
    {
        _redactions.Clear();
        RefreshMarks();
        UpdateRedactionCommands();
    }

    private async void ApplyRedactions_Click(object sender, RoutedEventArgs e)
    {
        if (_redactions.Count == 0) return;
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = $"Apply {_redactions.Count} redaction{(_redactions.Count == 1 ? "" : "s")}?",
            Content = new TextBlock
            {
                Text = "The marked text, images and drawings are removed from the document — not just covered. You can undo this until you save.",
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = "Apply Redactions", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var areas = new JsonArray();
        foreach (var group in _redactions.GroupBy(r => r.Page))
        {
            if (await InfoAsync(group.Key) is not { } info) continue;
            var rects = new JsonArray();
            foreach (var (_, rect) in group) rects.Add(ToJson(PdfRect(info, rect)));
            areas.Add(new JsonObject { ["page"] = group.Key, ["rects"] = rects, ["fill"] = new JsonArray(0, 0, 0) });
        }
        _redactions.Clear();
        UpdateRedactionCommands();
        await EditDocumentAsync("Redacting…", new JsonObject { ["op"] = "apply_redactions", ["marks"] = false, ["areas"] = areas });
    }

    private static readonly (string Name, string Pattern)[] RedactPatterns =
    [
        ("Social Security numbers", @"\b\d{3}-\d{2}-\d{4}\b"),
        ("Phone numbers", @"(?:\+?1[\s.-]?)?\(?\b\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\b"),
        ("Email addresses", @"\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b"),
        ("Credit card numbers", @"\b(?:\d[ -]?){13,16}\b"),
        ("Dates", @"\b(?:\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4}-\d{2}-\d{2})\b"),
    ];

    private async void SearchRedact_Click(object sender, RoutedEventArgs e)
    {
        if (_document is not { } document) return;
        var words = Text("Words or phrases (one per line)", "");
        words.AcceptsReturn = true;
        words.MinHeight = 80;
        var patterns = RedactPatterns.Select(p => new CheckBox { Content = p.Name }).ToList();
        var matchCase = new CheckBox { Content = "Match case" };
        var content = Stack([words, matchCase, new TextBlock { Text = "Patterns", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] }, .. patterns]);
        if (!await AskAsync("Search & Redact", content, "Mark Matches")) return;
        var regexes = new List<Regex>();
        var options = matchCase.IsChecked == true ? RegexOptions.None : RegexOptions.IgnoreCase;
        foreach (var line in words.Text.Split('\n', '\r').Select(l => l.Trim()).Where(l => l.Length > 0))
            regexes.Add(new Regex(Regex.Escape(line), options));
        for (var i = 0; i < patterns.Count; i++)
            if (patterns[i].IsChecked == true) regexes.Add(new Regex(RedactPatterns[i].Pattern));
        if (regexes.Count == 0) return;
        StatusText.Text = "Searching…";
        var found = 0;
        for (var page = 0; page < document.PageCount; page++)
        {
            if (await InfoAsync(page) is not { } info || document != _document) return;
            foreach (var regex in regexes)
            {
                foreach (Match match in regex.Matches(info.Text))
                {
                    if (match.Length == 0) continue;
                    var first = info.CharAt[match.Index];
                    var last = info.CharAt[Math.Min(info.CharAt.Length - 1, match.Index + match.Length - 1)];
                    foreach (var rect in info.RectsFor(first, last)) _redactions.Add((page, rect));
                    found++;
                }
            }
        }
        RefreshMarks();
        UpdateRedactionCommands();
        StatusText.Text = found == 0 ? "No matches to redact." : $"Marked {found} match{(found == 1 ? "" : "es")} for redaction — review them, then Apply.";
    }

    // ---------------------------------------------------------------- hidden information

    private async void RemoveHidden_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        JsonNode scan;
        try { scan = await Engine.QueryAsync(CurrentPath, "sanitize_scan", password: _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        var rows = new (string Key, string Label, bool Default)[]
        {
            ("metadata", "Document information and metadata", true), ("embedded_files", "Attached files", true),
            ("javascript", "Scripts and actions", true), ("hidden_layers", "Hidden layers", true),
            ("hidden_text", "Hidden text (e.g. under images)", true), ("private_data", "Private application data", true),
            ("bookmarks", "Bookmarks", false), ("comments", "Comments", false), ("form_fields", "Form fields (flattened)", false),
            ("links", "Links", false),
        };
        var boxes = rows.Select(r =>
        {
            var count = scan[r.Key] is JsonValue v && v.TryGetValue<int>(out var n) ? n : scan[r.Key] is JsonArray a ? a.Count : 0;
            return new CheckBox { Content = $"{r.Label} ({count})", IsChecked = r.Default && count > 0, IsEnabled = count > 0, Tag = r.Key };
        }).ToList();
        if (!await AskAsync("Remove Hidden Information", Stack([.. boxes]), "Remove")) return;
        var op = new JsonObject { ["op"] = "sanitize" };
        foreach (var box in boxes) op[(string)box.Tag] = box.IsChecked == true;
        var removed = boxes.Where(b => b.IsChecked == true).Select(b => ((string)b.Content).Split(" (")[0].ToLowerInvariant()).ToList();
        await EditDocumentAsync("Removing hidden information…", op);
        if (removed.Count > 0) StatusText.Text = $"Removed: {string.Join(", ", removed)}. Save to keep the change.";
    }
}
