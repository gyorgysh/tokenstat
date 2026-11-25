// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Pages;

static class ChatDraftTests
{
    static void Check(bool answer, string message) { if (!answer) throw new Exception(message); }

    static string Key(string account, string workspace, string chat) => Convert.ToHexString(
        System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(account + "/" + workspace + "/" + chat)));

    public static void Run()
    {
        var folder = Path.Combine(Path.GetTempPath(), "tokenstat-drafts-" + Guid.NewGuid().ToString("N"));
        try
        {
            var key = Key("account", "workspace", "chat");
            var store = new ChatDraftStore(folder);
            Check(store.Read(key) == "", "a conversation starts without a draft");
            store.Write(key, "half a thought\nand 🙂");
            Check(new ChatDraftStore(folder).Read(key) == "half a thought\nand 🙂", "a new launch reads the unsent text");
            Check(store.Read(Key("other", "workspace", "chat")) == "", "another account never reads it");
            store.Write(key, "");
            Check(store.Read(key) == "" && Directory.GetFiles(folder).Length == 0, "sending leaves nothing behind");
            store.Write("../escape", "no");
            Check(Directory.GetFiles(folder).Length == 0, "only an outbox key names a file");
            store.Write(key, new string('x', 300 * 1024));
            Check(store.Read(key) == "", "a draft has a bound");
            for (var i = 0; i < 305; i++) store.Write(Key("account", "workspace", "chat" + i), "text");
            Check(Directory.GetFiles(folder, "*.txt").Length == 300, "the oldest drafts make room");

            PullOpenPreference.FilePath = Path.Combine(folder, "pulls-open-in.txt");
            Check(PullOpenPreference.Choice == PullOpenChoice.Ask, "pull requests ask until told to remember");
            PullOpenPreference.Choice = PullOpenChoice.Browser;
            PullOpenPreference.Forget();
            Check(PullOpenPreference.Choice == PullOpenChoice.Browser, "a remembered place survives a launch");
            Check(PullOpenPreference.Parse("something else") == PullOpenChoice.Ask, "an unknown place asks");
        }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true); }
        Console.WriteLine("Chat drafts: kept across launches, per account, bounded and removed when sent");
    }
}
