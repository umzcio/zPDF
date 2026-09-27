using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Polyline = Microsoft.UI.Xaml.Shapes.Polyline;
using Microsoft.Windows.Storage.Pickers;
using Windows.Foundation;

namespace zPDF;

/// <summary>Fill &amp; Sign (signature, initials, text, date, ✓ ✗ ●) and digital signatures.</summary>
public sealed partial class MainWindow
{
    private static readonly string SignFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "zPDF");
    private (byte[] Png, string Kind, double Width)? _placing;       // an image waiting to be placed with a click
    private (DigitalId Id, string Password, JsonObject Options)? _signing;  // a visible digital signature waiting for its box

    private static string SavedSignaturePath(string kind) => Path.Combine(SignFolder, kind == "initials" ? "initials.png" : "signature.png");

    // ---------------------------------------------------------------- Fill & Sign

    private async void AddSignature_Click(object sender, RoutedEventArgs e) => await PlaceSignatureAsync("signature");
    private async void AddInitials_Click(object sender, RoutedEventArgs e) => await PlaceSignatureAsync("initials");

    private async Task PlaceSignatureAsync(string kind, bool forceNew = false)
    {
        var saved = SavedSignaturePath(kind);
        byte[]? png = !forceNew && File.Exists(saved) ? await File.ReadAllBytesAsync(saved) : null;
        png ??= await CreateSignatureAsync(kind);
        if (png is null) return;
        _placing = (png, kind, kind == "initials" ? 60 : 170);
        SetTool(CommentTool.Place);
        ShowTransient($"Click where the {kind} should go (Esc to cancel).");
    }

    private async void NewSignature_Click(object sender, RoutedEventArgs e) =>
        await PlaceSignatureAsync((sender as FrameworkElement)?.Tag as string ?? "signature", forceNew: true);

    private void ClearSavedSignatures_Click(object sender, RoutedEventArgs e)
    {
        foreach (var kind in new[] { "signature", "initials" }) TryDelete(SavedSignaturePath(kind));
        ShowTransient("Saved signature and initials removed.");
    }

    private void AddMark_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string glyph }) return;
        _placing = (SignatureArt.Glyph(glyph, System.Drawing.Color.FromArgb(20, 20, 20)), "image", 14);
        SetTool(CommentTool.Place);
        ShowTransient("Click where the mark should go (Esc to cancel).");
    }

    private void AddFillText_Click(object sender, RoutedEventArgs e) => SetTool(CommentTool.FreeText);

    private void AddDate_Click(object sender, RoutedEventArgs e)
    {
        _placing = null;
        _placingDate = DateTime.Now.ToString("d");
        SetTool(CommentTool.Place);
        ShowTransient($"Click where the date ({_placingDate}) should go.");
    }

    private string? _placingDate;

    /// <summary>Type / Draw / Image dialog. Returns the PNG (and saves it for next time if asked).</summary>
    private async Task<byte[]?> CreateSignatureAsync(string kind)
    {
        var name = new TextBox { Header = kind == "initials" ? "Your initials" : "Your name", Text = kind == "initials" ? Initials(Environment.UserName) : "" };
        var fonts = SignatureArt.InstalledFonts().ToList();
        var font = Choice("Style", fonts.Count > 0 ? fonts : ["Segoe Script"]);
        var preview = new TextBlock { FontSize = 36, Text = name.Text, MinHeight = 56 };
        void Update() { preview.Text = name.Text; if (font.SelectedItem is string f) preview.FontFamily = new FontFamily(f); }
        name.TextChanged += (_, _) => Update();
        font.SelectionChanged += (_, _) => Update();
        Update();
        var typePanel = Stack(name, font, new Border { Child = preview, Padding = new Thickness(12), BorderThickness = new Thickness(1), BorderBrush = (Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"] });

        var strokes = new List<List<Point>>();
        var pad = new Canvas { Width = 420, Height = 150, Background = new SolidColorBrush(Colors.White) };
        Polyline? current = null;
        pad.PointerPressed += (_, e) =>
        {
            pad.CapturePointer(e.Pointer);
            var p = e.GetCurrentPoint(pad).Position;
            strokes.Add([p]);
            current = new Polyline { Stroke = new SolidColorBrush(Colors.Black), StrokeThickness = 2.5, StrokeLineJoin = PenLineJoin.Round };
            current.Points.Add(p);
            pad.Children.Add(current);
        };
        pad.PointerMoved += (_, e) =>
        {
            if (current is null || !e.GetCurrentPoint(pad).Properties.IsLeftButtonPressed) return;
            var p = e.GetCurrentPoint(pad).Position;
            strokes[^1].Add(p);
            current.Points.Add(p);
        };
        pad.PointerReleased += (_, _) => { current = null; pad.ReleasePointerCaptures(); };
        var clear = new Button { Content = "Clear" };
        clear.Click += (_, _) => { strokes.Clear(); pad.Children.Clear(); };
        var drawPanel = Stack(new Border { Child = pad, BorderThickness = new Thickness(1), BorderBrush = (Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"] }, clear);

        byte[]? picked = null;
        var imagePreview = new Image { MaxHeight = 120, Stretch = Stretch.Uniform };
        var pick = new Button { Content = "Choose Image…" };
        pick.Click += async (_, _) =>
        {
            var picker = new FileOpenPicker(AppWindow.Id);
            foreach (var t in new[] { ".png", ".jpg", ".jpeg", ".bmp", ".gif" }) picker.FileTypeFilter.Add(t);
            if (await picker.PickSingleFileAsync() is not { } file) return;
            picked = await File.ReadAllBytesAsync(file.Path);
            imagePreview.Source = new BitmapImage(new Uri(file.Path));
        };
        var imagePanel = Stack(pick, imagePreview);

        var tabs = new SelectorBar();
        foreach (var t in new[] { "Type", "Draw", "Image" }) tabs.Items.Add(new SelectorBarItem { Text = t });
        tabs.SelectedItem = tabs.Items[0];
        var host = new ContentControl { Content = typePanel, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        tabs.SelectionChanged += (_, _) => host.Content = tabs.Items.IndexOf(tabs.SelectedItem) switch { 1 => drawPanel, 2 => imagePanel, _ => typePanel };
        var keep = new CheckBox { Content = "Save for next time", IsChecked = true };
        if (!await AskAsync(kind == "initials" ? "Create Initials" : "Create Signature", Stack(tabs, host, keep), "Use")) return null;

        byte[] png;
        try
        {
            png = tabs.Items.IndexOf(tabs.SelectedItem) switch
            {
                1 when strokes.Count > 0 => SignatureArt.Drawn(strokes.Select(s => (IReadOnlyList<System.Drawing.PointF>)s.Select(p => new System.Drawing.PointF((float)p.X, (float)p.Y)).ToList()).ToList(),
                                                               System.Drawing.Color.FromArgb(10, 30, 110)),
                2 when picked is not null => picked,
                0 when name.Text.Trim().Length > 0 => SignatureArt.Typed(name.Text.Trim(), font.SelectedItem as string ?? "Segoe Script", System.Drawing.Color.FromArgb(10, 30, 110)),
                _ => throw new ArgumentException("Type, draw or choose a signature first."),
            };
        }
        catch (ArgumentException error)
        {
            StatusText.Text = error.Message;
            return null;
        }
        if (keep.IsChecked == true)
        {
            Directory.CreateDirectory(SignFolder);
            await File.WriteAllBytesAsync(SavedSignaturePath(kind), png);
        }
        return png;
    }

    /// <summary>"Jane Q. Doe" → "JQD" (at most three letters).</summary>
    private static string Initials(string name)
    {
        var letters = string.Concat(name.Split([' ', '.', '_', '-'], StringSplitOptions.RemoveEmptyEntries)
                                        .Select(part => char.ToUpperInvariant(part[0])));
        return letters.Length > 3 ? letters[..3] : letters;
    }

    /// <summary>Place tool: a click puts the waiting image (or date) on the page.</summary>
    private async Task PlaceAtAsync(int page, Point point)
    {
        if (await InfoAsync(page) is not { } info) return;
        SetTool(CommentTool.Select);
        if (_placingDate is { } date)
        {
            _placingDate = null;
            var dateRect = new Rect(point.X, point.Y - 8, 90, 16);
            await AddAsync(page, new JsonObject
            {
                ["subtype"] = "FreeText", ["rect"] = ToJson(PdfRect(info, dateRect)), ["contents"] = date,
                ["color"] = new JsonArray(0, 0, 0), ["font_size"] = 11,
            });
            return;
        }
        if (_placing is not { } placing) return;
        _placing = null;
        var (w, h) = SignatureArt.Size(placing.Png);
        var width = placing.Width;
        var height = width * h / Math.Max(1, w);
        var rect = new Rect(point.X - width / 2, point.Y - height / 2, width, height);
        await Run("Placing…", async () =>
        {
            var edited = await Engine.TransformAsync(CurrentPath!, [new JsonObject
            {
                ["op"] = "place_image_stamp", ["page"] = page, ["rect"] = ToJson(PdfRect(info, rect)),
                ["image"] = Convert.ToBase64String(placing.Png), ["kind"] = placing.Kind, ["author"] = Environment.UserName,
                ["name"] = placing.Kind == "image" ? "Mark" : placing.Kind == "initials" ? "Initials" : "Signature",
            }], _password);
            _revisions.Push(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
        });
    }

    // ---------------------------------------------------------------- digital IDs

    private async void ManageIds_Click(object sender, RoutedEventArgs e) => await ManageIdsAsync();

    private async Task<DigitalId?> ManageIdsAsync(bool choosing = false)
    {
        while (true)
        {
            var ids = DigitalIds.All();
            var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 260, MinWidth = 380 };
            foreach (var id in ids)
                list.Items.Add(new ListViewItem { Tag = id, Content = new TextBlock { Text = $"{id.Name}{(id.Email.Length > 0 ? $" <{id.Email}>" : "")}\nIssued by {id.Issuer} · expires {id.Expires}", TextWrapping = TextWrapping.Wrap } });
            if (list.Items.Count > 0) list.SelectedIndex = 0;
            var action = "";
            var create = new Button { Content = "Create New ID…" };
            var import = new Button { Content = "Import .pfx / .p12…" };
            var remove = new Button { Content = "Remove", IsEnabled = ids.Count > 0 };
            var dialog = new ContentDialog
            {
                XamlRoot = Content.XamlRoot, Title = choosing ? "Choose a Digital ID" : "Digital IDs",
                Content = Stack(ids.Count == 0 ? new TextBlock { Text = "You don't have a digital ID yet. Create one or import one from a certificate authority.", TextWrapping = TextWrapping.Wrap } : list,
                                Row(create, import, remove)),
                PrimaryButtonText = choosing && ids.Count > 0 ? "Use This ID" : "", CloseButtonText = choosing ? "Cancel" : "Close",
                DefaultButton = choosing ? ContentDialogButton.Primary : ContentDialogButton.Close,
            };
            create.Click += (_, _) => { action = "create"; dialog.Hide(); };
            import.Click += (_, _) => { action = "import"; dialog.Hide(); };
            remove.Click += (_, _) => { action = "remove"; dialog.Hide(); };
            var result = await dialog.ShowAsync();
            switch (action)
            {
                case "create": await CreateIdAsync(); continue;
                case "import": await ImportIdAsync(); continue;
                case "remove":
                    if (list.SelectedItem is ListViewItem { Tag: DigitalId doomed }) DigitalIds.Delete(doomed);
                    continue;
            }
            return result == ContentDialogResult.Primary && list.SelectedItem is ListViewItem { Tag: DigitalId chosen } ? chosen : null;
        }
    }

    private async Task CreateIdAsync()
    {
        var name = Text("Name", Environment.UserName);
        var email = Text("Email");
        var org = Text("Organization");
        var password = new PasswordBox { Header = "Password (at least 6 characters)" };
        var again = new PasswordBox { Header = "Confirm password" };
        var note = new TextBlock { Text = "This creates a self-signed ID. Others see your signature as \"validity unknown\" until they trust it; IDs from a certificate authority are trusted automatically.", TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };
        if (!await AskAsync("Create Digital ID", Stack(name, email, org, password, again, note), "Create")) return;
        if (password.Password != again.Password) { StatusText.Text = "The passwords don't match."; return; }
        try
        {
            var info = await Engine.CryptoAsync("create_identity", new JsonObject
            {
                ["name"] = name.Text.Trim(), ["email"] = email.Text.Trim(), ["organization"] = org.Text.Trim(), ["password"] = password.Password,
            });
            DigitalIds.Save(ToDigitalId(info));
            ShowTransient($"Created a digital ID for {name.Text.Trim()}.");
        }
        catch (EngineException error) { StatusText.Text = error.Message; }
    }

    private async Task ImportIdAsync()
    {
        var picker = new FileOpenPicker(AppWindow.Id);
        picker.FileTypeFilter.Add(".pfx");
        picker.FileTypeFilter.Add(".p12");
        if (await picker.PickSingleFileAsync() is not { } file) return;
        var password = new PasswordBox { Header = $"Password for {Path.GetFileName(file.Path)}" };
        if (!await AskAsync("Import Digital ID", Stack(password), "Import")) return;
        try
        {
            var p12 = Convert.ToBase64String(await File.ReadAllBytesAsync(file.Path));
            var info = await Engine.CryptoAsync("inspect_identity", new JsonObject { ["p12_b64"] = p12, ["password"] = password.Password });
            DigitalIds.Save(ToDigitalId(info));
            ShowTransient("Digital ID imported.");
        }
        catch (EngineException error) { StatusText.Text = error.Message; }
    }

    private static DigitalId ToDigitalId(JsonNode info)
    {
        var expires = info["not_after"]?.GetValue<string>() ?? "";
        if (DateTime.TryParse(expires, out var date)) expires = date.ToString("d");
        var issuer = info["issuer"]?.GetValue<string>() ?? "";
        var cn = issuer.Split(',').Select(p => p.Trim()).FirstOrDefault(p => p.StartsWith("CN=", StringComparison.OrdinalIgnoreCase));
        return new DigitalId(Guid.NewGuid().ToString("N"), info["name"]?.GetValue<string>() ?? "Digital ID", info["email"]?.GetValue<string>() ?? "",
                             cn is null ? issuer : cn[3..], expires, info["p12"]!.GetValue<string>());
    }

    // ---------------------------------------------------------------- signing

    private async void SignDigital_Click(object sender, RoutedEventArgs e) => await StartDigitalSignatureAsync(certify: false);
    private async void Certify_Click(object sender, RoutedEventArgs e) => await StartDigitalSignatureAsync(certify: true);

    private async Task StartDigitalSignatureAsync(bool certify)
    {
        if (_document is null) return;
        await FlushFieldsAsync();
        if (_encryptedOriginal || _security is not null)
        {
            StatusText.Text = "Remove the password protection (and save) before signing digitally.";
            return;
        }
        if (await ManageIdsAsync(choosing: true) is not { } id) return;
        var password = new PasswordBox { Header = $"Password for {id.Name}" };
        var reason = Text("Reason", certify ? "I am the author of this document" : "I approve this document");
        var location = Text("Location");
        var visible = new CheckBox { Content = "Show the signature on the page (draw its box next)", IsChecked = true };
        var permission = Choice("After certifying, allow", ["Form filling and signing", "Form filling, signing and comments", "No changes"]);
        var timestamp = new CheckBox { Content = "Add a trusted timestamp (needs the internet)" };
        var content = certify ? Stack(password, reason, location, permission, visible, timestamp) : Stack(password, reason, location, visible, timestamp);
        if (!await AskAsync(certify ? "Certify Document" : "Sign with Digital ID", content, visible.IsChecked == true ? "Continue" : "Sign")) return;
        var options = new JsonObject { ["reason"] = reason.Text, ["location"] = location.Text };
        if (certify) options["certify"] = permission.SelectedIndex switch { 1 => 3, 2 => 1, _ => 2 };
        if (timestamp.IsChecked == true) options["timestamp_url"] = "http://timestamp.digicert.com";
        if (visible.IsChecked == true)
        {
            _signing = (id, password.Password, options);
            SetTool(CommentTool.SignBox);
            ShowTransient("Drag a box where the signature should appear (Esc to cancel).");
            return;
        }
        await SignAsync(id, password.Password, options, page: null, rect: null);
    }

    /// <summary>Signs the current revision, then saves right away (a signature seals the
    /// file as it is; later edits are appended after it).</summary>
    private async Task SignAsync(DigitalId id, string password, JsonObject options, int? page, double[]? rect)
    {
        var suggested = Path.GetFileNameWithoutExtension(_sourcePath) + " signed";
        if (await AskSavePathAsync(suggested) is not { } destination) return;
        await Run("Signing…", async () =>
        {
            var op = new JsonObject
            {
                ["op"] = "sign", ["identity"] = new JsonObject { ["p12"] = id.P12, ["password"] = password },
                ["name"] = id.Name,
            };
            foreach (var (key, value) in options) op[key] = value?.DeepClone();
            if (page is { } p && rect is not null) { op["page"] = p; op["rect"] = ToJson(rect); }
            var signed = await Engine.TransformAsync(CurrentPath!, [op], _password);
            await Engine.PublishAsync(signed, destination, overwrite: true);
            TryDelete(signed);
            // Continue with the signed file as the document.
            if (await OpenWithPasswordAsync(destination) is { } opened)
            {
                DeleteRevisions();
                _sourcePath = _savedPath = destination;
                _password = opened.Password;
                Show(opened.Document, keepPosition: true);
                NoteOpenedSecurity();
                AppSettings.Current.AddRecent(destination);
            }
            StatusText.Text = $"Signed and saved {Path.GetFileName(destination)}";
        }, keepStatus: true);
    }

    /// <summary>SignBox tool: the dragged box becomes the visible signature.</summary>
    private async Task FinishSignBoxAsync(int page, Rect box)
    {
        SetTool(CommentTool.Select);
        if (_signing is not { } signing) return;
        _signing = null;
        if (box.Width < 24 || box.Height < 12) box = new Rect(box.X, box.Y, 180, 54);
        if (await InfoAsync(page) is not { } info) return;
        await SignAsync(signing.Id, signing.Password, signing.Options, page, PdfRect(info, box));
    }

    private async void ValidateSignatures_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        JsonNode report;
        try { report = await Engine.QueryAsync(CurrentPath, "signatures", password: _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        var items = report["signatures"]!.AsArray().Where(s => s!["signed"]?.GetValue<bool>() == true).ToList();
        var panel = new StackPanel { Spacing = 14, MinWidth = 420 };
        if (items.Count == 0) panel.Children.Add(new TextBlock { Text = "This document has no digital signatures." });
        foreach (var s in items)
        {
            var ok = s!["integrity"]?.GetValue<bool>() == true;
            var covers = s["covers_document"]?.GetValue<bool>() == true;
            var errors = s["errors"]?.AsArray().Select(x => x!.ToString()).ToList() ?? [];
            var changes = s["changes_after"]?.AsArray().Count ?? 0;
            var status = !ok ? "✗ The document was altered after this signature — it is no longer valid."
                : s["mdp_violation"]?.GetValue<bool>() == true ? "✗ Changes after certifying break its permissions."
                : covers ? "✓ Signed and unchanged since signing."
                : $"✓ Signed; {changes} later change{(changes == 1 ? "" : "s")} were appended after it.";
            var trust = errors.Count > 0 ? $"Identity: {string.Join(" ", errors)}" : "Identity: trusted";
            var lines = new List<string>
            {
                $"{s["name"]} — {(s["certification"] is JsonValue c && c.TryGetValue<int>(out var level) ? $"certified (level {level})" : "approval signature")}",
                status, trust,
                $"Signed {s["time"]}{(s["reason"]?.ToString() is { Length: > 0 } r ? $" · {r}" : "")}{(s["location"]?.ToString() is { Length: > 0 } l ? $" · {l}" : "")}",
                s["ltv"]?.GetValue<bool>() == true ? "Long-term validation: enabled" : "Long-term validation: not enabled",
            };
            panel.Children.Add(new TextBlock { Text = string.Join("\n", lines), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        }
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = items.Count == 1 ? "1 Signature" : $"{items.Count} Signatures",
            Content = new ScrollViewer { Content = panel, MaxHeight = 480 }, CloseButtonText = "Close",
        };
        await dialog.ShowAsync();
    }
}
