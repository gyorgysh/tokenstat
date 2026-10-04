// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// <summary>
/// The transcript's row model, in a file of its own so the portable chat
/// tests can compile it and <see cref="ChatDetailFold"/> without WinUI.
/// </summary>
internal sealed partial class ChatPage
{
    internal enum ItemKind
    {
        User, Assistant, Thinking, Tool, Edit, Approval, Attachment, Usage, Failed,
        /// <summary>Steps folded into one line by the chat's detail level.</summary>
        Group,
        /// <summary>A question the agent asked, with the answer once there is one.</summary>
        Question,
    }

    internal struct DisplayItem
    {
        public string Id;
        public ItemKind Kind;
        public string Text;
        public string Verb;
        public string Target;
        public bool Running;
        public bool Failed;
        public string Detail;
        public string Duration;
        public string Path;
        public long Added;
        public long Removed;
        public string Patch;
        public JsonNode? Approval;
        public bool Pending;
        public string Name;
        public string MediaType;
        public long Size;
        public long Input;
        public long Output;
        public double Cost;
        public long StartedAt;
        public long EndedAt;
        /// <summary>
        /// The open step group this row is shown under, or empty for a
        /// top-level row.
        /// </summary>
        public string GroupId;
        /// <summary>The folded steps, on a <see cref="ItemKind.Group"/> row.</summary>
        public ChatStepGroup? Group;
        /// <summary>The question, on a <see cref="ItemKind.Question"/> row.</summary>
        public ChatQuestionItem? Question;

        public DisplayItem()
        {
            Id = "";
            Text = "";
            Verb = "";
            Target = "";
            Detail = "";
            Duration = "";
            Path = "";
            Patch = "";
            Name = "";
            MediaType = "";
            GroupId = "";
        }
    }
}
