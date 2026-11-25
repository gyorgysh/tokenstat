// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Pages;

static class ChatWindowTests
{
    static void Check(bool answer, string message) { if (!answer) throw new Exception(message); }

    public static void Run()
    {
        string[] before = ["a", "b", "c", "d"];
        Check(ChatPage.AnchorRow(before, 1, 2, new HashSet<string> { "x", "a", "b", "c" }) == "b", "the first visible row that is still drawn holds the place");
        Check(ChatPage.AnchorRow(before, 0, 1, new HashSet<string> { "x", "b", "c" }) == "b", "a joined reply that changed its id passes the place to the next row");
        Check(ChatPage.AnchorRow(before, 0, 0, new HashSet<string> { "joined", "b" }) == "b", "a reply filling the screen uses the row just below it");
        Check(ChatPage.AnchorRow(before, 3, 3, new HashSet<string> { "a" }) is null, "nothing kept leaves the scroll alone");
        var count = 400;
        var older = ChatPage.SliceClamp(100, count);
        Check(ChatPage.SliceStart(count, older) == 150 && ChatPage.SliceEnd(count, older) == 300, "a step up overlaps what was on screen");
        Console.WriteLine("Chat window: the reader's row survives older pages and joined replies");
    }
}
