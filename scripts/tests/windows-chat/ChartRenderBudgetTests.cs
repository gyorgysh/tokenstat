// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Pages;

internal static class ChartRenderBudgetTests
{
    internal static void Run()
    {
        static void Check(bool result) { if (!result) throw new Exception("Chart browser budget regression"); }
        var message = new ChartRenderBudget();
        Check(Enumerable.Range(0, 200).Count(_ => message.TryTake()) == 4);
        var transcript = new ChartRenderBudget(ChartRenderBudget.PerTranscript);
        var counts = Enumerable.Range(0, 100).Select(_ => {
            var reply = new ChartRenderBudget(shared: transcript);
            return Enumerable.Range(0, 200).Count(_ => reply.TryTake());
        }).ToArray();
        Check(counts.Take(2).SequenceEqual(new[] { 4, 4 }) && counts.Skip(2).All(count => count == 0));
        Check(!new ChartRenderBudget(0, transcript).TryTake());
        Console.WriteLine("Chart browsers: bounded to four per reply and eight per eager transcript.");
    }
}
