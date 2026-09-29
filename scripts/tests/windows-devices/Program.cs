// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;

static void Check(bool value, string message) { if (!value) throw new Exception(message); }
var before = JsonNode.Parse("""{"tunnel":true,"tunnelOnline":true,"label":"Computer","traffic":{"bytes":1}}""");
var after = before!.DeepClone();
after["traffic"]!["bytes"] = 999;
Check(JsonNode.DeepEquals(DevicePresentation.ConnectionState(before), DevicePresentation.ConnectionState(after)),
    "Traffic alone must not replace focused device controls.");
Check(before["traffic"]!["bytes"]!.GetValue<int>() == 1, "The source snapshot must remain intact.");
after["tunnelOnline"] = false;
Check(!JsonNode.DeepEquals(DevicePresentation.ConnectionState(before), DevicePresentation.ConnectionState(after)),
    "Connectivity changes must refresh device controls.");
after = before.DeepClone();
after["futureConnectionField"] = true;
Check(!JsonNode.DeepEquals(DevicePresentation.ConnectionState(before), DevicePresentation.ConnectionState(after)),
    "New host connection fields must not disappear from refresh detection.");
Check(DevicePresentation.ConnectionState(null) is null, "Missing status must be accepted.");
Console.WriteLine("Device presentation tests passed.");
