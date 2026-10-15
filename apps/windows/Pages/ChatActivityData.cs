// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal sealed record ChatActivityGoal(string Objective, string Status, double? TokenBudget, double? TokensUsed,
    double? TimeBudgetSeconds, double? TimeUsedSeconds, string? Source);
internal sealed record ChatActivityStep(string Text, string Status);
internal sealed record ChatActivityAgent(string Id, string? Name, string? Task, string Status, string? Model, string? Source)
{
    internal string DisplayStatus(bool live) => !live && Status is "pending" or "running" or "waiting" ? "unknown" : Status;
}
internal sealed record ChatActivityData(ChatActivityGoal? Goal, ChatActivityStep[] Plan, ChatActivityAgent[] Agents, string? PlanSource,
    bool GoalReported, bool PlanReported, bool AgentsReported, bool Partial, bool Live, long? ObservedAtMs)
{
    internal bool HasContent => Goal is not null || Plan.Length > 0 || Agents.Length > 0;
    internal int? RunningAgents => Live && AgentsReported && Agents.All(agent => agent.Status != "unknown") ? Agents.Count(agent => agent.Status == "running") : null;
    internal int CompletedSteps => Plan.Count(step => step.Status == "completed");
    internal string? Headline => !string.IsNullOrWhiteSpace(Goal?.Objective) ? Goal.Objective : Plan.FirstOrDefault(step => step.Status == "inProgress")?.Text;
    internal static double? Progress(double? used, double? budget) => used is double amount && budget is double limit
        && double.IsFinite(amount) && amount >= 0 && double.IsFinite(limit) && limit > 0 ? Math.Clamp(amount / limit, 0, 1) : null;
    private static string? Text(JsonNode? node, string key) => node?[key] is JsonValue value && value.TryGetValue<string>(out var result) && !string.IsNullOrWhiteSpace(result) ? result : null;
    private static bool Flag(JsonNode? node, string key) => node?[key] is JsonValue value && value.TryGetValue<bool>(out var result) && result;
    private static double? Metric(JsonNode? node, string key) => node?[key] is JsonValue value && value.TryGetValue<double>(out var result) && double.IsFinite(result) && result >= 0 ? result : null;
    private static string Status(JsonNode node, params string[] allowed) => Text(node, "status") is string status && allowed.Contains(status) ? status : "unknown";
    internal static ChatActivityData? Read(JsonNode? inspection, JsonNode? chat)
    {
        if (inspection?["activity"] is not JsonObject raw) return null;
        var goalReported = Flag(raw, "goalReported");
        var planReported = Flag(raw, "planReported");
        var agentsReported = Flag(raw, "agentsReported");
        var goal = raw["goal"] is JsonObject g && goalReported ? new ChatActivityGoal(Text(g, "objective") ?? "",
            Status(g, "active", "paused", "completed", "blocked", "budgetLimited", "usageLimited"), Metric(g, "tokenBudget"), Metric(g, "tokensUsed"),
            Metric(g, "timeBudgetSeconds"), Metric(g, "timeUsedSeconds"), Text(g, "source")) : null;
        var plan = planReported && raw["plan"] is JsonArray p ? p.OfType<JsonObject>().Select(step => new ChatActivityStep(Text(step, "text") ?? "", Status(step, "pending", "inProgress", "completed"))).ToArray() : [];
        var agents = agentsReported && raw["agents"] is JsonArray a ? a.OfType<JsonObject>().Where(agent => Text(agent, "id") is not null).Select(agent => new ChatActivityAgent(
            Text(agent, "id")!, Text(agent, "name"), Text(agent, "task"), Status(agent, "pending", "running", "waiting", "completed", "failed", "stopped"), Text(agent, "model"), Text(agent, "source"))).ToArray() : [];
        var observedAt = inspection?["observedAtMs"] is JsonValue stamp && stamp.TryGetValue<long>(out var milliseconds)
            && milliseconds is >= 0 and <= 253402300799999 ? (long?)milliseconds : null;
        return new(goal, plan, agents, Text(raw, "planSource"), goalReported, planReported, agentsReported, Flag(raw, "partial"),
            Flag(raw, "live") && Flag(inspection, "currentRun") && Flag(chat, "running"), observedAt);
    }
}
