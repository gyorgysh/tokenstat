// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal static class DevicePresentation
{
    // Traffic counters change on every poll but are not rendered by Devices.
    // Preserve all connection fields, including ones added by newer hosts.
    internal static JsonNode? ConnectionState(JsonNode? status)
    {
        var result = status?.DeepClone();
        if (result is JsonObject fields) fields.Remove("traffic");
        return result;
    }
}
