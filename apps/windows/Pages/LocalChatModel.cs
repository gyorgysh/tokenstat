// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal static class LocalChatModel
{
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

    internal static string? Provider(string id) => Parse(id) is { } local ? ProviderName(local.Provider) : null;

    internal static string Name(string id) => Parse(id)?.Model ?? id;

    internal static string Title(string id) => Parse(id) is { } local ? $"{ProviderName(local.Provider)}: {local.Model}" : id;
}
