// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;
using static Tokenstat.Pages.TeamManagementModel;

internal static class TeamFolderShareTests
{
    internal static async Task RunAsync()
    {
        static void Check(bool value, string reason) { if (!value) throw new Exception(reason); }
        static async Task Refuses(Func<Task> run) { try { await run(); } catch (InvalidDataException) { return; } throw new Exception("Unsafe project sharing accepted"); }
        static JsonObject Page(string key, params JsonObject[] rows) => new() { [key] = new JsonArray(rows.Select(row => row.DeepClone()).ToArray()), ["nextOffset"] = null };
        var workspace = new JsonObject { ["id"] = "folder", ["name"] = "Fictional folder" };
        var org = new JsonObject { ["id"] = "org", ["role"] = "owner", ["state"] = "active", ["eligible"] = true };
        var repo = new JsonObject { ["id"] = "created", ["name"] = "Fictional folder", ["organizationId"] = "org", ["role"] = "maintainer" };
        var member = new JsonObject { ["id"] = "mate", ["name"] = "Reviewed teammate", ["eligible"] = true, ["role"] = null, ["revision"] = 0L };
        var writes = new List<JsonObject>(); var attempts = new List<JsonObject>(); var createCount = 0; var collision = false;
        Task<JsonNode> Host(string method, JsonObject? fields)
        {
            if (Text(fields, "_accountSession") != "session") throw new Exception("Folder share lost its account receipt");
            JsonNode result;
            if (method == "teams.directory")
            {
                result = Text(fields, "operation") switch {
                    "organizations.get" => new JsonObject { ["organization"] = org.DeepClone() },
                    "repositories.list" => collision ? Page("repositories", repo) : Page("repositories"),
                    "members.list" => Page("members", new JsonObject { ["id"] = "owner", ["eligible"] = true }, member,
                        new JsonObject { ["id"] = "ineligible", ["eligible"] = false }),
                    "repositories.create" => Create(),
                    "repositories.members" => Page("members", member, new JsonObject { ["id"] = "future", ["eligible"] = true, ["role"] = null, ["revision"] = 0L }),
                    "repositories.access" => Grant(),
                    _ => throw new Exception("Unexpected project setup operation"),
                };
            }
            else if (method == "teams.checkout.preview") result = new JsonObject { ["workspaceId"] = "folder", ["repository"] = repo.DeepClone(), ["preview"] = new string('a', 64), ["sharesExistingChats"] = false, ["allowsAgentRuns"] = false };
            else if (method == "teams.checkout.publish")
            {
                attempts.Add((JsonObject)fields!.DeepClone()); if (attempts.Count == 1) throw new IOException("Fictional lost publication reply");
                result = new JsonObject { ["publication"] = new JsonObject { ["id"] = "checkout", ["organizationId"] = "org", ["repositoryId"] = "created", ["workspaceId"] = "folder" } };
            }
            else throw new Exception("Unexpected local setup method");
            return Task.FromResult(result);
            JsonNode Create() { createCount++; return new JsonObject { ["repository"] = repo.DeepClone() }; }
            JsonNode Grant() { writes.Add((JsonObject)fields!.DeepClone()); member["role"] = fields["input"]!["role"]!.DeepClone(); member["revision"] = 1L; return new JsonObject(); }
        }
        var client = new TeamDirectoryClient(new() { ["origin"] = "https://fixture.invalid" }, "session", "owner", Host);
        var model = new TeamFolderShareModel(client, workspace, org); await model.Load();
        Check(model.Included.SetEquals(["mate"]), "Project default included self, an ineligible person or an unreviewed member");
        try { await model.Share(); } catch (IOException) { }
        Check(model.Locked && model.Created is not null && createCount == 1 && writes.Count == 1 && Text(writes.Single(), "user") == "mate", "Partial setup lost project or reviewed people");
        model.Included.Add("future"); model.AccessRole = "viewer";
        await model.Share();
        Check(createCount == 1 && writes.Count == 1 && attempts.Count == 2 && JsonNode.DeepEquals(attempts[0], attempts[1]), "Retry created another project, expanded access or replaced the original publication");
        member["role"] = null; member["revision"] = 2L;
        await Refuses(() => model.Share()); Check(writes.Count == 1 && attempts.Count == 2, "Retry restored revoked permission");
        collision = true;
        var existing = new TeamFolderShareModel(client, workspace, org); await existing.Load();
        await Refuses(() => existing.Share()); Check(createCount == 1, "Same-named project was silently reused or duplicated");
        existing.ChooseExisting("created"); await existing.Share();
        Check(createCount == 1 && writes.Count == 1, "Explicit existing project changed its member access");
        Console.WriteLine("Windows folder sharing: reviewed eligible people only, original partial-setup retry, no future grants, no revoked access restoration and explicit existing-project selection pass.");
    }
}
