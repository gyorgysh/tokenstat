// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal static class ChatAgentSteps
{
    internal const string Agent = "backend";
    internal const string Model = "model";
    internal const string Effort = "effort";

    internal static IReadOnlyList<string> For(bool installed, bool hasEfforts)
    {
        if (!installed) return [Agent];
        return hasEfforts ? [Agent, Model, Effort] : [Agent, Model];
    }

    internal static string? Next(IReadOnlyList<string> steps, string step)
    {
        var index = IndexOf(steps, step);
        return index >= 0 && index + 1 < steps.Count ? steps[index + 1] : null;
    }

    internal static string? Previous(IReadOnlyList<string> steps, string step)
    {
        var index = IndexOf(steps, step);
        return index > 0 ? steps[index - 1] : null;
    }

    internal static string Current(IReadOnlyList<string> steps, string wanted) =>
        IndexOf(steps, wanted) >= 0 ? wanted : steps.Count > 0 ? steps[^1] : Agent;

    private static int IndexOf(IReadOnlyList<string> steps, string step)
    {
        for (var index = 0; index < steps.Count; index++)
            if (steps[index] == step) return index;
        return -1;
    }
}
