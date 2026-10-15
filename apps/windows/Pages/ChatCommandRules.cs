// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text;

namespace Tokenstat.Pages;

internal static class ChatCommandRules
{
    internal static readonly string[] Names = ["/compact", "/status", "/context", "/usage", "/mcp", "/tools", "/help", "/stop"];
    internal static string SendMethod(string text) => text.Trim() == "/compact" ? "chat.compact" : "chat.send";
    // Rust counts Unicode scalar values rather than UTF-16 code units.
    internal static bool CanSteer(string draft, bool attachments, bool acceptsAttachments)
    {
        var text = draft.Trim();
        return (text.Length > 0 || attachments) && (!attachments || acceptsAttachments)
            && !text.StartsWith('/') && text.EnumerateRunes().Count() <= 1_500;
    }
    internal enum Kind { Message, Complete, Inspect, Stop, Compact, Attachments, Arguments, Unsupported, Running }
    internal readonly record struct Action(Kind Kind, string? Completion = null);
    internal static string[] Matches(string draft)
    {
        var text = draft.Trim();
        return text.StartsWith('/') && !text.Any(char.IsWhiteSpace)
            ? Names.Where(n => n.StartsWith(text, StringComparison.Ordinal)).ToArray() : [];
    }
    internal static Action Evaluate(string draft, string? backend, bool running, bool attachments, int selection = 0)
    {
        var text = draft.Trim();
        var word = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        if (!Names.Contains(word))
        {
            var choices = Matches(text);
            return choices.Length == 0 ? new(Kind.Message) : new(Kind.Complete, choices[Math.Clamp(selection, 0, choices.Length - 1)]);
        }
        if (attachments) return new(Kind.Attachments);
        if (text != word) return new(Kind.Arguments);
        if (word == "/compact") return new(backend is not ("claude" or "codex") ? Kind.Unsupported : running ? Kind.Running : Kind.Compact);
        return new(word == "/stop" ? Kind.Stop : Kind.Inspect);
    }
}
