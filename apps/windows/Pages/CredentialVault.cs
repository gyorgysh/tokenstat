// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Runtime.InteropServices;
using System.Text;

namespace Tokenstat.Pages;

/// <summary>
/// SSH private key material in the Windows credential store. This is the
/// Windows side of the vault the Apple client keeps behind its own lock:
/// secrets live in Credential Manager under tokenstat/ssh/, encrypted with
/// the signed-in user account, and only labels ever cross into the UI.
/// Nothing here logs, displays, or otherwise surfaces secret material, and
/// every failure reads as unavailable rather than throwing into a page.
/// Credential Manager (Advapi32) is used instead of the Credential Locker
/// API because this app is unpackaged and per-user, and the Locker needs a
/// package identity.
/// </summary>
internal static class CredentialVault
{
    public const string Scheme = "wincred:";

    private const string Prefix = "tokenstat/ssh/";

    private const uint Generic = 1;

    private const uint PersistLocalMachine = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeCredential
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("Advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWriteW(ref NativeCredential credential, uint flags);

    [DllImport("Advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredReadW(string target, uint type, int reserved, out IntPtr credential);

    [DllImport("Advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredEnumerateW(string? filter, int flags, out uint count, out IntPtr credentials);

    [DllImport("Advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDeleteW(string target, uint type, int flags);

    [DllImport("Advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    public static string RefFor(string id) => Scheme + id;

    public static string? IdFromRef(string? secretRef) =>
        string.IsNullOrEmpty(secretRef) || !secretRef.StartsWith(Scheme, StringComparison.Ordinal)
            ? null
            : secretRef[Scheme.Length..];

    /// <summary>
    /// Store a secret and return the reference metadata keeps, mirroring the
    /// Mac store call. Empty string when the store refused the write.
    /// </summary>
    public static string Store(string secret, string id) =>
        Save(id, secret) ? RefFor(id) : "";

    /// <summary>Load through a stored reference rather than a bare id.</summary>
    public static string? LoadReference(string? secretRef)
    {
        var id = IdFromRef(secretRef);
        return id is null ? null : Load(id);
    }

    /// <summary>Whether a stored reference still resolves to a secret.</summary>
    public static bool ContainsReference(string? secretRef)
    {
        var id = IdFromRef(secretRef);
        return id is not null && Contains(id);
    }

    /// <summary>
    /// Delete through a stored reference. Unknown references are ignored,
    /// matching the Mac delete.
    /// </summary>
    public static void Delete(string? secretRef)
    {
        var id = IdFromRef(secretRef);
        if (id is not null)
        {
            Remove(id);
        }
    }

    public static bool Save(string id, string secret)
    {
        if (string.IsNullOrEmpty(id) || string.IsNullOrEmpty(secret))
        {
            return false;
        }
        var bytes = Encoding.UTF8.GetBytes(secret);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new NativeCredential
            {
                Flags = 0,
                Type = Generic,
                TargetName = Prefix + id,
                Comment = "",
                LastWritten = 0,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = PersistLocalMachine,
                AttributeCount = 0,
                Attributes = IntPtr.Zero,
                TargetAlias = "",
                UserName = "",
            };
            try
            {
                return CredWriteW(ref credential, 0);
            }
            catch
            {
                return false;
            }
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    public static string? Load(string id)
    {
        if (string.IsNullOrEmpty(id))
        {
            return null;
        }
        var held = IntPtr.Zero;
        try
        {
            if (!CredReadW(Prefix + id, Generic, 0, out held) || held == IntPtr.Zero)
            {
                return null;
            }
            var credential = Marshal.PtrToStructure<NativeCredential>(held);
            if (credential.CredentialBlob == IntPtr.Zero
                || credential.CredentialBlobSize == 0
                || credential.CredentialBlobSize > 1_048_576)
            {
                return null;
            }
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, (int)credential.CredentialBlobSize);
            return Encoding.UTF8.GetString(bytes);
        }
        catch
        {
            return null;
        }
        finally
        {
            if (held != IntPtr.Zero)
            {
                try
                {
                    CredFree(held);
                }
                catch
                {
                    // Releasing the store buffer must not throw into a page.
                }
            }
        }
    }

    public static bool Contains(string id)
    {
        if (string.IsNullOrEmpty(id))
        {
            return false;
        }
        var held = IntPtr.Zero;
        try
        {
            return CredReadW(Prefix + id, Generic, 0, out held) && held != IntPtr.Zero;
        }
        catch
        {
            return false;
        }
        finally
        {
            if (held != IntPtr.Zero)
            {
                try
                {
                    CredFree(held);
                }
                catch
                {
                    // Releasing the store buffer must not throw into a page.
                }
            }
        }
    }

    public static bool Remove(string id)
    {
        if (string.IsNullOrEmpty(id))
        {
            return false;
        }
        try
        {
            return CredDeleteW(Prefix + id, Generic, 0);
        }
        catch
        {
            return false;
        }
    }

    public static List<string> ListIds()
    {
        var ids = new List<string>();
        var list = IntPtr.Zero;
        try
        {
            if (!CredEnumerateW(Prefix + "*", 0, out var count, out list) || list == IntPtr.Zero)
            {
                return ids;
            }
            for (var i = 0u; i < count; i++)
            {
                var item = Marshal.ReadIntPtr(list, (int)i * IntPtr.Size);
                if (item == IntPtr.Zero)
                {
                    continue;
                }
                var credential = Marshal.PtrToStructure<NativeCredential>(item);
                var target = credential.TargetName ?? "";
                if (target.StartsWith(Prefix, StringComparison.Ordinal))
                {
                    ids.Add(target[Prefix.Length..]);
                }
            }
        }
        catch
        {
            // An unreadable store reads as empty, never as an exception.
        }
        finally
        {
            if (list != IntPtr.Zero)
            {
                try
                {
                    CredFree(list);
                }
                catch
                {
                    // Releasing the store buffer must not throw into a page.
                }
            }
        }
        return ids;
    }
}
