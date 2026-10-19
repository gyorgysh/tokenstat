// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Microsoft.Windows.AppLifecycle;
using Windows.ApplicationModel.Activation;

namespace Tokenstat.Navigation;

/// <summary>Protocol launches reach the existing window, including during boot.</summary>
internal static class DesktopActivation
{
    private static readonly ConcurrentQueue<DesktopOpenRequest> Pending = new();
    private static AppInstance? _instance;
    public static event Action? Changed;
    public static bool TryTake(out DesktopOpenRequest? request) => Pending.TryDequeue(out request);

    public static bool Initialize()
    {
        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        Program.LogStartup("Desktop startup activation; kind=" + activation.Kind);
        var instance = AppInstance.FindOrRegisterForKey("desktop");
        if (!instance.IsCurrent)
        {
            // No window or XAML initialization in the forwarding process.
            Redirect(instance, activation);
            return false;
        }
        _instance = instance;
        _instance.Activated += (_, args) => Receive(args);
        var executable = Environment.ProcessPath;
        if (executable is not null)
        {
            try { ActivationRegistrationManager.RegisterForProtocolActivation("tokenstat", executable + ",0", "tokenstat", executable); }
            catch (Exception error) { Program.LogStartup("Desktop link registration failed: " + error.Message); }
        }
        Receive(activation);
        return true;
    }
    private static void Redirect(AppInstance instance, AppActivationArguments activation)
    {
        using var complete = new ManualResetEvent(false);
        var redirect = Task.Run(async () =>
        {
            try { await instance.RedirectActivationToAsync(activation); }
            finally { try { complete.Set(); } catch (ObjectDisposedException) { } }
        });
        // Keep a synchronous STA entry point for XAML. Pump COM and window
        // messages while the secondary process forwards its activation.
        var handles = new[] { complete.SafeWaitHandle.DangerousGetHandle() };
        var result = CoWaitForMultipleHandles(0x8 | 0x10, 30000, 1, handles, out _);
        if (result < 0) Marshal.ThrowExceptionForHR(result);
        redirect.GetAwaiter().GetResult();
    }
    [DllImport("ole32.dll")]
    private static extern int CoWaitForMultipleHandles(uint flags, uint timeout, uint count, [In] IntPtr[] handles, out uint index);
    private static void Receive(AppActivationArguments activation)
    {
        Program.LogStartup("Desktop activation; kind=" + activation.Kind + "; protocol=" + (activation.Data is IProtocolActivatedEventArgs));
        if (activation.Data is IProtocolActivatedEventArgs protocol
            && DesktopOpenRequest.Parse(protocol.Uri.AbsoluteUri) is { } request)
        {
            Program.LogStartup("Desktop action received; tool=" + request.Tool);
            while (Pending.Count >= 16) Pending.TryDequeue(out _);
            Pending.Enqueue(request);
        }
        Changed?.Invoke();
    }
}
