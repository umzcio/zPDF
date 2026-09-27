namespace zPDF;

/// <summary>Word-level differences for Compare.</summary>
internal static class TextDiff
{
    /// <summary>Myers diff: the (oldStart, oldCount, newStart, newCount) runs that differ.
    /// Only the band of the search vector each step reads is kept (d² memory, not d·(n+m)).</summary>
    public static List<(int, int, int, int)> Diff(string[] a, string[] b)
    {
        int n = a.Length, m = b.Length, max = n + m;
        const int maxEdits = 4000;  // beyond this, report the rest as one change
        var v = new int[2 * max + 2];
        var trace = new List<int[]>();  // trace[d][k + d] = v[k] before step d, for k in [-d, d]
        for (var d = 0; d <= Math.Min(max, maxEdits); d++)
        {
            var band = new int[2 * d + 1];
            for (var k = -d; k <= d; k++) band[k + d] = v[max + k];
            trace.Add(band);
            for (var k = -d; k <= d; k += 2)
            {
                var x = k == -d || (k != d && v[max + k - 1] < v[max + k + 1]) ? v[max + k + 1] : v[max + k - 1] + 1;
                var y = x - k;
                while (x < n && y < m && a[x] == b[y]) { x++; y++; }
                v[max + k] = x;
                if (x >= n && y >= m) return Runs(Backtrack(trace, n, m), n, m);
            }
        }
        return [(0, n, 0, m)];
    }

    private static List<(int X, int Y)> Backtrack(List<int[]> trace, int n, int m)
    {
        var equal = new List<(int, int)>();
        int x = n, y = m;
        for (var d = trace.Count - 1; d > 0; d--)
        {
            var band = trace[d];
            int V(int k) => band[k + d];
            var k0 = x - y;
            var prevK = k0 == -d || (k0 != d && V(k0 - 1) < V(k0 + 1)) ? k0 + 1 : k0 - 1;
            var prevX = V(prevK);
            var prevY = prevX - prevK;
            while (x > prevX && y > prevY) { x--; y--; equal.Add((x, y)); }  // a diagonal: equal words
            x = prevX; y = prevY;
        }
        while (x > 0 && y > 0) { x--; y--; equal.Add((x, y)); }
        equal.Reverse();
        return equal;
    }

    /// <summary>Matched (equal) positions → the runs between them.</summary>
    private static List<(int, int, int, int)> Runs(List<(int X, int Y)> equal, int n, int m)
    {
        var runs = new List<(int, int, int, int)>();
        int ai = 0, bi = 0;
        foreach (var (x, y) in equal.Append((n, m)))
        {
            if (x > ai || y > bi) runs.Add((ai, x - ai, bi, y - bi));
            ai = x + 1; bi = y + 1;
        }
        return runs;
    }
}
