using System.Text.Json;

namespace zPDF;

/// <summary>Per-user settings in %LOCALAPPDATA%\zPDF\settings.json (unpackaged apps
/// have no ApplicationData store). Missing or unreadable settings fall back to defaults.</summary>
public sealed class AppSettings
{
    private const int MaxRecent = 15;
    /// <summary>zPDF's own data (settings, saved signatures, digital IDs, error log), in
    /// %APPDATA%\zPDF. Not %LOCALAPPDATA%\zPDF: that is where the installer puts the app,
    /// and installing, repairing or uninstalling replaces that folder.</summary>
    public static readonly string DataFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "zPDF");
    private static readonly string Folder = DataFolder;

    /// <summary>Moves data written by earlier builds out of %LOCALAPPDATA%\zPDF (only zPDF's
    /// own files; never the installed app), then removes that folder if nothing else is left.</summary>
    public static void MigrateDataFolder()
    {
        var old = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "zPDF");
        try
        {
            if (!Directory.Exists(old)) return;
            Directory.CreateDirectory(DataFolder);
            foreach (var name in new[] { "settings.json", "signature.png", "initials.png", "errors.log" })
            {
                var (from, to) = (Path.Combine(old, name), Path.Combine(DataFolder, name));
                if (File.Exists(from) && !File.Exists(to)) File.Move(from, to);
            }
            var ids = Path.Combine(old, "ids");
            if (Directory.Exists(ids))
            {
                var target = Path.Combine(DataFolder, "ids");
                Directory.CreateDirectory(target);
                foreach (var file in Directory.GetFiles(ids))
                    if (Path.Combine(target, Path.GetFileName(file)) is var to && !File.Exists(to)) File.Move(file, to);
                if (!Directory.EnumerateFileSystemEntries(ids).Any()) Directory.Delete(ids);
            }
            if (!Directory.EnumerateFileSystemEntries(old).Any()) Directory.Delete(old);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
    private static readonly string FilePath = Path.Combine(Folder, "settings.json");
    private static AppSettings? _current;

    public List<string> RecentFiles { get; set; } = [];
    /// <summary>Files starred on Home.</summary>
    public List<string> StarredFiles { get; set; } = [];
    /// <summary>When each recent file was last opened (Home shows it).</summary>
    public Dictionary<string, DateTime> LastOpened { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>Name on new comments, signatures' "signed by" and replies (empty: the Windows user name).</summary>
    public string AuthorName { get; set; } = "";
    public bool FitWidthOnOpen { get; set; } = true;
    /// <summary>The page layout new documents open in: "single", "continuous" or "facing".</summary>
    public string DefaultViewMode { get; set; } = "continuous";
    public bool HighlightFields { get; set; } = true;
    public bool OpenInNewWindow { get; set; } = true;  // older setting (tabs replaced it)
    public bool OpenInTabs { get; set; } = true;
    /// <summary>The All tools drawer is open (Mac sidebarVisible; on by default).</summary>
    public bool ToolsDrawerVisible { get; set; } = true;
    public DateTime LastUpdateCheck { get; set; }
    /// <summary>The files open in each window when zPDF restarted to install an update.</summary>
    public List<List<string>> RestoreSession { get; set; } = [];
    public DateTime RestoreSessionSaved { get; set; }
    /// <summary>Saved batch actions: name → step title (and "title#n" option values) → value.</summary>
    public Dictionary<string, Dictionary<string, string>> SavedActions { get; set; } = [];

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
        LastOpened[path] = DateTime.Now;
        if (RecentFiles.Count > MaxRecent) RecentFiles.RemoveRange(MaxRecent, RecentFiles.Count - MaxRecent);
        Save();
        // Windows' own recent list, which fills zPDF's taskbar jump list (Recent).
        try { SHAddToRecentDocs(ShardPathW, path); }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException) { }
    }

    private const uint ShardPathW = 3;

    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern void SHAddToRecentDocs(uint flags, string path);

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
