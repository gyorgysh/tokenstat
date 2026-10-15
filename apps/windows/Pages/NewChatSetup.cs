// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal sealed record NewChatSetup(string Backend, string? Model, string? Effort)
{
    internal static bool ShouldSend(string text) => !string.IsNullOrWhiteSpace(text);
    internal bool IsAvailable(System.Text.Json.Nodes.JsonNode? descriptor)
    {
        bool Offers(string field, string? value) => value is null || descriptor?[field] is System.Text.Json.Nodes.JsonArray options && options.Any(option => option?.ToString() == value);
        return Backend != "sh" && descriptor is not null && descriptor["id"]?.ToString() == Backend && descriptor["installed"]?.ToString() != "false"
            && Offers("models", Model) && Offers("efforts", Effort);
    }
}
