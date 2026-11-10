// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// The order of the agent, model and effort panel, as steps.
///
/// Picking an agent moves on to its models, picking a model moves on to its
/// efforts, and picking in the last step closes the panel. An agent with no
/// effort control has two steps, not three. Kept apart from the page so the
/// walk can be tested without a window. Mirrors the Mac's stepped
/// `PickerOptionList` and Android's `pickerNextStep`.
internal static class ChatAgentSteps
{
    internal const string Agent = "backend";
    internal const string Model = "model";
    internal const string Effort = "effort";

    /// The steps this agent has. Model and effort need an installed agent, and
    /// effort needs one that lists efforts.
    internal static IReadOnlyList<string> For(bool installed, bool hasEfforts)
    {
        if (!installed) return [Agent];
        return hasEfforts ? [Agent, Model, Effort] : [Agent, Model];
    }

    /// The step after `step`, or null when the panel should close: after the
    /// last step, and for a step the agent no longer has.
    internal static string? Next(IReadOnlyList<string> steps, string step)
    {
        var index = IndexOf(steps, step);
        return index >= 0 && index + 1 < steps.Count ? steps[index + 1] : null;
    }

    /// The step before `step`, or null on the first.
    internal static string? Previous(IReadOnlyList<string> steps, string step)
    {
        var index = IndexOf(steps, step);
        return index > 0 ? steps[index - 1] : null;
    }

    /// Where the panel stands. A step that disappeared (Effort after switching
    /// to an agent without it) falls back to the last one that still exists.
    internal static string Current(IReadOnlyList<string> steps, string wanted) =>
        IndexOf(steps, wanted) >= 0 ? wanted : steps.Count > 0 ? steps[^1] : Agent;

    private static int IndexOf(IReadOnlyList<string> steps, string step)
    {
        for (var index = 0; index < steps.Count; index++)
            if (steps[index] == step) return index;
        return -1;
    }
}
