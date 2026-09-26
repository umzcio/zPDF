using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace zPDF;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
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
