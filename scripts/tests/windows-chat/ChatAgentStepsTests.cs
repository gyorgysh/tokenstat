// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Pages;

internal static class ChatAgentStepsTests
{
    internal static void Run()
    {
        static void Check(bool result, string message) { if (!result) throw new Exception(message); }
        var full = ChatAgentSteps.For(installed: true, hasEfforts: true);
        Check(full.SequenceEqual(new[] { "backend", "model", "effort" }), "an agent with efforts asks three questions in order");
        Check(ChatAgentSteps.Next(full, "backend") == "model" && ChatAgentSteps.Next(full, "model") == "effort",
            "picking moves on to the next step");
        Check(ChatAgentSteps.Next(full, "effort") is null, "the last step closes the panel");
        var noEffort = ChatAgentSteps.For(installed: true, hasEfforts: false);
        Check(ChatAgentSteps.Next(noEffort, "model") is null, "an agent without efforts finishes on the model step");
        Check(ChatAgentSteps.For(installed: false, hasEfforts: true).SequenceEqual(new[] { "backend" }),
            "an agent that is not installed offers only the agent step");
        Check(ChatAgentSteps.Previous(full, "backend") is null && ChatAgentSteps.Previous(full, "effort") == "model",
            "back goes one step and stops at the first");
        Check(ChatAgentSteps.Current(noEffort, "effort") == "model" && ChatAgentSteps.Current(full, "model") == "model",
            "a step the new agent lacks falls back to its last one");
        Console.WriteLine("Agent steps: agent, model and effort walk in order, skip what an agent lacks, and go back.");
    }
}
