// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Tokenstat.Host;

/// <summary>
/// Shared lock hostd watches when Always-on is off. Same file as
/// tokenstat-paths data_dir / host-owner.lock:
/// %APPDATA%\tokenstat\tokenstat\host-owner.lock
/// </summary>
internal static class HostOwnerLock
{
    private static FileStream? _stream;

    public static void Acquire()
    {
        if (_stream is not null)
        {
            return;
        }
        var path = LockPath;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var stream = new FileStream(
                path,
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.ReadWrite | FileShare.Delete);
            var overlapped = new NativeOverlapped();
            // Shared lock: flags 0. hostd's exclusive probe then fails while
            // this process (or another Tokenstat window) is open.
            if (!LockFileEx(stream.SafeFileHandle, 0, 0, 1, 0, ref overlapped))
            {
                stream.Dispose();
                return;
            }
            stream.SetLength(0);
            var pid = System.Text.Encoding.UTF8.GetBytes(Environment.ProcessId.ToString());
            stream.Write(pid, 0, pid.Length);
            stream.Flush();
            _stream = stream;
        }
        catch
        {
            // A missing lock is the same as no owner: hostd may exit on a laptop.
        }
    }

    public static void Release()
    {
        var stream = _stream;
        _stream = null;
        if (stream is null)
        {
            return;
        }
        try
        {
            var overlapped = new NativeOverlapped();
            UnlockFileEx(stream.SafeFileHandle, 0, 1, 0, ref overlapped);
        }
        catch
        {
            // Best effort.
        }
        stream.Dispose();
    }

    private static string LockPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "tokenstat",
            "tokenstat",
            "host-owner.lock");

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool LockFileEx(
        SafeFileHandle hFile,
        uint dwFlags,
        uint dwReserved,
        uint nNumberOfBytesToLockLow,
        uint nNumberOfBytesToLockHigh,
        ref NativeOverlapped lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UnlockFileEx(
        SafeFileHandle hFile,
        uint dwReserved,
        uint nNumberOfBytesToUnlockLow,
        uint nNumberOfBytesToUnlockHigh,
        ref NativeOverlapped lpOverlapped);
}
