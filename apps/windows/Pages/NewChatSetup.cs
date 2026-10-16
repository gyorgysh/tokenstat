// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal sealed record NewChatSetup(string Backend, string? Model, string? Effort,
    string Mode = "execute", string Autonomy = "bypass", bool FastMode = false)
{
    internal static bool ShouldSend(string text, int files = 0) => !string.IsNullOrWhiteSpace(text) || files > 0;
    internal bool IsAvailable(System.Text.Json.Nodes.JsonNode? descriptor)
    {
        bool Offers(string field, string? value) => value is null || descriptor?[field] is System.Text.Json.Nodes.JsonArray options && options.Any(option => option?.ToString() == value);
        return !string.IsNullOrWhiteSpace(Backend) && Backend != "sh" && descriptor is not null && descriptor["id"]?.ToString() == Backend && descriptor["installed"]?.ToString() != "false"
            && Offers("models", Model) && Offers("efforts", Effort)
            && Mode is "plan" or "execute" && Autonomy is "standard" or "bypass"
            && (descriptor["gateTier"]?.ToString() != "bypassOnly" || Autonomy == "bypass")
            && (!FastMode || ChatFastMode.Available(Model, descriptor["fastModeModels"] as System.Text.Json.Nodes.JsonArray, Backend));
    }
}
