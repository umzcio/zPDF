using System.Runtime.InteropServices;
using System.Text;
using Windows.Foundation;

namespace zPDF;

internal static partial class Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct FSRectF { public float Left, Top, Right, Bottom; }

    [LibraryImport(Lib)] public static partial int FPDFPage_GetRotation(IntPtr page);
    [LibraryImport(Lib)]
    public static partial int FPDF_PageToDevice(IntPtr page, int startX, int startY, int sizeX, int sizeY, int rotate,
                                                double pageX, double pageY, out int deviceX, out int deviceY);
    [LibraryImport(Lib)] public static partial IntPtr FPDFText_LoadPage(IntPtr page);
    [LibraryImport(Lib)] public static partial void FPDFText_ClosePage(IntPtr textPage);
    [LibraryImport(Lib)] public static partial int FPDFText_CountChars(IntPtr textPage);
    [LibraryImport(Lib)] public static partial uint FPDFText_GetUnicode(IntPtr textPage, int index);
    [LibraryImport(Lib)] public static partial int FPDFText_GetLooseCharBox(IntPtr textPage, int index, out FSRectF rect);
    [LibraryImport(Lib)] public static partial int FPDFLink_Enumerate(IntPtr page, ref int startPos, out IntPtr link);
    [LibraryImport(Lib)] public static partial int FPDFLink_GetAnnotRect(IntPtr link, out FSRectF rect);
    [LibraryImport(Lib)] public static partial IntPtr FPDFLink_GetDest(IntPtr document, IntPtr link);
    [LibraryImport(Lib)] public static partial IntPtr FPDFLink_GetAction(IntPtr link);
    [LibraryImport(Lib)] public static partial uint FPDFAction_GetType(IntPtr action);
    [LibraryImport(Lib)] public static partial IntPtr FPDFAction_GetDest(IntPtr document, IntPtr action);
    [LibraryImport(Lib)] public static partial uint FPDFAction_GetURIPath(IntPtr document, IntPtr action, byte[]? buffer, uint length);
    [LibraryImport(Lib)] public static partial int FPDFDest_GetDestPageIndex(IntPtr document, IntPtr dest);
    [LibraryImport(Lib)] public static partial IntPtr FPDFBookmark_GetFirstChild(IntPtr document, IntPtr bookmark);
    [LibraryImport(Lib)] public static partial IntPtr FPDFBookmark_GetNextSibling(IntPtr document, IntPtr bookmark);
    [LibraryImport(Lib)] public static partial uint FPDFBookmark_GetTitle(IntPtr bookmark, byte[]? buffer, uint length);
    [LibraryImport(Lib)] public static partial IntPtr FPDFBookmark_GetDest(IntPtr document, IntPtr bookmark);
    [LibraryImport(Lib)] public static partial IntPtr FPDFBookmark_GetAction(IntPtr bookmark);
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    public static partial uint FPDF_GetMetaText(IntPtr document, string tag, byte[]? buffer, uint length);
    [LibraryImport(Lib)] public static partial int FPDF_GetFileVersion(IntPtr document, out int version);
    [LibraryImport(Lib)] public static partial uint FPDF_GetPageLabel(IntPtr document, int index, byte[]? buffer, uint length);
    [LibraryImport(Lib)] public static partial int FPDF_GetSecurityHandlerRevision(IntPtr document);
    [LibraryImport(Lib)] public static partial uint FPDF_GetDocPermissions(IntPtr document);

    /// <summary>Calls a PDFium "fill this buffer, return the size" function; UTF-16LE text.</summary>
    public static string Utf16(Func<byte[]?, uint, uint> call)
    {
        var size = call(null, 0);
        if (size <= 2) return "";
        var buffer = new byte[size];
        call(buffer, size);
        return Encoding.Unicode.GetString(buffer, 0, (int)size - 2);
    }
}

/// <summary>A link on a page: a page jump or a web address.</summary>
public sealed record PageLink(Rect Bounds, int? TargetPage, string? Uri);

/// <summary>An outline (bookmark) entry.</summary>
public sealed record OutlineItem(string Title, int? TargetPage, string? Uri, IReadOnlyList<OutlineItem> Children);

/// <summary>Everything about a page that interaction needs, read once from PDFium so
/// hit-testing, selection and search never wait on a render.</summary>
public sealed class PageInfo
{
    // Page (PDF user space, points) → view (points, top-left origin, y down, page rotation applied).
    private readonly double _a, _b, _c, _d, _tx, _ty;
    private readonly double _ia, _ib, _ic, _id;

    public double Width { get; }   // view size in points (after rotation)
    public double Height { get; }
    public string Text { get; }    // one UTF-16 string for search/copy
    public int[] CharAt { get; }   // Text position → PDFium char index
    public int[] TextAt { get; }   // PDFium char index → first Text position
    public Rect[] Boxes { get; }   // per char, in view points (empty for generated chars)
    public IReadOnlyList<PageLink> Links { get; }

    internal PageInfo(double width, double height, (double a, double b, double c, double d, double tx, double ty) m,
                      string text, int[] charAt, int[] textAt, Rect[] pageBoxes, List<(Native.FSRectF rect, int? page, string? uri)> links)
    {
        Width = width; Height = height;
        (_a, _b, _c, _d, _tx, _ty) = m;
        var det = _a * _d - _b * _c;
        (_ia, _ib, _ic, _id) = (_d / det, -_b / det, -_c / det, _a / det);
        Text = text; CharAt = charAt; TextAt = textAt;
        Boxes = pageBoxes.Select(r => r.IsEmpty ? Rect.Empty : ToView(r)).ToArray();
        Links = links.Select(l => new PageLink(ToView(new Rect(new Point(l.rect.Left, l.rect.Top), new Point(l.rect.Right, l.rect.Bottom))),
                                              l.page, l.uri)).ToList();
    }

    public Point ToView(double x, double y) => new(_a * x + _c * y + _tx, _b * x + _d * y + _ty);

    public Point ToPage(Point view)
    {
        double x = view.X - _tx, y = view.Y - _ty;
        return new Point(_ia * x + _ic * y, _ib * x + _id * y);
    }

    public Rect ToView(Rect page)
    {
        var p1 = ToView(page.Left, page.Top);
        var p2 = ToView(page.Right, page.Bottom);
        return new Rect(p1, p2);
    }

    /// <summary>The char under `view` (points), or the nearest on the same line within `slack`.</summary>
    public int CharIndexAt(Point view, double slack = 4)
    {
        var best = -1;
        var bestDistance = slack;
        for (var i = 0; i < Boxes.Length; i++)
        {
            var box = Boxes[i];
            if (box.IsEmpty) continue;
            if (box.Contains(view)) return i;
            var dx = Math.Max(0, Math.Max(box.Left - view.X, view.X - box.Right));
            var dy = Math.Max(0, Math.Max(box.Top - view.Y, view.Y - box.Bottom));
            var distance = Math.Sqrt(dx * dx + dy * dy);
            if (distance < bestDistance) { bestDistance = distance; best = i; }
        }
        return best;
    }

    public bool IsOverText(Point view) => CharIndexAt(view, 1) >= 0;

    public PageLink? LinkAt(Point view) => Links.FirstOrDefault(l => l.Bounds.Contains(view));

    /// <summary>Line-merged rectangles (view points) covering chars [first, last].</summary>
    public List<Rect> RectsFor(int first, int last)
    {
        var rects = new List<Rect>();
        Rect? line = null;
        for (var i = Math.Max(0, first); i <= Math.Min(last, Boxes.Length - 1); i++)
        {
            var box = Boxes[i];
            if (box.IsEmpty) continue;
            if (line is { } current && Math.Abs(current.Top - box.Top) < current.Height * 0.6
                                    && Math.Abs(current.Bottom - box.Bottom) < current.Height * 0.6
                                    && box.Left >= current.Left - 1)
            {
                var merged = current;
                merged.Union(box);
                line = merged;
            }
            else
            {
                if (line is { } done) rects.Add(done);
                line = box;
            }
        }
        if (line is { } last2) rects.Add(last2);
        return rects;
    }

    /// <summary>The text of chars [first, last].</summary>
    public string TextOf(int first, int last)
    {
        if (Boxes.Length == 0 || first > last) return "";
        first = Math.Clamp(first, 0, TextAt.Length - 1);
        last = Math.Clamp(last, 0, TextAt.Length - 1);
        var end = last + 1 < TextAt.Length ? TextAt[last + 1] : Text.Length;
        return Text[TextAt[first]..end];
    }
}

public sealed partial class PdfDocument
{
    private const uint ActionGoto = 1, ActionUri = 3;

    /// <summary>Reads a page's text, char boxes, links and coordinate mapping.</summary>
    public PageInfo LoadPageInfo(int index)
    {
        lock (Gate)
        {
            var page = LoadPage(index);
            var textPage = IntPtr.Zero;
            try
            {
                double w = Native.FPDF_GetPageWidthF(page), h = Native.FPDF_GetPageHeightF(page);
                // Affine map from two basis vectors, at 1/100 pt resolution (PDFium returns ints).
                const int scale = 100;
                int sx = (int)Math.Round(w * scale), sy = (int)Math.Round(h * scale);
                Native.FPDF_PageToDevice(page, 0, 0, sx, sy, 0, 0, 0, out var ox, out var oy);
                Native.FPDF_PageToDevice(page, 0, 0, sx, sy, 0, 1000, 0, out var xx, out var xy);
                Native.FPDF_PageToDevice(page, 0, 0, sx, sy, 0, 0, 1000, out var yx, out var yy);
                var m = ((xx - ox) / (1000.0 * scale), (xy - oy) / (1000.0 * scale),
                         (yx - ox) / (1000.0 * scale), (yy - oy) / (1000.0 * scale), ox / (double)scale, oy / (double)scale);

                textPage = Native.FPDFText_LoadPage(page);
                var count = textPage == IntPtr.Zero ? 0 : Native.FPDFText_CountChars(textPage);
                var text = new StringBuilder(count);
                var charAt = new List<int>(count);
                var textAt = new int[count];
                var boxes = new Rect[count];
                for (var i = 0; i < count; i++)
                {
                    textAt[i] = text.Length;
                    var code = Native.FPDFText_GetUnicode(textPage, i);
                    var s = code is 0 or > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF) ? " " : char.ConvertFromUtf32((int)code);
                    text.Append(s);
                    for (var k = 0; k < s.Length; k++) charAt.Add(i);
                    boxes[i] = Native.FPDFText_GetLooseCharBox(textPage, i, out var r) != 0 && r.Right > r.Left
                        ? new Rect(new Point(r.Left, r.Top), new Point(r.Right, r.Bottom))
                        : Rect.Empty;
                }

                var links = new List<(Native.FSRectF, int?, string?)>();
                var position = 0;
                while (Native.FPDFLink_Enumerate(page, ref position, out var link) != 0)
                {
                    if (Native.FPDFLink_GetAnnotRect(link, out var rect) == 0) continue;
                    var (target, uri) = Resolve(Native.FPDFLink_GetDest(_handle, link), Native.FPDFLink_GetAction(link));
                    if (target is not null || uri is not null) links.Add((rect, target, uri));
                }
                return new PageInfo(w, h, m, text.ToString(), charAt.ToArray(), textAt, boxes, links);
            }
            finally
            {
                if (textPage != IntPtr.Zero) Native.FPDFText_ClosePage(textPage);
                Native.FPDF_ClosePage(page);
            }
        }
    }

    /// <summary>The document outline (bookmarks), depth- and cycle-limited.</summary>
    public IReadOnlyList<OutlineItem> Outline()
    {
        lock (Gate)
        {
            var seen = new HashSet<IntPtr>();
            List<OutlineItem> Read(IntPtr parent, int depth)
            {
                var items = new List<OutlineItem>();
                if (depth > 32) return items;
                for (var bm = Native.FPDFBookmark_GetFirstChild(_handle, parent);
                     bm != IntPtr.Zero && items.Count < 5000 && seen.Add(bm);
                     bm = Native.FPDFBookmark_GetNextSibling(_handle, bm))
                {
                    var title = Native.Utf16((b, n) => Native.FPDFBookmark_GetTitle(bm, b, n));
                    var (target, uri) = Resolve(Native.FPDFBookmark_GetDest(_handle, bm), Native.FPDFBookmark_GetAction(bm));
                    items.Add(new OutlineItem(string.IsNullOrWhiteSpace(title) ? "(Untitled)" : title.Trim(), target, uri, Read(bm, depth + 1)));
                }
                return items;
            }
            return _handle == IntPtr.Zero ? [] : Read(IntPtr.Zero, 0);
        }
    }

    /// <summary>Title, author, etc. plus version and security, for Document Properties.</summary>
    public (Dictionary<string, string> Info, string Version, bool Encrypted, uint Permissions) Properties()
    {
        lock (Gate)
        {
            var info = new Dictionary<string, string>();
            foreach (var tag in new[] { "Title", "Author", "Subject", "Keywords", "Creator", "Producer", "CreationDate", "ModDate" })
                info[tag] = Native.Utf16((b, n) => Native.FPDF_GetMetaText(_handle, tag, b, n));
            Native.FPDF_GetFileVersion(_handle, out var version);
            return (info, $"{version / 10}.{version % 10}", Native.FPDF_GetSecurityHandlerRevision(_handle) >= 0,
                    Native.FPDF_GetDocPermissions(_handle));
        }
    }

    /// <summary>Runs `action` with a loaded PDFium page, under the document lock.</summary>
    public void WithPage(int index, Action<IntPtr> action)
    {
        lock (Gate)
        {
            var page = LoadPage(index);
            try { action(page); }
            finally { Native.FPDF_ClosePage(page); }
        }
    }

    public string PageLabel(int index)
    {
        lock (Gate) return Native.Utf16((b, n) => Native.FPDF_GetPageLabel(_handle, index, b, n));
    }

    private (int? Page, string? Uri) Resolve(IntPtr dest, IntPtr action)
    {
        if (dest == IntPtr.Zero && action != IntPtr.Zero && Native.FPDFAction_GetType(action) == ActionGoto)
            dest = Native.FPDFAction_GetDest(_handle, action);
        if (dest != IntPtr.Zero)
        {
            var index = Native.FPDFDest_GetDestPageIndex(_handle, dest);
            return (index >= 0 && index < PageCount ? index : null, null);
        }
        if (action != IntPtr.Zero && Native.FPDFAction_GetType(action) == ActionUri)
        {
            var size = Native.FPDFAction_GetURIPath(_handle, action, null, 0);
            if (size > 1)
            {
                var buffer = new byte[size];
                Native.FPDFAction_GetURIPath(_handle, action, buffer, size);
                return (null, Encoding.ASCII.GetString(buffer, 0, (int)size - 1));
            }
        }
        return (null, null);
    }
}
