// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.IO;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Tokenstat.Design;
using Tokenstat.Navigation;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.System;

namespace Tokenstat.Pages;
internal sealed partial class ChatPage
{
    private readonly SemaphoreSlim _imageSlots = new(2);
    private readonly Dictionary<string, string> _imageFiles = new();
    private readonly Dictionary<string, Task<string?>> _imageFlights = new();
    private readonly HashSet<Image> _imageViews = [];
    private CancellationTokenSource _imageCancellation = new();
    private ContentDialog? _imageDialog;
    private StackPanel? _imageConsentHost;
    private TaskCompletionSource<bool>? _imageConsent;
    private string? _imageViewedFile;
    private long _imageViewerRevision;
    private long _imageEpoch;
    private string ImageOwner() => $"{AppServices.AccountGeneration}/{_openGeneration}/{_imageEpoch}/{_workspaceId}/{_openId}";
    private void ImagesAccountChanged() => DispatcherQueue.TryEnqueue(ResetImagePreviews);
    private void ImagesPeerChanged() => DispatcherQueue.TryEnqueue(() => {
        if (RemoteWorkspaces.TrySplit(_workspaceId, out var peer, out _)
            && (!RemoteWorkspaces.IsConnected(peer) || RemoteWorkspaces.CachedFolder(_workspaceId) is null)) ResetImagePreviews();
    });
    private void ResetImagePreviews()
    {
        _imageEpoch++;
        _imageCancellation.Cancel();
        _imageCancellation.Dispose();
        _imageCancellation = new();
        _imageDialog?.Hide();
        _imageConsent?.TrySetResult(false);
        _imageConsent = null;
        _imageConsentHost = null;
        _imageDialog = null;
        _imageViewedFile = null;
        foreach (var image in _imageViews) image.Source = null;
        _imageViews.Clear();
        foreach (var path in _imageFiles.Values) DeleteImageFile(path);
        _imageFiles.Clear();
        _imageFlights.Clear();
    }
    private static void DeleteImageFile(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
    private UIElement ImageGalleryRow(DisplayItem gallery)
    {
        var images = gallery.Images?.ToArray() ?? [];
        if (images.Length == 0) return new Border();
        var tool = !string.IsNullOrEmpty(gallery.ToolCallId);
        var count = Math.Min(images.Length, ChatImageGallery.VisibleLimit);
        var aspects = Enumerable.Repeat(ChatImageLayout.FallbackAspect, count).ToArray();
        var tiles = new List<Button>(count);
        var canvas = new Canvas { HorizontalAlignment = HorizontalAlignment.Left };
        var host = new Grid { HorizontalAlignment = HorizontalAlignment.Stretch, Children = { canvas } };
        var availableWidth = _transcript.ActualWidth > 0 ? _transcript.ActualWidth : ChatImageLayout.MaximumWidth;
        void Layout()
        {
            var geometry = ChatImageLayout.Measure(aspects, availableWidth, tool);
            canvas.Width = geometry.Width; canvas.Height = geometry.Height;
            foreach (var tile in geometry.Tiles)
            {
                var button = tiles[tile.Index];
                button.Width = tile.Width; button.Height = tile.Height;
                Canvas.SetLeft(button, tile.X); Canvas.SetTop(button, tile.Y);
            }
        }
        for (var index = 0; index < count; index++)
        {
            var selected = index;
            var item = images[index];
            var image = new Image { Stretch = Stretch.Uniform };
            var placeholder = ActionIcon.Preview.Icon();
            placeholder.Opacity = .3;
            placeholder.HorizontalAlignment = HorizontalAlignment.Center;
            placeholder.VerticalAlignment = VerticalAlignment.Center;
            var tile = new Grid { Background = Theme.PanelBrush };
            tile.Children.Add(placeholder); tile.Children.Add(image);
            if (index == count - 1 && images.Length > count)
            {
                tile.Children.Add(new Border { Background = Theme.PanelBrush, CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(6), HorizontalAlignment = HorizontalAlignment.Right,
                    VerticalAlignment = VerticalAlignment.Bottom, Child = new TextBlock { Text = L10n.Text("common.chat.images.more", (images.Length - count).ToString("N0")) } });
            }
            var button = new Button { Content = tile, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Theme.PanelBrush,
                MinWidth = tool ? 0 : ChatImageLayout.MinimumTile, MinHeight = tool ? 0 : ChatImageLayout.MinimumTile,
                HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch,
                CornerRadius = new CornerRadius(8) };
            ToolTipService.SetToolTip(button, item.Name);
            AutomationProperties.SetName(button, L10n.Text("common.chat.images.open") + " · " + item.Name + " · " + L10n.Text("common.chat.images.count", images.Length.ToString()));
            var loadRevision = 0;
            image.Loaded += async (_, _) => {
                var requested = ++loadRevision;
                _imageViews.Add(image);
                await LoadImageThumbnailAsync(image, item, tool ? 192u : 1280u, () => requested == loadRevision, aspect => {
                    aspects[selected] = aspect;
                    placeholder.Visibility = Visibility.Collapsed;
                    if (!tool) Layout();
                });
            };
            image.Unloaded += (_, _) => {
                loadRevision++; _imageViews.Remove(image); image.Source = null; placeholder.Visibility = Visibility.Visible;
            };
            button.Click += async (_, _) => await ShowImageGalleryAsync(images, selected);
            tiles.Add(button); canvas.Children.Add(button);
        }
        // Geometry changes resize these existing tiles. They never rebuild the
        // transcript or restart an image download as metadata arrives.
        host.SizeChanged += (_, args) => {
            if (Math.Abs(args.NewSize.Width - args.PreviousSize.Width) < .1) return;
            availableWidth = args.NewSize.Width; Layout();
        };
        Layout();
        return host;
    }
    private async Task LoadImageThumbnailAsync(Image image, DisplayItem item, uint decodeEdge, Func<bool> loadIsCurrent, Action<double> decoded)
    {
        var owner = ImageOwner();
        bool Current() => ImageOwner() == owner && image.IsLoaded && loadIsCurrent();
        try
        {
            var file = await ImageFileAsync(item, false);
            if (file is null || !Current()) return;
            var aspect = ChatImageLayout.FallbackAspect;
            var bitmap = await DecodeImageAsync(file, decodeEdge, value => aspect = value);
            if (!Current()) return;
            image.Source = bitmap;
            decoded(aspect);
        }
        catch { /* A file tile and its explicit viewer action remain available. */ }
    }
    private static async Task<BitmapImage> DecodeImageAsync(string path, uint edge, Action<double>? aspectReady = null)
    {
        var file = await StorageFile.GetFileFromPathAsync(path);
        using var stream = await file.OpenReadAsync();
        var decoder = await BitmapDecoder.CreateAsync(stream);
        var longest = Math.Max(decoder.PixelWidth, decoder.PixelHeight);
        if (longest == 0) throw new InvalidDataException("Invalid image dimensions");
        var scale = Math.Min(1d, edge / (double)longest);
        var bitmap = new BitmapImage {
            DecodePixelWidth = Math.Max(1, (int)(decoder.PixelWidth * scale)),
            DecodePixelHeight = Math.Max(1, (int)(decoder.PixelHeight * scale)),
        };
        stream.Seek(0);
        await bitmap.SetSourceAsync(stream);
        aspectReady?.Invoke(ChatImageLayout.Aspect(decoder.OrientedPixelWidth, decoder.OrientedPixelHeight));
        return bitmap;
    }
    private async Task<string?> ImageFileAsync(DisplayItem item, bool userInitiated, CancellationToken? requestToken = null)
    {
        if (_openId is null) return null;
        var owner = ImageOwner();
        var key = owner + "/" + item.Id;
        if (_imageFiles.TryGetValue(key, out var saved) && File.Exists(saved)) return saved;
        var flightKey = key + "/" + (userInitiated ? "viewer-" + _imageViewerRevision : "thumbnail");
        if (_imageFlights.TryGetValue(flightKey, out var flight)) return await flight;
        var task = DownloadImageFileAsync(item, userInitiated, owner, requestToken ?? _imageCancellation.Token);
        _imageFlights[flightKey] = task;
        try
        {
            var result = await task;
            if (owner != ImageOwner()) { if (result is not null) DeleteImageFile(result); return null; }
            if (result is not null && owner == ImageOwner())
            {
                if (_imageFiles.TryGetValue(key, out var duplicate)) { DeleteImageFile(result); return duplicate; }
                long Size(string path) { try { return new FileInfo(path).Length; } catch (IOException) { return 0; } }
                while (_imageFiles.Count >= 12 || _imageFiles.Values.Sum(Size) + Size(result) > 384L * 1024 * 1024)
                {
                    var oldest = _imageFiles.FirstOrDefault(entry => entry.Value != _imageViewedFile);
                    if (oldest.Key is null) break;
                    _imageFiles.Remove(oldest.Key); DeleteImageFile(oldest.Value);
                }
                _imageFiles[key] = result;
            }
            return result;
        }
        finally { if (owner == ImageOwner()) _imageFlights.Remove(flightKey); }
    }
    private async Task<string?> DownloadImageFileAsync(DisplayItem item, bool userInitiated, string owner, CancellationToken token)
    {
        var chat = _openId;
        var attachment = item.Id.StartsWith("attachment-", StringComparison.Ordinal) ? item.Id[11..] : item.Id;
        var remote = RemoteWorkspaces.TrySplit(_workspaceId, out _, out _);
        var limit = ChatImagePolicy.DownloadLimit(userInitiated, remote, FileMaximumBytes);
        if (item.Size > limit) return null;
        var extension = item.MediaType.ToLowerInvariant() switch { "image/jpeg" => ".jpg", "image/gif" => ".gif",
            "image/webp" => ".webp", "image/bmp" => ".bmp", _ => ".png" };
        var path = Path.Combine(Path.GetTempPath(), "tokenstat-image-" + Guid.NewGuid().ToString("N") + extension);
        bool Current() => !token.IsCancellationRequested && IsLoaded && owner == ImageOwner();
        await _imageSlots.WaitAsync(token);
        try
        {
            if (!Current()) throw new OperationCanceledException();
            var protocol = RemoteFeatureGate.ProtocolOf(await CallChatAsync("protocol", new JsonObject()));
            if (!Current()) throw new OperationCanceledException();
            await using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, FileChunkBytes, true))
            {
                if (protocol is null or < 34)
                {
                    var request = new JsonObject { ["id"] = chat, ["attachmentId"] = attachment, ["allowRelay"] = false };
                    JsonNode response;
                    try { response = await CallChatAsync("chat.attachment", request); }
                    catch (Tokenstat.Host.HostException error) when (userInitiated && error.Code == "relay_consent_required")
                    {
                        if (!Current() || !await ConfirmImageRelayAsync(item.Name, item.Size, token) || !Current()) throw new OperationCanceledException();
                        request["allowRelay"] = true; response = await CallChatAsync("chat.attachment", request);
                    }
                    if (!Current()) throw new OperationCanceledException();
                    var encoded = Format.Text(response, "data");
                    if (encoded.Length > AttachmentCap / 3 * 4 + 4) throw new InvalidDataException(L10n.Text("common.chat_files_too_large"));
                    var bytes = Convert.FromBase64String(encoded);
                    if (bytes.Length > Math.Min(AttachmentCap, limit)) throw new InvalidDataException(L10n.Text("common.chat_files_too_large"));
                    await output.WriteAsync(bytes, token);
                }
                else
                {
                    var caps = await CallChatAsync("chat.fileCapabilities", new JsonObject { ["id"] = chat });
                    if (!Current()) throw new OperationCanceledException();
                    var info = await CallChatAsync("chat.fileDownloadInfo", new JsonObject { ["id"] = chat, ["attachmentId"] = attachment });
                    if (!Current()) throw new OperationCanceledException();
                    var size = Format.Long(info["attachment"], "size");
                    if (size <= 0 || size > Math.Min(limit, Format.Long(caps, "maxFileBytes"))) throw new InvalidDataException(L10n.Text("common.chat_files_too_large"));
                    var relay = Format.Flag(caps, "relay");
                    if (relay && (!userInitiated || !await ConfirmImageRelayAsync(item.Name, size, token) || !Current())) throw new OperationCanceledException();
                    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                    long offset = 0;
                    while (offset < size)
                    {
                        if (!Current()) throw new OperationCanceledException();
                        var request = new JsonObject { ["id"] = chat, ["attachmentId"] = attachment, ["offset"] = offset, ["allowRelay"] = relay };
                        JsonNode chunk;
                        try { chunk = await CallChatAsync("chat.fileDownloadChunk", request); }
                        catch (Tokenstat.Host.HostException error) when (userInitiated && !relay && error.Code == "relay_consent_required")
                        {
                            if (!Current() || !await ConfirmImageRelayAsync(item.Name, size, token) || !Current()) throw new OperationCanceledException();
                            relay = true; request["allowRelay"] = true; chunk = await CallChatAsync("chat.fileDownloadChunk", request);
                        }
                        if (!Current()) throw new OperationCanceledException();
                        var encoded = Format.Text(chunk, "data");
                        if (encoded.Length > 699052) throw new InvalidDataException("Invalid file chunk");
                        var bytes = Convert.FromBase64String(encoded);
                        if (bytes.Length == 0 || bytes.Length > FileChunkBytes || Format.Long(chunk, "offset") != offset
                            || Format.Long(chunk, "nextOffset") != offset + bytes.Length || offset + bytes.Length > size) throw new InvalidDataException("Invalid file chunk");
                        await output.WriteAsync(bytes, token); hash.AppendData(bytes); offset += bytes.Length;
                    }
                    if (!string.Equals(Convert.ToHexString(hash.GetHashAndReset()), Format.Text(info, "sha256"), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("File integrity check failed");
                }
                await output.FlushAsync(token);
            }
            if (!Current()) throw new OperationCanceledException();
            return path;
        }
        catch { DeleteImageFile(path); throw; }
        finally { _imageSlots.Release(); }
    }
    private async Task<bool> ConfirmImageRelayAsync(string name, long size, CancellationToken token)
    {
        if (_imageConsentHost is not StackPanel host) return await ConfirmFileRelayAsync(name, size);
        _imageConsent?.TrySetResult(false);
        var completion = new TaskCompletionSource<bool>(); _imageConsent = completion;
        host.Children.Clear();
        host.Children.Add(new TextBlock { Text = L10n.Text("common.chat_files_relay_message", name, $"{size / 1048576.0:0.#} MB"), TextWrapping = TextWrapping.Wrap });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var accepted in new[] { true, false })
        {
            var button = new Button { Content = L10n.Text(accepted ? "common.continue" : "common.cancel") };
            button.Click += (_, _) => completion.TrySetResult(accepted); actions.Children.Add(button);
        }
        host.Children.Add(actions);
        using var registration = token.Register(() => completion.TrySetResult(false));
        try { return await completion.Task; }
        finally { if (_imageConsent == completion) { _imageConsent = null; host.Children.Clear(); } }
    }
    private async Task SaveImageFileAsync(string path, DisplayItem item, string owner)
    {
        var token = _imageCancellation.Token;
        try
        {
            var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = item.Name };
            var extension = Path.GetExtension(item.Name); if (string.IsNullOrEmpty(extension)) extension = ".png";
            picker.FileTypeChoices.Add(L10n.Text("common.file"), new List<string> { extension });
            if (App.CurrentWindow is { } window) WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
            var destination = await picker.PickSaveFileAsync();
            if (destination is null || owner != ImageOwner() || !IsLoaded) return;
            await using var input = File.OpenRead(path);
            await using var output = await destination.OpenStreamForWriteAsync();
            output.SetLength(0); await input.CopyToAsync(output, token); await output.FlushAsync(token);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (owner == ImageOwner() && IsLoaded) Banner(error.Message); }
    }
    private async Task ShowImageGalleryAsync(DisplayItem[] images, int selected)
    {
        if (_imageDialog is not null || images.Length == 0) return;
        _imageViewerRevision++;
        using var viewerCancellation = CancellationTokenSource.CreateLinkedTokenSource(_imageCancellation.Token);
        var owner = ImageOwner();
        var image = new Image { Stretch = Stretch.Uniform };
        var viewer = new ScrollViewer { Content = image, ZoomMode = ZoomMode.Enabled, MinZoomFactor = .1f, MaxZoomFactor = 5,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Height = Math.Clamp(XamlRoot.Size.Height - 240, 180, 620), HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center };
        var name = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis, IsTextSelectionEnabled = true };
        var count = new TextBlock { Opacity = .7 };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var consent = new StackPanel { Spacing = 6 }; _imageConsentHost = consent;
        var body = new StackPanel { Spacing = 8, Width = Math.Clamp(XamlRoot.Size.Width - 100, 260, 1000) };
        body.Children.Add(name); body.Children.Add(count); body.Children.Add(consent); body.Children.Add(viewer);
        body.Children.Add(new ScrollViewer { Content = actions, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollMode = ScrollMode.Disabled });
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Content = body, CloseButtonText = L10n.Text("common.close") };
        dialog.Resources["ContentDialogMaxWidth"] = 1100d;
        _imageDialog = dialog;
        var revision = 0;
        CancellationTokenSource? selectionCancellation = null;
        string? currentFile = null;
        bool Current() => owner == ImageOwner() && _imageDialog == dialog && IsLoaded;
        async Task Show(int next)
        {
            selectionCancellation?.Cancel();
            var selection = CancellationTokenSource.CreateLinkedTokenSource(viewerCancellation.Token);
            selectionCancellation = selection;
            _imageViewerRevision++;
            selected = Math.Clamp(next, 0, images.Length - 1);
            var item = images[selected]; var request = ++revision;
            currentFile = null; _imageViewedFile = null; image.Source = null;
            var position = L10n.Text("common.chat.images.position", (selected + 1).ToString(), images.Length.ToString());
            name.Text = item.Name; count.Text = position + " …";
            if (actions.Children.Count >= 2) { ((Button)actions.Children[0]).IsEnabled = selected > 0; ((Button)actions.Children[1]).IsEnabled = selected < images.Length - 1; }
            viewer.ChangeView(0, 0, 1, true);
            try
            {
                var file = await ImageFileAsync(item, true, selection.Token);
                if (!Current() || request != revision) return;
                if (file is null) { count.Text = position + " · " + L10n.Text("common.chat.images.unavailable"); return; }
                _imageViewedFile = file;
                currentFile = file;
                var bitmap = await DecodeImageAsync(file, 4096);
                if (!Current() || request != revision) return;
                image.Source = bitmap; count.Text = position;
                image.MaxWidth = Math.Max(1, body.Width); image.MaxHeight = viewer.Height;
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { if (Current() && request == revision) count.Text = position + " · " + error.Message; }
            finally { if (selectionCancellation == selection) selectionCancellation = null; selection.Dispose(); }
        }
        Button Action(string label, Action click)
        {
            var button = new Button { Content = label, MinHeight = 32, Padding = new Thickness(8, 4, 8, 4) };
            button.Click += (_, _) => click(); actions.Children.Add(button); return button;
        }
        var previous = Action(L10n.Text("common.chat.images.previous"), () => _ = Show(selected - 1));
        var next = Action(L10n.Text("common.chat.images.next"), () => _ = Show(selected + 1));
        previous.IsEnabled = next.IsEnabled = images.Length > 1;
        var zoomOut = Action("−", () => viewer.ChangeView(null, null, Math.Max(.1f, viewer.ZoomFactor / 1.25f)));
        AutomationProperties.SetName(zoomOut, L10n.Text("common.chat.images.zoom_out"));
        var zoomIn = Action("+", () => viewer.ChangeView(null, null, Math.Min(5, viewer.ZoomFactor * 1.25f)));
        AutomationProperties.SetName(zoomIn, L10n.Text("common.chat.images.zoom_in"));
        Action(L10n.Text("common.chat.images.fit"), () => viewer.ChangeView(0, 0, 1));
        Action(L10n.Text("common.open"), async () => { try { if (currentFile is string file && Current()) { var original = await StorageFile.GetFileFromPathAsync(file); if (Current()) await Launcher.LaunchFileAsync(original); } } catch (Exception error) { if (Current()) count.Text = error.Message; } });
        Action(L10n.Text("common.save"), () => { if (currentFile is string file && Current()) _ = SaveImageFileAsync(file, images[selected], owner); });
        dialog.PreviewKeyDown += (_, args) => {
            if (args.Key == VirtualKey.Escape) { dialog.Hide(); args.Handled = true; }
            else if (args.Key == VirtualKey.Left) { _ = Show(selected - 1); args.Handled = true; }
            else if (args.Key == VirtualKey.Right) { _ = Show(selected + 1); args.Handled = true; }
        };
        try { _ = Show(selected); await dialog.ShowAsync(); }
        finally { viewerCancellation.Cancel(); revision++; image.Source = null; if (_imageDialog == dialog) { _imageDialog = null; _imageViewedFile = null; _imageConsent?.TrySetResult(false); _imageConsentHost = null; } }
    }
}
