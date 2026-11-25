// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Tokenstat.Pages;

internal sealed partial class ScreenPage
{
    private const int ScreenFileChunk = 256 * 1024;
    private const long ScreenFileMaximum = 10L * 1024 * 1024 * 1024;
    private readonly StackPanel _screenFiles = new() { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
    private readonly ProgressBar _screenFileProgress = new() { Width = 82, MaxHeight = 8, VerticalAlignment = VerticalAlignment.Center };
    private Button? _sendScreenFile;
    private Button? _cancelScreenFile;
    private CancellationTokenSource? _screenFileTransfer;
    private bool _screenFilePicking;

    private void BuildScreenFileControls()
    {
        _sendScreenFile = ActionIconGlyph.Button(L10n.Text("windows.screenpage.send_file"), ActionIcon.Upload, async (_, _) => await SendScreenFileAsync());
        _cancelScreenFile = ActionIconGlyph.Button(L10n.Text("common.cancel"), ActionIcon.Stop, (_, _) => _screenFileTransfer?.Cancel());
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_screenFileProgress, L10n.Text("windows.screenpage.sending_file"));
        _screenFiles.Children.Add(_sendScreenFile);
        _screenFiles.Children.Add(_screenFileProgress);
        _screenFiles.Children.Add(_cancelScreenFile);
        RefreshScreenFileControls();
    }

    private void RefreshScreenFileControls()
    {
        var sending = _screenFileTransfer is not null;
        if (_sendScreenFile is null || _cancelScreenFile is null) return;
        _sendScreenFile.Visibility = !sending && _control ? Visibility.Visible : Visibility.Collapsed;
        _sendScreenFile.IsEnabled = !_closed && !_screenFilePicking && !_changingControl && !_reconnecting && _sessionId is not null;
        _screenFileProgress.Visibility = _cancelScreenFile.Visibility = sending ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task SendScreenFileAsync()
    {
        bool Current() => IsLoaded && !_closed && _control && _accountGeneration == AppServices.AccountGeneration;
        if (!Current() || _sessionId is null || _screenFilePicking || _screenFileTransfer is not null || App.CurrentWindow is not { } window) return;
        _screenFilePicking = true;
        RefreshScreenFileControls();
        StorageFile? file;
        try
        {
            var picker = new FileOpenPicker();
            picker.FileTypeFilter.Add("*");
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
            file = await picker.PickSingleFileAsync();
        }
        catch (Exception error)
        {
            if (Current()) Banner(FriendlyError.Display(error.Message));
            return;
        }
        finally { _screenFilePicking = false; RefreshScreenFileControls(); }
        if (file is null || !Current() || _sessionId is null) return;
        using var transfer = new CancellationTokenSource();
        _screenFileTransfer = transfer;
        _screenFileProgress.Value = 0;
        _screenFileProgress.IsIndeterminate = true;
        RefreshScreenFileControls();
        string? id = null;
        bool opened = false;
        void RequireCurrent()
        {
            transfer.Token.ThrowIfCancellationRequested();
            if (!Current()) throw new OperationCanceledException();
        }
        try
        {
            using var stream = await file.OpenStreamForReadAsync();
            var size = stream.Length;
            if (size < 0 || size > ScreenFileMaximum) throw new IOException(L10n.Text("windows.screenpage.file_too_large"));
            using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await ChatPage.ReadFileHashAsync(stream, hasher, size, transfer.Token);
            var hash = Convert.ToHexString(hasher.GetHashAndReset()).ToLowerInvariant();
            RequireCurrent();
            if (stream.Length != size || stream.Position != size) throw new IOException(L10n.Text("windows.screenpage.file_changed"));
            var resume = Encoding.UTF8.GetBytes(file.Name + "\0" + size.ToString(CultureInfo.InvariantCulture) + "\0" + hash);
            id = Convert.ToHexString(SHA256.HashData(resume)).ToLowerInvariant();
            var response = await RemoteWorkspaces.CallOnPeerAsync(_peer, "screen.transfer.open", new JsonObject
            {
                ["id"] = id, ["name"] = file.Name, ["size"] = size, ["digest"] = hash,
            });
            opened = true;
            RequireCurrent();
            if (Format.Text(response, "id") != id || !long.TryParse(Format.Text(response, "offset"), out var offset)
                || offset < 0 || offset > size || !int.TryParse(Format.Text(response, "chunkBytes"), out var chunk) || chunk <= 0)
                throw new InvalidDataException(L10n.Text("windows.screenpage.file_progress_invalid"));
            var buffer = new byte[Math.Min(chunk, ScreenFileChunk)];
            stream.Seek(offset, SeekOrigin.Begin);
            _screenFileProgress.IsIndeterminate = false;
            _screenFileProgress.Value = size == 0 ? 100 : 100d * offset / size;
            while (offset < size)
            {
                RequireCurrent();
                var count = (int)Math.Min(buffer.Length, size - offset);
                await stream.ReadExactlyAsync(buffer.AsMemory(0, count), transfer.Token);
                RequireCurrent();
                var acknowledgement = await RemoteWorkspaces.CallOnPeerAsync(_peer, "screen.transfer.chunk", new JsonObject
                {
                    ["id"] = id, ["offset"] = offset, ["data"] = Convert.ToBase64String(buffer, 0, count),
                });
                RequireCurrent();
                if (!long.TryParse(Format.Text(acknowledgement, "offset"), out var next) || next != offset + count)
                    throw new InvalidDataException(L10n.Text("windows.screenpage.file_progress_invalid"));
                offset = next;
                _screenFileProgress.Value = 100d * offset / size;
            }
            if (stream.Length != size) throw new IOException(L10n.Text("windows.screenpage.file_changed"));
            var saved = await RemoteWorkspaces.CallOnPeerAsync(_peer, "screen.transfer.finish", new JsonObject { ["id"] = id });
            if (!Format.Flag(saved, "saved")) throw new IOException(L10n.Text("windows.screenpage.file_progress_invalid"));
            if (Current())
            {
                _status.Children.Clear();
                _status.Children.Add(Chrome.Banner(L10n.Text("windows.screenpage.file_sent", file.Name, _name), Theme.Accent, Symbol.Accept));
            }
        }
        catch (OperationCanceledException)
        {
            if (opened && id is not null && _accountGeneration == AppServices.AccountGeneration)
            {
                try { await RemoteWorkspaces.CallOnPeerAsync(_peer, "screen.transfer.cancel", new JsonObject { ["id"] = id }); }
                catch { /* A lost cancel leaves the host's resumable partial file. */ }
            }
        }
        catch (Exception error)
        {
            if (Current()) Banner(FriendlyError.Display(error.Message));
        }
        finally
        {
            _screenFileTransfer = null;
            if (IsLoaded) RefreshScreenFileControls();
        }
    }
}
