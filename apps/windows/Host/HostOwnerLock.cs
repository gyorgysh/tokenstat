// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Tokenstat.Host;

internal static class HostOwnerLock
{
    private static FileStream? _stream;

    public static void Acquire() => AcquireAt(LockPath);

    internal static void AcquireAt(string path)
    {
        if (_stream is not null)
        {
            return;
        }
        FileStream? stream = null;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            stream = new FileStream(
                path,
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.ReadWrite | FileShare.Delete);
            var overlapped = new NativeOverlapped();
            if (!LockFileEx(stream.SafeFileHandle, 0, 0, 1, 0, ref overlapped))
            {
                return;
            }
            _stream = stream;
            stream = null;
        }
        catch
        {
        }
        finally
        {
            stream?.Dispose();
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
        }
        stream.Dispose();
    }

    internal static string LockPath
    {
        get
        {
            var data = Environment.GetEnvironmentVariable("TOKENSTAT_DATA_DIR");
            if (string.IsNullOrEmpty(data) || !Path.IsPathFullyQualified(data))
                data = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "tokenstat", "tokenstat", "data");
            return Path.Combine(data, "host-owner.lock");
        }
    }

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
