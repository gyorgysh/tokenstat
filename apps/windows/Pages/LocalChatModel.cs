// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>
/// A chat model on a local server, named <c>local:&lt;provider&gt;/&lt;model&gt;</c> by
/// the host. Shown as the server and the model rather than the stored id.
/// Port of the Apple <c>LocalChatModel</c>.
/// </summary>
internal static class LocalChatModel
{
    /// <summary>Below this an agent's own instructions crowd out the conversation.</summary>
    internal const long RoomyContext = 65_536;

    private static (string Provider, string Model)? Parse(string id)
    {
        if (!id.StartsWith("local:", StringComparison.Ordinal)) return null;
        var rest = id["local:".Length..];
        var slash = rest.IndexOf('/');
        if (slash <= 0 || slash == rest.Length - 1) return null;
        return (rest[..slash], rest[(slash + 1)..]);
    }

    private static string ProviderName(string id) => id switch
    {
        "lmstudio" => "LM Studio",
        "ollama" => "Ollama",
        _ => id,
    };

    /// <summary>The server's name for a local id, null for a cloud model.</summary>
    internal static string? Provider(string id) => Parse(id) is { } local ? ProviderName(local.Provider) : null;

    /// <summary>The model alone for a local id, the id itself otherwise.</summary>
    internal static string Name(string id) => Parse(id)?.Model ?? id;

    /// <summary><c>Ollama: qwen2.5</c> for a local id, the id itself otherwise.</summary>
    internal static string Title(string id) => Parse(id) is { } local ? $"{ProviderName(local.Provider)}: {local.Model}" : id;
}
