// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>Capture before queueing work. Recheck after each asynchronous boundary.</summary>
internal sealed class OperationEpoch
{
    private long _revision;
    public long Revision => Volatile.Read(ref _revision);
    public void Advance() => Interlocked.Increment(ref _revision);
    public Operation Capture(Func<bool>? cancelled = null) => new(this, Revision, cancelled);
    internal readonly record struct Operation(OperationEpoch Epoch, long Revision, Func<bool>? Cancelled)
    {
        public bool IsCurrent => Epoch.Revision == Revision && Cancelled?.Invoke() != true;
        public async Task<string?> AcquireAsync(Func<Task<string>> acquire, Func<Task> release)
        {
            if (!IsCurrent) return null;
            var resource = await acquire();
            if (IsCurrent) return resource;
            await release();
            return null;
        }
    }
}
