using System.Text.Json;

namespace zPDF;

/// <summary>Per-user settings in %LOCALAPPDATA%\zPDF\settings.json (unpackaged apps
/// have no ApplicationData store). Missing or unreadable settings fall back to defaults.</summary>
public sealed class AppSettings
{
    private const int MaxRecent = 15;
    private static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "zPDF");
    private static readonly string FilePath = Path.Combine(Folder, "settings.json");
    private static AppSettings? _current;

    public List<string> RecentFiles { get; set; } = [];
    /// <summary>Name on new comments, signatures' "signed by" and replies (empty: the Windows user name).</summary>
    public string AuthorName { get; set; } = "";
    public bool FitWidthOnOpen { get; set; } = true;
    public bool HighlightFields { get; set; } = true;
    public bool OpenInNewWindow { get; set; } = true;

    public static AppSettings Current => _current ??= Load();

    private static AppSettings Load()
    {
        try { return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings(); }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return new AppSettings(); }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Folder);
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temp, FilePath, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    public void AddRecent(string path)
    {
        RecentFiles.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
        RecentFiles.Insert(0, path);
        if (RecentFiles.Count > MaxRecent) RecentFiles.RemoveRange(MaxRecent, RecentFiles.Count - MaxRecent);
        Save();
    }

    public void RemoveRecent(string path)
    {
        if (RecentFiles.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase)) > 0) Save();
    }

    public void ClearRecent()
    {
        RecentFiles.Clear();
        Save();
    }
}
