// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// <summary>
/// When a message is about to make the agent read a whole conversation again.
/// Mirrors the Mac's <c>ChatPromptCacheRule</c>.
///
/// The provider caches a conversation for one model, for a few minutes or an
/// hour after the last turn. The host records the size, model and lifetime on
/// the conversation as <c>promptCache</c>. No percentage of a plan is shown:
/// nobody publishes how tokens map onto one.
/// </summary>
internal static class ChatCacheRule
{
    /// <summary>Below this a full read is cheap, and a question is noise.</summary>
    public const long MinimumTokens = 50_000;

    /// <summary>Protocol 54 adds <c>chat.continueInNew</c>.</summary>
    public const int ContinueMinProtocol = 54;

    public static long NowMs => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    /// <summary>The record, when it is this agent's and big enough to matter.</summary>
    public static JsonObject? Cache(JsonNode? chat)
    {
        if ((chat as JsonObject)?["promptCache"] is not JsonObject cache) return null;
        if (Format.Text(cache, "backend") != Format.Text(chat, "backend")) return null;
        return Format.Long(cache, "tokens") >= MinimumTokens ? cache : null;
    }

    /// <summary>How long the cache has been gone, or null while it holds.</summary>
    public static long? Idle(JsonNode? chat, long nowMs)
    {
        if (Cache(chat) is not { } cache) return null;
        var idle = nowMs - Format.Long(cache, "atMs");
        return idle > Format.Long(cache, "ttlMs") ? idle : null;
    }

    /// <summary>
    /// A warm cache on another model. A cold one costs the same either way,
    /// and the send question covers it.
    /// </summary>
    public static bool Switching(JsonNode? chat, string next, long nowMs)
    {
        if (Cache(chat) is not { } cache) return false;
        if (nowMs - Format.Long(cache, "atMs") > Format.Long(cache, "ttlMs")) return false;
        return Format.Text(cache, "selection") != (next ?? "");
    }

    /// <summary>Days and hours, or hours and minutes, like "1d 17h".</summary>
    public static string Duration(long milliseconds)
    {
        var minutes = Math.Max(0, milliseconds) / 60_000;
        var hours = minutes / 60;
        var days = hours / 24;
        if (days > 0) return hours % 24 > 0 ? $"{days}d {hours % 24}h" : $"{days}d";
        if (hours > 0) return minutes % 60 > 0 ? $"{hours}h {minutes % 60}m" : $"{hours}h";
        return $"{minutes}m";
    }

    public static string ModelName(string? id) =>
        string.IsNullOrEmpty(id) ? L10n.Text("common.chat.cache.default_model") : id;

    public static bool IdleSuppressed
    {
        get => Suppressed("chat-cache-idle-suppressed");
        set => Suppress("chat-cache-idle-suppressed", value);
    }

    public static bool ModelSuppressed
    {
        get => Suppressed("chat-cache-model-suppressed");
        set => Suppress("chat-cache-model-suppressed", value);
    }

    // A plain file, not LocalSettings: this app is unpackaged, and
    // ApplicationData.Current throws there.
    private static string FilePath(string name) => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", name);

    private static bool Suppressed(string name)
    {
        try { return File.Exists(FilePath(name)); }
        catch { return false; }
    }

    private static void Suppress(string name, bool value)
    {
        try
        {
            var path = FilePath(name);
            if (!value) { File.Delete(path); return; }
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, "1");
        }
        catch
        {
            // Remembering is a courtesy. The next question can be answered again.
        }
    }
}
