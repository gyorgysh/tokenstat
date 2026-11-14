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
            if (!inside && Opening(line) is { } open)
            {
                if (open.Prefix.Length > 0) kept.Add(open.Prefix);
                inside = true;
                isPlan = open.IsPlan;
                block = [open.FenceLine];
                bodyBytes = 0;
                if (open.SameLineBody is { } same)
                {
                    if (CloseBodyLine(same, block, ref isPlan, kept) is { } closed)
                    {
                        inside = closed;
                        bodyBytes = 0;
                    }
                    else
                    {
                        bodyBytes = System.Text.Encoding.UTF8.GetByteCount(same);
                        block.Add(same);
                    }
                }
                continue;
            }
            if (inside)
            {
                if (CloseBodyLine(line, block, ref isPlan, kept) is { } closed)
                {
                    inside = closed;
                    bodyBytes = 0;
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

    private readonly record struct FenceOpening(string Prefix, string FenceLine, string? SameLineBody, bool IsPlan);
    private readonly record struct FenceMatch(string Language, string? Body, bool IsPlan);
    private readonly record struct FenceClose(string BodyPrefix, string Trailing);

    private static FenceOpening? Opening(string line)
    {
        var index = 0;
        while (index <= line.Length - 3)
        {
            var tick = line.IndexOf("```", index, StringComparison.Ordinal);
            if (tick < 0) return null;
            var after = line[(tick + 3)..];
            var headerEnd = after.IndexOf('\n');
            if (headerEnd < 0) headerEnd = after.Length;
            var header = after[..headerEnd].TrimEnd('\r');
            if (FenceBody(header) is { } matched)
            {
                return new FenceOpening(line[..tick].Trim(), "```" + matched.Language, matched.Body, matched.IsPlan);
            }
            index = tick + 3;
        }
        return null;
    }

    private static FenceMatch? FenceBody(string header)
    {
        var trimmed = header.Trim();
        foreach (var (name, isPlan) in new[] { (PlanFence, true), (Fence, false) })
        {
            if (trimmed == name) return new FenceMatch(name, null, isPlan);
            if (!trimmed.StartsWith(name, StringComparison.Ordinal)) continue;
            var rest = trimmed[name.Length..];
            if (rest.Length == 0) return new FenceMatch(name, null, isPlan);
            if (!char.IsWhiteSpace(rest[0])) continue;
            var body = rest.TrimStart();
            return new FenceMatch(name, body.Length == 0 ? null : body, isPlan);
        }
        return null;
    }

    /// <summary>True when still inside a block after this line.</summary>
    private static bool? CloseBodyLine(string line, List<string> block, ref bool isPlan, List<string> kept)
    {
        if (ClosingFence(line) is not { } closed) return null;
        if (closed.BodyPrefix.Length > 0) block.Add(closed.BodyPrefix);
        var body = string.Join("\n", block.Skip(1));
        var valid = false;
        try
        {
            var value = System.Text.Encoding.UTF8.GetByteCount(body) < BlockMaxBytes
                ? System.Text.Json.Nodes.JsonNode.Parse(body) : null;
            valid = isPlan
                ? value is System.Text.Json.Nodes.JsonObject && value["steps"] is System.Text.Json.Nodes.JsonArray
                : value is System.Text.Json.Nodes.JsonObject && value["question"] is { } question
                    && question.GetValueKind() == System.Text.Json.JsonValueKind.String
                    && !string.IsNullOrWhiteSpace(question.GetValue<string>());
        }
        catch (System.Text.Json.JsonException) { }
        var next = closed.Trailing.Trim(' ', '\t');
        var nextInfo = next.StartsWith("```", StringComparison.Ordinal) ? FenceBody(next[3..]) : null;
        if (!valid)
        {
            kept.AddRange(block);
            if (closed.BodyPrefix.Length == 0)
            {
                kept.Add(nextInfo is not null ? line[..^closed.Trailing.Length] : line);
            }
            else if (nextInfo is null && closed.Trailing.Length > 0)
            {
                kept.Add(closed.Trailing);
            }
        }
        else if (closed.Trailing.Length > 0 && nextInfo is null)
        {
            kept.Add(closed.Trailing);
        }
        block.Clear();
        if (nextInfo is { } openNext)
        {
            isPlan = openNext.IsPlan;
            block.Add("```" + openNext.Language);
            return true;
        }
        return false;
    }

    private static FenceClose? ClosingFence(string line)
    {
        var index = 0;
        while (index < line.Length && (line[index] == ' ' || line[index] == '\t')) index++;
        var ticks = 0;
        while (index + ticks < line.Length && line[index + ticks] == '`') ticks++;
        if (ticks >= 3)
        {
            var afterRun = line[(index + ticks)..].TrimStart(' ', '\t');
            if (ticks >= 6 && afterRun.Length > 0 && char.IsAsciiLetter(afterRun[0]))
            {
                var glued = line[(index + 3)..];
                return new FenceClose("", glued.EndsWith('\r') ? glued[..^1] : glued);
            }
            var trailing = line[(index + ticks)..];
            if (trailing.EndsWith('\r')) trailing = trailing[..^1];
            return new FenceClose("", trailing.TrimStart(' ', '\t'));
        }
        return TrailingClose(line);
    }

    private static FenceClose? TrailingClose(string line)
    {
        var index = 0;
        while (index <= line.Length - 3)
        {
            var tick = line.IndexOf("```", index, StringComparison.Ordinal);
            if (tick < 0) return null;
            var before = line[..tick];
            if (string.IsNullOrWhiteSpace(before))
            {
                index = tick + 3;
                continue;
            }
            var ticks = 0;
            while (tick + ticks < line.Length && line[tick + ticks] == '`') ticks++;
            var afterRun = line[(tick + ticks)..].TrimStart(' ', '\t');
            if (ticks >= 6 && afterRun.Length > 0 && char.IsAsciiLetter(afterRun[0]))
            {
                var glued = line[(tick + 3)..];
                return new FenceClose(before, glued.EndsWith('\r') ? glued[..^1] : glued);
            }
            var trailing = line[(tick + ticks)..];
            if (trailing.EndsWith('\r')) trailing = trailing[..^1];
            return new FenceClose(before, trailing.TrimStart(' ', '\t'));
        }
        return null;
    }
}
