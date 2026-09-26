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
        }
        using var engine = new Engine();
        var edited = await engine.TransformAsync(input, [new JsonObject { ["op"] = "watermark", ["text"] = "ZPDF WINDOWS" }]);
        using (var doc = PdfDocument.Open(edited)) WriteBmp(doc.Render(0, 1.5), Path.Combine(folder, "page1-watermarked.bmp"));
        var saved = Path.Combine(folder, "watermarked.pdf");
        var receipt = await engine.PublishAsync(edited, saved, overwrite: true);
        File.Delete(edited);
        Console.WriteLine($"saved={receipt["path"]} sha256={receipt["sha256"]}");
        return 0;
    }

    private static void WriteBmp(PageImage image, string path)
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
