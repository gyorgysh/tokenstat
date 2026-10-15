// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>Gallery layout and explicit tool provenance, independent of WinUI.</summary>
internal static class ChatImageGallery
{
    internal const int VisibleLimit = 4;
    internal static bool IsImage(ChatPage.DisplayItem item) => item.Kind == ChatPage.ItemKind.Attachment
        && item.MediaType?.ToLowerInvariant() is "image/png" or "image/jpeg" or "image/gif" or "image/webp" or "image/bmp";

    internal static List<ChatPage.DisplayItem> Compose(List<ChatPage.DisplayItem> items)
    {
        var linked = new Dictionary<string, List<ChatPage.DisplayItem>>();
        var moved = new HashSet<int>();
        var owners = new Dictionary<(string Scope, string Call), string>();
        for (var index = 0; index < items.Count; index++)
        {
            var image = items[index];
            void Remember(ChatPage.DisplayItem tool)
            {
                if (!string.IsNullOrEmpty(tool.ToolCallId)) owners[(tool.AttachmentScope, tool.ToolCallId)] = image.Id;
            }
            if (image.Kind is ChatPage.ItemKind.Tool or ChatPage.ItemKind.Edit) Remember(image);
            else if (image.Kind == ChatPage.ItemKind.Group && image.Group is { Open: false } group)
                foreach (var member in group.Members) Remember(member);
            if (!IsImage(image) || string.IsNullOrEmpty(image.ToolCallId)) continue;
            // Provenance can identify only a preceding step. Reused call IDs
            // belong to their most recent preceding start, including folded starts.
            if (!owners.TryGetValue((image.AttachmentScope, image.ToolCallId), out var owner)) continue;
            if (!linked.TryGetValue(owner, out var images)) linked[owner] = images = [];
            if (!images.Any(prior => prior.Id == image.Id)) images.Add(image);
            moved.Add(index);
        }
        var output = new List<ChatPage.DisplayItem>();
        var ordinary = new List<ChatPage.DisplayItem>();
        void Flush()
        {
            if (ordinary.Count == 0) return;
            output.Add(new() { Id = "gallery-" + ordinary[0].Id, Kind = ChatPage.ItemKind.Gallery, Images = ordinary.ToArray() });
            ordinary.Clear();
        }
        for (var index = 0; index < items.Count; index++)
        {
            if (moved.Contains(index)) { Flush(); continue; }
            var item = items[index];
            if (IsImage(item)) {
                if (ordinary.Count > 0 && (ordinary[^1].AttachmentScope != item.AttachmentScope
                    || ordinary[^1].ToolCallId != item.ToolCallId)) Flush();
                ordinary.Add(item); continue;
            }
            Flush();
            output.Add(item);
            if (linked.TryGetValue(item.Id, out var images)) output.Add(new() {
                Id = "tool-gallery-" + item.Id, Kind = ChatPage.ItemKind.Gallery,
                Images = images, ToolCallId = item.Id, GroupId = item.GroupId,
            });
        }
        Flush();
        return output;
    }
}
