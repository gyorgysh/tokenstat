// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Windows.ApplicationModel.DataTransfer;

namespace Tokenstat.Pages;

internal sealed partial class ChatPage
{
    private CancellationTokenSource? _dropImport;

    private void CancelDropImport()
    {
        if (_dropImport is not { } import) return;
        _dropImport = null;
        import.Cancel(); _queueing = false;
        if (IsLoaded) { RebuildAttachStrip(); RebuildComposerActions(); }
    }
    private bool AcceptsChatDrop() => IsLoaded && !_opening && _openId is not null
        && !_queueing && !_sending && !_pickingAttachment && _fileTransfer is null && _dropImport is null;

    private void AttachChatDropSurface(Grid layout)
    {
        layout.AllowDrop = true;
        layout.Background = Theme.BackgroundBrush;
        var title = new TextBlock { Text = L10n.Text("windows.chatpage.drop_to_attach"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center, Foreground = Theme.AccentBrush };
        var glyph = ActionIcon.Attach.Icon(); glyph.Foreground = Theme.AccentBrush;
        var label = new StackPanel { Spacing = Theme.SpaceS, HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center, Children = { glyph, title } };
        var overlay = new Border { Background = Theme.AccentSoftBrush, BorderBrush = Theme.AccentBrush, BorderThickness = new Thickness(1.5),
            CornerRadius = new CornerRadius(Theme.CardRadius), Margin = new Thickness(6), Child = label,
            IsHitTestVisible = false, Visibility = Visibility.Collapsed };
        Grid.SetRowSpan(overlay, 2); layout.Children.Add(overlay);
        bool Supported(DataPackageView data) => data.Contains(StandardDataFormats.StorageItems)
            || data.Contains(StandardDataFormats.Text) || data.Contains(StandardDataFormats.WebLink);
        layout.DragOver += (_, args) => {
            if (!Supported(args.DataView)) return;
            args.Handled = true;
            var accepts = AcceptsChatDrop();
            args.AcceptedOperation = accepts ? DataPackageOperation.Copy : DataPackageOperation.None;
            overlay.Visibility = accepts ? Visibility.Visible : Visibility.Collapsed;
            if (accepts) args.DragUIOverride.Caption = title.Text;
        };
        layout.DragLeave += (_, _) => overlay.Visibility = Visibility.Collapsed;
        layout.Drop += async (_, args) => {
            overlay.Visibility = Visibility.Collapsed;
            if (!Supported(args.DataView)) return;
            args.Handled = true;
            if (!AcceptsChatDrop()) return;
            var deferral = args.GetDeferral();
            try { await ImportChatDataAsync(args.DataView, fromClipboard: false); }
            finally { deferral.Complete(); }
        };
    }

    private Task PasteChatAttachmentsAsync(DataPackageView data) => ImportChatDataAsync(data, fromClipboard: true);

    private async Task ImportChatDataAsync(DataPackageView data, bool fromClipboard)
    {
        if (SharedSource) return;
        if (!AcceptsChatDrop())
        {
            if (fromClipboard && IsLoaded && !_opening && _openId is not null) Banner(L10n.Text("common.chat_files_busy"));
            return;
        }
        var chat = _openId; var generation = _openGeneration; var account = AppServices.AccountGeneration;
        using var cancellation = new CancellationTokenSource();
        bool Current() => IsLoaded && !_opening && _openId == chat && _openGeneration == generation
            && account == AppServices.AccountGeneration && !cancellation.IsCancellationRequested;
        _dropImport = cancellation;
        _queueing = true; RebuildAttachStrip(); RebuildComposerActions();
        try
        {
            if (fromClipboard)
            {
                foreach (var capture in await ChatClipboard.ReadAsync(data))
                {
                    if (!Current()) return;
                    if (_attachments.Count >= NewChatFile.MaximumCount) { Banner(L10n.Text("common.chat_files_busy")); return; }
                    var file = await capture(cancellation.Token);
                    if (file.RetainIfOwned(Current()) is not { } staged) return;
                    _attachments.Add(new StagedFile("local-" + Guid.NewGuid().ToString("N"), staged.Name, staged));
                    RememberDraft(); RebuildAttachStrip();
                }
            }
            else if (data.Contains(StandardDataFormats.StorageItems))
            {
                var paths = await ChatClipboard.FilePathsAsync(data);
                if (!Current()) return;
                if (paths.Length == 0) { Banner(L10n.Text("windows.chatpage.drop_files_not_folders")); return; }
                await StageDroppedFilesAsync(paths, Current, cancellation.Token);
            }
            else
            {
                var text = data.Contains(StandardDataFormats.WebLink)
                    ? (await data.GetWebLinkAsync()).AbsoluteUri : await data.GetTextAsync();
                if (Current() && !string.IsNullOrEmpty(text))
                    _draft.Text += (_draft.Text.Length == 0 || _draft.Text.EndsWith('\n') ? "" : "\n") + text;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (Current()) Banner(error.Message); }
        finally
        {
            if (ReferenceEquals(_dropImport, cancellation))
            {
                _dropImport = null; _queueing = false;
                if (Current()) RememberDraft();
                if (IsLoaded) { RebuildAttachStrip(); RebuildComposerActions(); }
            }
        }
    }

    private async Task StageDroppedFilesAsync(IEnumerable<string> paths, Func<bool> current, CancellationToken cancellation)
    {
        foreach (var path in paths)
        {
            if (!current()) return;
            if (_attachments.Count >= NewChatFile.MaximumCount) { Banner(L10n.Text("common.chat_files_busy")); return; }
            var file = await NewChatFile.CaptureAsync(path, cancellation);
            file = file.RetainIfOwned(current());
            if (file is null) return;
            _attachments.Add(new StagedFile("local-" + Guid.NewGuid().ToString("N"), file.Name, file));
            RememberDraft(); RebuildAttachStrip();
        }
    }
}
