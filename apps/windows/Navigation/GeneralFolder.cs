// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tokenstat.Navigation;

/// <summary>
/// The host's folder for chats with no repository (protocol 56). Mirrors
/// Apple <c>WorkspaceFolder.presented</c>. <c>workspace.list</c> returns it
/// only beside <c>includeGeneral</c>, which an older host ignores, so the
/// list never offers it where the host cannot serve it.
/// </summary>
internal static class GeneralFolder
{
    public const int MinimumProtocol = 56;

    public static JsonObject ListParameters() => new() { ["includeGeneral"] = true };

    public static bool IsGeneral(JsonNode? folder) =>
        folder?["general"] is JsonValue value && value.GetValueKind() == JsonValueKind.True;

    /// <summary>Names the general folder "No repository" and lists it first.</summary>
    public static JsonArray Present(JsonArray listed)
    {
        var general = new List<JsonNode?>();
        var projects = new List<JsonNode?>();
        foreach (var folder in listed)
        {
            var copy = folder?.DeepClone();
            if (IsGeneral(copy) && copy is JsonObject named)
            {
                named["name"] = L10n.Text("common.new_chat.no_repository");
                general.Add(named);
            }
            else
            {
                projects.Add(copy);
            }
        }
        return new JsonArray(general.Concat(projects).ToArray());
    }
}
