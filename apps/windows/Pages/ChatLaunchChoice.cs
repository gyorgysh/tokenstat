// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// <summary>
/// The setup the last conversation ended up with, so a new chat starts where
/// the person left off. Mirrors the Mac launch choice: the agent, model,
/// effort, autonomy and persona travel, the mode does not. A new chat always
/// starts in Execute, because Plan is a choice for one piece of work.
///
/// A plain file, not LocalSettings: this app is unpackaged, and
/// ApplicationData.Current throws there.
/// </summary>
internal sealed record ChatLaunchChoice(
    string Backend,
    string Model,
    string Effort,
    string Autonomy,
    // Three states, all different: null means nothing was recorded and the
    // workspace default applies, empty means the person chose no persona,
    // and an id means that one.
    string? PersonaId)
{
    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tokenstat",
        "chat-launch-choice.json");

    public static ChatLaunchChoice? Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return null;
            var node = JsonNode.Parse(File.ReadAllText(FilePath));
            if (node is null) return null;
            var backend = Format.Text(node, "backend");
            if (string.IsNullOrEmpty(backend)) return null;
            return new ChatLaunchChoice(
                backend,
                Format.Text(node, "model"),
                Format.Text(node, "effort"),
                Format.Text(node, "autonomy", "bypass"),
                node["personaId"] is null ? null : Format.Text(node, "personaId"));
        }
        catch
        {
            // A damaged file only costs the remembered setup.
            return null;
        }
    }

    /// <summary>Remember the setup of a conversation record the host returned.</summary>
    public static void Save(JsonNode? chat)
    {
        var backend = Format.Text(chat, "backend");
        if (string.IsNullOrEmpty(backend)) return;
        var node = new JsonObject
        {
            ["backend"] = backend,
            ["model"] = Format.Text(chat, "model"),
            ["effort"] = Format.Text(chat, "effort"),
            ["autonomy"] = Format.Text(chat, "autonomy", "standard"),
            // Empty, not absent: no persona is a choice worth carrying.
            ["personaId"] = Format.Text(chat, "personaId"),
        };
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, node.ToJsonString());
        }
        catch
        {
            // Remembering is a courtesy. The next chat takes the defaults.
        }
    }
}
