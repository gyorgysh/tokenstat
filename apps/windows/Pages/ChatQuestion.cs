// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

namespace Tokenstat.Pages;

/// <summary>
/// A question the agent asked in its reply, and the answer once there is one.
/// Port of ChatQuestion.swift. The host finds the block and records it.
/// </summary>
internal sealed record ChatQuestionItem(
    string Id,
    string Question,
    IReadOnlyList<string> Options,
    bool Multiple,
    string? DefaultAnswer,
    bool Blocking)
{
    public string? Answer { get; init; }
    /// <summary><c>note</c>, <c>queued</c> or <c>sent</c>: how the answer travelled.</summary>
    public string? Delivery { get; init; }
}

internal static class ChatQuestionText
{
    public const string Fence = "tokenstat-question";
    /// <summary>A plan the agent wrote for the activity panel. The host reads it, so the reply drops it.</summary>
    public const string PlanFence = "tokenstat-plan";
    // Match the host scanner, including the newline before the closing fence.
    private const int BlockMaxBytes = 64 * 1024;

    /// <summary>
    /// The reply without its question blocks, which the card shows instead. A
    /// block still streaming is cut from its opening line.
    /// </summary>
    public static string Strip(string text, bool streaming = true)
    {
        if (!text.Contains(Fence, StringComparison.Ordinal) && !text.Contains(PlanFence, StringComparison.Ordinal)) return text;
        var kept = new List<string>();
        var inside = false;
        var isPlan = false;
        var block = new List<string>();
        long bodyBytes = 0;
        var lines = text.Split('\n');
        for (var index = 0; index < lines.Length; index++)
        {
            var line = lines[index];
            var trimmed = line.Trim();
            // The host reads the info string trimmed, so "``` tokenstat-question"
            // is a question there too and must not show as raw JSON here.
            var info = trimmed.StartsWith("```", StringComparison.Ordinal) ? trimmed[3..].Trim() : "";
            if (!inside && (info == Fence || info == PlanFence))
            {
                inside = true;
                isPlan = info == PlanFence;
                block = [line];
                bodyBytes = 0;
                continue;
            }
            if (inside)
            {
                // Host closing_fence: ticks may share the line with the next
                // sentence (` ```Yes,...`), so trailing text stays as prose.
                // Probe the raw line (leading space/tab only) so a full trim
                // cannot eat spaces that belong to the glued sentence.
                if (ClosingFenceTrailing(line) is { } trailing)
                {
                    var valid = false;
                    try
                    {
                        var body = string.Join("\n", block.Skip(1));
                        var value = System.Text.Encoding.UTF8.GetByteCount(body) < BlockMaxBytes
                            ? System.Text.Json.Nodes.JsonNode.Parse(body) : null;
                        valid = isPlan
                            ? value is System.Text.Json.Nodes.JsonObject && value["steps"] is System.Text.Json.Nodes.JsonArray
                            : value is System.Text.Json.Nodes.JsonObject && value["question"] is { } question
                                && question.GetValueKind() == System.Text.Json.JsonValueKind.String
                                && !string.IsNullOrWhiteSpace(question.GetValue<string>());
                    }
                    catch (System.Text.Json.JsonException) { }
                    if (!valid)
                    {
                        kept.AddRange(block);
                        kept.Add(line);
                    }
                    else if (trailing.Length > 0)
                    {
                        kept.Add(trailing);
                    }
                    block.Clear();
                    inside = false;
                }
                else
                {
                    block.Add(line);
                    bodyBytes += System.Text.Encoding.UTF8.GetByteCount(line) + (index < lines.Length - 1 ? 1 : 0);
                    if (bodyBytes > BlockMaxBytes)
                    {
                        kept.AddRange(block);
                        block.Clear();
                        inside = false;
                    }
                }
                continue;
            }
            kept.Add(line);
        }
        if (!streaming) kept.AddRange(block);
        return string.Join("\n", kept).Replace("\n\n\n", "\n\n").Trim();
    }

    /// <summary>Prose after closing backticks, or empty when the line is only the fence. Null when it does not close.</summary>
    private static string? ClosingFenceTrailing(string line)
    {
        var index = 0;
        while (index < line.Length && (line[index] == ' ' || line[index] == '\t')) index++;
        var ticks = 0;
        while (index + ticks < line.Length && line[index + ticks] == '`') ticks++;
        if (ticks < 3) return null;
        var trailing = line[(index + ticks)..];
        if (trailing.EndsWith('\r')) trailing = trailing[..^1];
        return trailing.TrimStart(' ', '\t');
    }
}
