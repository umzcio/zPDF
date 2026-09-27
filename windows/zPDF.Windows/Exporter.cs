using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace zPDF;

/// <summary>The document exporter (EngineSupport/export_worker.py): Word, Excel, PowerPoint,
/// HTML, Markdown, RTF, XML and EPUB. JSON lines over stdin/stdout, one job per worker.
/// The worker runs in a job object (memory cap, killed with the job) under a deadline,
/// and every output file is checked against its reported SHA-256 before publishing.</summary>
internal static partial class Exporter
{
    public sealed record Result(string Path, int Files, long Bytes, IReadOnlyList<string> Notices);

    private const long MemoryLimit = 3L * 1024 * 1024 * 1024;
    private static readonly TimeSpan Deadline = TimeSpan.FromMinutes(15);

    public static async Task<Result> ExportAsync(string input, string format, IReadOnlyList<int> pages, string destination,
                                                 JsonObject? extraOptions, IProgress<string>? progress, CancellationToken cancel)
    {
        var info = new FileInfo(input);
        if (pages.Count is 0 or > 500 || info.Length > 512L * 1024 * 1024)
            throw new EngineException("EXPORT_LIMIT", "Choose up to 500 pages from a PDF smaller than 512 MB.");
        var folder = Path.GetDirectoryName(Path.GetFullPath(destination))!;
        var staging = Directory.CreateDirectory(Path.Combine(folder, $".zpdf-export-{Guid.NewGuid():N}")).FullName;
        File.SetAttributes(staging, File.GetAttributes(staging) | FileAttributes.Hidden);
        using var job = JobObject.Create(MemoryLimit);
        using var process = Start(job);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        deadline.CancelAfter(Deadline);
        using var kill = deadline.Token.Register(() => { try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
        try
        {
            var caps = await ExchangeAsync(process, new JsonObject { ["protocol_version"] = 1, ["operation"] = "capabilities" }, _ => true, deadline.Token);
            var capability = caps["formats"]?[format];
            if (caps["protocol_version"]?.GetValue<int>() != 1 || capability?["available"]?.GetValue<bool>() != true)
                throw new EngineException("EXPORT_UNAVAILABLE", "This exporter build doesn't support that format.");
            var settings = extraOptions?.DeepClone().AsObject() ?? new JsonObject();
            var stem = new string(Path.GetFileNameWithoutExtension(destination).Select(c => char.IsAsciiLetterOrDigit(c) ? c : '_').Take(60).ToArray());
            var assetName = $"{(stem.Length > 0 ? stem : "Export")}_images_{Guid.NewGuid().ToString("N")[..8]}";
            if (format == "md") { settings["markdown_images"] = "folder"; settings["markdown_asset_folder"] = assetName; }
            var hash = Sha256(input);
            var jobId = Guid.NewGuid().ToString();
            var request = new JsonObject
            {
                ["protocol_version"] = 1, ["operation"] = "convert", ["job_id"] = jobId,
                ["snapshot"] = new JsonObject { ["path"] = input, ["sha256"] = hash }, ["staging_directory"] = staging,
                ["format"] = format, ["pages"] = new JsonArray(pages.Select(p => (JsonNode)(p + 1)).ToArray()), ["options"] = settings,
            };
            var response = await ExchangeAsync(process, request, message =>
            {
                if (message["job_id"]?.GetValue<string>() != jobId) throw new EngineException("EXPORT_INVALID", "The exporter replied out of turn.");
                if (message["event"]?.GetValue<string>() == "progress")
                {
                    var stage = message["stage"]?.GetValue<string>() switch { "extract" => "Reading pages", "write" => "Creating export", "validate" => "Checking export", _ => "Exporting" };
                    progress?.Report($"{stage} ({message["pages_done"]?.GetValue<int>() ?? 0} of {message["pages_total"]?.GetValue<int>() ?? pages.Count})…");
                    return false;
                }
                return message["event"]?.GetValue<string>() == "result";
            }, deadline.Token);
            var status = response["status"]?.GetValue<string>();
            if (status is not ("ok" or "ok_with_warnings"))
            {
                var code = response["error"]?["code"]?.GetValue<string>() ?? "EXPORT_FAILED";
                throw new EngineException(code, code switch
                {
                    "OCR_REQUIRED" => "These pages need OCR before they can be converted. Run Recognize Text first.",
                    "POLICY_BLOCKED" => "Encrypted and XFA documents can't be exported.",
                    "SOURCE_CHANGED" => "The document changed during the export. Try again.",
                    _ => $"The exporter couldn't complete this document ({code}). Nothing was saved.",
                });
            }
            var ext = format;
            var artifact = response["artifact"]!;
            if (response["snapshot_sha256"]?.GetValue<string>() != hash || artifact["relative_path"]?.GetValue<string>() != $"document.{ext}")
                throw new EngineException("EXPORT_INVALID", "The export failed its integrity check. Nothing was saved.");
            var primary = Path.Combine(staging, $"document.{ext}");
            var bytes = Validate(primary, artifact);
            var files = artifact["files"]?.AsArray() ?? [];
            foreach (var file in files)
            {
                var relative = file!["relative_path"]!.GetValue<string>();
                if (format != "md" || !relative.StartsWith(assetName + "/", StringComparison.Ordinal) || relative.Contains(".."))
                    throw new EngineException("EXPORT_INVALID", "The export contained an unexpected file. Nothing was saved.");
                bytes += Validate(Path.Combine(staging, relative.Replace('/', Path.DirectorySeparatorChar)), file);
            }
            // Publish: the document, then its image folder (Markdown) next to it.
            File.Move(primary, destination, overwrite: true);
            if (files.Count > 0)
            {
                var assets = Path.Combine(folder, assetName);
                Directory.Move(Path.Combine(staging, assetName), assets);
            }
            var notices = response["warnings"]?.AsArray().Select(w => w!["code"]?.GetValue<string>() ?? "").Where(c => c.Length > 0).Distinct().ToList() ?? [];
            return new Result(destination, 1 + files.Count, bytes, notices);
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
        {
            throw new EngineException("EXPORT_TIMEOUT", "The export took too long and was stopped. Try fewer pages.");
        }
        finally
        {
            try { process.StandardInput.Close(); } catch (Exception error) when (error is IOException or InvalidOperationException) { }
            try { Directory.Delete(staging, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private static Process Start(JobObject job)
    {
        var start = new ProcessStartInfo(Engine.PythonPath, ["-B", "-u", Path.Combine(Engine.EngineFolder, "export_worker.py")])
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Engine.EngineFolder,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8,
        };
        start.Environment["PYTHONUTF8"] = "1";
        start.Environment["PYTHONNOUSERSITE"] = "1";
        start.Environment["PYTHONDONTWRITEBYTECODE"] = "1";
        start.Environment.Remove("PYTHONPATH");
        start.Environment.Remove("PYTHONHOME");
        var process = Process.Start(start) ?? throw new EngineException("EXPORT_UNAVAILABLE", "The exporter didn't start.");
        job.Assign(process);
        process.ErrorDataReceived += (_, _) => { };
        process.BeginErrorReadLine();
        return process;
    }

    private static async Task<JsonNode> ExchangeAsync(Process process, JsonObject request, Func<JsonNode, bool> done, CancellationToken cancel)
    {
        await process.StandardInput.WriteLineAsync(request.ToJsonString().AsMemory(), cancel);
        await process.StandardInput.FlushAsync(cancel);
        while (true)
        {
            var line = await process.StandardOutput.ReadLineAsync(cancel)
                       ?? throw new EngineException("EXPORT_FAILED", "The exporter stopped unexpectedly.");
            var message = JsonNode.Parse(line)!;
            if (done(message)) return message;
        }
    }

    private static long Validate(string path, JsonNode metadata)
    {
        var file = new FileInfo(path);
        var expected = metadata["sha256"]?.GetValue<string>();
        var size = metadata["bytes"]?.GetValue<long>() ?? -1;
        if (!file.Exists || file.Attributes.HasFlag(FileAttributes.ReparsePoint) || size <= 0 || file.Length != size || Sha256(path) != expected)
            throw new EngineException("EXPORT_INVALID", "The export failed its integrity check. Nothing was saved.");
        return size;
    }

    private static string Sha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }

    /// <summary>A Windows job object: caps the worker's memory and kills it (and any
    /// children) when zPDF closes the job.</summary>
    private sealed partial class JobObject : IDisposable
    {
        private readonly IntPtr _handle;
        private JobObject(IntPtr handle) => _handle = handle;

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimit
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public nuint MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public nuint Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimit
        {
            public BasicLimit Basic;
            public IoCounters Io;
            public nuint ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        private const uint LimitProcessMemory = 0x100, LimitKillOnJobClose = 0x2000;
        private const int ExtendedLimitInformation = 9;

        [LibraryImport("kernel32.dll", EntryPoint = "CreateJobObjectW")] private static partial IntPtr CreateJobObject(IntPtr attributes, IntPtr name);
        [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        private static partial bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimit info, int size);
        [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        private static partial bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
        private static partial bool CloseHandle(IntPtr handle);

        public static JobObject Create(long memoryLimit)
        {
            var handle = CreateJobObject(IntPtr.Zero, IntPtr.Zero);
            var limits = new ExtendedLimit { ProcessMemoryLimit = (nuint)memoryLimit };
            limits.Basic.LimitFlags = LimitProcessMemory | LimitKillOnJobClose;
            if (handle != IntPtr.Zero) SetInformationJobObject(handle, ExtendedLimitInformation, ref limits, Marshal.SizeOf<ExtendedLimit>());
            return new JobObject(handle);
        }

        public void Assign(Process process)
        {
            if (_handle != IntPtr.Zero) AssignProcessToJobObject(_handle, process.Handle);
        }

        public void Dispose()
        {
            if (_handle != IntPtr.Zero) CloseHandle(_handle);
        }
    }
}
