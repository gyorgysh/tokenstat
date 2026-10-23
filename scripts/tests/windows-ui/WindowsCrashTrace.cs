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
    [StructLayout(LayoutKind.Explicit, Size = 16)]
    private struct Address64
    {
        [FieldOffset(0)] public ulong Offset;
        [FieldOffset(12)] public uint Mode;
    }
    // STACKFRAME64 includes a 112-byte KDHELP64 after offset 152. Only the
    // instruction/frame/stack addresses are inspected; parameters stay private.
    [StructLayout(LayoutKind.Explicit, Size = 264)]
    private struct StackFrame64
    {
        [FieldOffset(0)] public Address64 Pc;
        [FieldOffset(32)] public Address64 Frame;
        [FieldOffset(48)] public Address64 Stack;
    }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate nint FunctionTable(nint process, ulong address);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate ulong ModuleBase(nint process, ulong address);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DebugActiveProcess(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DebugActiveProcessStop(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DebugSetProcessKillOnExit(bool kill);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool WaitForDebugEvent(out DebugEvent info, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool ContinueDebugEvent(uint pid, uint tid, uint status);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern nint OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool ReadProcessMemory(nint process, nint address, [Out] byte[] bytes, nuint size, out nuint read);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern nint OpenThread(uint access, bool inherit, uint tid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetThreadContext(nint thread, nint context);
    [DllImport("dbghelp.dll", CharSet = CharSet.Ansi, SetLastError = true)] private static extern bool SymInitialize(nint process, string searchPath, bool invade);
    [DllImport("dbghelp.dll")] private static extern bool SymCleanup(nint process);
    [DllImport("dbghelp.dll")] private static extern bool SymRefreshModuleList(nint process);
    [DllImport("dbghelp.dll")] private static extern nint SymFunctionTableAccess64(nint process, ulong address);
    [DllImport("dbghelp.dll")] private static extern ulong SymGetModuleBase64(nint process, ulong address);
    [DllImport("dbghelp.dll")] private static extern bool StackWalk64(uint machine, nint process, nint thread, ref StackFrame64 frame, nint context,
        nint readMemory, FunctionTable functionTable, ModuleBase moduleBase, nint translate);

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
        var symbols = false;
        try
        {
            if (!DebugSetProcessKillOnExit(false)) { Log("could not disable debugger kill-on-exit"); return 1; }
            process = OpenProcess(0x0010 | 0x0400, false, pid);
            // An explicit empty path avoids environment/network symbol paths.
            symbols = process != 0 && SymInitialize(process, "", true);
            Log("attached; structural exception tracing only");
            var deadline = DateTime.UtcNow.AddMinutes(10); var initialBreakpoint = true; var origins = 0;
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
                        // Stowed exceptions only retain the dispatcher's later
                        // stack. Capture native throw/origination frames before
                        // unwinding, without reading exception text or objects.
                        if (symbols && e.FirstChance == 1 && origins < 64
                            && e.Exception is 0xe06d7363 or 0x40080201 or 0x40080202)
                        {
                            var frames = NativeStack(process, pid, e.Thread);
                            if (frames.Any(frame => frame.StartsWith("Microsoft.UI.Xaml.dll+", StringComparison.OrdinalIgnoreCase)))
                            {
                                origins++;
                                Log($"native origin[{origins}]; code=0x{e.Exception:x8}; thread={e.Thread}");
                                for (var i = 0; i < frames.Count; i++) Log($"origin-frame[{i}] {frames[i]}");
                            }
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
            if (symbols) SymCleanup(process);
            if (process != 0) CloseHandle(process);
        }
        return 0;
    }
    private static List<string> NativeStack(nint process, uint pid, uint tid)
    {
        var frames = new List<string>();
        var thread = OpenThread(0x0008 | 0x0040, false, tid);
        if (thread == 0) return frames;
        var allocation = Marshal.AllocHGlobal(1232 + 15);
        var context = (nint)(((long)allocation + 15) & ~15L);
        try
        {
            // Windows SDK AMD64 CONTEXT: flags at48, RSP152, RBP160, RIP248.
            Marshal.Copy(new byte[1232], 0, context, 1232);
            Marshal.WriteInt32(context, 48, 0x00100003); // CONTROL | INTEGER
            if (!GetThreadContext(thread, context)) return frames;
            SymRefreshModuleList(process);
            var modules = Modules(pid);
            var frame = new StackFrame64
            {
                Pc = new Address64 { Offset = (ulong)Marshal.ReadInt64(context, 248), Mode = 3 },
                Frame = new Address64 { Offset = (ulong)Marshal.ReadInt64(context, 160), Mode = 3 },
                Stack = new Address64 { Offset = (ulong)Marshal.ReadInt64(context, 152), Mode = 3 },
            };
            var seen = new HashSet<ulong>();
            for (var i = 0; i < 32 && StackWalk64(0x8664, process, thread, ref frame, context, 0, SymFunctionTableAccess64, SymGetModuleBase64, 0); i++)
            {
                if (frame.Pc.Offset == 0 || !seen.Add(frame.Pc.Offset)) break;
                var module = modules.FirstOrDefault(m => frame.Pc.Offset >= m.Base && frame.Pc.Offset - m.Base < m.Size);
                frames.Add(module.Name is null ? "unresolved" : $"{module.Name}+0x{frame.Pc.Offset - module.Base:x}");
            }
        }
        finally { Marshal.FreeHGlobal(allocation); CloseHandle(thread); }
        return frames;
    }
    private static List<(ulong Base, ulong Size, string Name)> Modules(uint pid)
    {
        var modules = new List<(ulong Base, ulong Size, string Name)>();
        try {
            using var target = Process.GetProcessById((int)pid);
            foreach (ProcessModule m in target.Modules) modules.Add(((ulong)m.BaseAddress, (ulong)m.ModuleMemorySize, m.ModuleName));
        } catch { }
        return modules;
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
        var modules = Modules(pid);
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
