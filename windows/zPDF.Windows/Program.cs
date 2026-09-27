using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace zPDF;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // Installer and update hooks (install, update, uninstall); returns at once otherwise.
        Velopack.VelopackApp.Build().Run();
        if (args is ["--printtest", var source, var printed])
        {
            // Prints every page to a file through "Microsoft Print to PDF" (no dialog).
            try
            {
                using var document = PdfDocument.Open(source);
                var job = Printing.ForPrinter("Microsoft Print to PDF", Enumerable.Range(0, document.PageCount));
                Printing.Print(document, job, Path.GetFileName(source), Path.GetFullPath(printed));
                Console.WriteLine($"printed {document.PageCount} pages to {printed}");
                return 0;
            }
            catch (Exception error) { Console.Error.WriteLine($"printtest failed: {error}"); return 1; }
        }
        if (args is ["--selftest", var input, var folder])
        {
            try { return SelfTest.RunAsync(input, folder).GetAwaiter().GetResult(); }
            catch (Exception error) { Console.Error.WriteLine($"selftest failed: {error}"); return 1; }
        }
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(callback =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
        return 0;
    }
}
