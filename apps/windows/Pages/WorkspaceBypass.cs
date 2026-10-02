// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// <summary>
/// Whether tools launched in a project skip their permission prompts, per
/// project, like the Mac's Bypass switch. Off unless somebody turned it on:
/// an agent that asks before acting is the default everywhere.
///
/// A plain file, not LocalSettings: this app is unpackaged, and
/// ApplicationData.Current throws there.
/// </summary>
internal static class WorkspaceBypass
{
    private static readonly object Gate = new();

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tokenstat",
        "workspace-bypass.json");

    public static bool IsOn(string workspaceId)
    {
        lock (Gate)
        {
            return Read()[workspaceId] is JsonValue value
                && value.TryGetValue<bool>(out var on) && on;
        }
    }

    public static void Set(string workspaceId, bool on)
    {
        lock (Gate)
        {
            var all = Read();
            if (on) all[workspaceId] = true;
            else all.Remove(workspaceId);
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                File.WriteAllText(FilePath, all.ToJsonString());
            }
            catch
            {
                // Not remembered, so the next launch asks first. The safe way
                // to lose this setting.
            }
        }
    }

    private static JsonObject Read()
    {
        try
        {
            return File.Exists(FilePath) && JsonNode.Parse(File.ReadAllText(FilePath)) is JsonObject all
                ? all
                : new JsonObject();
        }
        catch
        {
            return new JsonObject();
        }
    }
}
