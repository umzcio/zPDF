using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace zPDF;

/// <summary>Scan cleanup before OCR: straighten (by the skew Windows OCR reports), whiten a
/// grey background and remove isolated specks. Works on BGRA page renders.</summary>
internal static class ScanCleanup
{
    public static RenderedPage Clean(RenderedPage page, double? skew, bool whiten, bool despeckle)
    {
        using var source = ToBitmap(page);
        using var result = new Bitmap(page.Width, page.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(result))
        {
            g.Clear(Color.White);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            if (skew is { } angle && Math.Abs(angle) >= 0.1 && Math.Abs(angle) <= 15)
            {
                // Windows reports the text's clockwise rotation: turn it back about the centre.
                g.TranslateTransform(page.Width / 2f, page.Height / 2f);
                g.RotateTransform((float)-angle);
                g.TranslateTransform(-page.Width / 2f, -page.Height / 2f);
            }
            g.DrawImage(source, 0, 0, page.Width, page.Height);
        }
        var pixels = Pixels(result);
        if (whiten) Whiten(pixels);
        if (despeckle) Despeckle(pixels, page.Width, page.Height);
        return new RenderedPage(page.Width, page.Height, pixels);
    }

    /// <summary>Writes `page` as a JPEG tagged with `dpi` (the page image replacing the scan).</summary>
    public static string SaveJpeg(RenderedPage page, double dpi)
    {
        using var bitmap = ToBitmap(page);
        bitmap.SetResolution((float)dpi, (float)dpi);
        var path = Path.Combine(Path.GetTempPath(), $"zpdf-scan-{Guid.NewGuid():N}.jpg");
        var codec = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(Encoder.Quality, 85L);
        bitmap.Save(path, codec, parameters);
        return path;
    }

    private static Bitmap ToBitmap(RenderedPage page)
    {
        var bitmap = new Bitmap(page.Width, page.Height, PixelFormat.Format32bppArgb);
        var data = bitmap.LockBits(new Rectangle(0, 0, page.Width, page.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            for (var row = 0; row < page.Height; row++)
                Marshal.Copy(page.Pixels, row * page.Width * 4, data.Scan0 + row * data.Stride, page.Width * 4);
        }
        finally { bitmap.UnlockBits(data); }
        return bitmap;
    }

    private static byte[] Pixels(Bitmap bitmap)
    {
        var pixels = new byte[bitmap.Width * bitmap.Height * 4];
        var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            for (var row = 0; row < bitmap.Height; row++)
                Marshal.Copy(data.Scan0 + row * data.Stride, pixels, row * bitmap.Width * 4, bitmap.Width * 4);
        }
        finally { bitmap.UnlockBits(data); }
        return pixels;
    }

    private static int Luma(byte[] p, int i) => (p[i] * 29 + p[i + 1] * 150 + p[i + 2] * 77) >> 8;  // BGRA

    /// <summary>Paper tone to white: light pixels become white, the rest keep their contrast.</summary>
    private static void Whiten(byte[] p)
    {
        for (var i = 0; i < p.Length; i += 4)
            if (Luma(p, i) > 200) p[i] = p[i + 1] = p[i + 2] = 255;
    }

    /// <summary>Removes dark pixels with at most one dark neighbour (dust, scanner noise).</summary>
    private static void Despeckle(byte[] p, int width, int height)
    {
        var dark = new bool[width * height];
        for (var i = 0; i < dark.Length; i++) dark[i] = Luma(p, i * 4) < 128;
        for (var y = 1; y < height - 1; y++)
            for (var x = 1; x < width - 1; x++)
            {
                var at = y * width + x;
                if (!dark[at]) continue;
                var neighbours = 0;
                for (var dy = -1; dy <= 1; dy++)
                    for (var dx = -1; dx <= 1; dx++)
                        if ((dx != 0 || dy != 0) && dark[at + dy * width + dx]) neighbours++;
                if (neighbours <= 1) p[at * 4] = p[at * 4 + 1] = p[at * 4 + 2] = 255;
            }
    }
}
