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
    // Match the host scanner, including the newline before the closing fence.
    private const int BlockMaxBytes = 64 * 1024;

    /// <summary>
    /// The reply without its question blocks, which the card shows instead. A
    /// block still streaming is cut from its opening line.
    /// </summary>
    public static string Strip(string text, bool streaming = true)
    {
        if (!text.Contains(Fence, StringComparison.Ordinal)) return text;
        var kept = new List<string>();
        var inside = false;
        var block = new List<string>();
        foreach (var line in text.Split('\n'))
        {
            var trimmed = line.Trim();
            // The host reads the info string trimmed, so "``` tokenstat-question"
            // is a question there too and must not show as raw JSON here.
            if (!inside && trimmed.StartsWith("```", StringComparison.Ordinal) && trimmed[3..].Trim() == Fence)
            {
                inside = true;
                block = [line];
                continue;
            }
            if (inside)
            {
                block.Add(line);
                if (trimmed == "```")
                {
                    var valid = false;
                    try
                    {
                        var body = string.Join("\n", block.Skip(1).SkipLast(1));
                        var value = System.Text.Encoding.UTF8.GetByteCount(body) < BlockMaxBytes
                            ? System.Text.Json.Nodes.JsonNode.Parse(body) : null;
                        valid = value is System.Text.Json.Nodes.JsonObject && value["question"] is { } question
                            && question.GetValueKind() == System.Text.Json.JsonValueKind.String
                            && !string.IsNullOrWhiteSpace(question.GetValue<string>());
                    }
                    catch (System.Text.Json.JsonException) { }
                    if (!valid) kept.AddRange(block);
                    block.Clear();
                    inside = false;
                }
                continue;
            }
            kept.Add(line);
        }
        if (!streaming) kept.AddRange(block);
        return string.Join("\n", kept).Replace("\n\n\n", "\n\n").Trim();
    }
}
