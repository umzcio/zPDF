using System.Text.Json.Nodes;

namespace zPDF;

/// <summary>`zPDF.exe --selftest in.pdf outdir`: exercises PDFium rendering and the
/// engine without any window (for checks over SSH). Writes BMPs and a saved PDF.</summary>
internal static class SelfTest
{
    public static async Task<int> RunAsync(string input, string folder)
    {
        Directory.CreateDirectory(folder);
        using (var doc = PdfDocument.Open(input))
        {
            var (w, h) = doc.PageSize(0);
            Console.WriteLine($"pages={doc.PageCount} size={w:0.#}x{h:0.#}pt");
            WriteBmp(doc.Render(0, 1.5), Path.Combine(folder, "page1.bmp"));
            var info = doc.LoadPageInfo(0);
            var boxed = info.Boxes.Count(b => !b.IsEmpty);
            Console.WriteLine($"text chars={info.Boxes.Length} boxed={boxed} links={info.Links.Count} view={info.Width:0}x{info.Height:0}");
            Console.WriteLine($"text starts: {info.Text[..Math.Min(70, info.Text.Length)].ReplaceLineEndings(" ")}");
            var word = info.Text.IndexOf("Employment", StringComparison.OrdinalIgnoreCase);
            if (word >= 0)
            {
                var rects = info.RectsFor(info.CharAt[word], info.CharAt[word + 9]);
                Console.WriteLine($"find 'Employment' at char {info.CharAt[word]}: {rects.Count} rect(s), first {rects[0].X:0},{rects[0].Y:0} {rects[0].Width:0}x{rects[0].Height:0}");
                var hit = info.CharIndexAt(new Windows.Foundation.Point(rects[0].X + 2, rects[0].Y + rects[0].Height / 2));
                Console.WriteLine($"hit-test inside that word -> char {hit}; text '{info.TextOf(info.CharAt[word], info.CharAt[word + 9])}'");
            }
            foreach (var link in info.Links.Take(3)) Console.WriteLine($"link {link.Bounds.X:0},{link.Bounds.Y:0} -> page {link.TargetPage} uri {link.Uri}");
            Console.WriteLine($"outline items={doc.Outline().Count}");
            var (meta, version, encrypted, _) = doc.Properties();
            Console.WriteLine($"title='{meta["Title"]}' producer='{meta["Producer"]}' version={version} encrypted={encrypted} label1='{doc.PageLabel(0)}'");
        }
        Console.WriteLine($"engine={(Engine.IsBundled ? "bundled" : "development")} python={Engine.PythonPath}");
        using var engine = new Engine();
        var edited = await engine.TransformAsync(input, [new JsonObject { ["op"] = "watermark", ["text"] = "ZPDF WINDOWS" }]);
        using (var doc = PdfDocument.Open(edited)) WriteBmp(doc.Render(0, 1.5), Path.Combine(folder, "page1-watermarked.bmp"));
        var commented = await engine.TransformAsync(edited, [new JsonObject
        {
            ["op"] = "comment_edits",
            ["items"] = new JsonArray(
                new JsonObject { ["action"] = "add", ["page"] = 0, ["annot"] = new JsonObject { ["subtype"] = "Highlight",
                    ["quads"] = new JsonArray(199, 770, 276, 770, 199, 755, 276, 755), ["color"] = new JsonArray(1, 0.85, 0) } },
                new JsonObject { ["action"] = "add", ["page"] = 0, ["annot"] = new JsonObject { ["subtype"] = "Text",
                    ["rect"] = new JsonArray(500, 700, 522, 722), ["contents"] = "Self-test note", ["author"] = "selftest" } }),
        }]);
        var threads = await engine.QueryAsync(commented, "comment_threads");
        var first = threads["pages"]![0]!.AsArray();
        Console.WriteLine($"comments on page 1: {first.Count} ({string.Join(", ", first.Select(c => c!["subtype"]!.GetValue<string>()))}); " +
                          $"annotations={PdfDocument.Open(commented).AnnotationCount(0)}");
        File.Delete(commented);
        var filled = await engine.TransformAsync(input, [new JsonObject
        {
            ["op"] = "fill_fields", ["values"] = new JsonObject { ["Last Name Family Name from Section 1"] = "Doe" },
        }]);
        var form = await engine.QueryAsync(filled, "form_fields");
        var field = form["fields"]!.AsArray().First(f => f!["name"]!.GetValue<string>() == "Last Name Family Name from Section 1");
        Console.WriteLine($"form: {form["fields"]!.AsArray().Count} fields; filled value = '{field!["value"]}'");
        using (var filledDoc = PdfDocument.Open(filled))
        {
            // The filled value must be drawn (PDFium needs its form environment for this).
            var r = field["widgets"]![0]!["rect"]!.AsArray().Select(v => v!.GetValue<double>()).ToArray();
            var page = filledDoc.Render(field["widgets"]![0]!["page"]!.GetValue<int>(), 2);
            var dark = 0;
            for (var y = (int)((792 - r[3]) * 2); y < (int)((792 - r[1]) * 2); y++)
                for (var x = (int)(r[0] * 2); x < (int)(r[2] * 2); x++)
                    if (page.Pixels[(y * page.Width + x) * 4 + 1] < 128) dark++;
            Console.WriteLine($"filled field renders {dark} dark pixels (0 would mean the value is invisible)");
        }
        File.Delete(filled);
        // Fill & Sign image and a digital signature, end to end.
        var png = SignatureArt.Typed("Jane Doe", SignatureArt.InstalledFonts().FirstOrDefault() ?? "Segoe Script", System.Drawing.Color.Navy);
        var stamped = await engine.TransformAsync(input, [new JsonObject
        {
            ["op"] = "place_image_stamp", ["page"] = 0, ["rect"] = new JsonArray(360, 420, 540, 460),
            ["image"] = Convert.ToBase64String(png), ["kind"] = "signature",
        }]);
        var id = await engine.CryptoAsync("create_identity", new JsonObject { ["name"] = "Self Test", ["password"] = "selftest" });
        var signed = await engine.TransformAsync(stamped, [new JsonObject
        {
            ["op"] = "sign", ["identity"] = new JsonObject { ["p12"] = id["p12"]!.GetValue<string>(), ["password"] = "selftest" },
            ["page"] = 0, ["rect"] = new JsonArray(40, 40, 220, 94), ["reason"] = "Self-test",
        }]);
        var report = await engine.QueryAsync(signed, "signatures");
        var sig = report["signatures"]!.AsArray().First(x => x!["signed"]?.GetValue<bool>() == true)!;
        Console.WriteLine($"signature image {SignatureArt.Size(png)}; digital signature by {sig["name"]}: integrity={sig["integrity"]} covers={sig["covers_document"]}");
        File.Delete(stamped); File.Delete(signed);
        string[] Split(string text) => text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        foreach (var (before, after, expected) in new[]
        {
            ("the quick brown fox", "the quick red fox", "(2, 1, 2, 1)"),
            ("a b c", "a b c d", "(3, 0, 3, 1)"),
            ("a b c", "b c", "(0, 1, 0, 0)"),
            ("", "x y", "(0, 0, 0, 2)"),
            ("same words", "same words", ""),
        })
        {
            var runs = string.Join(" ", TextDiff.Diff(Split(before), Split(after)));
            Console.WriteLine($"diff '{before}' → '{after}': {runs} {(runs == expected ? "ok" : $"EXPECTED {expected}")}");
        }
        var docx = Path.Combine(folder, "export.docx");
        var exported = await Exporter.ExportAsync(input, "docx", [0, 1], docx, null, null, CancellationToken.None);
        Console.WriteLine($"export: {Path.GetFileName(exported.Path)} {exported.Bytes} bytes, notices [{string.Join(", ", exported.Notices)}]");
        var ocr = Windows.Media.Ocr.OcrEngine.TryCreateFromUserProfileLanguages();
        if (ocr is null) Console.WriteLine("ocr: no OCR language installed");
        else
        {
            using var ocrDoc = PdfDocument.Open(input);
            var image = ocrDoc.Render(0, 2);
            using var bitmap = Windows.Graphics.Imaging.SoftwareBitmap.CreateCopyFromBuffer(
                System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(image.Pixels),
                Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, image.Width, image.Height, Windows.Graphics.Imaging.BitmapAlphaMode.Ignore);
            var result = await ocr.RecognizeAsync(bitmap);
            var words = result.Lines.SelectMany(l => l.Words).ToList();
            Console.WriteLine($"ocr ({ocr.RecognizerLanguage.LanguageTag}): {result.Lines.Count} lines, {words.Count} words; first: {string.Join(" ", words.Take(4).Select(w => w.Text))}");
        }
        var saved = Path.Combine(folder, "watermarked.pdf");
        var receipt = await engine.PublishAsync(edited, saved, overwrite: true);
        File.Delete(edited);
        Console.WriteLine($"saved={receipt["path"]} sha256={receipt["sha256"]}");
        return 0;
    }

    private static void WriteBmp(RenderedPage image, string path)
    {
        using var file = new BinaryWriter(File.Create(path));
        var size = 54 + image.Pixels.Length;
        file.Write((ushort)0x4D42); file.Write(size); file.Write(0); file.Write(54);
        file.Write(40); file.Write(image.Width); file.Write(-image.Height);  // negative height: top-down rows
        file.Write((ushort)1); file.Write((ushort)32); file.Write(0); file.Write(image.Pixels.Length);
        file.Write(2835); file.Write(2835); file.Write(0); file.Write(0);
        file.Write(image.Pixels);
        Console.WriteLine($"wrote {path} ({image.Width}x{image.Height})");
    }
}
