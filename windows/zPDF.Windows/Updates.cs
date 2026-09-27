using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Velopack;
using Velopack.Sources;

namespace zPDF;

/// <summary>Updates from zPDF's GitHub Releases ("win" channel), installed by Velopack.
/// Checks quietly once a day and on request; installing always asks first.</summary>
internal static class Updates
{
    private const string Repository = "https://github.com/umzcio/zPDF";
    private static bool _offered;

    /// <summary>GitHub Releases, or (for testing an update end to end) a local folder of
    /// packages named by ZPDF_UPDATE_SOURCE.</summary>
    private static UpdateManager Manager() =>
        Environment.GetEnvironmentVariable("ZPDF_UPDATE_SOURCE") is { Length: > 0 } local && Directory.Exists(local)
            ? new(new SimpleFileSource(new DirectoryInfo(local)))
            : new(new GithubSource(Repository, null, false));

    public static async Task CheckInBackgroundAsync(DocumentPane window)
    {
        var settings = AppSettings.Current;
        if (_offered || DateTime.UtcNow - settings.LastUpdateCheck < TimeSpan.FromDays(1)) return;
        await Task.Delay(TimeSpan.FromSeconds(20));  // not during startup
        await CheckAsync(window, quiet: true);
    }

    public static async Task CheckAsync(DocumentPane window, bool quiet)
    {
        var manager = Manager();
        if (!manager.IsInstalled)
        {
            if (!quiet) await window.InfoAsync("Updates", "Updates work in the installed version of zPDF (this is a development build).");
            return;
        }
        UpdateInfo? update;
        try { update = await manager.CheckForUpdatesAsync(); }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or InvalidOperationException or IOException)
        {
            if (!quiet) await window.InfoAsync("Updates", "zPDF couldn't check for updates. Check your internet connection and try again.");
            return;
        }
        AppSettings.Current.LastUpdateCheck = DateTime.UtcNow;
        AppSettings.Current.Save();
        if (update is null)
        {
            if (!quiet) await window.InfoAsync("Updates", $"zPDF {DocumentPane.Version} is the latest version.");
            return;
        }
        _offered = true;
        var version = update.TargetFullRelease.Version.ToString();
        if (!await window.ConfirmAsync($"zPDF {version} is available", "Download it now? zPDF restarts to finish installing (you'll be asked to save changes first).", "Update")) return;
        await manager.DownloadUpdatesAsync(update);
        if (await window.PrepareToQuitAsync()) manager.ApplyUpdatesAndRestart(update.TargetFullRelease);
    }
}
