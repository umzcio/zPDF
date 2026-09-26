using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace zPDF;

public sealed class EngineException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

/// <summary>The zPDF engine (EngineSupport/serve.py), one JSON request per line.
/// Prototype: uses a development Python; the shipping app bundles its runtime.</summary>
public sealed class Engine : IDisposable
{
    private readonly Process _process;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public static string PythonPath => Environment.GetEnvironmentVariable("ZPDF_PYTHON") ?? @"C:\dev\venv-zpdf\Scripts\python.exe";
    public static string EngineFolder => Environment.GetEnvironmentVariable("ZPDF_ENGINE") ?? @"C:\dev\zPDF\EngineSupport";

    public Engine()
    {
        var start = new ProcessStartInfo(PythonPath, ["-B", "-u", Path.Combine(EngineFolder, "serve.py")])
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
            WorkingDirectory = EngineFolder,
        };
        start.Environment["PYTHONUTF8"] = "1";
        start.Environment["PYTHONDONTWRITEBYTECODE"] = "1";
        var qpdf = Environment.GetEnvironmentVariable("QPDF_BIN", EnvironmentVariableTarget.User)
                   ?? Environment.GetEnvironmentVariable("QPDF_BIN");
        if (qpdf is not null) start.Environment["QPDF_BIN"] = qpdf;
        _process = Process.Start(start) ?? throw new EngineException("ENGINE_UNAVAILABLE", "The PDF engine didn't start.");
        _process.ErrorDataReceived += (_, _) => { };  // drain stderr so it can never fill up and block
        _process.BeginErrorReadLine();
    }

    public async Task<JsonNode> CallAsync(string command, JsonObject parameters)
    {
        await _gate.WaitAsync();
        try
        {
            var request = new JsonObject { ["command"] = command, ["parameters"] = parameters };
            await _process.StandardInput.WriteLineAsync(request.ToJsonString());
            await _process.StandardInput.FlushAsync();
            var line = await _process.StandardOutput.ReadLineAsync()
                       ?? throw new EngineException("ENGINE_UNAVAILABLE", "The PDF engine stopped unexpectedly.");
            var response = JsonNode.Parse(line)!;
            if (response["ok"]?.GetValue<bool>() == true) return response["result"]!;
            var error = response["error"];
            throw new EngineException(error?["code"]?.GetValue<string>() ?? "ENGINE_FAILED",
                                      error?["message"]?.GetValue<string>() ?? "The PDF engine couldn't complete this.");
        }
        finally { _gate.Release(); }
    }

    /// <summary>Runs edit operations on `source` into a new private file; returns its path.</summary>
    public async Task<string> TransformAsync(string source, JsonArray ops)
    {
        var destination = Path.Combine(Path.GetTempPath(), $"zpdf-{Guid.NewGuid():N}.pdf");
        await CallAsync("transform", new JsonObject
        {
            ["path"] = source, ["destination"] = destination, ["ops"] = ops, ["sha256"] = Sha256(source),
        });
        return destination;
    }

    /// <summary>Publishes a finished private copy to the user's chosen file.</summary>
    public Task<JsonNode> PublishAsync(string candidate, string destination, bool overwrite) =>
        CallAsync("publish", new JsonObject
        {
            ["path"] = candidate, ["destination"] = destination, ["sha256"] = Sha256(candidate), ["overwrite"] = overwrite,
        });

    public static string Sha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }

    public void Dispose()
    {
        try
        {
            _process.StandardInput.Close();
            if (!_process.WaitForExit(3000)) _process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException) { }
        _process.Dispose();
    }
}
