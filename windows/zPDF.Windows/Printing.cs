using System.Runtime.InteropServices;

namespace zPDF;

/// <summary>Printing through the standard Windows print dialog. PDFium draws each page
/// straight into the printer's device context, so text and vector art stay sharp at
/// the printer's resolution.</summary>
internal static partial class Printing
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PrintDlgEx
    {
        public int lStructSize;
        public IntPtr hwndOwner, hDevMode, hDevNames, hDC;
        public uint Flags, Flags2, ExclusionFlags, nPageRanges, nMaxPageRanges;
        public IntPtr lpPageRanges;
        public uint nMinPage, nMaxPage, nCopies;
        public IntPtr hInstance, lpPrintTemplateName, lpCallback;
        public uint nPropertyPages;
        public IntPtr lphPropertyPages;
        public uint nStartPage, dwResultAction;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PageRange { public uint From, To; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DocInfo
    {
        public int cbSize;
        public string lpszDocName;
        public string? lpszOutput, lpszDatatype;
        public uint fwType;
    }

    private const uint PD_PAGENUMS = 0x2, PD_NOSELECTION = 0x4, PD_RETURNDC = 0x100, PD_USEDEVMODECOPIESANDCOLLATE = 0x40000,
                       PD_CURRENTPAGE = 0x400000, StartPageGeneral = 0xFFFFFFFF, ResultPrint = 1;
    private const int HORZRES = 8, VERTRES = 10, LOGPIXELSX = 88, LOGPIXELSY = 90;
    private const int RenderAnnotations = 0x01, RenderPrinting = 0x800;

    [DllImport("comdlg32.dll", CharSet = CharSet.Unicode)] private static extern int PrintDlgExW(ref PrintDlgEx pd);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] private static extern int StartDocW(IntPtr hdc, ref DocInfo di);
    [DllImport("gdi32.dll")] private static extern int StartPage(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern int EndPage(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern int EndDoc(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern int AbortDoc(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern int GetDeviceCaps(IntPtr hdc, int index);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateDCW(string? driver, string device, string? output, IntPtr devMode);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalFree(IntPtr handle);
    [DllImport("pdfium")] private static extern void FPDF_RenderPage(IntPtr hdc, IntPtr page, int x, int y, int w, int h, int rotate, int flags);

    public sealed record Job(IntPtr Dc, List<int> Pages);

    /// <summary>Shows the print dialog. Returns the printer and pages, or null if cancelled.</summary>
    public static Job? Ask(IntPtr owner, int pageCount, int currentPage)
    {
        var ranges = Marshal.AllocHGlobal(Marshal.SizeOf<PageRange>() * 16);
        var dialog = new PrintDlgEx
        {
            lStructSize = Marshal.SizeOf<PrintDlgEx>(),
            hwndOwner = owner,
            Flags = PD_RETURNDC | PD_NOSELECTION | PD_USEDEVMODECOPIESANDCOLLATE,
            nMaxPageRanges = 16,
            lpPageRanges = ranges,
            nMinPage = 1,
            nMaxPage = (uint)pageCount,
            nCopies = 1,
            nStartPage = StartPageGeneral,
        };
        try
        {
            if (PrintDlgExW(ref dialog) != 0 || dialog.dwResultAction != ResultPrint || dialog.hDC == IntPtr.Zero)
            {
                if (dialog.hDC != IntPtr.Zero) DeleteDC(dialog.hDC);
                return null;
            }
            var pages = new List<int>();
            if ((dialog.Flags & PD_CURRENTPAGE) != 0) pages.Add(currentPage);
            else if ((dialog.Flags & PD_PAGENUMS) != 0)
            {
                for (var i = 0; i < dialog.nPageRanges; i++)
                {
                    var range = Marshal.PtrToStructure<PageRange>(ranges + i * Marshal.SizeOf<PageRange>());
                    for (var p = range.From; p <= range.To && p <= pageCount; p++) pages.Add((int)p - 1);
                }
            }
            else pages.AddRange(Enumerable.Range(0, pageCount));
            return new Job(dialog.hDC, pages);
        }
        finally
        {
            Marshal.FreeHGlobal(ranges);
            if (dialog.hDevMode != IntPtr.Zero) GlobalFree(dialog.hDevMode);
            if (dialog.hDevNames != IntPtr.Zero) GlobalFree(dialog.hDevNames);
        }
    }

    /// <summary>A job for a named printer without the dialog (`output`: print to that file,
    /// for drivers such as "Microsoft Print to PDF").</summary>
    public static Job ForPrinter(string printer, IEnumerable<int> pages) =>
        new(CreateDCW(null, printer, null, IntPtr.Zero) is var dc && dc != IntPtr.Zero
            ? dc : throw new IOException($"The printer \"{printer}\" isn't available."), pages.ToList());

    /// <summary>Prints `job.Pages`, each scaled to fit the printable area and turned to match
    /// the paper's orientation. Runs off the UI thread; `progress` gets pages done.</summary>
    public static void Print(PdfDocument document, Job job, string title, string? output = null, IProgress<int>? progress = null)
    {
        var info = new DocInfo { cbSize = Marshal.SizeOf<DocInfo>(), lpszDocName = title, lpszOutput = output };
        try
        {
            if (StartDocW(job.Dc, ref info) <= 0) throw new IOException("The printer didn't accept the job.");
            int width = GetDeviceCaps(job.Dc, HORZRES), height = GetDeviceCaps(job.Dc, VERTRES);
            double dpiX = GetDeviceCaps(job.Dc, LOGPIXELSX), dpiY = GetDeviceCaps(job.Dc, LOGPIXELSY);
            var done = 0;
            foreach (var index in job.Pages)
            {
                if (StartPage(job.Dc) <= 0) throw new IOException("The printer stopped accepting pages.");
                document.WithPage(index, page =>
                {
                    var (w, h) = (Native.FPDF_GetPageWidthF(page), Native.FPDF_GetPageHeightF(page));
                    // Turn landscape pages on portrait paper (and vice versa) to use the sheet.
                    var turn = (w > h) != (width > height);
                    double pw = (turn ? h : w) / 72 * dpiX, ph = (turn ? w : h) / 72 * dpiY;
                    var scale = Math.Min(1, Math.Min(width / pw, height / ph));  // shrink to fit, never enlarge
                    int sw = (int)(pw * scale), sh = (int)(ph * scale);
                    FPDF_RenderPage(job.Dc, page, (width - sw) / 2, (height - sh) / 2, sw, sh, turn ? 1 : 0,
                                    RenderAnnotations | RenderPrinting);
                });
                if (EndPage(job.Dc) <= 0) throw new IOException("The printer stopped accepting pages.");
                progress?.Report(++done);
            }
            EndDoc(job.Dc);
        }
        catch
        {
            AbortDoc(job.Dc);
            throw;
        }
        finally
        {
            DeleteDC(job.Dc);
        }
    }
}
