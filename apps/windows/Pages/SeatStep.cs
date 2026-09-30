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
                return Labeled("Reading", FileName(line));
            case "Write":
                return Labeled("Writing", FileName(line));
            case "Edit":
            case "NotebookEdit":
                return Labeled("Editing", FileName(line));
            case "Diff":
                return Labeled("Comparing", FileName(line));
            case "Shell":
            case "Bash":
                return Labeled("Running", collapsed);
            case "Grep":
            case "Search":
                return Labeled("Searching", collapsed);
            case "Glob":
            case "Find":
                var file = FileName(line);
                if (file.Length == 0) return "Looking";
                return Labeled("Looking through", file);
            case "WebFetch":
                return Labeled("Opening", Site(collapsed));
            case "WebSearch":
                return "Searching the web";
            case "Task":
            case "Subagent":
                return "Asking another agent";
            case "TodoWrite":
                return "Updating the list";
            default:
                // A path with nothing left after the slashes is just work.
                // "Working on" with an empty name reads as a broken sentence.
                var edges = TrimEdges(line);
                if (edges.Contains('/') || edges.Contains('\\'))
                {
                    var named = FileName(line);
                    if (named.Length == 0) return "Working";
                    return Labeled("Working on", named);
                }
                if (collapsed.Length == 0) return "Working";
                return Labeled("Working on", collapsed);
        }
    }

    /// <summary>
    /// Waiting wins. A real step is shown as written. Speaking is a reply.
    /// Everything else is thought.
    /// </summary>
    public static string SeatLabel(bool waiting, string? step, bool speaking)
    {
        if (waiting) return "Waiting";
        if (!string.IsNullOrWhiteSpace(step)) return step!;
        if (speaking) return "Replying";
        return "Thinking";
    }

    /// <summary>
    /// Present while the step runs, past once it has finished.
    /// An unknown name is returned unchanged, once trimmed.
    /// </summary>
    public static string Word(string? verb, bool running)
    {
        switch (TrimVerb(verb))
        {
            case "Read": return running ? "Reading" : "Read";
            case "Write": return running ? "Writing" : "Wrote";
            case "Edit":
            case "NotebookEdit": return running ? "Editing" : "Edited";
            case "Diff": return running ? "Comparing" : "Compared";
            case "Shell":
            case "Bash": return running ? "Running" : "Ran";
            case "Grep":
            case "Search": return running ? "Searching" : "Searched";
            case "Glob":
            case "Find": return running ? "Looking" : "Looked";
            case "WebFetch": return running ? "Opening" : "Opened";
            case "WebSearch": return running ? "Searching the web" : "Searched the web";
            case "Task":
            case "Subagent": return running ? "Asking another agent" : "Asked another agent";
            case "TodoWrite": return running ? "Updating the list" : "Updated the list";
            case "": return running ? "Working" : "Worked";
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
        if (name.Length == 0) return "Approval";
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
            return "Always allow remembers " + prefix + " for this chat only.";
        }
        if (IsShell(verb))
        {
            return "Always allow answers this request only. Nothing is saved for later.";
        }
        var name = TrimVerb(verb);
        if (name.Length == 0) return null;
        return "Always allow remembers " + name + " for this chat only.";
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
