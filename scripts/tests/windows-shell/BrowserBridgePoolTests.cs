// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Pages;

internal static class BrowserBridgePoolTests
{
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    private static TaskCompletionSource<T> Pending<T>() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    internal static async Task RunAsync()
    {
        long epoch = 1;
        int listens = 0, retires = 0;
        var pool = new BrowserBridgePool(() => epoch,
            (_, _, _) => Task.FromResult($"http://127.0.0.1:{49000 + ++listens}/"),
            (_, _, _) => { retires++; return Task.CompletedTask; });
        var a = await pool.AcquireAsync("peer", "localhost", 3000, 1);
        Check(pool.IsCurrentListener(new Uri(a))
            && pool.IsCurrentListener(new Uri(a.Replace("http:", "https:")))
            && !pool.IsCurrentListener(new Uri("http://localhost:3000/"))
            && !pool.IsCurrentListener(new Uri("http://127.0.0.1:49999/")),
            "Worker routing accepted an original/unknown endpoint or lost raw TLS transport");
        Check(a == await pool.AcquireAsync("peer", "localhost", 3000, 1) && listens == 1,
            "Same-account project tabs failed to share a listener");
        await pool.ReleaseAsync("peer", "localhost", 3000, 1);
        Check(retires == 0, "Closing one shared lease disconnected its sibling");
        epoch = 2;
        Check(!pool.IsCurrentListener(new Uri(a)), "Account change exposed an older listener before invalidation ran");
        await pool.InvalidateAsync();
        Check(retires == 1, "Account change retained an older account's listener");
        var b = await pool.AcquireAsync("peer", "localhost", 3000, 2);
        await pool.ReleaseAsync("peer", "localhost", 3000, 1);
        Check(a != b && retires == 1, "A stale account release disconnected the replacement");
        Check(pool.IsCurrentListener(new Uri(b)) && !pool.IsCurrentListener(new Uri(a)), "Listener snapshot retained a stale generation");
        await pool.ReleaseAsync("peer", "localhost", 3000, 2);
        Check(retires == 2, "The current account could not retire its listener");
        try { await pool.AcquireAsync("peer", "localhost", 3000, 1); throw new Exception("Stale Open was accepted"); }
        catch (InvalidOperationException) { }
        Check(listens == 2, "Stale Open started a host call");

        epoch = 1;
        var listening = Pending<string>();
        listens = retires = 0;
        pool = new BrowserBridgePool(() => epoch,
            (_, _, _) => { listens++; return listens == 1 ? listening.Task : Task.FromResult("http://127.0.0.1:49002/"); },
            (_, _, _) => { retires++; return Task.CompletedTask; });
        var pending = pool.AcquireAsync("peer", "localhost", 3000, 1);
        epoch = 2;
        listening.SetResult("http://127.0.0.1:49001/");
        try { await pending; throw new Exception("Late old-account listener was published"); }
        catch (InvalidOperationException) { }
        Check(retires == 1, "Late old-account listener was not retired");
        await pool.AcquireAsync("peer", "localhost", 3000, 2);
        await pool.ReleaseAsync("peer", "localhost", 3000, 1);
        Check(listens == 2 && retires == 1, "Late old-account release affected the new account");

        epoch = 1;
        listens = 0;
        var retiring = Pending<bool>();
        var retired = Pending<bool>();
        pool = new BrowserBridgePool(() => epoch,
            (_, _, _) => Task.FromResult($"http://127.0.0.1:{49000 + ++listens}/"),
            async (_, _, _) => { retiring.TrySetResult(true); await retired.Task; });
        await pool.AcquireAsync("peer", "localhost", 3000, 1);
        var close = pool.ReleaseAsync("peer", "localhost", 3000, 1);
        await retiring.Task;
        Check(!pool.IsCurrentListener(new Uri("http://127.0.0.1:49001/")), "A retiring listener stayed available to workers");
        var reopen = pool.AcquireAsync("peer", "localhost", 3000, 1);
        Check(!reopen.IsCompleted && listens == 1, "Reopen raced the old unlisten");
        retired.SetResult(true);
        await close;
        Check(await reopen == "http://127.0.0.1:49002/", "Reopen reused a retired listener");

        epoch = 1;
        listens = 0;
        retiring = Pending<bool>();
        retired = Pending<bool>();
        pool = new BrowserBridgePool(() => epoch,
            (_, _, _) => Task.FromResult($"http://127.0.0.1:{49000 + ++listens}/"),
            async (_, _, _) => { retiring.TrySetResult(true); await retired.Task; });
        await pool.AcquireAsync("peer", "localhost", 3000, 1);
        epoch = 2;
        var replacement = pool.AcquireAsync("peer", "localhost", 3000, 2);
        await retiring.Task;
        epoch = 3;
        retired.SetResult(true);
        try { await replacement; throw new Exception("Ownership changed during retirement without rejection"); }
        catch (InvalidOperationException) { }
        Check(listens == 1, "Account changed during retirement but still acquired a new listener");

        epoch = 1;
        listens = 0;
        bool refuseRetirement = true;
        pool = new BrowserBridgePool(() => epoch,
            (_, _, _) => Task.FromResult($"http://127.0.0.1:{49000 + ++listens}/"),
            (_, _, _) => refuseRetirement ? Task.FromException(new IOException("Retirement unavailable")) : Task.CompletedTask);
        await pool.AcquireAsync("peer", "localhost", 3000, 1);
        epoch = 2;
        await pool.InvalidateAsync();
        try { await pool.AcquireAsync("peer", "localhost", 3000, 2); throw new Exception("Unretired account listener was reused"); }
        catch (IOException) { }
        Check(listens == 1, "Failed retirement allowed cross-account reuse");
        refuseRetirement = false;
        await pool.AcquireAsync("peer", "localhost", 3000, 2);
        Check(listens == 2, "Failed retirement could not be retried before a fresh acquire");

        epoch = 1;
        listens = 0;
        refuseRetirement = true;
        pool = new BrowserBridgePool(() => epoch,
            (_, _, _) => ++listens == 1 ? Task.FromException<string>(new IOException("Answer lost")) : Task.FromResult("http://127.0.0.1:49002/"),
            (_, _, _) => refuseRetirement ? Task.FromException(new IOException("Retirement unavailable")) : Task.CompletedTask);
        try { await pool.AcquireAsync("peer", "localhost", 3000, 1); throw new Exception("Lost answer was accepted"); }
        catch (IOException) { }
        epoch = 2;
        try { await pool.AcquireAsync("peer", "localhost", 3000, 2); throw new Exception("Uncertain registration was reused"); }
        catch (IOException) { }
        Check(listens == 1, "A lost listener answer bypassed account retirement");
        refuseRetirement = false;
        await pool.AcquireAsync("peer", "localhost", 3000, 2);
        Check(listens == 2, "An uncertain listener could not be retired and reopened");

    }
}
