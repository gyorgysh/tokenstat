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
        for (var index = 0; index < items.Count; index++)
        {
            var image = items[index];
            if (!IsImage(image) || string.IsNullOrEmpty(image.ToolCallId)) continue;
            var tool = items.FirstOrDefault(item => item.ToolCallId == image.ToolCallId && item.AttachmentScope == image.AttachmentScope
                && item.Kind is ChatPage.ItemKind.Tool or ChatPage.ItemKind.Edit);
            var toolId = tool.Id;
            var owner = string.IsNullOrEmpty(toolId) ? -1 : items.FindIndex(item => item.Id == toolId && item.Kind is ChatPage.ItemKind.Tool or ChatPage.ItemKind.Edit);
            if (owner < 0) owner = items.FindIndex(item => item.Kind == ChatPage.ItemKind.Group
                && item.Group is { Open: false } group && group.Members.Any(member => member.ToolCallId == image.ToolCallId && member.AttachmentScope == image.AttachmentScope));
            if (owner < 0) continue; // Older/paged archives keep an ordinary gallery.
            if (!linked.TryGetValue(items[owner].Id, out var images)) linked[items[owner].Id] = images = [];
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
