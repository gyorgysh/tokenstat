// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Navigation;

internal static class BoundedHostSweep
{
    public static async Task RunAsync<T>(IReadOnlyList<T> hosts, int limit, Func<T, Task> visit)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        using var slots = new SemaphoreSlim(limit);
        await Task.WhenAll(hosts.Select(async host =>
        {
            await slots.WaitAsync();
            try
            {
                await visit(host);
            }
            finally
            {
                slots.Release();
            }
        }));
    }
}
