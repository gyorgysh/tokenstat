// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available, not open source. See LICENSE for permissions and restrictions.

using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    internal enum ItemKind
    {
        User, Assistant, Thinking, Tool, Edit, Approval, Attachment, Gallery, Usage, Failed,
        Group,
        Question,
        Changes,
        Plan,
        Handoff,
    }

    internal sealed record PlanStepItem(string Text, string Status);

    internal struct DisplayItem
    {
        public string Id;
        public ItemKind Kind;
        public long? SourceSequence;
        public string Text;
        public string Verb;
        public string Target;
        public bool Running;
        public bool IsSteer;
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
        public string ToolCallId;
        public string AttachmentScope;
        public IReadOnlyList<DisplayItem>? Images;
        public long Input;
        public long Output;
        public double Cost;
        public bool CostUnknown;
        public long StartedAt;
        public long EndedAt;
        public string GroupId;
        public PlainStep Plain;
        public ChatStepGroup? Group;
        public ChatQuestionItem? Question;
        public IReadOnlyList<ChangedFile>? Changes;
        public IReadOnlyList<PlanStepItem>? Plan;

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
            ToolCallId = "";
            AttachmentScope = "";
            GroupId = "";
        }
    }
}
