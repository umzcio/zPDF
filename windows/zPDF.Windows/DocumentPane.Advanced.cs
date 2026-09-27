using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace zPDF;

/// <summary>Advanced signing (long-term validation, clearing a signature, the signed version),
/// form logic (calculation and tab order, duplicating fields, recalculating, XFA conversion,
/// barcodes), document JavaScript, the Tags editor, PDF/UA and standards status.</summary>
public sealed partial class DocumentPane
{
    private (string Path, bool Xfa, bool Barcodes, bool Calculations)? _advTraits;

    /// <summary>Runs ops on the current revision into a new private file; returns it with the ops' results.</summary>
    private async Task<(string Path, JsonArray Results)> AdvTransformAsync(JsonArray ops)
    {
        var destination = Path.Combine(Path.GetTempPath(), $"zpdf-{Guid.NewGuid():N}.pdf");
        var parameters = new JsonObject
        {
            ["path"] = CurrentPath!, ["destination"] = destination, ["ops"] = ops, ["sha256"] = Engine.Sha256(CurrentPath!),
        };
        if (_password is not null) parameters["password"] = _password;
        var result = await Engine.CallAsync("transform", parameters);
        return (destination, result["results"] as JsonArray ?? []);
    }

    private static string AdvText(JsonNode? node) => node is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";

    private static JsonArray AdvStrings(IEnumerable<string> items) => new(items.Select(s => (JsonNode)s).ToArray());

    // ---------------------------------------------------------------- signatures

    /// <summary>The signed signature fields (signatures query), or null after an error.</summary>
    private async Task<List<JsonNode>?> AdvSignedAsync()
    {
        if (CurrentPath is null) return null;
        await FlushFieldsAsync();
        try
        {
            var report = await Engine.QueryAsync(CurrentPath, "signatures", password: _password);
            return report["signatures"]!.AsArray().Where(s => s!["signed"]?.GetValue<bool>() == true).Select(s => s!).ToList();
        }
        catch (EngineException error) { StatusText.Text = error.Message; return null; }
    }

    private static string AdvSignatureLabel(JsonNode signature)
    {
        var who = AdvText(signature["name"]);
        var when = DateTimeOffset.TryParse(AdvText(signature["time"]), out var time) ? time.LocalDateTime.ToString("g") : "";
        return $"{AdvText(signature["field"])}{(who.Length > 0 ? $" — {who}" : "")}{(when.Length > 0 ? $", {when}" : "")}";
    }

    /// <summary>Asks which signature to act on; returns its field name.</summary>
    private async Task<string?> AdvPickSignatureAsync(List<JsonNode> signed, string title, string note, string action)
    {
        var choice = Choice("Signature", signed.Select(AdvSignatureLabel));
        if (!await AskAsync(title, Stack(choice, Note(note)), action)) return null;
        return AdvText(signed[Math.Max(0, choice.SelectedIndex)]["field"]);
    }

    /// <summary>Embeds the certificates (and, if allowed, revocation data) the signatures need to
    /// be validated later: a Document Security Store appended after the signatures.</summary>
    private async void AddLtv_Click(object sender, RoutedEventArgs e)
    {
        if (await AdvSignedAsync() is not { } signed) return;
        if (signed.Count == 0) { StatusText.Text = "Sign the document first; long-term validation is added to its signatures."; return; }
        var network = new CheckBox { Content = "Fetch revocation information (OCSP and CRL) from the internet" };
        if (!await AskAsync("Add Long-Term Validation", Stack(
                Note("Embeds the certificates each signature needs so it can still be validated after they expire. It's appended after the signatures, so they stay valid."),
                network, Note("With the internet off, only certificates already in the signatures are embedded.")), "Add")) return;
        await Run("Adding validation information…", async () =>
        {
            var (edited, results) = await AdvTransformAsync([new JsonObject { ["op"] = "add_ltv", ["allow_network"] = network.IsChecked == true }]);
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
            var result = results.FirstOrDefault();
            int Count(string key) => result?[key] is JsonValue v && v.TryGetValue<int>(out var n) ? n : 0;
            var (certificates, ocsps, crls) = (Count("certificates"), Count("ocsps"), Count("crls"));
            var notes = (result?["notes"] as JsonArray ?? []).Select(n => n?.ToString()).Where(n => !string.IsNullOrEmpty(n)).ToList();
            StatusText.Text = $"Embedded {certificates} certificate{(certificates == 1 ? "" : "s")}"
                              + (ocsps + crls > 0 ? $", {ocsps} OCSP and {crls} CRL response{(ocsps + crls == 1 ? "" : "s")}" : "")
                              + $". Save to keep it.{(notes.Count > 0 ? " " + string.Join(" ", notes) : "")}";
        }, keepStatus: true);
    }

    /// <summary>Removes a signature's value so the field can be signed again (rewrites the file).</summary>
    private async void ClearSignature_Click(object sender, RoutedEventArgs e)
    {
        if (await AdvSignedAsync() is not { } signed) return;
        if (signed.Count == 0) { StatusText.Text = "This document has no digital signatures."; return; }
        var field = await AdvPickSignatureAsync(signed, "Clear Signature",
            "The signature is removed and its field left empty, ready to sign again. The file is rewritten, so every other signature in it stops being valid. You can undo this until you save.",
            "Clear");
        if (field is null) return;
        if (await EditDocumentAsync("Clearing the signature…", new JsonObject { ["op"] = "clear_signature", ["field"] = field }))
            StatusText.Text = $"Cleared {field}. Save to keep the change.";
    }

    /// <summary>Saves the exact revision a signature covers and opens it in a new tab.</summary>
    private async void ViewSignedVersion_Click(object sender, RoutedEventArgs e)
    {
        if (await AdvSignedAsync() is not { } signed) return;
        if (signed.Count == 0) { StatusText.Text = "This document has no digital signatures."; return; }
        var field = await AdvPickSignatureAsync(signed, "View Signed Version",
            "Saves the document exactly as it was when this signature was applied, without any later changes, and opens it in a new tab.", "Save…");
        if (field is null || CurrentPath is not { } source) return;
        long length;
        try
        {
            var revision = await Engine.QueryAsync(source, "signature_revision", new JsonObject { ["field"] = field }, _password);
            length = revision["length"]!.GetValue<long>();
        }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        var unchanged = length == new FileInfo(source).Length;
        if (await AskSavePathAsync($"{Path.GetFileNameWithoutExtension(_sourcePath)} (signed version)") is not { } destination) return;
        await Run("Extracting the signed version…", async () =>
        {
            var output = await Engine.TransformAsync(source, [new JsonObject { ["op"] = "extract_signed_revision", ["field"] = field }], _password);
            try { await Engine.PublishAsync(output, destination, overwrite: true); }
            finally { TryDelete(output); }
            Host.AddTab(destination);
            StatusText.Text = unchanged
                ? $"Saved {Path.GetFileName(destination)} — nothing has changed since {field} was signed."
                : $"Saved {Path.GetFileName(destination)}, the document as {field} signed it ({length / 1024.0:0} KB).";
        }, keepStatus: true);
    }

    // ---------------------------------------------------------------- forms

    /// <summary>Hides the Tools menu's XFA, barcode and calculation items (Tag "xfa", "barcodes",
    /// "calculations") unless the form has them. Attach as the menu's Opening handler.</summary>
    private async void AdvancedFormsMenu_Opening(object sender, object e)
    {
        if (sender is not MenuFlyout menu) return;
        var items = AdvTaggedItems(menu.Items).ToList();
        if (items.Count == 0) return;
        if (CurrentPath is not { } path)
        {
            foreach (var item in items) item.Visibility = Visibility.Collapsed;
            return;
        }
        if (_advTraits?.Path != path)
        {
            try
            {
                var form = await Engine.QueryAsync(path, "form_fields", password: _password);
                var fields = form["fields"]!.AsArray();
                _advTraits = (path, form["xfa"]?.GetValue<bool>() == true,
                              fields.Any(f => AdvText(f!["kind"]) == "barcode"), fields.Any(f => f!["calculate"] is JsonObject));
            }
            catch (EngineException) { return; }
        }
        if (_advTraits is not { } traits) return;
        foreach (var item in items)
        {
            var shown = (item.Tag as string) switch { "xfa" => traits.Xfa, "barcodes" => traits.Barcodes, _ => traits.Calculations };
            item.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private static IEnumerable<MenuFlyoutItemBase> AdvTaggedItems(IList<MenuFlyoutItemBase> items)
    {
        foreach (var item in items)
        {
            if (item.Tag is "xfa" or "barcodes" or "calculations") yield return item;
            if (item is MenuFlyoutSubItem sub)
                foreach (var inner in AdvTaggedItems(sub.Items)) yield return inner;
        }
    }

    /// <summary>form_fields for the current revision (pending entries written first), or null after an error.</summary>
    private async Task<JsonNode?> AdvFormFieldsAsync()
    {
        if (CurrentPath is null) return null;
        await FlushFieldsAsync();
        try { return await Engine.QueryAsync(CurrentPath, "form_fields", password: _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return null; }
    }

    /// <summary>A reorderable list (drag, or Move Up/Down) over `items`.</summary>
    private static StackPanel AdvReorderList(ObservableCollection<string> items)
    {
        var list = new ListView
        {
            ItemsSource = items, CanReorderItems = true, AllowDrop = true, CanDragItems = true,
            SelectionMode = ListViewSelectionMode.Single, MaxHeight = 300, MinWidth = 360,
        };
        void Move(int delta)
        {
            if (list.SelectedIndex is var index and >= 0 && index + delta >= 0 && index + delta < items.Count)
            {
                items.Move(index, index + delta);
                list.SelectedIndex = index + delta;
            }
        }
        var up = new Button { Content = "Move Up" };
        var down = new Button { Content = "Move Down" };
        up.Click += (_, _) => Move(-1);
        down.Click += (_, _) => Move(1);
        return Stack(list, Row(up, down));
    }

    /// <summary>The order calculated fields are computed in (Put fields others depend on first).</summary>
    private async void CalculationOrder_Click(object sender, RoutedEventArgs e)
    {
        if (await AdvFormFieldsAsync() is not { } form) return;
        var calculated = form["fields"]!.AsArray().Where(f => f!["calculate"] is JsonObject).Select(f => AdvText(f!["name"])).ToList();
        if (calculated.Count == 0) { StatusText.Text = "This form has no calculated fields."; return; }
        var current = form["calculation_order"]!.AsArray().Select(AdvText).ToList();
        var order = current.Where(calculated.Contains).Concat(calculated.Where(n => !current.Contains(n))).ToList();
        var items = new ObservableCollection<string>(order);
        if (!await AskAsync("Calculation Order", Stack(Note("Fields are calculated top to bottom. Put fields that others depend on first."), AdvReorderList(items)), "Apply")) return;
        if (items.SequenceEqual(current)) return;
        await ApplyOpsAsync("Setting the calculation order…", [new JsonObject { ["op"] = "set_calculation_order", ["order"] = AdvStrings(items) }],
                            "Calculation order set. Save to keep it.");
    }

    /// <summary>How Tab moves between the fields of a page: by structure, rows, columns or a manual order.</summary>
    private async void TabOrder_Click(object sender, RoutedEventArgs e)
    {
        if (await AdvFormFieldsAsync() is not { } form || _document is null) return;
        var fields = form["fields"]!.AsArray();
        var tabs = form["tab_order"]!.AsArray().Select(AdvText).ToList();
        string[] modes = ["structure", "row", "column", "manual"];
        var page = Choice("Page", Enumerable.Range(1, _document.PageCount).Select(p => $"Page {p}"), Math.Clamp(_page, 0, _document.PageCount - 1));
        var mode = Choice("Order", ["By document structure", "By rows", "By columns", "Manual (drag to reorder)"]);
        var items = new ObservableCollection<string>();
        var list = AdvReorderList(items);
        void Load()
        {
            var p = Math.Max(0, page.SelectedIndex);
            mode.SelectedIndex = Math.Max(0, Array.IndexOf(modes, p < tabs.Count ? tabs[p] : "manual"));
            items.Clear();
            foreach (var field in fields)
                if (field!["widgets"]!.AsArray().Any(w => w!["page"] is JsonValue v && v.TryGetValue<int>(out var n) && n == p))
                    items.Add(AdvText(field["name"]));
        }
        void ShowList() => list.Visibility = mode.SelectedIndex == 3 ? Visibility.Visible : Visibility.Collapsed;
        page.SelectionChanged += (_, _) => { Load(); ShowList(); };
        mode.SelectionChanged += (_, _) => ShowList();
        Load();
        ShowList();
        if (!await AskAsync("Tab Order", Stack(page, mode, list, Note("Structure order follows the document's tags; rows go left to right, then down.")), "Apply")) return;
        var op = new JsonObject { ["op"] = "set_tab_order", ["page"] = Math.Max(0, page.SelectedIndex), ["mode"] = modes[Math.Max(0, mode.SelectedIndex)] };
        if (mode.SelectedIndex == 3) op["order"] = AdvStrings(items);
        await ApplyOpsAsync("Setting the tab order…", [op], $"Tab order of page {Math.Max(0, page.SelectedIndex) + 1} set. Save to keep it.");
    }

    /// <summary>Adds widgets of a field on other pages; the copies share one value.</summary>
    private async void DuplicateFieldPages_Click(object sender, RoutedEventArgs e)
    {
        if (await AdvFormFieldsAsync() is not { } form || _document is null) return;
        var fields = form["fields"]!.AsArray().Where(f => f!["widgets"]!.AsArray().Count > 0).Select(f => f!).ToList();
        if (fields.Count == 0) { StatusText.Text = "This document has no form fields."; return; }
        var names = fields.Select(f => AdvText(f["name"])).ToList();
        var chosen = Choice("Field", names, _preparedWidget is { } selected ? Math.Max(0, names.IndexOf(selected.Field.Name)) : 0);
        var grid = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, MaximumRowsOrColumns = 4, ItemWidth = 100 };
        var boxes = Enumerable.Range(0, _document.PageCount).Select(p => new CheckBox { Content = $"Page {p + 1}", MinWidth = 0 }).ToList();
        foreach (var box in boxes) grid.Children.Add(box);
        void Refresh()
        {
            var own = fields[Math.Max(0, chosen.SelectedIndex)]["widgets"]!.AsArray()
                .Select(w => w!["page"] is JsonValue v && v.TryGetValue<int>(out var n) ? n : -1).ToHashSet();
            for (var i = 0; i < boxes.Count; i++)
            {
                boxes[i].IsEnabled = !own.Contains(i);
                if (!boxes[i].IsEnabled) boxes[i].IsChecked = false;
            }
        }
        chosen.SelectionChanged += (_, _) => Refresh();
        Refresh();
        var all = new Button { Content = "All Pages" };
        var none = new Button { Content = "None" };
        all.Click += (_, _) => { foreach (var box in boxes) if (box.IsEnabled) box.IsChecked = true; };
        none.Click += (_, _) => { foreach (var box in boxes) box.IsChecked = false; };
        if (!await AskAsync("Duplicate Field Across Pages", Stack(chosen, Row(all, none), new ScrollViewer { Content = grid, MaxHeight = 220 },
                            Note("The copies share one value, like a name repeated in every page header.")), "Duplicate")) return;
        var pages = Enumerable.Range(0, boxes.Count).Where(i => boxes[i].IsChecked == true).ToList();
        if (pages.Count == 0) return;
        var name = names[Math.Max(0, chosen.SelectedIndex)];
        _preparedWidget = null;
        await ApplyOpsAsync("Duplicating the field…", [new JsonObject { ["op"] = "duplicate_form_field", ["name"] = name, ["pages"] = ToJson(pages) }],
                            $"Added “{name}” to {pages.Count} page{(pages.Count == 1 ? "" : "s")}.");
    }

    /// <summary>Runs every field calculation again (one undo step, only when something changed).</summary>
    private async void RecalculateForm_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        await Run("Recalculating…", async () =>
        {
            var (edited, results) = await AdvTransformAsync([new JsonObject { ["op"] = "recalculate" }]);
            if (results.FirstOrDefault()?["calculated"] is not JsonObject { Count: > 0 } changed)
            {
                TryDelete(edited);
                StatusText.Text = "All calculated fields are up to date.";
                return;
            }
            PushRevision(edited);
            Show(PdfDocument.Open(edited, _password), keepPosition: true);
            StatusText.Text = $"Recalculated {changed.Count} field{(changed.Count == 1 ? "" : "s")}.";
        }, keepStatus: true);
    }

    /// <summary>Keeps a hybrid form's standard fields and drops its XFA data.</summary>
    private async void ConvertXfaForm_Click(object sender, RoutedEventArgs e)
    {
        if (await AdvFormFieldsAsync() is not { } form) return;
        if (form["xfa"]?.GetValue<bool>() != true)
        {
            await InfoAsync("Not an XFA Form", "This document has no XFA form data; its form is already a standard PDF form.");
            return;
        }
        if (!await AskAsync("Convert to a Standard PDF Form?", Note(
                "This form also contains Adobe XFA data. Converting keeps the standard form fields, which every PDF app can fill, and removes the XFA data. Dynamic XFA behaviour (such as sections that grow) is lost."),
                "Convert")) return;
        if (await ApplyOpsAsync("Converting the form…", [new JsonObject { ["op"] = "convert_xfa_form" }], "Converted to a standard PDF form. Save to keep it."))
            _advTraits = null;
    }

    /// <summary>Re-encodes barcode fields from the current values of their source fields.</summary>
    private async void UpdateBarcodes_Click(object sender, RoutedEventArgs e)
    {
        if (await AdvFormFieldsAsync() is not { } form) return;
        var all = form["fields"]!.AsArray();
        string ValueOf(string name) => all.FirstOrDefault(f => AdvText(f!["name"]) == name)?["value"] switch
        {
            JsonArray list => string.Join(", ", list.Select(v => v?.ToString())),
            JsonValue v when v.TryGetValue<string>(out var s) => s,
            _ => "",
        };
        var items = new JsonArray();
        var skipped = new List<string>();
        foreach (var field in all.Where(f => AdvText(f!["kind"]) == "barcode"))
        {
            var name = AdvText(field!["name"]);
            var spec = field["barcode"];
            var data = string.Join("\t", (spec?["fields"] as JsonArray ?? []).Select(n => ValueOf(AdvText(n))));
            // PDF417 isn't encoded on Windows yet; Data Matrix fields get a QR code, as on the Mac.
            if (AdvText(spec?["symbology"]) == "pdf417" || AdvQr.Matrix(data) is not { } matrix) { skipped.Add(name); continue; }
            items.Add(new JsonObject { ["name"] = name, ["value"] = data, ["matrix"] = matrix });
        }
        if (items.Count == 0)
        {
            StatusText.Text = skipped.Count == 0 ? "This form has no barcode fields."
                : $"Couldn't encode {string.Join(", ", skipped)} (PDF417 barcodes and very long data aren't supported yet).";
            return;
        }
        await ApplyOpsAsync("Updating barcodes…", [new JsonObject { ["op"] = "update_barcodes", ["items"] = items }],
                            $"Updated {items.Count} barcode{(items.Count == 1 ? "" : "s")}{(skipped.Count > 0 ? $"; skipped {string.Join(", ", skipped)} (PDF417 isn't supported yet)" : "")}.");
    }

    /// <summary>QR Code encoder (byte mode, error correction M), the matrix the engine draws
    /// for barcode fields: rows of 0/1, top row first, with a one-module quiet zone.</summary>
    private static class AdvQr
    {
        private static readonly int[] EccPerBlock = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28];
        private static readonly int[] Blocks = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49];

        private static int RawModules(int version)
        {
            var result = (16 * version + 128) * version + 64;
            if (version >= 2)
            {
                var align = version / 7 + 2;
                result -= (25 * align - 10) * align - 55;
                if (version >= 7) result -= 36;
            }
            return result;
        }

        private static int DataCodewords(int version) => RawModules(version) / 8 - EccPerBlock[version] * Blocks[version];

        private static int Multiply(int x, int y)
        {
            var z = 0;
            for (var i = 7; i >= 0; i--)
            {
                z = ((z << 1) ^ ((z >> 7) * 0x11D)) & 0xFF;
                z ^= ((y >> i) & 1) * x;
            }
            return z;
        }

        private static int[] Divisor(int degree)
        {
            var result = new int[degree];
            result[degree - 1] = 1;
            var root = 1;
            for (var i = 0; i < degree; i++)
            {
                for (var j = 0; j < degree; j++)
                {
                    result[j] = Multiply(result[j], root);
                    if (j + 1 < degree) result[j] ^= result[j + 1];
                }
                root = Multiply(root, 2);
            }
            return result;
        }

        private static int[] Remainder(int[] data, int[] divisor)
        {
            var result = new int[divisor.Length];
            foreach (var b in data)
            {
                var factor = b ^ result[0];
                Array.Copy(result, 1, result, 0, result.Length - 1);
                result[^1] = 0;
                for (var i = 0; i < result.Length; i++) result[i] ^= Multiply(divisor[i], factor);
            }
            return result;
        }

        /// <summary>Null when the text is too long for a QR code (over 2331 UTF-8 bytes).</summary>
        public static JsonArray? Matrix(string text)
        {
            var data = System.Text.Encoding.UTF8.GetBytes(text);
            var version = Enumerable.Range(1, 40).FirstOrDefault(v => 4 + (v <= 9 ? 8 : 16) + 8 * data.Length <= DataCodewords(v) * 8);
            if (version == 0) return null;

            var bits = new List<int>();
            void Put(int value, int count) { for (var i = count - 1; i >= 0; i--) bits.Add((value >> i) & 1); }
            Put(4, 4);
            Put(data.Length, version <= 9 ? 8 : 16);
            foreach (var b in data) Put(b, 8);
            var capacity = DataCodewords(version) * 8;
            Put(0, Math.Min(4, capacity - bits.Count));
            Put(0, (8 - bits.Count % 8) % 8);
            for (var pad = 0xEC; bits.Count < capacity; pad ^= 0xEC ^ 0x11) Put(pad, 8);
            var codewords = new int[bits.Count / 8];
            for (var i = 0; i < bits.Count; i++) codewords[i >> 3] |= bits[i] << (7 - (i & 7));

            // Split into blocks, add error correction and interleave.
            var (blockCount, eccLength, raw) = (Blocks[version], EccPerBlock[version], RawModules(version) / 8);
            var shortBlocks = blockCount - raw % blockCount;
            var shortLength = raw / blockCount;
            var divisor = Divisor(eccLength);
            var blocks = new List<int[]>();
            for (int i = 0, k = 0; i < blockCount; i++)
            {
                var n = shortLength - eccLength + (i < shortBlocks ? 0 : 1);
                var chunk = codewords[k..(k + n)];
                k += n;
                var block = new List<int>(chunk);
                if (i < shortBlocks) block.Add(0);
                block.AddRange(Remainder(chunk, divisor));
                blocks.Add(block.ToArray());
            }
            var stream = new List<int>();
            for (var i = 0; i < blocks[0].Length; i++)
                for (var j = 0; j < blocks.Count; j++)
                    if (i != shortLength - eccLength || j >= shortBlocks) stream.Add(blocks[j][i]);

            // Function patterns: timing, finders, alignment, format and version information.
            var size = version * 4 + 17;
            var dark = new bool[size, size];      // [y, x]
            var function = new bool[size, size];
            void Set(int x, int y, bool on) { dark[y, x] = on; function[y, x] = true; }
            for (var i = 0; i < size; i++) { Set(6, i, i % 2 == 0); Set(i, 6, i % 2 == 0); }
            foreach (var (cx, cy) in new[] { (3, 3), (size - 4, 3), (3, size - 4) })
                for (var dy = -4; dy <= 4; dy++)
                    for (var dx = -4; dx <= 4; dx++)
                    {
                        var (x, y, d) = (cx + dx, cy + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)));
                        if (x >= 0 && x < size && y >= 0 && y < size) Set(x, y, d != 2 && d != 4);
                    }
            if (version > 1)
            {
                var count = version / 7 + 2;
                var step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2;
                var positions = new int[count];
                positions[0] = 6;
                for (int i = count - 1, p = size - 7; i >= 1; i--, p -= step) positions[i] = p;
                for (var i = 0; i < count; i++)
                    for (var j = 0; j < count; j++)
                    {
                        if ((i == 0 && j == 0) || (i == 0 && j == count - 1) || (i == count - 1 && j == 0)) continue;
                        for (var dy = -2; dy <= 2; dy++)
                            for (var dx = -2; dx <= 2; dx++)
                                Set(positions[i] + dx, positions[j] + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
                    }
            }
            void Format(int mask)
            {
                var rem = mask;  // error correction M = 0b00
                for (var i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
                var word = ((mask << 10) | rem) ^ 0x5412;
                bool Bit(int k) => ((word >> k) & 1) != 0;
                for (var i = 0; i < 6; i++) Set(8, i, Bit(i));
                Set(8, 7, Bit(6));
                Set(8, 8, Bit(7));
                Set(7, 8, Bit(8));
                for (var i = 9; i < 15; i++) Set(14 - i, 8, Bit(i));
                for (var i = 0; i < 8; i++) Set(size - 1 - i, 8, Bit(i));
                for (var i = 8; i < 15; i++) Set(8, size - 15 + i, Bit(i));
                Set(8, size - 8, true);
            }
            Format(0);
            if (version >= 7)
            {
                var rem = version;
                for (var i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
                var word = (version << 12) | rem;
                for (var i = 0; i < 18; i++)
                {
                    var on = ((word >> i) & 1) != 0;
                    var (a, b) = (size - 11 + i % 3, i / 3);
                    Set(a, b, on);
                    Set(b, a, on);
                }
            }

            // Data, in the zigzag order.
            var index = 0;
            for (var right = size - 1; right >= 1; right -= 2)
            {
                if (right == 6) right = 5;
                for (var vert = 0; vert < size; vert++)
                    for (var j = 0; j < 2; j++)
                    {
                        var x = right - j;
                        var y = ((right + 1) & 2) == 0 ? size - 1 - vert : vert;
                        if (function[y, x] || index >= stream.Count * 8) continue;
                        dark[y, x] = ((stream[index >> 3] >> (7 - (index & 7))) & 1) != 0;
                        index++;
                    }
            }

            bool[,] Masked(int mask)
            {
                var grid = (bool[,])dark.Clone();
                for (var y = 0; y < size; y++)
                    for (var x = 0; x < size; x++)
                    {
                        if (function[y, x]) continue;
                        var invert = mask switch
                        {
                            0 => (x + y) % 2 == 0, 1 => y % 2 == 0, 2 => x % 3 == 0, 3 => (x + y) % 3 == 0,
                            4 => (x / 3 + y / 2) % 2 == 0, 5 => x * y % 2 + x * y % 3 == 0,
                            6 => (x * y % 2 + x * y % 3) % 2 == 0, _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
                        };
                        if (invert) grid[y, x] = !grid[y, x];
                    }
                return grid;
            }
            int Penalty(bool[,] grid)
            {
                var score = 0;
                var line = new bool[size];
                for (var pass = 0; pass < 2 * size; pass++)
                {
                    for (var k = 0; k < size; k++) line[k] = pass < size ? grid[pass, k] : grid[k, pass - size];
                    var run = 1;
                    for (var k = 1; k <= size; k++)
                    {
                        if (k < size && line[k] == line[k - 1]) { run++; continue; }
                        if (run >= 5) score += run - 2;
                        run = 1;
                    }
                    for (var k = 0; k + 7 <= size; k++)
                    {
                        if (!(line[k] && !line[k + 1] && line[k + 2] && line[k + 3] && line[k + 4] && !line[k + 5] && line[k + 6])) continue;
                        var before = true;
                        for (var t = Math.Max(0, k - 4); t < k; t++) before &= !line[t];
                        var after = true;
                        for (var t = k + 7; t < Math.Min(size, k + 11); t++) after &= !line[t];
                        if (before || after) score += 40;
                    }
                }
                var darkCount = 0;
                for (var y = 0; y < size; y++)
                    for (var x = 0; x < size; x++)
                    {
                        if (grid[y, x]) darkCount++;
                        if (y + 1 < size && x + 1 < size && grid[y, x] == grid[y, x + 1] && grid[y, x] == grid[y + 1, x] && grid[y, x] == grid[y + 1, x + 1]) score += 3;
                    }
                var total = size * size;
                return score + Math.Abs(darkCount * 20 - total * 10) / total * 10;
            }
            var (bestScore, bestMask) = (int.MaxValue, 0);
            for (var mask = 0; mask < 8; mask++)
            {
                Format(mask);
                var score = Penalty(Masked(mask));
                if (score < bestScore) (bestScore, bestMask) = (score, mask);
            }
            Format(bestMask);
            var result = Masked(bestMask);
            var rows = new JsonArray();
            for (var y = -1; y <= size; y++)
            {
                var row = new JsonArray();
                for (var x = -1; x <= size; x++) row.Add(y >= 0 && y < size && x >= 0 && x < size && result[y, x] ? 1 : 0);
                rows.Add(row);
            }
            return rows;
        }
    }

    // ---------------------------------------------------------------- JavaScript

    private sealed record AdvScript(string Id, string Label, string Script, int Length)
    {
        public override string ToString() => Label;
    }

    private static string AdvScriptLocation(string location) => location switch
    {
        "document" => "Document script", "open_action" => "Open action", "document_action" => "Document action",
        "page" => "Page action", "field" => "Form field", "link" => "Link", _ => "Annotation",
    };

    /// <summary>Every script in the document (document-level, open and page actions, fields, links),
    /// to read and delete. zPDF never runs them.</summary>
    private async void DocumentJavaScript_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        await FlushFieldsAsync();
        var items = new ObservableCollection<AdvScript>();
        var list = new ListView { ItemsSource = items, SelectionMode = ListViewSelectionMode.Extended, Width = 300, Height = 380 };
        var source = new TextBox
        {
            IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, Width = 460, Height = 380,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, PlaceholderText = "Select a script to read it.",
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(source, ScrollBarVisibility.Auto);
        ScrollViewer.SetVerticalScrollBarVisibility(source, ScrollBarVisibility.Auto);
        var info = Note("");
        var copy = new Button { Content = "Copy", IsEnabled = false };
        var delete = new Button { Content = "Delete Selected…", IsEnabled = false };
        var deleteAll = new Button { Content = "Delete All…", IsEnabled = false };

        async Task Load()
        {
            JsonNode result;
            try { result = await Engine.QueryAsync(CurrentPath!, "document_javascript", password: _password); }
            catch (EngineException error) { info.Text = error.Message; return; }
            items.Clear();
            foreach (var item in result["items"]!.AsArray())
            {
                var where = string.Join(" · ", new[]
                {
                    AdvScriptLocation(AdvText(item!["location"])), AdvText(item["event"]),
                    item["page"] is JsonValue p && p.TryGetValue<int>(out var page) ? $"page {page + 1}" : "",
                }.Where(s => s.Length > 0));
                var length = item["length"] is JsonValue l && l.TryGetValue<int>(out var n) ? n : 0;
                items.Add(new AdvScript(AdvText(item["id"]), $"{AdvText(item["name"])}\n{where}", AdvText(item["script"]), length));
            }
            info.Text = items.Count == 0 ? "This document contains no scripts." : $"{items.Count} script{(items.Count == 1 ? "" : "s")}.";
            deleteAll.IsEnabled = items.Count > 0;
            source.Text = "";
        }

        list.SelectionChanged += (_, _) =>
        {
            var selected = list.SelectedItems.OfType<AdvScript>().ToList();
            delete.IsEnabled = selected.Count > 0;
            copy.IsEnabled = selected.Count == 1;
            source.Text = selected.Count switch
            {
                1 when selected[0].Script.Length == 0 => "(empty script)",
                1 => selected[0].Script.ReplaceLineEndings("\r") + (selected[0].Script.Length < selected[0].Length ? "\r… (truncated)" : ""),
                0 => "",
                _ => $"{selected.Count} scripts selected.",
            };
        };
        copy.Click += (_, _) =>
        {
            if (list.SelectedItems.OfType<AdvScript>().FirstOrDefault() is not { } script) return;
            var package = new DataPackage();
            package.SetText(script.Script.ReplaceLineEndings(Environment.NewLine));
            Clipboard.SetContent(package);
            info.Text = "Copied the script.";
        };

        async Task Remove(IEnumerable<AdvScript> doomed)
        {
            var ids = doomed.Select(s => s.Id).ToList();
            if (ids.Count == 0) return;
            delete.IsEnabled = deleteAll.IsEnabled = false;
            var ok = await ApplyOpsAsync(ids.Count == 1 ? "Deleting the script…" : "Deleting scripts…",
                                         [new JsonObject { ["op"] = "remove_javascript", ["ids"] = AdvStrings(ids) }],
                                         $"Deleted {ids.Count} script{(ids.Count == 1 ? "" : "s")}. Save to keep the change.");
            var message = StatusText.Text;
            await Load();
            if (!ok || items.Count > 0) info.Text = message;
        }
        Flyout Confirm(string action, Func<IEnumerable<AdvScript>> targets)
        {
            var go = new Button { Content = action };
            var flyout = new Flyout
            {
                Content = new StackPanel
                {
                    Spacing = 10, MaxWidth = 320,
                    Children =
                    {
                        new TextBlock { Text = "Form calculations, validation and buttons that rely on these scripts stop working in other apps. You can undo this.", TextWrapping = TextWrapping.Wrap },
                        go,
                    },
                },
            };
            go.Click += async (_, _) => { flyout.Hide(); await Remove(targets().ToList()); };
            return flyout;
        }
        delete.Flyout = Confirm("Delete", () => list.SelectedItems.OfType<AdvScript>());
        deleteAll.Flyout = Confirm("Delete All", () => items);

        await Load();
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = "Document JavaScript", CloseButtonText = "Done", DefaultButton = ContentDialogButton.Close,
            Content = Stack(Note("zPDF never runs document JavaScript. Review the scripts here and delete any you don't trust."),
                            Row(list, source), info, Row(copy, delete, deleteAll)),
        };
        dialog.Resources["ContentDialogMaxWidth"] = 900.0;
        await dialog.ShowAsync();
    }

    // ---------------------------------------------------------------- tags

    private static readonly string[] AdvStandardTags =
    [
        "Document", "Part", "Art", "Sect", "Div", "BlockQuote", "Caption", "TOC", "TOCI", "Index", "NonStruct",
        "H1", "H2", "H3", "H4", "H5", "H6", "H", "P", "L", "LI", "Lbl", "LBody",
        "Table", "THead", "TBody", "TFoot", "TR", "TH", "TD",
        "Span", "Quote", "Note", "Reference", "BibEntry", "Code", "Link", "Annot", "Figure", "Formula", "Form",
    ];

    private static string AdvTagLabel(JsonNode node)
    {
        var type = AdvText(node["type"]);
        var text = AdvText(node["text"]).ReplaceLineEndings(" ");
        if (text.Length > 50) text = text[..50] + "…";
        var page = node["page"] is JsonValue p && p.TryGetValue<int>(out var n) ? $"  · p{n + 1}" : "";
        var missingAlt = type is "Figure" or "Formula" && AdvText(node["alt"]).Trim('\0', ' ').Length == 0 ? "  ⚠ no alternate text" : "";
        return $"<{type}>  {text}{page}{missingAlt}";
    }

    /// <summary>The tag tree: change a tag's type, title, alternate/actual text and language, move it
    /// up/down, indent/outdent or delete it. Each change is applied at once as one undo step.</summary>
    private async void TagsEditor_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        await FlushFieldsAsync();
        JsonNode? root;
        try { root = (await Engine.QueryAsync(CurrentPath, "structure_tree", password: _password))["root"]; }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        if (root is null) { StatusText.Text = "This document isn't tagged. Use Tools ▸ Autotag Document first."; return; }

        var nodes = new Dictionary<TreeViewNode, (JsonNode Data, int[] Path)>();
        var tree = new TreeView { SelectionMode = TreeViewSelectionMode.Single, Width = 400, Height = 440 };
        var type = new ComboBox { Header = "Type", IsEditable = true, ItemsSource = AdvStandardTags, MinWidth = 200 };
        var title = Text("Title");
        var alt = Text("Alternate text", "", "Read instead of the content (required for figures)");
        alt.AcceptsReturn = true;
        alt.TextWrapping = TextWrapping.Wrap;
        alt.MinHeight = 60;
        var actual = Text("Actual text", "", "Exact replacement text");
        var lang = Text("Language", "", "Inherited");
        var apply = new Button { Content = "Apply" };
        var up = new Button { Content = "Up" };
        var down = new Button { Content = "Down" };
        var outdent = new Button { Content = "Outdent" };
        var indent = new Button { Content = "Indent" };
        var remove = new Button { Content = "Delete" };
        var show = new HyperlinkButton { Content = "Show on page" };
        var message = Note("");
        var inspector = new StackPanel { Spacing = 10, Width = 300 };
        foreach (var child in new UIElement[] { type, title, alt, actual, lang, apply, Row(up, down), Row(outdent, indent, remove), show, message })
            inspector.Children.Add(child);
        ToolTipService.SetToolTip(remove, "Delete this tag; its content moves to the parent tag");
        var busy = false;

        TreeViewNode Make(JsonNode data, int[] path)
        {
            var node = new TreeViewNode { Content = AdvTagLabel(data), HasUnrealizedChildren = data["children"] is JsonArray { Count: > 0 } };
            nodes[node] = (data, path);
            return node;
        }
        void Realize(TreeViewNode node)
        {
            if (!node.HasUnrealizedChildren || !nodes.TryGetValue(node, out var entry)) return;
            node.HasUnrealizedChildren = false;
            var kids = entry.Data["children"]!.AsArray();
            for (var i = 0; i < kids.Count; i++) node.Children.Add(Make(kids[i]!, [.. entry.Path, i]));
        }
        JsonNode? At(int[] path)
        {
            var node = root;
            foreach (var i in path)
            {
                if (node?["children"] is not JsonArray kids || i >= kids.Count) return null;
                node = kids[i];
            }
            return node;
        }
        (JsonNode Data, int[] Path)? Selected() => tree.SelectedNode is { } s && nodes.TryGetValue(s, out var entry) ? entry : null;

        void Fill()
        {
            var selected = Selected();
            foreach (var control in new Control[] { type, title, alt, actual, lang, apply, up, down, outdent, indent, remove })
                control.IsEnabled = selected is not null && !busy;
            if (selected is not { } entry)
            {
                show.Visibility = Visibility.Collapsed;
                return;
            }
            var tag = AdvText(entry.Data["type"]);
            type.SelectedItem = AdvStandardTags.Contains(tag) ? tag : null;
            type.Text = tag;
            title.Text = AdvText(entry.Data["title"]);
            alt.Text = AdvText(entry.Data["alt"]);
            actual.Text = AdvText(entry.Data["actual_text"]);
            lang.Text = AdvText(entry.Data["lang"]);
            var page = entry.Data["page"] is JsonValue p && p.TryGetValue<int>(out var n) ? n : (int?)null;
            show.Visibility = page is null ? Visibility.Collapsed : Visibility.Visible;
            show.Content = page is { } pg ? $"Show on page {pg + 1}" : "";
            show.Tag = page;
        }

        void Build(int[]? reselect)
        {
            nodes.Clear();
            tree.RootNodes.Clear();
            var top = root?["children"] as JsonArray ?? [];
            for (var i = 0; i < top.Count; i++) tree.RootNodes.Add(Make(top[i]!, [i]));
            TreeViewNode? target = null;
            if (reselect is { Length: > 0 })
            {
                IList<TreeViewNode> level = tree.RootNodes;
                for (var k = 0; k < reselect.Length; k++)
                {
                    if (reselect[k] >= level.Count) { target = null; break; }
                    target = level[reselect[k]];
                    if (k == reselect.Length - 1) break;
                    Realize(target);
                    target.IsExpanded = true;
                    level = target.Children;
                }
            }
            if (target is not null) tree.SelectedNode = target;
            Fill();
        }

        async Task Edit(JsonObject edit, int[]? reselect, string done)
        {
            busy = true;
            Fill();
            message.Text = "";
            var ok = await ApplyOpsAsync("Editing tags…", [new JsonObject { ["op"] = "edit_structure", ["edits"] = new JsonArray(edit) }], done);
            message.Text = StatusText.Text;
            try { root = (await Engine.QueryAsync(CurrentPath!, "structure_tree", password: _password))["root"]; }
            catch (EngineException error) { message.Text = error.Message; }
            busy = false;
            Build(ok ? reselect : Selected()?.Path);
        }

        tree.Expanding += (_, args) => Realize(args.Node);
        tree.SelectionChanged += (_, _) => { message.Text = ""; Fill(); };
        show.Click += (_, _) => { if (show.Tag is int page) GoTo(page); };
        apply.Click += async (_, _) =>
        {
            if (Selected() is not { } entry) return;
            var set = new JsonObject();
            void Diff(string key, string value) { if (value != AdvText(entry.Data[key])) set[key] = value; }
            Diff("type", (type.Text is { Length: > 0 } typed ? typed : type.SelectedItem as string ?? "").Trim());
            Diff("title", title.Text);
            Diff("alt", alt.Text);
            Diff("actual_text", actual.Text);
            Diff("lang", lang.Text.Trim());
            if (set.Count == 0) return;
            await Edit(new JsonObject { ["id"] = AdvText(entry.Data["id"]), ["set"] = set }, entry.Path, "Tag updated.");
        };
        async Task MoveTo(JsonNode data, JsonNode parent, int index, int[] reselect, string done) =>
            await Edit(new JsonObject
            {
                ["id"] = AdvText(data["id"]), ["move"] = new JsonObject { ["parent"] = AdvText(parent["id"]), ["index"] = index },
            }, reselect, done);
        async Task Shift(int delta)
        {
            if (Selected() is not { } entry) return;
            var parentPath = entry.Path[..^1];
            var target = entry.Path[^1] + delta;
            if (At(parentPath) is not { } parent || target < 0 || target >= (parent["children"] as JsonArray)?.Count) return;
            await MoveTo(entry.Data, parent, target, [.. parentPath, target], "Tag moved.");
        }
        up.Click += async (_, _) => await Shift(-1);
        down.Click += async (_, _) => await Shift(1);
        indent.Click += async (_, _) =>
        {
            if (Selected() is not { } entry || entry.Path[^1] == 0) return;
            var parentPath = entry.Path[..^1];
            int[] siblingPath = [.. parentPath, entry.Path[^1] - 1];
            if (At(siblingPath) is not { } sibling) return;
            var count = (sibling["children"] as JsonArray)?.Count ?? 0;
            await MoveTo(entry.Data, sibling, count, [.. siblingPath, count], "Tag indented.");
        };
        outdent.Click += async (_, _) =>
        {
            if (Selected() is not { } entry || entry.Path.Length < 2) return;
            var parentPath = entry.Path[..^1];
            var grandPath = parentPath[..^1];
            if (At(grandPath) is not { } grand) return;
            await MoveTo(entry.Data, grand, parentPath[^1] + 1, [.. grandPath, parentPath[^1] + 1], "Tag outdented.");
        };
        remove.Click += async (_, _) =>
        {
            if (Selected() is not { } entry) return;
            await Edit(new JsonObject { ["id"] = AdvText(entry.Data["id"]), ["delete"] = true }, entry.Path[..^1], "Tag deleted; its content moved to the parent tag.");
        };

        Build(null);
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot, Title = "Tags", CloseButtonText = "Done", DefaultButton = ContentDialogButton.Close,
            Content = Stack(Row(tree, inspector), Note("Changes apply immediately; Undo reverts each one.")),
        };
        dialog.Resources["ContentDialogMaxWidth"] = 960.0;
        await dialog.ShowAsync();
    }

    // ---------------------------------------------------------------- PDF/UA and standards

    /// <summary>Adds (or removes) the PDF/UA-1 identifier. Adding requires a tagged document
    /// that passes the accessibility check, as on the Mac.</summary>
    private async void MarkPdfUa_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        await FlushFieldsAsync();
        JsonNode status, report;
        try { status = await Engine.QueryAsync(CurrentPath, "standards_status", password: _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        if ((status["claims"] as JsonArray ?? []).Any(c => AdvText(c).StartsWith("PDF/UA", StringComparison.Ordinal)))
        {
            if (!await AskAsync("Remove the PDF/UA Identifier?", Note("The document will no longer claim to conform to PDF/UA. Its tags are kept."), "Remove")) return;
            await ApplyOpsAsync("Removing the PDF/UA identifier…", [new JsonObject { ["op"] = "mark_pdfua", ["enabled"] = false }],
                                "PDF/UA identifier removed. Save to keep the change.");
            return;
        }
        try { report = await Engine.QueryAsync(CurrentPath, "accessibility_check", password: _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        if (report["tagged"]?.GetValue<bool>() != true) { StatusText.Text = "PDF/UA requires a tagged document. Use Tools ▸ Autotag Document first."; return; }
        var failed = report["summary"]?["failed"] is JsonValue f && f.TryGetValue<int>(out var n) ? n : 0;
        if (failed > 0)
        {
            await InfoAsync("Fix the Failed Checks First",
                $"PDF/UA requires an accessible document, and {failed} accessibility check{(failed == 1 ? "" : "s")} failed. Use Tools ▸ Accessibility Check to fix {(failed == 1 ? "it" : "them")}, then try again.");
            return;
        }
        if (!await AskAsync("Identify as PDF/UA-1?", Note(
                "Adds the PDF/UA-1 identifier to the document's metadata. It's a claim, not a certification: items the Accessibility Check marks for manual checking still need a person to review them."),
                "Identify")) return;
        await ApplyOpsAsync("Identifying as PDF/UA…", [new JsonObject { ["op"] = "mark_pdfua", ["enabled"] = true }], "Identified as PDF/UA-1. Save to keep it.");
    }

    /// <summary>Which standards (PDF/A, PDF/X, PDF/E, PDF/UA) the file claims to meet.</summary>
    private async void StandardsStatus_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPath is null) return;
        JsonNode status;
        try { status = await Engine.QueryAsync(CurrentPath, "standards_status", password: _password); }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        var claims = (status["claims"] as JsonArray ?? []).Select(AdvText).Where(c => c.Length > 0).ToList();
        var summary = claims.Count == 0
            ? "It doesn't claim to conform to PDF/A, PDF/X, PDF/E or PDF/UA."
            : $"It claims to conform to {string.Join(", ", claims)}.";
        await InfoAsync("Standards",
            $"This is a PDF {AdvText(status["version"])} document. {summary}\n\n" +
            "A claim is what the file says about itself. Save as PDF/A, PDF/X or PDF/E (Convert) converts and checks the file; Accessibility Check (Tools) reviews PDF/UA requirements.");
    }
}
