using System.Runtime.InteropServices;

namespace zPDF;

/// <summary>Minimal PDFium bindings for page rendering.</summary>
internal static partial class Native
{
    private const string Lib = "pdfium";

    [LibraryImport(Lib)] public static partial void FPDF_InitLibrary();
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr FPDF_LoadMemDocument64(IntPtr data, nuint size, string? password);
    [LibraryImport(Lib)] public static partial void FPDF_CloseDocument(IntPtr document);
    [LibraryImport(Lib)] public static partial uint FPDF_GetLastError();
    [LibraryImport(Lib)] public static partial int FPDF_GetPageCount(IntPtr document);
    [LibraryImport(Lib)] public static partial IntPtr FPDF_LoadPage(IntPtr document, int index);
    [LibraryImport(Lib)] public static partial void FPDF_ClosePage(IntPtr page);
    [LibraryImport(Lib)] public static partial float FPDF_GetPageWidthF(IntPtr page);
    [LibraryImport(Lib)] public static partial float FPDF_GetPageHeightF(IntPtr page);
    [LibraryImport(Lib)] public static partial IntPtr FPDFBitmap_Create(int width, int height, int alpha);
    [LibraryImport(Lib)] public static partial void FPDFBitmap_Destroy(IntPtr bitmap);
    [LibraryImport(Lib)] public static partial int FPDFBitmap_FillRect(IntPtr bitmap, int left, int top, int width, int height, uint color);
    [LibraryImport(Lib)] public static partial IntPtr FPDFBitmap_GetBuffer(IntPtr bitmap);
    [LibraryImport(Lib)] public static partial int FPDFBitmap_GetStride(IntPtr bitmap);
    [LibraryImport(Lib)]
    public static partial void FPDF_RenderPageBitmap(IntPtr bitmap, IntPtr page, int x, int y, int width, int height, int rotate, int flags);
}

/// <summary>A rendered page: top-down BGRA pixels.</summary>
public sealed record PageImage(int Width, int Height, byte[] Pixels);

/// <summary>A PDF opened from memory, so the file itself is never held open
/// (Windows would otherwise block replacing it on Save).</summary>
public sealed class PdfDocument : IDisposable
{
    private const int RenderAnnotations = 0x01, RenderLcdText = 0x02;
    private static readonly object Gate = new();
    private static bool _initialized;

    private IntPtr _handle;
    private IntPtr _data;

    public int PageCount { get; }

    private PdfDocument(IntPtr handle, IntPtr data)
    {
        _handle = handle;
        _data = data;
        PageCount = Native.FPDF_GetPageCount(handle);
    }

    public static PdfDocument Open(string path, string? password = null)
    {
        var bytes = File.ReadAllBytes(path);
        lock (Gate)
        {
            if (!_initialized) { Native.FPDF_InitLibrary(); _initialized = true; }
            var data = Marshal.AllocHGlobal(bytes.Length);
            Marshal.Copy(bytes, 0, data, bytes.Length);
            var handle = Native.FPDF_LoadMemDocument64(data, (nuint)bytes.Length, password);
            if (handle == IntPtr.Zero)
            {
                var error = Native.FPDF_GetLastError();
                Marshal.FreeHGlobal(data);
                throw new InvalidDataException(error switch
                {
                    3 => "This file isn't a PDF, or it's damaged.",
                    4 => "This PDF needs a password.",
                    _ => $"PDFium couldn't open this PDF (error {error}).",
                });
            }
            return new PdfDocument(handle, data);
        }
    }

    /// <summary>Page size in points (1/72 inch).</summary>
    public (double Width, double Height) PageSize(int index)
    {
        lock (Gate)
        {
            var page = LoadPage(index);
            try { return (Native.FPDF_GetPageWidthF(page), Native.FPDF_GetPageHeightF(page)); }
            finally { Native.FPDF_ClosePage(page); }
        }
    }

    /// <summary>Renders a page at `scale` pixels per point, annotations included.</summary>
    public PageImage Render(int index, double scale)
    {
        lock (Gate)
        {
            var page = LoadPage(index);
            try
            {
                var width = Math.Max(1, (int)Math.Round(Native.FPDF_GetPageWidthF(page) * scale));
                var height = Math.Max(1, (int)Math.Round(Native.FPDF_GetPageHeightF(page) * scale));
                var bitmap = Native.FPDFBitmap_Create(width, height, 0);
                if (bitmap == IntPtr.Zero) throw new OutOfMemoryException("The page is too large to draw.");
                try
                {
                    Native.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF);
                    Native.FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, RenderAnnotations | RenderLcdText);
                    var stride = Native.FPDFBitmap_GetStride(bitmap);
                    var pixels = new byte[width * height * 4];
                    var buffer = Native.FPDFBitmap_GetBuffer(bitmap);
                    for (var row = 0; row < height; row++)
                        Marshal.Copy(buffer + row * stride, pixels, row * width * 4, width * 4);
                    return new PageImage(width, height, pixels);
                }
                finally { Native.FPDFBitmap_Destroy(bitmap); }
            }
            finally { Native.FPDF_ClosePage(page); }
        }
    }

    private IntPtr LoadPage(int index)
    {
        ObjectDisposedException.ThrowIf(_handle == IntPtr.Zero, this);
        if (index < 0 || index >= PageCount) throw new ArgumentOutOfRangeException(nameof(index));
        var page = Native.FPDF_LoadPage(_handle, index);
        if (page == IntPtr.Zero) throw new InvalidDataException($"PDFium couldn't load page {index + 1}.");
        return page;
    }

    public void Dispose()
    {
        lock (Gate)
        {
            if (_handle != IntPtr.Zero) { Native.FPDF_CloseDocument(_handle); _handle = IntPtr.Zero; }
            if (_data != IntPtr.Zero) { Marshal.FreeHGlobal(_data); _data = IntPtr.Zero; }
        }
    }
}
