// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace NativeUiTests;

/// CI-only native exception diagnostics. Read only bounded exception headers
/// and stack addresses, never ErrorText, locals, environment or a memory dump.
/// Layouts: DEBUG_EVENT, EXCEPTION_RECORD64 and STOWED_EXCEPTION_INFORMATION_V2
/// in the Windows SDK / Microsoft Learn Win32 debugging documentation.
internal static class WindowsCrashTrace
{
    [StructLayout(LayoutKind.Explicit, Size = 176)]
    private struct DebugEvent
    {
        [FieldOffset(0)] public uint Code;
        [FieldOffset(4)] public uint Process;
        [FieldOffset(8)] public uint Thread;
        [FieldOffset(16)] public uint Exception;
        [FieldOffset(16)] public nint File;
        [FieldOffset(40)] public uint ParameterCount;
        [FieldOffset(48)] public ulong Parameter0;
        [FieldOffset(56)] public ulong Parameter1;
        [FieldOffset(168)] public uint FirstChance;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DebugActiveProcess(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DebugActiveProcessStop(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DebugSetProcessKillOnExit(bool kill);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool WaitForDebugEvent(out DebugEvent info, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool ContinueDebugEvent(uint pid, uint tid, uint status);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern nint OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool ReadProcessMemory(nint process, nint address, [Out] byte[] bytes, nuint size, out nuint read);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);

    internal static int Run(string[] args)
    {
        if (args.Length != 3 || Environment.GetEnvironmentVariable("CI") != "true"
            || Environment.GetEnvironmentVariable("TOKENSTAT_UI_STARTUP_TRACE") != "1" || IntPtr.Size != 8
            || !uint.TryParse(args[1], out var pid) || pid == Environment.ProcessId) return 2;
        var root = Environment.GetEnvironmentVariable("RUNNER_TEMP");
        if (string.IsNullOrEmpty(root) || !Path.GetFullPath(args[2]).StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return 2;
        void Log(string line) { try { File.AppendAllText(args[2], $"{DateTime.UtcNow:o} pid={pid} {line}\n"); } catch { } }
        if (!DebugActiveProcess(pid)) { Log($"attach failed: {Marshal.GetLastWin32Error()}"); return 1; }
        nint process = 0;
        try
        {
            if (!DebugSetProcessKillOnExit(false)) { Log("could not disable debugger kill-on-exit"); return 1; }
            process = OpenProcess(0x0010 | 0x0400, false, pid);
            Log("attached; structural exception tracing only");
            var deadline = DateTime.UtcNow.AddMinutes(10); var initialBreakpoint = true;
            while (DateTime.UtcNow < deadline)
            {
                if (!WaitForDebugEvent(out var e, 1000)) {
                    if (Marshal.GetLastWin32Error() == 121) continue;
                    Log($"wait failed: {Marshal.GetLastWin32Error()}"); break;
                }
                var status = 0x00010002u; // DBG_CONTINUE for non-exception events.
                var continued = false;
                try
                {
                    if (e.Code == 1)
                    {
                        status = 0x80010001u; // Never handle an application's exception.
                        if (e.Exception == 0x80000003 && initialBreakpoint) { initialBreakpoint = false; status = 0x00010002u; }
                        if (e.Exception == 0xc000027b)
                        {
                            Log($"stowed exception; firstChance={e.FirstChance}; parameters={e.ParameterCount}");
                            if (process != 0 && e.ParameterCount >= 2 && e.Parameter1 is > 0 and <= 4096)
                                Stowed(process, pid, e.Parameter0, (int)Math.Min(e.Parameter1, 8ul), Log);
                        }
                    }
                    // The SDK requires the debugger to close image-file handles.
                    if (e.Code is 3 or 6 && e.File != 0) CloseHandle(e.File);
                }
                catch { Log("exception metadata unavailable"); }
                finally { continued = ContinueDebugEvent(e.Process, e.Thread, status); }
                if (!continued) { Log($"continue failed: {Marshal.GetLastWin32Error()}"); break; }
                if (e.Code == 5) { Log("process exited"); break; }
            }
        }
        finally
        {
            DebugActiveProcessStop(pid);
            if (process != 0) CloseHandle(process);
        }
        return 0;
    }
    private static byte[]? Read(nint process, ulong address, int count)
    {
        if (address == 0 || count is < 1 or > 512) return null;
        var bytes = new byte[count];
        return ReadProcessMemory(process, unchecked((nint)address), bytes, (nuint)count, out var read) && read == (nuint)count ? bytes : null;
    }
    private static void Stowed(nint process, uint pid, ulong array, int count, Action<string> log)
    {
        var pointers = Read(process, array, count * 8); if (pointers is null) return;
        var modules = new List<(ulong Base, ulong Size, string Name)>();
        try {
            using var target = Process.GetProcessById((int)pid);
            foreach (ProcessModule m in target.Modules) modules.Add(((ulong)m.BaseAddress, (ulong)m.ModuleMemorySize, m.ModuleName));
        } catch { }
        for (var i = 0; i < count; i++)
        {
            var header = Read(process, BitConverter.ToUInt64(pointers, i * 8), 40); if (header is null) continue;
            var size = BitConverter.ToUInt32(header, 0); var signature = BitConverter.ToUInt32(header, 4);
            if (size is < 40 or > 4096 || signature is not (0x53453031 or 0x53453032)) continue;
            var form = BitConverter.ToUInt32(header, 12) & 3;
            log($"stowed[{i}] HRESULT=0x{BitConverter.ToUInt32(header, 8):x8}; form={form}");
            if (form != 1 || BitConverter.ToUInt32(header, 24) != 8) continue;
            var words = Math.Min(BitConverter.ToUInt32(header, 28), 32u);
            var stack = Read(process, BitConverter.ToUInt64(header, 32), (int)words * 8); if (stack is null) continue;
            for (var frame = 0; frame < words; frame++)
            {
                var address = BitConverter.ToUInt64(stack, frame * 8);
                var module = modules.FirstOrDefault(m => address >= m.Base && address - m.Base < m.Size);
                log(module.Name is null ? $"frame[{frame}] unresolved" : $"frame[{frame}] {module.Name}+0x{address - module.Base:x}");
            }
        }
    }
}
