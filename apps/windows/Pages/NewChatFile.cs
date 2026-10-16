// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// Private local bytes, independent of the source screenshot or file. Upload
/// happens only after explicit Send creates and owns the new conversation.
internal sealed record NewChatFile(string Path, string Name, long Size, DateTime ModifiedUtc)
{
    internal const int MaximumCount = 20;
    internal const long MaximumBytes = 256L * 1024 * 1024;
    private static readonly string StagingRoot = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "tokenstat-chat-staging-" + Guid.NewGuid().ToString("N"));

    static NewChatFile()
    {
        AppDomain.CurrentDomain.ProcessExit += (_, _) => {
            try { if (Directory.Exists(StagingRoot)) Directory.Delete(StagingRoot, recursive: true); }
            catch (IOException) { } catch (UnauthorizedAccessException) { }
        };
    }

    internal static Task<NewChatFile> CaptureAsync(string path, CancellationToken cancellation = default) =>
        Task.Run(() => CaptureCoreAsync(path, cancellation), cancellation);

    private static async Task<NewChatFile> CaptureCoreAsync(string path, CancellationToken cancellation)
    {
        var source = new FileInfo(System.IO.Path.GetFullPath(path));
        if (!source.Exists || source.Length is <= 0 or > MaximumBytes) throw new IOException("Invalid attachment file");
        var expectedSize = source.Length; var modified = source.LastWriteTimeUtc;
        var folder = System.IO.Path.Combine(StagingRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var copy = System.IO.Path.Combine(folder, source.Name);
        try {
            await using (var input = new FileStream(source.FullName, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
            await using (var output = new FileStream(copy, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan)) {
                var buffer = new byte[128 * 1024]; long copied = 0;
                while (true) {
                    var count = await input.ReadAsync(buffer, cancellation).ConfigureAwait(false);
                    if (count == 0) break;
                    copied += count;
                    if (copied > expectedSize || copied > MaximumBytes) throw new IOException("The attachment changed while reading");
                    await output.WriteAsync(buffer.AsMemory(0, count), cancellation).ConfigureAwait(false);
                }
                if (copied != expectedSize || input.Length != expectedSize) throw new IOException("The attachment changed while reading");
                await output.FlushAsync(cancellation).ConfigureAwait(false);
            }
            cancellation.ThrowIfCancellationRequested();
            source.Refresh();
            if (!source.Exists || source.Length != expectedSize || source.LastWriteTimeUtc != modified) throw new IOException("The attachment changed while reading");
            var owned = new FileInfo(copy);
            return new NewChatFile(copy, source.Name, owned.Length, owned.LastWriteTimeUtc);
        } catch {
            try { File.Delete(copy); Directory.Delete(folder); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            throw;
        }
    }

    internal NewChatFile? RetainIfOwned(bool current)
    {
        if (current) return this;
        Discard(); return null;
    }

    internal void Discard()
    {
        // This type must never delete the user's source, even if a malformed
        // in-memory record is passed to a remove or cleanup action.
        var directory = System.IO.Path.GetDirectoryName(Path);
        if (directory is null || System.IO.Path.GetDirectoryName(directory) != StagingRoot) return;
        try { File.Delete(Path); Directory.Delete(directory); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    internal bool IsCurrent()
    {
        var file = new FileInfo(Path);
        return file.Exists && file.Length == Size && file.LastWriteTimeUtc == ModifiedUtc;
    }
}
