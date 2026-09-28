using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;

namespace zPDF;

/// <summary>Transparent PNGs for Fill &amp; Sign: typed signatures, drawn strokes and marks.</summary>
internal static class SignatureArt
{
    /// <summary>Handwriting-style fonts that ship with Windows 10/11.</summary>
    public static readonly string[] Fonts = ["Segoe Script", "Ink Free", "Segoe Print", "Lucida Handwriting", "Brush Script MT"];

    public static IEnumerable<string> InstalledFonts()
    {
        using var families = new InstalledFontCollection();
        var names = families.Families.Select(f => f.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return Fonts.Where(names.Contains);
    }

    public static byte[] Typed(string text, string font, Color color)
    {
        using var typeface = new Font(font, 72, FontStyle.Regular, GraphicsUnit.Pixel);
        SizeF size;
        using (var probe = new Bitmap(1, 1)) using (var g = Graphics.FromImage(probe)) size = g.MeasureString(text, typeface);
        using var bitmap = new Bitmap(Math.Max(1, (int)Math.Ceiling(size.Width) + 24), Math.Max(1, (int)Math.Ceiling(size.Height) + 24));
        using (var g = Graphics.FromImage(bitmap))
        {
            g.Clear(Color.Transparent);
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            using var brush = new SolidBrush(color);
            g.DrawString(text, typeface, brush, 12, 12);
        }
        return Png(Crop(bitmap));
    }

    /// <summary>Strokes in any coordinate space; drawn at 3× for smooth edges.</summary>
    public static byte[] Drawn(IReadOnlyList<IReadOnlyList<PointF>> strokes, Color color, float width = 3)
    {
        var points = strokes.SelectMany(s => s).ToList();
        if (points.Count == 0) throw new ArgumentException("Draw a signature first.");
        const float scale = 3, pad = 8;
        float minX = points.Min(p => p.X), minY = points.Min(p => p.Y);
        var w = (int)((points.Max(p => p.X) - minX) * scale + pad * 2 * scale) + 1;
        var h = (int)((points.Max(p => p.Y) - minY) * scale + pad * 2 * scale) + 1;
        using var bitmap = new Bitmap(Math.Max(2, w), Math.Max(2, h));
        using (var g = Graphics.FromImage(bitmap))
        {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var pen = new Pen(color, width * scale) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
            foreach (var stroke in strokes)
            {
                var mapped = stroke.Select(p => new PointF((p.X - minX + pad) * scale, (p.Y - minY + pad) * scale)).ToArray();
                if (mapped.Length == 1) g.FillEllipse(new SolidBrush(color), mapped[0].X - width * scale / 2, mapped[0].Y - width * scale / 2, width * scale, width * scale);
                else g.DrawLines(pen, mapped);
            }
        }
        return Png(bitmap);
    }

    /// <summary>✓, ✗ or ● as a mark to place on a form.</summary>
    public static byte[] Glyph(string glyph, Color color)
    {
        using var bitmap = new Bitmap(96, 96);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.Clear(Color.Transparent);
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            using var font = new Font("Segoe UI Symbol", 64, FontStyle.Bold, GraphicsUnit.Pixel);
            using var brush = new SolidBrush(color);
            var size = g.MeasureString(glyph, font);
            g.DrawString(glyph, font, brush, (96 - size.Width) / 2, (96 - size.Height) / 2);
        }
        return Png(Crop(bitmap));
    }

    /// <summary>A photo or scan of a signature on paper: light paper becomes transparent (ink
    /// keeps its colour, edges fade smoothly), trimmed to the ink, at most 1600 px wide.</summary>
    public static byte[] RemoveBackground(byte[] image)
    {
        using var stream = new MemoryStream(image);
        using var loaded = Image.FromStream(stream);
        var scale = Math.Min(1.0, 1600.0 / Math.Max(loaded.Width, loaded.Height));
        using var bitmap = new Bitmap(Math.Max(1, (int)(loaded.Width * scale)), Math.Max(1, (int)(loaded.Height * scale)), PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.Clear(Color.White);  // transparent areas of the source count as paper
            g.DrawImage(loaded, 0, 0, bitmap.Width, bitmap.Height);
        }
        var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        try
        {
            var pixels = new byte[data.Stride * data.Height];
            System.Runtime.InteropServices.Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
            for (var y = 0; y < data.Height; y++)
            {
                for (var x = 0; x < data.Width; x++)
                {
                    var i = y * data.Stride + x * 4;  // B G R A
                    var luminance = 0.114 * pixels[i] + 0.587 * pixels[i + 1] + 0.299 * pixels[i + 2];
                    // Paper (>= 200) disappears; darker pixels keep more of their opacity.
                    var alpha = Math.Clamp((200 - luminance) / 90.0, 0, 1);
                    pixels[i + 3] = (byte)(alpha * 255);
                }
            }
            System.Runtime.InteropServices.Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
        }
        finally { bitmap.UnlockBits(data); }
        return Png(Crop(bitmap));
    }

    public static (int Width, int Height) Size(byte[] png)
    {
        using var stream = new MemoryStream(png);
        using var image = Image.FromStream(stream);
        return (image.Width, image.Height);
    }

    /// <summary>The smallest box holding every visible pixel.</summary>
    private static Bitmap Crop(Bitmap source)
    {
        int left = source.Width, top = source.Height, right = -1, bottom = -1;
        var data = source.LockBits(new Rectangle(0, 0, source.Width, source.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var row = new byte[data.Stride];
            for (var y = 0; y < source.Height; y++)
            {
                System.Runtime.InteropServices.Marshal.Copy(data.Scan0 + y * data.Stride, row, 0, data.Stride);
                for (var x = 0; x < source.Width; x++)
                {
                    if (row[x * 4 + 3] < 8) continue;
                    left = Math.Min(left, x); right = Math.Max(right, x);
                    top = Math.Min(top, y); bottom = Math.Max(bottom, y);
                }
            }
        }
        finally { source.UnlockBits(data); }
        if (right < 0) return (Bitmap)source.Clone();
        const int pad = 4;
        var box = Rectangle.FromLTRB(Math.Max(0, left - pad), Math.Max(0, top - pad), Math.Min(source.Width, right + pad + 1), Math.Min(source.Height, bottom + pad + 1));
        return source.Clone(box, PixelFormat.Format32bppArgb);
    }

    private static byte[] Png(Image image)
    {
        using var stream = new MemoryStream();
        image.Save(stream, ImageFormat.Png);
        return stream.ToArray();
    }
}
