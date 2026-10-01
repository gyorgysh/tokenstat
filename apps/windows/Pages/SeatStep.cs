// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text;

namespace Tokenstat.Pages;

/// <summary>
/// Words for the live seat, a tool row, and a permission chip.
/// The same sentences are used on every client. The seat names the whole
/// step in one line. A row keeps the path or the command beside a shorter
/// word: present while the step runs, past once it has finished. A name
/// this list does not know stays as the tool wrote it. The permission
/// chip uses that same word. The Always allow line names the rule that
/// is stored, which is a command prefix or a tool name, never the chip.
/// </summary>
internal static class SeatStep
{
    public const int DetailCap = 32;
    public const int ScanCap = 4096;

    public static string Phrase(string? verb, string? target)
    {
        var name = TrimVerb(verb);
        var line = FirstLine(Scan(target));
        var collapsed = Collapse(line);
        switch (name)
        {
            case "Read":
                return Labeled(L10n.Text("windows.seatstep.reading.463816d0"), FileName(line));
            case "Write":
                return Labeled(L10n.Text("windows.seatstep.writing.a8bfae3e"), FileName(line));
            case "Edit":
            case "NotebookEdit":
                return Labeled(L10n.Text("windows.seatstep.editing.fab4539d"), FileName(line));
            case "Diff":
                return Labeled(L10n.Text("windows.seatstep.comparing.1fa1aad0"), FileName(line));
            case "Shell":
            case "Bash":
                return Labeled(L10n.Text("common.running"), collapsed);
            case "Grep":
            case "Search":
                return Labeled(L10n.Text("windows.seatstep.searching.03bd6fca"), collapsed);
            case "Glob":
            case "Find":
                var file = FileName(line);
                if (file.Length == 0) return L10n.Text("windows.seatstep.looking.afa37c88");
                return Labeled(L10n.Text("windows.seatstep.looking_through.6c8d5b7b"), file);
            case "WebFetch":
                return Labeled(L10n.Text("windows.seatstep.opening.f4b13e93"), Site(collapsed));
            case "WebSearch":
                return L10n.Text("windows.seatstep.searching_the_web.87d2f338");
            case "Task":
            case "Subagent":
                return L10n.Text("windows.seatstep.asking_another_agent.fde5ee73");
            case "TodoWrite":
                return L10n.Text("windows.seatstep.updating_the_list.ca724dcc");
            default:
                // A path with nothing left after the slashes is just work.
                // "Working on" with an empty name reads as a broken sentence.
                var edges = TrimEdges(line);
                if (edges.Contains('/') || edges.Contains('\\'))
                {
                    var named = FileName(line);
                    if (named.Length == 0) return L10n.Text("common.working");
                    return Labeled(L10n.Text("windows.seatstep.working_on.006abaf3"), named);
                }
                if (collapsed.Length == 0) return L10n.Text("common.working");
                return Labeled(L10n.Text("windows.seatstep.working_on.006abaf3"), collapsed);
        }
    }

    /// <summary>
    /// Waiting wins. A real step is shown as written. Speaking is a reply.
    /// Everything else is thought.
    /// </summary>
    public static string SeatLabel(bool waiting, string? step, bool speaking)
    {
        if (waiting) return L10n.Text("common.waiting");
        if (!string.IsNullOrWhiteSpace(step)) return step!;
        if (speaking) return L10n.Text("windows.seatstep.replying.b2663dd7");
        return L10n.Text("windows.seatstep.thinking.a20d12c5");
    }

    /// <summary>
    /// Present while the step runs, past once it has finished.
    /// An unknown name is returned unchanged, once trimmed.
    /// </summary>
    public static string Word(string? verb, bool running)
    {
        switch (TrimVerb(verb))
        {
            case "Read": return running ? L10n.Text("windows.seatstep.reading.463816d0") : L10n.Text("windows.seatstep.read.9b9a8d05");
            case "Write": return running ? L10n.Text("windows.seatstep.writing.a8bfae3e") : L10n.Text("windows.seatstep.wrote.42717062");
            case "Edit":
            case "NotebookEdit": return running ? L10n.Text("windows.seatstep.editing.fab4539d") : L10n.Text("windows.seatstep.edited.7117f080");
            case "Diff": return running ? L10n.Text("windows.seatstep.comparing.1fa1aad0") : L10n.Text("windows.seatstep.compared.17c858fc");
            case "Shell":
            case "Bash": return running ? L10n.Text("common.running") : L10n.Text("windows.seatstep.ran.b6a7c95e");
            case "Grep":
            case "Search": return running ? L10n.Text("windows.seatstep.searching.03bd6fca") : L10n.Text("windows.seatstep.searched.9fc7f116");
            case "Glob":
            case "Find": return running ? L10n.Text("windows.seatstep.looking.afa37c88") : L10n.Text("windows.seatstep.looked.07558310");
            case "WebFetch": return running ? L10n.Text("windows.seatstep.opening.f4b13e93") : L10n.Text("windows.seatstep.opened.b19fb8d1");
            case "WebSearch": return running ? L10n.Text("windows.seatstep.searching_the_web.87d2f338") : L10n.Text("windows.seatstep.searched_the_web.7d2580ce");
            case "Task":
            case "Subagent": return running ? L10n.Text("windows.seatstep.asking_another_agent.fde5ee73") : L10n.Text("windows.seatstep.asked_another_agent.629f8e22");
            case "TodoWrite": return running ? L10n.Text("windows.seatstep.updating_the_list.ca724dcc") : L10n.Text("windows.seatstep.updated_the_list.de8e6fab");
            case "": return running ? L10n.Text("common.working") : L10n.Text("windows.seatstep.worked.e7f93aad");
            default: return TrimVerb(verb);
        }
    }

    /// <summary>
    /// The running word already says what is happening, so a Running chip
    /// beside it would repeat the same news.
    /// </summary>
    public static bool Speaks(string? verb)
    {
        var name = TrimVerb(verb);
        return Word(name, true) != name;
    }

    /// <summary>
    /// The chip on a permission card. Pending is present tense, a decision
    /// is past tense, and a blank name stays Approval.
    /// </summary>
    public static string ApprovalWord(string? verb, bool pending)
    {
        var name = TrimVerb(verb);
        if (name.Length == 0) return L10n.Text("windows.seatstep.approval.147fb813");
        return Word(name, pending);
    }

    /// <summary>
    /// What Always allow will store for the rest of this chat.
    /// A command prefix is that prefix. A plain tool is its own name.
    /// A command with no safe prefix is not stored, so the line says so
    /// instead of naming the tool.
    /// </summary>
    public static string? AllowAlwaysNote(string? verb, string? shellPrefix)
    {
        var prefix = TrimVerb(shellPrefix);
        if (prefix.Length > 0)
        {
            return L10n.Text("windows.seatstep.always_allow_remembers_0_for_this_chat_onl.394a9e6d", $"{prefix}");
        }
        if (IsShell(verb))
        {
            return L10n.Text("windows.seatstep.always_allow_answers_this_request_only_not.a067a2b7");
        }
        var name = TrimVerb(verb);
        if (name.Length == 0) return null;
        return L10n.Text("windows.seatstep.always_allow_remembers_0_for_this_chat_onl.394a9e6d", $"{name}");
    }

    /// <summary>
    /// Same rule as the host: a shell tool is never remembered by its name.
    /// </summary>
    public static bool IsShell(string? verb)
    {
        var name = TrimVerb(verb).ToLowerInvariant();
        if (name.Contains("bash") || name.Contains("shell")
            || name.Contains("command") || name.Contains("terminal"))
        {
            return true;
        }
        var token = "";
        foreach (var character in name)
        {
            if (character < 128 && char.IsLetterOrDigit(character))
            {
                token += character;
            }
            else if (token is "sh" or "zsh" or "exec" or "run")
            {
                return true;
            }
            else
            {
                token = "";
            }
        }
        return token is "sh" or "zsh" or "exec" or "run";
    }

    private static string TrimVerb(string? verb) => verb?.Trim() ?? "";

    private static string Scan(string? target)
    {
        if (string.IsNullOrEmpty(target)) return "";
        return target.Length <= ScanCap ? target : target.Substring(0, ScanCap);
    }

    private static string FirstLine(string text)
    {
        var cut = text.IndexOfAny(new[] { '\n', '\r' });
        return cut < 0 ? text : text.Substring(0, cut);
    }

    private static string TrimEdges(string text)
    {
        var start = 0;
        var end = text.Length;
        while (start < end && (text[start] == ' ' || text[start] == '\t')) start++;
        while (end > start && (text[end - 1] == ' ' || text[end - 1] == '\t')) end--;
        return text.Substring(start, end - start);
    }

    private static string Collapse(string line)
    {
        var trimmed = TrimEdges(line);
        var builder = new StringBuilder(trimmed.Length);
        var pending = false;
        foreach (var character in trimmed)
        {
            if (character == ' ' || character == '\t')
            {
                pending = true;
                continue;
            }
            if (pending && builder.Length > 0) builder.Append(' ');
            pending = false;
            builder.Append(character);
        }
        return builder.ToString();
    }

    private static string FileName(string line)
    {
        var name = TrimEdges(line);
        while (name.Length > 0 && (name[name.Length - 1] == '/' || name[name.Length - 1] == '\\'))
        {
            name = name.Substring(0, name.Length - 1);
        }
        if (name.Length == 0) return "";
        var slash = name.LastIndexOf('/');
        var back = name.LastIndexOf('\\');
        var cut = slash > back ? slash : back;
        if (cut < 0) return name;
        return name.Substring(cut + 1);
    }

    private static string Clip(string detail)
    {
        if (detail.Length <= DetailCap) return detail;
        return detail.Substring(0, DetailCap - 1) + "…";
    }

    private static string Labeled(string gerund, string detail)
    {
        if (detail.Length == 0) return gerund;
        return gerund + " " + Clip(detail);
    }

    private static string Site(string collapsed)
    {
        if (collapsed.Length == 0) return "";
        var host = collapsed;
        var scheme = host.IndexOf("://", StringComparison.Ordinal);
        if (scheme >= 0) host = host.Substring(scheme + 3);
        var cut = host.IndexOfAny(new[] { '/', '?', '#' });
        if (cut >= 0) host = host.Substring(0, cut);
        var at = host.LastIndexOf('@');
        if (at >= 0) host = host.Substring(at + 1);
        host = StripPort(host);
        if (host.Length == 0) return Clip(collapsed);
        return Clip(host);
    }

    private static string StripPort(string host)
    {
        if (host.StartsWith('['))
        {
            var close = host.IndexOf(']');
            if (close < 0) return host;
            var suffix = host.Substring(close + 1);
            if (suffix.StartsWith(':') && IsAsciiDigits(suffix.Substring(1)))
            {
                return host.Substring(0, close + 1);
            }
            return host;
        }
        var colon = host.LastIndexOf(':');
        if (colon < 0) return host;
        if (IsAsciiDigits(host.Substring(colon + 1))) return host.Substring(0, colon);
        return host;
    }

    private static bool IsAsciiDigits(string text)
    {
        if (text.Length == 0) return false;
        foreach (var character in text)
        {
            if (character < '0' || character > '9') return false;
        }
        return true;
    }
}
