using System.Security.Cryptography;
using System.Text.Json;

namespace zPDF;

/// <summary>A stored digital ID: a password-protected PKCS#12 plus display details.</summary>
public sealed record DigitalId(string Id, string Name, string Email, string Issuer, string Expires, string P12);

/// <summary>Per-user digital IDs in %LOCALAPPDATA%\zPDF\ids. Each file is the ID's own
/// password-protected .p12, additionally encrypted for this Windows user (DPAPI).</summary>
internal static class DigitalIds
{
    private static readonly string Folder = Path.Combine(AppSettings.DataFolder, "ids");

    public static List<DigitalId> All()
    {
        if (!Directory.Exists(Folder)) return [];
        var ids = new List<DigitalId>();
        foreach (var file in Directory.EnumerateFiles(Folder, "*.id"))
        {
            try
            {
                var json = ProtectedData.Unprotect(File.ReadAllBytes(file), null, DataProtectionScope.CurrentUser);
                if (JsonSerializer.Deserialize<DigitalId>(json) is { } id) ids.Add(id);
            }
            catch (Exception error) when (error is CryptographicException or JsonException or IOException) { }
        }
        return ids.OrderBy(i => i.Name).ToList();
    }

    public static void Save(DigitalId id)
    {
        Directory.CreateDirectory(Folder);
        var bytes = ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(id), null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(Path.Combine(Folder, id.Id + ".id"), bytes);
    }

    public static void Delete(DigitalId id)
    {
        try { File.Delete(Path.Combine(Folder, id.Id + ".id")); } catch (IOException) { }
    }
}
