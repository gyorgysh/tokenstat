// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text;

namespace Tokenstat.Pages;

internal sealed class ChatDraftStore(string directory)
{
    public static readonly ChatDraftStore Shared = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "chat-drafts"));

    private const int MaximumBytes = 256 * 1024;
    private const int MaximumDrafts = 300;

    private string? PathFor(string key) => key.Length == 64 && key.All(Uri.IsHexDigit)
        ? Path.Combine(directory, key + ".txt") : null;

    public string Read(string key)
    {
        try
        {
            if (PathFor(key) is not { } path || !File.Exists(path) || new FileInfo(path).Length > MaximumBytes) return "";
            return File.ReadAllText(path);
        }
        catch { return ""; }
    }

    public void Write(string key, string text)
    {
        if (PathFor(key) is not { } path) return;
        try
        {
            if (text.Length == 0)
            {
                File.Delete(path);
                return;
            }
            var bytes = Encoding.UTF8.GetBytes(text);
            if (bytes.Length > MaximumBytes) return;
            Directory.CreateDirectory(directory);
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllBytes(temporary, bytes);
                File.Move(temporary, path, overwrite: true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
            Trim(path);
        }
        catch { }
    }

    private void Trim(string kept)
    {
        var files = new DirectoryInfo(directory).GetFiles("*.txt");
        if (files.Length <= MaximumDrafts) return;
        foreach (var old in files.Where(file => file.FullName != kept)
            .OrderBy(file => file.LastWriteTimeUtc).Take(files.Length - MaximumDrafts)) old.Delete();
    }
}
