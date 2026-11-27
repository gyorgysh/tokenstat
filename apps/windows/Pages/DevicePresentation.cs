// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal static class DevicePresentation
{
    internal static JsonNode? ConnectionState(JsonNode? status)
    {
        var result = status?.DeepClone();
        if (result is JsonObject fields) fields.Remove("traffic");
        return result;
    }
}
