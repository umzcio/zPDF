using Microsoft.Win32;

namespace zPDF;

/// <summary>Per-user registration so PDFs can be opened with zPDF (Open with, Default apps).
/// Windows only lets the user choose the default app, so this registers zPDF and opens
/// its page in Settings.</summary>
internal static class FileAssociation
{
    private const string ProgId = "zPDF.Document";
    private const string Capabilities = @"Software\zPDF\Capabilities";

    public static void Register()
    {
        var exe = Environment.ProcessPath ?? throw new InvalidOperationException("zPDF's location is unknown.");
        using (var prog = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{ProgId}"))
        {
            prog.SetValue("", "PDF Document");
            using (var icon = prog.CreateSubKey("DefaultIcon")) icon.SetValue("", $"\"{exe}\",0");
            using var command = prog.CreateSubKey(@"shell\open\command");
            command.SetValue("", $"\"{exe}\" \"%1\"");
        }
        using (var ext = Registry.CurrentUser.CreateSubKey(@"Software\Classes\.pdf\OpenWithProgids")) ext.SetValue(ProgId, Array.Empty<byte>(), RegistryValueKind.None);
        using (var app = Registry.CurrentUser.CreateSubKey(@"Software\Classes\Applications\zPDF.exe"))
        {
            app.SetValue("FriendlyAppName", "zPDF");
            using (var types = app.CreateSubKey("SupportedTypes")) types.SetValue(".pdf", "");
            using var command = app.CreateSubKey(@"shell\open\command");
            command.SetValue("", $"\"{exe}\" \"%1\"");
        }
        using (var caps = Registry.CurrentUser.CreateSubKey(Capabilities))
        {
            caps.SetValue("ApplicationName", "zPDF");
            caps.SetValue("ApplicationDescription", "Read, comment, fill and sign, edit, redact, organize, convert and protect PDFs.");
            using var files = caps.CreateSubKey("FileAssociations");
            files.SetValue(".pdf", ProgId);
        }
        using (var registered = Registry.CurrentUser.CreateSubKey(@"Software\RegisteredApplications")) registered.SetValue("zPDF", Capabilities);
        SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero);  // SHCNE_ASSOCCHANGED
    }

    public static bool IsRegistered()
    {
        using var command = Registry.CurrentUser.OpenSubKey($@"Software\Classes\{ProgId}\shell\open\command");
        return command?.GetValue("") is string value && Environment.ProcessPath is { } exe && value.Contains(exe, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Settings ▸ Default apps, on zPDF's page where available.</summary>
    public static Task OpenDefaultAppsSettingsAsync() =>
        Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:defaultapps?registeredAppUser=zPDF")).AsTask();

    [System.Runtime.InteropServices.DllImport("shell32.dll")]
    private static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
}
