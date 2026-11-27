// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.System;
using Windows.UI.Core;

namespace Tokenstat.Pages;

internal delegate Task<NewChatFile> CaptureChatFile(CancellationToken cancellation);

internal static class ChatClipboard
{
    internal static void Wire(TextBox composer, Func<DataPackageView, Task> attach, Action<string> report)
    {
        DataPackageView? Attachment()
        {
            try
            {
                var data = Clipboard.GetContent();
                return !data.Contains(StandardDataFormats.Text)
                    && (data.Contains(StandardDataFormats.StorageItems) || data.Contains(StandardDataFormats.Bitmap)) ? data : null;
            }
            catch (Exception error) { report(FriendlyError.Display(error.Message)); return null; }
        }

        composer.PreviewKeyDown += async (_, args) =>
        {
            bool Down(VirtualKey key) => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
            var paste = (args.Key == VirtualKey.V && Down(VirtualKey.Control) && !Down(VirtualKey.Menu))
                || (args.Key == VirtualKey.Insert && Down(VirtualKey.Shift));
            if (args.Handled || !paste || composer.IsReadOnly || Attachment() is not { } data) return;
            args.Handled = true;
            await attach(data);
        };
    }

    internal static async Task<string[]> FilePathsAsync(DataPackageView data)
    {
        var items = await data.GetStorageItemsAsync();
        return items.OfType<StorageFile>().Select(file => file.Path).Where(path => !string.IsNullOrEmpty(path)).ToArray();
    }

    internal static IEnumerable<CaptureChatFile> FromPaths(IEnumerable<string> paths) =>
        paths.Select<string, CaptureChatFile>(path => cancellation => NewChatFile.CaptureAsync(path, cancellation));

    internal static async Task<IEnumerable<CaptureChatFile>> ReadAsync(DataPackageView data)
    {
        if (data.Contains(StandardDataFormats.StorageItems))
        {
            var paths = await FilePathsAsync(data);
            if (paths.Length > 0) return FromPaths(paths);
        }
        if (data.Contains(StandardDataFormats.Bitmap))
            return [cancellation => CaptureBitmapAsync(data, cancellation)];
        throw new IOException(L10n.Text("windows.chatpage.drop_files_not_folders"));
    }

    internal static async Task<NewChatFile> CaptureBitmapAsync(DataPackageView data, CancellationToken cancellation)
    {
        var bitmap = await data.GetBitmapAsync();
        using var image = await bitmap.OpenReadAsync();
        if (image.Size == 0 || image.Size > (ulong)NewChatFile.MaximumBytes)
            throw new IOException(L10n.Text("common.chat_files_too_large"));
        var decoder = await BitmapDecoder.CreateAsync(image);
        cancellation.ThrowIfCancellationRequested();
        var extension = decoder.DecoderInformation.FileExtensions.First();
        image.Seek(0);
        using var input = image.AsStreamForRead();
        return await NewChatFile.CaptureAsync(input, $"clipboard-image{extension}", cancellation);
    }
}
