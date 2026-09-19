// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>Register or clone a folder on its owning computer, as on desktop Mac.</summary>
internal sealed class RemoteWorkspaceAddDialog
{
    private readonly ContentDialog _dialog = new()
    {
        Title = "On another machine",
        PrimaryButtonText = "Register this folder",
        CloseButtonText = "Cancel",
        IsPrimaryButtonEnabled = false,
    };
    private readonly ComboBox _machine = new() { Header = "Computer", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox _route = new() { Header = "Add", ItemsSource = new[] { "An existing folder", "Clone a repository" }, SelectedIndex = 0 };
    private readonly TextBox _url = new() { Header = "Repository address", PlaceholderText = "https://github.com/owner/project.git" };
    private readonly TextBox _name = new() { Header = "Folder name (optional)" };
    private readonly StackPanel _cloneFields = new() { Spacing = Theme.SpaceS, Visibility = Visibility.Collapsed };
    private readonly TextBlock _path = new() { FontFamily = Fonts.Mono, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private readonly StackPanel _folders = new() { Spacing = 4 };
    private readonly StackPanel _roots = new() { Spacing = 4 };
    private readonly TextBlock _notice = new() { TextWrapping = TextWrapping.Wrap };
    private readonly ProgressRing _progress = new() { Width = 20, Height = 20, IsActive = false, Visibility = Visibility.Collapsed };
    private readonly List<(string Key, string Label)> _peers = new();
    private readonly CancellationTokenSource _closed = new();
    private string? _currentPath;
    private string? _added;
    private int _generation;
    private bool _working;
    private bool _browsing;
    private bool _loadingPeers;
    private string? _cloneSession;
    private string? Peer => _machine.SelectedIndex >= 0 && _machine.SelectedIndex < _peers.Count
        ? _peers[_machine.SelectedIndex].Key : null;
    private bool Clone => _route.SelectedIndex == 1;

    private RemoteWorkspaceAddDialog()
    {
        _cloneFields.Children.Add(_url);
        _cloneFields.Children.Add(_name);
        _cloneFields.Children.Add(new TextBlock
        {
            Text = "Git runs on the selected computer. Private repositories use credentials on that computer. Closing this window leaves a started clone running there.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.7,
        });
        var body = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 340 };
        body.Children.Add(_machine);
        body.Children.Add(_route);
        body.Children.Add(_cloneFields);
        body.Children.Add(_roots);
        body.Children.Add(_path);
        body.Children.Add(new ScrollViewer { Content = _folders, Height = 190 });
        body.Children.Add(_progress);
        body.Children.Add(_notice);
        var retry = ActionIconGlyph.Button("Reload folders", ActionIcon.Refresh, async (_, _) =>
        {
            if (_working || _cloneSession is not null) return;
            if (Peer is null) await LoadPeersAsync();
            else await BrowseAsync(_currentPath);
        });
        body.Children.Add(retry);
        _dialog.Content = new ScrollViewer { Content = body, MaxHeight = 600 };
        _machine.SelectionChanged += async (_, _) => await BrowseAsync(null);
        _route.SelectionChanged += (_, _) =>
        {
            _cloneFields.Visibility = Clone ? Visibility.Visible : Visibility.Collapsed;
            UpdateActions();
        };
        _url.TextChanged += (_, _) => UpdateActions();
        _dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            await AddAsync();
        };
        _dialog.Closed += (_, _) => _closed.Cancel();
        _dialog.Opened += async (_, _) => await LoadPeersAsync();
    }

    public static async Task<string?> ShowAsync(UIElement owner)
    {
        var view = new RemoteWorkspaceAddDialog();
        try
        {
            await Chrome.ShowDialog(owner, view._dialog);
            return view._added;
        }
        finally
        {
            view._closed.Cancel();
            // In-flight host calls retain the token until their continuations finish.
        }
    }

    private void UpdateActions()
    {
        _dialog.PrimaryButtonText = _working ? (Clone ? "Cloning…" : "Registering…")
            : _cloneSession is not null ? "Check clone" : Clone ? "Clone here" : "Register this folder";
        _dialog.IsPrimaryButtonEnabled = !_working && !_browsing && Peer is not null
            && !string.IsNullOrEmpty(_currentPath) && (!Clone || !string.IsNullOrWhiteSpace(_url.Text));
        _machine.IsEnabled = !_working && _cloneSession is null;
        _route.IsEnabled = !_working && _cloneSession is null;
        _url.IsEnabled = !_working && _cloneSession is null;
        _name.IsEnabled = !_working && _cloneSession is null;
        foreach (var control in _folders.Children.OfType<Control>().Concat(_roots.Children.OfType<Control>()))
        {
            control.IsEnabled = !_working && !_browsing && _cloneSession is null;
        }
        _progress.IsActive = _working || _browsing;
        _progress.Visibility = _progress.IsActive ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task LoadPeersAsync()
    {
        if (_loadingPeers || _closed.IsCancellationRequested) return;
        _loadingPeers = true;
        _notice.Text = "Finding paired computers…";
        try
        {
            var listed = Format.Items(await AppServices.Host.CallAsync("machine.peers")) ?? new JsonArray();
            JsonArray machines = new();
            try
            {
                var account = await AppServices.Host.CallAsync("account.status");
                machines = account["machines"] as JsonArray ?? new();
            }
            catch { /* approved peers remain usable without the account directory */ }
            if (_closed.IsCancellationRequested) return;
            _peers.Clear();
            foreach (var peer in listed)
            {
                var key = Format.Text(peer, "key");
                if (string.IsNullOrEmpty(key) || Format.Text(peer, "trust") != "approved") continue;
                var fingerprint = Format.Text(peer, "fingerprint");
                var companion = machines.Any(machine =>
                {
                    var identity = Format.Text(machine, "publicIdentity", Format.Text(machine, "machineId"));
                    return (identity == key || (!string.IsNullOrEmpty(fingerprint) && identity == fingerprint))
                        && Format.Text(machine, "kind") == "client";
                });
                if (companion) continue;
                var label = Format.Text(peer, "label");
                _peers.Add((key, string.IsNullOrWhiteSpace(label) ? key[..Math.Min(8, key.Length)] : label));
            }
            _machine.ItemsSource = _peers.Select(peer => peer.Label).ToList();
            _notice.Text = _peers.Count == 0 ? "Pair a computer on the Devices screen first. Folders live on computers, not phones or tablets." : "Choose the computer that will hold the folder.";
            if (_peers.Count > 0) _machine.SelectedIndex = 0;
        }
        catch (Exception ex)
        {
            _notice.Text = FriendlyError.Display(ex.Message);
        }
        finally
        {
            _loadingPeers = false;
        }
    }

    private async Task BrowseAsync(string? path)
    {
        var peer = Peer;
        if (peer is null || _working || _cloneSession is not null || _closed.IsCancellationRequested) return;
        var generation = ++_generation;
        _browsing = true;
        _currentPath = null;
        _path.Text = "";
        _folders.Children.Clear();
        _roots.Children.Clear();
        _notice.Text = "Loading folders…";
        UpdateActions();
        try
        {
            var protocol = await RemoteFeatureGate.PeerProtocolAsync(peer);
            if (protocol.HasValue && protocol.Value < RemoteFeatureGate.FolderPickerMinProtocol)
            {
                throw new InvalidOperationException("Update tokenstat on this computer to browse folders and clone repositories.");
            }
            if (_closed.IsCancellationRequested || generation != _generation) return;
            var listing = await RemoteWorkspaces.CallOnPeerAsync(peer, "fs.browse", new JsonObject { ["path"] = path });
            if (_closed.IsCancellationRequested || generation != _generation) return;
            _currentPath = Format.Text(listing, "path");
            _path.Text = _currentPath;
            _roots.Children.Clear();
            foreach (var root in Format.Items(listing, "roots") ?? new JsonArray())
            {
                var destination = Format.Text(root, "path");
                if (string.IsNullOrEmpty(destination)) continue;
                _roots.Children.Add(ActionIconGlyph.Button(Format.Text(root, "label", destination), ActionIcon.Reveal,
                    async (_, _) => await BrowseAsync(destination)));
            }
            _folders.Children.Clear();
            var parent = Format.Text(listing, "parent");
            if (!string.IsNullOrEmpty(parent))
            {
                _folders.Children.Add(ActionIconGlyph.Button("Up one folder", ActionIcon.Back, async (_, _) => await BrowseAsync(parent)));
            }
            var count = 0;
            foreach (var entry in Format.Items(listing, "entries") ?? new JsonArray())
            {
                var destination = Format.Text(entry, "path");
                if (Format.Text(entry, "kind") != "directory" || Format.Flag(entry, "hidden") || string.IsNullOrEmpty(destination)) continue;
                var label = Format.Text(entry, "name") + (Format.Flag(entry, "isRegistered") ? " · registered" : "");
                _folders.Children.Add(ActionIconGlyph.Button(label, ActionIcon.Reveal, async (_, _) => await BrowseAsync(destination)));
                count++;
            }
            _notice.Text = Format.Flag(listing, "truncated") ? "This folder has more entries than can be displayed."
                : count == 0 ? "No subfolders here. You can select the folder shown above." : "Select the folder shown above, or open a subfolder.";
        }
        catch (Exception ex)
        {
            if (generation == _generation) _notice.Text = FriendlyError.Display(ex.Message);
        }
        finally
        {
            if (generation == _generation)
            {
                _browsing = false;
                UpdateActions();
            }
        }
    }

    private async Task AddAsync()
    {
        var peer = Peer;
        var path = _currentPath;
        if (_working || _browsing || peer is null || string.IsNullOrEmpty(path)) return;
        _working = true;
        _notice.Text = Clone ? "Cloning on the selected computer…" : "Registering folder…";
        UpdateActions();
        try
        {
            string id;
            if (Clone)
            {
                if (_cloneSession is null)
                {
                    var request = new JsonObject { ["url"] = _url.Text.Trim(), ["parent"] = path };
                    if (!string.IsNullOrWhiteSpace(_name.Text)) request["name"] = _name.Text.Trim();
                    var session = await RemoteWorkspaces.CallOnPeerAsync(peer, "workspace.clone", request);
                    var sessionId = Format.Text(session, "id");
                    if (string.IsNullOrEmpty(sessionId)) throw new InvalidOperationException("The computer did not return a clone session. Check its folders before starting another clone.");
                    _cloneSession = sessionId;
                }
                id = await WatchCloneAsync(peer, _cloneSession);
                if (string.IsNullOrEmpty(id)) return;
            }
            else
            {
                var added = await RemoteWorkspaces.CallOnPeerAsync(peer, "workspace.add", new JsonObject { ["path"] = path });
                id = Format.Text(added, "id");
                if (string.IsNullOrEmpty(id)) throw new InvalidOperationException("The computer did not return the folder. Reload its folders before trying again.");
            }
            RemoteWorkspaces.RefreshPeer(peer);
            if (_closed.IsCancellationRequested) return;
            _added = RemoteWorkspaces.Join(peer, id);
            _dialog.Hide();
        }
        catch (OperationCanceledException) when (_closed.IsCancellationRequested) { }
        catch (Exception ex)
        {
            _notice.Text = FriendlyError.Display(ex.Message);
        }
        finally
        {
            _working = false;
            UpdateActions();
        }
    }

    private async Task<string> WatchCloneAsync(string peer, string sessionId)
    {
        var deadline = DateTime.UtcNow.AddMinutes(30);
        while (DateTime.UtcNow < deadline)
        {
            _closed.Token.ThrowIfCancellationRequested();
            try
            {
                var status = await RemoteWorkspaces.CallOnPeerAsync(peer, "workspace.cloneStatus", new JsonObject { ["sessionId"] = sessionId });
                _closed.Token.ThrowIfCancellationRequested();
                switch (Format.Text(status, "state"))
                {
                    case "done":
                        _cloneSession = null;
                        var id = Format.Text(status, "workspaceId");
                        if (string.IsNullOrEmpty(id))
                        {
                            _notice.Text = "The clone finished but its registered folder was not returned. Refresh folders on the machine.";
                        }
                        return id;
                    case "failed":
                        _cloneSession = null;
                        _notice.Text = FriendlyError.Display(Format.Text(status, "error", "The clone did not finish."));
                        return "";
                }
                _notice.Text = "Cloning on the selected computer…";
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                _notice.Text = "Waiting for the computer. " + FriendlyError.Display(ex.Message);
            }
            await Task.Delay(TimeSpan.FromSeconds(2), _closed.Token);
        }
        _notice.Text = "Stopped waiting for the clone. It may still be running on the computer. Choose Check clone to resume checking the same operation.";
        return "";
    }
}
