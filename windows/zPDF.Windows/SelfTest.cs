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
