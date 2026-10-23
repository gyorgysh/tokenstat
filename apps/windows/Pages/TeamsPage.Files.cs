// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed partial class TeamsPage
{
    private int _fileOperations;
    private async Task SaveSharedFileAsync(TeamSharedFileData file, Func<bool> current)
    {
        if (_saveFile is not null) { await _saveFile(file, current); return; }
        var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = file.Name };
        var extension = Path.GetExtension(file.Name);
        if (!System.Text.RegularExpressions.Regex.IsMatch(extension, "^\\.[a-zA-Z0-9]{1,16}$")) extension = ".bin";
        picker.FileTypeChoices.Add(L10n.Text("common.file"), new List<string> { extension });
        if (App.CurrentWindow is not { } window) throw new InvalidOperationException();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        var destination = await picker.PickSaveFileAsync();
        if (destination is null) throw new OperationCanceledException();
        if (!current()) throw new OperationCanceledException();
        await TeamSharedFileSave.WriteMarked(destination.Path, file.Bytes, current);
    }
    private UIElement SharedFile(JsonObject target, JsonObject file)
    {
        var view = _view; var generation = AppServices.AccountGeneration;
        bool Current() => IsLoaded && _view == view && AppServices.AccountGeneration == generation;
        var id = Format.Text(file, "id"); var name = TeamSharedFileData.SafeName(Format.Text(file, "name"));
        var panel = new StackPanel { Spacing = Theme.SpaceS };
        panel.Children.Add(TeamText(name));
        var actions = new FlowPanel { Spacing = Theme.SpaceS }; panel.Children.Add(actions);
        var note = TeamText(""); panel.Children.Add(note);
        var key = Format.Text(target, "share") + "/" + id;
        var hasImage = _openedImages.TryGetValue(key, out var opened);
        if (opened is not null) panel.Children.Add(new Image { Source = opened, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left });
        Button? preview = null; Button? save = null; var busy = false;
        void SetBusy(bool value) { busy = value; save!.IsEnabled = !value; if (preview is not null) preview.IsEnabled = !value && !hasImage; }
        async Task<TeamSharedFileData> Fetch()
        {
            var reply = await CallAsync("teams.connection.call", new JsonObject { ["target"] = target.DeepClone(), ["method"] = "team.chat.attachment", ["params"] = new JsonObject { ["attachment"] = id } });
            if (!Current()) throw new OperationCanceledException();
            return await Task.Run(() => TeamSharedFileData.Read(reply, Format.Text(target, "share"), id));
        }
        save = ActionIconGlyph.Button(L10n.Text("common.teams.save_file"), ActionIcon.Save, async (_, _) => {
            if (busy || !Current()) return; SetBusy(true); _fileOperations++; note.Text = "";
            try { var data = await Fetch(); if (!Current()) return; await SaveSharedFileAsync(data, Current); if (Current()) note.Text = L10n.Text("common.teams.file_saved"); }
            catch (OperationCanceledException) { }
            catch (Exception error) { if (Current()) note.Text = error is Host.HostException ? error.Message : L10n.Text("common.teams.file_save_failed"); }
            finally { _fileOperations--; if (Current()) SetBusy(false); }
        }); actions.Children.Add(save);
        var hint = Format.Text(file, "mediaType").ToLowerInvariant();
        if (!hasImage && hint.StartsWith("image/", StringComparison.Ordinal) && hint != "image/svg+xml")
        {
            preview = ActionIconGlyph.Button(L10n.Text("common.teams.open_file_action"), ActionIcon.Preview, async (_, _) => {
                if (busy || !Current()) return; SetBusy(true); _fileOperations++; note.Text = "";
                try
                {
                    var data = await Fetch(); if (!data.IsRaster) throw new InvalidDataException();
                    using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream(); await stream.WriteAsync(data.Bytes.AsBuffer()); stream.Seek(0);
                    var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
                    uint width = decoder.PixelWidth, height = decoder.PixelHeight;
                    if (width == 0 || height == 0 || (ulong)width * height > 100_000_000UL || Math.Max(width, height) / Math.Min(width, height) > 50) throw new InvalidDataException();
                    stream.Seek(0); var bitmap = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
                    if (width >= height) bitmap.DecodePixelWidth = (int)Math.Min(width, 2048u); else bitmap.DecodePixelHeight = (int)Math.Min(height, 2048u);
                    await bitmap.SetSourceAsync(stream); if (!Current()) return;
                    if (_openedImages.Count >= 16) _openedImages.Clear(); _openedImages[key] = bitmap; hasImage = true;
                    actions.Children.Remove(preview); panel.Children.Add(new Image { Source = bitmap, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left });
                }
                catch (OperationCanceledException) { }
                catch (Exception error) { if (Current()) note.Text = error is Host.HostException ? error.Message : L10n.Text("common.teams.file_unavailable"); }
                finally { _fileOperations--; if (Current()) SetBusy(false); }
            }); actions.Children.Add(preview);
        }
        return panel;
    }
}
