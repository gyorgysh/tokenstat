// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// <summary>
/// The setup the last conversation ended up with, so a new chat starts where
/// the person left off. Mirrors the Mac launch choice: the agent, model,
/// effort and persona travel. A new chat starts in Execute and Don't ask;
/// a draft can explicitly choose its own working style and permissions.
///
/// A plain file, not LocalSettings: this app is unpackaged, and
/// ApplicationData.Current throws there.
/// </summary>
internal sealed record ChatLaunchChoice(
    string Backend,
    string Model,
    string Effort,
    string Autonomy,
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
            return null;
        }
    }

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
            ["personaId"] = Format.Text(chat, "personaId"),
        };
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, node.ToJsonString());
        }
        catch
        {
        }
    }
}
