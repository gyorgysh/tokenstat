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
    /// <summary>One quiet line per step, the way most editors show it.</summary>
    Minimal,
    /// <summary>One line per stretch of work.</summary>
    Compact,
    /// <summary>Thinking and runs of reads and searches fold to one line each.</summary>
    Standard,
    /// <summary>Every step on its own row, with its output open.</summary>
    Detailed,
}

internal enum ChatStepGroupStyle { Work, Explored, Thought, Step }

/// <summary>One file a turn changed. Counts are summed over the turn's edits to it.</summary>
internal sealed record ChangedFile(string Path, long Added, long Removed)
{
    public string FileName
    {
        get
        {
            var slash = Math.Max(Path.LastIndexOf('/'), Path.LastIndexOf('\\'));
            var name = slash >= 0 ? Path[(slash + 1)..] : Path;
            return name.Length == 0 ? Path : name;
        }
    }
}

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
    /// <summary>Drawn as Minimal draws it: a plain line, no icon or chevron.</summary>
    public bool Minimal { get; init; }
    /// <summary>The one step a single-member group stands for.</summary>
    public string? Verb { get; init; }
    public string? Subject { get; init; }
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
        Func<string, bool> isOpen)
    {
        var folded = detail switch
        {
            ChatDetail.Compact => Compact(items, running, isOpen),
            ChatDetail.Standard => Standard(items, running, isOpen),
            ChatDetail.Minimal => Minimal(items, running, isOpen),
            _ => items,
        };
        return WithTurnChanges(folded, items, running);
    }

    /// <summary>
    /// A turn's edits, one row per file, after the turn has finished. Read
    /// from the raw rows, since a closed group hides its edits. User rows are
    /// never folded, so the n-th one starts the same turn in both lists.
    /// </summary>
    public static List<ChatPage.DisplayItem> WithTurnChanges(
        List<ChatPage.DisplayItem> folded, List<ChatPage.DisplayItem> raw, bool running)
    {
        var changes = new Dictionary<int, ChatPage.DisplayItem>();
        var turn = 0;
        var id = "";
        var files = new List<ChangedFile>();
        var index = new Dictionary<string, int>();
        void Close()
        {
            if (files.Count > 0)
            {
                changes[turn] = new ChatPage.DisplayItem { Id = id, Kind = ChatPage.ItemKind.Changes, Changes = [.. files] };
            }
            files.Clear();
            index.Clear();
        }
        foreach (var item in raw)
        {
            if (item.Kind == ChatPage.ItemKind.User)
            {
                Close();
                turn++;
            }
            else if (item.Kind == ChatPage.ItemKind.Edit && !item.Failed && !item.Running)
            {
                if (files.Count == 0) id = "changes:" + item.Id;
                if (index.TryGetValue(item.Path, out var at))
                {
                    var prior = files[at];
                    files[at] = prior with { Added = prior.Added + item.Added, Removed = prior.Removed + item.Removed };
                }
                else
                {
                    index[item.Path] = files.Count;
                    files.Add(new ChangedFile(item.Path, item.Added, item.Removed));
                }
            }
        }
        Close();
        if (changes.Count == 0) return folded;
        var output = new List<ChatPage.DisplayItem>(folded.Count + changes.Count);
        turn = 0;
        foreach (var item in folded)
        {
            if (item.Kind == ChatPage.ItemKind.User)
            {
                if (changes.TryGetValue(turn, out var finished)) output.Add(finished);
                turn++;
            }
            output.Add(item);
        }
        // The turn still running gets its card when it ends.
        if (!running && changes.TryGetValue(turn, out var last)) output.Add(last);
        return output;
    }

    /// <summary>
    /// Every step is one line. Runs of reads and searches still read as one,
    /// even a run of one. Port of <c>ChatTranscriptFold.minimal</c>.
    /// </summary>
    private static List<ChatPage.DisplayItem> Minimal(
        List<ChatPage.DisplayItem> items, bool running, Func<string, bool> isOpen)
    {
        var output = new List<ChatPage.DisplayItem>(items.Count);
        var run = new List<ChatPage.DisplayItem>();

        void Line(ChatStepGroupStyle style, List<ChatPage.DisplayItem> members, bool live) =>
            Emit(Make(style, members, live) with { Minimal = true }, members, output, isOpen);

        void FlushRun(bool trailing)
        {
            if (run.Count > 0) Line(ChatStepGroupStyle.Explored, [.. run], running && trailing);
            run.Clear();
        }

        for (var position = 0; position < items.Count; position++)
        {
            var item = items[position];
            if (item.Kind == ChatPage.ItemKind.Tool && !item.Failed && IsExploration(item.Verb))
            {
                run.Add(item);
            }
            else if (item.Kind == ChatPage.ItemKind.Thinking)
            {
                FlushRun(false);
                if (running && position == items.Count - 1)
                {
                    output.Add(item);
                }
                else
                {
                    var group = Make(ChatStepGroupStyle.Thought, [item], false) with { Preview = Preview(item.Text), Minimal = true };
                    Emit(group, [item], output, isOpen);
                }
            }
            else if ((item.Kind == ChatPage.ItemKind.Tool || item.Kind == ChatPage.ItemKind.Edit) && !item.Failed)
            {
                FlushRun(false);
                Line(ChatStepGroupStyle.Step, [item], item.Running);
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

    /// <summary>A path becomes its file name. A command keeps its first line.</summary>
    public static string ShortSubject(string? verb, string subject)
    {
        var newline = subject.IndexOf('\n');
        var line = (newline < 0 ? subject : subject[..newline]).Trim();
        switch (verb)
        {
            case "Read" or "Edit" or "NotebookEdit" or "Write" or "Diff":
                var slash = Math.Max(line.LastIndexOf('/'), line.LastIndexOf('\\'));
                var name = slash >= 0 ? line[(slash + 1)..] : line;
                return name.Length == 0 ? line : name;
            default:
                return line.Length > 160 ? line[..160] : line;
        }
    }

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
        var single = members.Count == 1 ? members[0] : (ChatPage.DisplayItem?)null;
        return new ChatStepGroup
        {
            Verb = single is { Kind: ChatPage.ItemKind.Tool } tool ? tool.Verb
                : single is { Kind: ChatPage.ItemKind.Edit } ? "Edit" : null,
            Subject = single is { Kind: ChatPage.ItemKind.Tool } command ? command.Target
                : single is { Kind: ChatPage.ItemKind.Edit } edit ? edit.Path : null,
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
