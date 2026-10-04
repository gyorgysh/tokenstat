// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.


namespace Tokenstat.Pages;

/// <summary>
/// How much of an agent's work a transcript shows between a question and its
/// answer. Port of ChatTranscriptFold.swift <c>ChatDetail</c>. Every level
/// keeps the question, every reply, an approval, a failure and an attachment.
/// </summary>
internal enum ChatDetail
{
    /// <summary>One line per stretch of work.</summary>
    Compact,
    /// <summary>Thinking and runs of reads and searches fold to one line each.</summary>
    Standard,
    /// <summary>Every step on its own row, with its output open.</summary>
    Detailed,
}

internal enum ChatStepGroupStyle { Work, Explored, Thought }

/// <summary>One folded line standing in for several rows. Port of <c>ChatStepGroup</c>.</summary>
internal sealed record ChatStepGroup
{
    public ChatStepGroupStyle Style { get; init; }
    public bool Open { get; init; }
    /// <summary>The rows this line stands for, oldest first.</summary>
    public IReadOnlyList<string> MemberIds { get; init; } = [];
    /// <summary>The rows themselves, shown below the header when it is open.</summary>
    public IReadOnlyList<ChatPage.DisplayItem> Members { get; init; } = [];
    /// <summary>Tool calls and edits. Thinking and in-between text are not steps.</summary>
    public int Steps { get; init; }
    public int Files { get; init; }
    public long Added { get; init; }
    public long Removed { get; init; }
    public int Reads { get; init; }
    public int Searches { get; init; }
    public int Pages { get; init; }
    public bool Running { get; init; }
    public string? LiveVerb { get; init; }
    public string? LiveTarget { get; init; }
    public long? StartedAt { get; init; }
    public long? EndedAt { get; init; }
    /// <summary>The turn's reported spend, in Compact, where its usage row is not drawn.</summary>
    public double? Cost { get; init; }
    /// <summary>The first line of a folded thought.</summary>
    public string? Preview { get; init; }
}

/// <summary>
/// Folds coalesced rows into what a detail level shows. Port of
/// <c>ChatTranscriptFold</c>. Detailed is the identity. An open group is its
/// header followed by its steps, each marked with <c>GroupId</c>, never one
/// tall card.
/// </summary>
internal static class ChatDetailFold
{
    private static readonly HashSet<string> ReadVerbs = ["Read"];
    private static readonly HashSet<string> SearchVerbs = ["Grep", "Search", "Glob", "Find", "WebSearch"];
    private static readonly HashSet<string> PageVerbs = ["WebFetch"];

    public static List<ChatPage.DisplayItem> Fold(
        List<ChatPage.DisplayItem> items,
        ChatDetail detail,
        bool running,
        Func<string, bool> isOpen) => detail switch
    {
        ChatDetail.Compact => Compact(items, running, isOpen),
        ChatDetail.Standard => Standard(items, running, isOpen),
        _ => items,
    };

    /// <summary>
    /// The group header standing for <paramref name="id"/>, when it is one of
    /// a closed group's steps.
    /// </summary>
    public static string? Owner(string id, List<ChatPage.DisplayItem> folded)
    {
        foreach (var item in folded)
        {
            if (item.Kind == ChatPage.ItemKind.Group && item.Group is { Open: false } group && group.MemberIds.Contains(id))
            {
                return item.Id;
            }
        }
        return null;
    }

    /// <summary>Named after the first step, so it holds while a live turn grows.</summary>
    public static string GroupId(string firstMember) => "g:" + firstMember;

    private static bool IsExploration(string verb) =>
        ReadVerbs.Contains(verb) || SearchVerbs.Contains(verb) || PageVerbs.Contains(verb);

    private static List<ChatPage.DisplayItem> Standard(
        List<ChatPage.DisplayItem> items, bool running, Func<string, bool> isOpen)
    {
        var output = new List<ChatPage.DisplayItem>(items.Count);
        var run = new List<ChatPage.DisplayItem>();

        void FlushRun(bool trailing)
        {
            // One read is a row like any other.
            if (run.Count >= 2) Emit(Make(ChatStepGroupStyle.Explored, run, running && trailing), run, output, isOpen);
            else output.AddRange(run);
            run.Clear();
        }

        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            if (item.Kind == ChatPage.ItemKind.Tool && !item.Failed && IsExploration(item.Verb))
            {
                run.Add(item);
            }
            else if (item.Kind == ChatPage.ItemKind.Thinking)
            {
                FlushRun(false);
                // Reasoning still arriving stays open. It folds once anything
                // comes after it.
                if (running && index == items.Count - 1)
                {
                    output.Add(item);
                }
                else
                {
                    var group = Make(ChatStepGroupStyle.Thought, [item], false) with { Preview = Preview(item.Text) };
                    Emit(group, [item], output, isOpen);
                }
            }
            else
            {
                FlushRun(false);
                output.Add(item);
            }
        }
        FlushRun(true);
        return output;
    }

    private static List<ChatPage.DisplayItem> Compact(
        List<ChatPage.DisplayItem> items, bool running, Func<string, bool> isOpen)
    {
        var output = new List<ChatPage.DisplayItem>();
        // A turn runs from one question to the next. Rows before the first
        // question (a window that opens mid-turn) are a turn of their own.
        var starts = new List<int>();
        for (var i = 0; i < items.Count; i++)
        {
            if (items[i].Kind == ChatPage.ItemKind.User) starts.Add(i);
        }
        if (starts.Count == 0 || starts[0] != 0) starts.Insert(0, 0);
        for (var n = 0; n < starts.Count; n++)
        {
            var start = starts[n];
            if (start >= items.Count) continue;
            var end = n + 1 < starts.Count ? starts[n + 1] : items.Count;
            CompactTurn(items.GetRange(start, end - start), running && end == items.Count, isOpen, output);
        }
        return output;
    }

    private static void CompactTurn(
        List<ChatPage.DisplayItem> turn, bool live, Func<string, bool> isOpen, List<ChatPage.DisplayItem> output)
    {
        var members = new List<ChatPage.DisplayItem>();
        var usage = new List<ChatPage.DisplayItem>();
        var cost = 0.0;
        var lastHeader = -1;

        void Flush(bool trailing)
        {
            if (members.Count == 0) return;
            lastHeader = output.Count;
            var thoughtsOnly = members.All(item => item.Kind == ChatPage.ItemKind.Thinking);
            var group = Make(thoughtsOnly ? ChatStepGroupStyle.Thought : ChatStepGroupStyle.Work, members, live && trailing);
            if (thoughtsOnly) group = group with { Preview = Preview(members[0].Text) };
            Emit(group, [.. members], output, isOpen);
            members.Clear();
        }

        for (var index = 0; index < turn.Count; index++)
        {
            var item = turn[index];
            switch (item.Kind)
            {
                case ChatPage.ItemKind.Usage:
                    cost += item.Cost;
                    usage.Add(item);
                    break;
                case ChatPage.ItemKind.Thinking:
                case ChatPage.ItemKind.Tool when !item.Failed:
                case ChatPage.ItemKind.Edit when !item.Failed:
                    members.Add(item);
                    break;
                default:
                    // Replies, questions, failures and handoffs stay in order.
                    Flush(false);
                    output.Add(item);
                    break;
            }
        }
        Flush(true);

        // The spend rides on the turn's last work line. A turn with no work to
        // fold, or nothing spent because a plan covers it, keeps its usage
        // rows, or its token counts would just vanish.
        if (lastHeader >= 0 && cost > 0 && output[lastHeader].Group is { } group)
        {
            var header = output[lastHeader];
            header.Group = group with { Cost = cost };
            output[lastHeader] = header;
        }
        else
        {
            output.AddRange(usage);
        }
    }

    private static void Emit(
        ChatStepGroup group,
        List<ChatPage.DisplayItem> members,
        List<ChatPage.DisplayItem> output,
        Func<string, bool> isOpen)
    {
        var id = GroupId(members[0].Id);
        var open = isOpen(id);
        output.Add(new ChatPage.DisplayItem
        {
            Id = id,
            Kind = ChatPage.ItemKind.Group,
            Running = group.Running,
            Group = group with { Open = open, Members = [.. members] },
        });
        if (!open) return;
        foreach (var member in members)
        {
            var row = member;
            row.GroupId = id;
            output.Add(row);
        }
    }

    private static ChatStepGroup Make(ChatStepGroupStyle style, List<ChatPage.DisplayItem> members, bool running)
    {
        int steps = 0, reads = 0, searches = 0, pages = 0;
        long added = 0, removed = 0;
        var paths = new HashSet<string>();
        var anyRunning = false;
        string? liveVerb = null, liveTarget = null;
        long? started = null, ended = null;

        foreach (var member in members)
        {
            if (member.Kind == ChatPage.ItemKind.Tool)
            {
                steps++;
                if (ReadVerbs.Contains(member.Verb)) reads++;
                if (SearchVerbs.Contains(member.Verb)) searches++;
                if (PageVerbs.Contains(member.Verb)) pages++;
                if (member.StartedAt > 0) started = Math.Min(started ?? member.StartedAt, member.StartedAt);
                if (member.EndedAt > 0) ended = Math.Max(ended ?? member.EndedAt, member.EndedAt);
                if (member.Running)
                {
                    anyRunning = true;
                    liveVerb = member.Verb;
                    liveTarget = member.Target;
                }
            }
            else if (member.Kind == ChatPage.ItemKind.Edit)
            {
                steps++;
                paths.Add(member.Path);
                added += member.Added;
                removed += member.Removed;
                if (member.Running)
                {
                    anyRunning = true;
                    liveVerb = "Edit";
                    liveTarget = member.Path;
                }
            }
        }
        return new ChatStepGroup
        {
            Style = style,
            MemberIds = members.Select(member => member.Id).ToList(),
            Steps = steps,
            Files = paths.Count,
            Added = added,
            Removed = removed,
            Reads = reads,
            Searches = searches,
            Pages = pages,
            // A step still running is running whatever came after it.
            Running = anyRunning || running,
            LiveVerb = liveVerb,
            LiveTarget = liveTarget,
            StartedAt = started,
            EndedAt = ended,
        };
    }

    /// <summary>The first line that says something, without its markdown marks.</summary>
    public static string? Preview(string text)
    {
        foreach (var line in text.Split('\n'))
        {
            var plain = line.Trim().Trim('#', '*', '_', '>', '`', '-', ' ').Trim();
            if (plain.Length > 0) return plain.Length > 160 ? plain[..160] : plain;
        }
        return null;
    }
}
