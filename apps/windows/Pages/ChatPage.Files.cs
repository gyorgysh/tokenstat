// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.IO;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Tokenstat.Design;
using Tokenstat.Host;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Tokenstat.Pages;
internal sealed partial class ChatPage
{
    private const int FileChunkBytes = 512 * 1024;
    private const long FileMaximumBytes = 256L * 1024 * 1024;
    private CancellationTokenSource? _fileTransfer;

    private async Task<bool> ConfirmFileRelayAsync(string name, long size, long? remaining = null)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = L10n.Text("common.chat_files_relay_title"),
            Content = new TextBlock { Text = L10n.Text("common.chat_files_relay_message", name, $"{size / 1048576.0:0.#} MB") + (remaining.HasValue ? "\n\n" + L10n.Text("common.chat_files_remaining", $"{remaining.Value / 1048576.0:0.#} MB") : ""), TextWrapping = Microsoft.UI.Xaml.TextWrapping.Wrap },
            PrimaryButtonText = L10n.Text("common.continue"),
            CloseButtonText = L10n.Text("common.cancel"),
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }
    private async Task<JsonNode> UploadFileAsync(string chat, Windows.Storage.StorageFile file, Func<bool> selected)
    {
        var accountGeneration = AppServices.AccountGeneration;
        bool current() => selected() && accountGeneration == AppServices.AccountGeneration;
        using var stream = await file.OpenStreamForReadAsync();
        if (stream.Length is <= 0 or > FileMaximumBytes) throw new IOException(L10n.Text("common.chat_files_too_large"));
        var protocol = RemoteFeatureGate.ProtocolOf(await CallChatAsync("protocol", new JsonObject()));
        if (!current()) throw new OperationCanceledException();
        if (protocol < 34)
        {
            if (stream.Length > AttachmentCap) throw new IOException(L10n.Text("common.chat_route_unavailable"));
            var bytes = new byte[(int)stream.Length];
            await stream.ReadExactlyAsync(bytes);
            var request = new JsonObject { ["id"] = chat, ["name"] = file.Name, ["data"] = Convert.ToBase64String(bytes), ["allowRelay"] = false };
            try { return await CallChatAsync("chat.attach", request); }
            catch (HostException error) when (error.Code == "relay_consent_required") { if (!await ConfirmFileRelayAsync(file.Name, bytes.Length) || !current()) throw new OperationCanceledException(); request["allowRelay"] = true; return await CallChatAsync("chat.attach", request); }
        }
        if (_fileTransfer is not null) throw new IOException(L10n.Text("common.chat_files_busy"));
        using var cancel = new CancellationTokenSource(); _fileTransfer = cancel;
        RebuildComposerActions();
        try
        {
            var expectedSize = stream.Length;
            using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var hashBuffer = new byte[FileChunkBytes];
            long hashedBytes = 0;
            while (true)
            {
                var count = await stream.ReadAsync(hashBuffer, cancel.Token);
                if (count == 0) break;
                hashedBytes += count;
                if (hashedBytes > expectedSize) throw new IOException("The file changed while reading");
                hasher.AppendData(hashBuffer, 0, count);
            }
            if (hashedBytes != expectedSize || stream.Length != expectedSize) throw new IOException("The file changed while reading");
            var hash = Convert.ToHexString(hasher.GetHashAndReset()).ToLowerInvariant(); stream.Position = 0;
            var caps = await CallChatAsync("chat.fileCapabilities", new JsonObject { ["id"] = chat });
            if (!current()) throw new OperationCanceledException();
            if (stream.Length > Format.Long(caps, "maxFileBytes")) throw new IOException(L10n.Text("common.chat_files_too_large"));
            var relay = Format.Flag(caps, "relay");
            if (relay && !await ConfirmFileRelayAsync(file.Name, stream.Length, caps?["relayRemainingBytes"] is null ? null : Format.Long(caps, "relayRemainingBytes"))) throw new OperationCanceledException();
            if (!current()) throw new OperationCanceledException();
            var account = await AppServices.Host.CallAsync("account.status", new JsonObject());
            if (!current()) throw new OperationCanceledException();
            var owner = Format.Text(account, "host") + "|" + Format.Text(account, "accountId") + "|" + Format.Text(account, "handle");
            var key = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(owner + "|" + _workspaceId + "|" + chat + "|" + hash)));
            var journal = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "file-transfers", key + ".json");
            JsonNode? previous = null;
            if (File.Exists(journal) && new FileInfo(journal).Length < 8192)
            {
                try { var saved = JsonNode.Parse(await File.ReadAllTextAsync(journal)); previous = await CallChatAsync("chat.fileUploadStatus", new JsonObject { ["id"] = chat, ["transferId"] = Format.Text(saved, "transferId") }); } catch (HostException) { }
            }
            if (!current()) throw new OperationCanceledException();
            if (Format.Flag(previous, "finished") && previous?["attachment"] is JsonNode completed) { File.Delete(journal); return completed.DeepClone(); }
            var start = previous ?? await CallChatAsync("chat.fileUploadStart", new JsonObject { ["id"] = chat, ["name"] = file.Name, ["size"] = stream.Length, ["sha256"] = hash });
            Directory.CreateDirectory(Path.GetDirectoryName(journal)!);
            try
            {
                await File.WriteAllTextAsync(journal + ".tmp", start.ToJsonString(), cancel.Token);
                File.Move(journal + ".tmp", journal, true);
            }
            catch
            {
                try { await CallChatAsync("chat.fileUploadCancel", new JsonObject { ["id"] = chat, ["transferId"] = Format.Text(start, "transferId") }); } catch { }
                throw;
            }
            var transfer = Format.Text(start, "transferId");
            var offset = Format.Long(start, "offset");
            if (offset < 0 || offset > stream.Length) throw new IOException("Invalid file transfer response");
            try
            {
                var buffer = new byte[FileChunkBytes];
                while (offset < expectedSize)
                {
                    cancel.Token.ThrowIfCancellationRequested(); if (!current()) throw new OperationCanceledException();
                    stream.Position = offset;
                    var count = (int)Math.Min(buffer.Length, expectedSize - offset);
                    await stream.ReadExactlyAsync(buffer.AsMemory(0, count), cancel.Token);
                    var request = new JsonObject { ["id"] = chat, ["transferId"] = transfer, ["offset"] = offset, ["data"] = Convert.ToBase64String(buffer, 0, count), ["allowRelay"] = relay };
                    JsonNode chunk;
                    try { chunk = await CallChatAsync("chat.fileUploadChunk", request); }
                    catch (HostException error) when (error.Code == "relay_consent_required" && !relay)
                    {
                        if (!await ConfirmFileRelayAsync(file.Name, stream.Length, caps?["relayRemainingBytes"] is null ? null : Format.Long(caps, "relayRemainingBytes")) || !current()) throw new OperationCanceledException();
                        relay = true; request["allowRelay"] = true; chunk = await CallChatAsync("chat.fileUploadChunk", request);
                    }
                    if (Format.Long(chunk, "offset") != offset + count) throw new IOException("Invalid file transfer response");
                    offset += count;
                    Banner($"{file.Name} · {offset * 100 / stream.Length}%");
                }
                cancel.Token.ThrowIfCancellationRequested(); if (!current()) throw new OperationCanceledException();
                var result = await CallChatAsync("chat.fileUploadFinish", new JsonObject { ["id"] = chat, ["transferId"] = transfer });
                File.Delete(journal); return result;
            }
            catch (OperationCanceledException)
            {
                try { await CallChatAsync("chat.fileUploadCancel", new JsonObject { ["id"] = chat, ["transferId"] = transfer }); } catch { }
                File.Delete(journal); throw;
            }
        }
        finally { _fileTransfer = null; if (current()) RebuildComposerActions(); }
    }
    private async Task DownloadFileAsync(DisplayItem item)
    {
        if (_openId is not string chat || _fileTransfer is not null) return;
        var generation = _openGeneration;
        var accountGeneration = AppServices.AccountGeneration;
        bool Current() => OpenChatIs(chat) && _openGeneration == generation && accountGeneration == AppServices.AccountGeneration;
        var picker = new FileSavePicker { SuggestedFileName = item.Name };
        var extension = Path.GetExtension(item.Name); if (string.IsNullOrEmpty(extension)) extension = ".bin";
        picker.FileTypeChoices.Add(L10n.Text("common.file"), new List<string> { extension });
        if (App.CurrentWindow is { } window) InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
        var destination = await picker.PickSaveFileAsync();
        if (destination is null || !Current()) return;
        var temporary = Path.Combine(Path.GetTempPath(), "tokenstat-file-" + Guid.NewGuid().ToString("N"));
        using var cancel = new CancellationTokenSource(); _fileTransfer = cancel; RebuildComposerActions();
        var keepPartial = false;
        try
        {
            var protocol = RemoteFeatureGate.ProtocolOf(await CallChatAsync("protocol", new JsonObject()));
            var attachment = item.Id.StartsWith("attachment-", StringComparison.Ordinal) ? item.Id[11..] : item.Id;
            JsonNode? caps = null, info = null;
            long size = 0;
            if (protocol >= 34)
            {
                caps = await CallChatAsync("chat.fileCapabilities", new JsonObject { ["id"] = chat });
                info = await CallChatAsync("chat.fileDownloadInfo", new JsonObject { ["id"] = chat, ["attachmentId"] = attachment });
                size = Format.Long(info["attachment"], "size");
                if (size <= 0 || size > Math.Min(FileMaximumBytes, Format.Long(caps, "maxFileBytes"))) throw new IOException(L10n.Text("common.chat_files_too_large"));
                var account = await AppServices.Host.CallAsync("account.status", new JsonObject());
                if (!Current()) throw new OperationCanceledException();
                var owner = Format.Text(account, "host") + "|" + Format.Text(account, "accountId") + "|" + Format.Text(account, "handle");
                var key = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(owner + "|" + _workspaceId + "|" + chat + "|" + attachment + "|" + Format.Text(info, "sha256"))));
                temporary = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "file-downloads", key + ".part");
                Directory.CreateDirectory(Path.GetDirectoryName(temporary)!);
                if (File.Exists(temporary) && (new FileInfo(temporary).Length > size || DateTime.UtcNow - File.GetLastWriteTimeUtc(temporary) > TimeSpan.FromDays(1))) File.Delete(temporary);
                keepPartial = true;
            }
            await using (var output = new FileStream(temporary, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, FileChunkBytes, true))
            {
                if (protocol < 34)
                {
                    var request = new JsonObject { ["id"] = chat, ["attachmentId"] = attachment, ["allowRelay"] = false };
                    JsonNode old;
                    try { old = await CallChatAsync("chat.attachment", request); }
                    catch (HostException error) when (error.Code == "relay_consent_required") { if (!await ConfirmFileRelayAsync(item.Name, item.Size) || !Current()) throw new OperationCanceledException(); request["allowRelay"] = true; old = await CallChatAsync("chat.attachment", request); }
                    var encoded = Format.Text(old, "data"); if (encoded.Length > AttachmentCap / 3 * 4 + 4) throw new IOException(L10n.Text("common.chat_files_too_large"));
                    await output.WriteAsync(Convert.FromBase64String(encoded), cancel.Token);
                }
                else
                {
                    var relay = Format.Flag(caps, "relay"); if (relay && !await ConfirmFileRelayAsync(item.Name, size, caps?["relayRemainingBytes"] is null ? null : Format.Long(caps, "relayRemainingBytes"))) throw new OperationCanceledException();
                    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                    long offset = 0;
                    var prefix = new byte[FileChunkBytes];
                    while (true) { var read = await output.ReadAsync(prefix, cancel.Token); if (read == 0) break; hash.AppendData(prefix, 0, read); offset += read; }
                    while (offset < size)
                    {
                        cancel.Token.ThrowIfCancellationRequested(); if (!Current()) throw new OperationCanceledException();
                        var request = new JsonObject { ["id"] = chat, ["attachmentId"] = attachment, ["offset"] = offset, ["allowRelay"] = relay };
                        JsonNode chunk;
                        try { chunk = await CallChatAsync("chat.fileDownloadChunk", request); }
                        catch (HostException error) when (error.Code == "relay_consent_required" && !relay)
                        { if (!await ConfirmFileRelayAsync(item.Name, size, caps?["relayRemainingBytes"] is null ? null : Format.Long(caps, "relayRemainingBytes")) || !Current()) throw new OperationCanceledException(); relay = true; request["allowRelay"] = true; chunk = await CallChatAsync("chat.fileDownloadChunk", request); }
                        var encoded = Format.Text(chunk, "data"); if (encoded.Length > 699052) throw new IOException("Invalid file chunk");
                        var bytes = Convert.FromBase64String(encoded);
                        if (bytes.Length == 0 || bytes.Length > FileChunkBytes || Format.Long(chunk, "offset") != offset || Format.Long(chunk, "nextOffset") != offset + bytes.Length || offset + bytes.Length > size) throw new IOException("Invalid file chunk");
                        await output.WriteAsync(bytes, cancel.Token); hash.AppendData(bytes); offset += bytes.Length; Banner($"{item.Name} · {offset * 100 / size}%");
                    }
                    if (Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant() != Format.Text(info, "sha256")) throw new IOException("File integrity check failed");
                }
                await output.FlushAsync(cancel.Token);
            }
            cancel.Token.ThrowIfCancellationRequested(); if (!Current()) throw new OperationCanceledException();
            await using (var input = File.OpenRead(temporary))
            await using (var output = await destination.OpenStreamForWriteAsync()) { output.SetLength(0); await input.CopyToAsync(output, cancel.Token); await output.FlushAsync(cancel.Token); }
            keepPartial = false;
            if (Current()) Banner(L10n.Text("common.chat_files_saved"));
        }
        catch (OperationCanceledException) { keepPartial = false; }
        catch (Exception error) { if (Current()) Banner(error.Message); }
        finally { _fileTransfer = null; if (!keepPartial) File.Delete(temporary); if (Current()) RebuildComposerActions(); }
    }
}
