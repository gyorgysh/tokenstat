// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Navigation;

internal static class BoundedHostSweepTests
{
    public static async Task RunAsync()
    {
        var releaseSlow = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var fastFinished = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var gate = new object();
        var active = 0;
        var peak = 0;
        var completed = new List<int>();
        var sweep = BoundedHostSweep.RunAsync(Enumerable.Range(0, 10).ToArray(), 4, async host =>
        {
            lock (gate)
            {
                active++;
                peak = Math.Max(peak, active);
            }
            try
            {
                if (host == 0) await releaseSlow.Task;
                else
                {
                    await Task.Delay(10);
                    if (host == 1) fastFinished.TrySetResult(true);
                }
                lock (gate) completed.Add(host);
            }
            finally
            {
                lock (gate) active--;
            }
        });
        try
        {
            if (await Task.WhenAny(fastFinished.Task, Task.Delay(3000)) != fastFinished.Task)
                throw new Exception("One sleeping host blocked healthy hosts");
        }
        finally
        {
            releaseSlow.TrySetResult(true);
        }
        await sweep;
        if (peak > 4 || peak < 2 || completed.Count != 10 || completed[0] == 0)
            throw new Exception("The ten-host sweep lost its concurrency bound or stalled behind a host");
    }
}
