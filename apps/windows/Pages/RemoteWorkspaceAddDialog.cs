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
        Title = L10n.Text("windows.remoteworkspaceadddialog.on_another_machine.4b887bce"),
        PrimaryButtonText = L10n.Text("windows.remoteworkspaceadddialog.register_this_folder.e273b524"),
        CloseButtonText = L10n.Text("common.cancel"),
        IsPrimaryButtonEnabled = false,
    };
    private readonly ComboBox _machine = new() { Header = L10n.Text("windows.remoteworkspaceadddialog.computer.76ed42d2"), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox _route = new() { Header = L10n.Text("common.add"), ItemsSource = new[] { L10n.Text("windows.remoteworkspaceadddialog.an_existing_folder.d02dd1f1"), L10n.Text("windows.remoteworkspaceadddialog.clone_a_repository.749e5d4d") }, SelectedIndex = 0 };
    private readonly TextBox _url = new() { Header = L10n.Text("windows.remoteworkspaceadddialog.repository_address.790657b9"), PlaceholderText = "https://github.com/owner/project.git" };
    private readonly TextBox _name = new() { Header = L10n.Text("windows.remoteworkspaceadddialog.folder_name_optional.1c606620") };
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
            Text = L10n.Text("windows.remoteworkspaceadddialog.git_runs_on_the_selected_computer_private.9d863aab"),
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
        var retry = ActionIconGlyph.Button(L10n.Text("windows.remoteworkspaceadddialog.reload_folders.e9d554ab"), ActionIcon.Refresh, async (_, _) =>
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
        _dialog.PrimaryButtonText = _working ? (Clone ? L10n.Text("windows.remoteworkspaceadddialog.cloning.2c3cf7cb") : L10n.Text("windows.remoteworkspaceadddialog.registering.6bf4d89b"))
            : _cloneSession is not null ? L10n.Text("windows.remoteworkspaceadddialog.check_clone.8fb17b7e") : Clone ? L10n.Text("windows.remoteworkspaceadddialog.clone_here.d17ed090") : L10n.Text("windows.remoteworkspaceadddialog.register_this_folder.e273b524");
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
        _notice.Text = L10n.Text("windows.remoteworkspaceadddialog.finding_paired_computers.6b928a28");
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
            _notice.Text = _peers.Count == 0 ? L10n.Text("windows.remoteworkspaceadddialog.pair_a_computer_on_the_devices_screen_firs.2b5f4c70") : L10n.Text("windows.remoteworkspaceadddialog.choose_the_computer_that_will_hold_the_fol.8029a844");
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
        _notice.Text = L10n.Text("windows.remoteworkspaceadddialog.loading_folders.d0aa0da7");
        UpdateActions();
        try
        {
            var protocol = await RemoteFeatureGate.PeerProtocolAsync(peer);
            if (protocol.HasValue && protocol.Value < RemoteFeatureGate.FolderPickerMinProtocol)
            {
                throw new InvalidOperationException(L10n.Text("windows.remoteworkspaceadddialog.update_tokenstat_on_this_computer_to_brows.6ed19d6c"));
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
                _folders.Children.Add(ActionIconGlyph.Button(L10n.Text("windows.remoteworkspaceadddialog.up_one_folder.ef9a7ae0"), ActionIcon.Back, async (_, _) => await BrowseAsync(parent)));
            }
            var count = 0;
            foreach (var entry in Format.Items(listing, "entries") ?? new JsonArray())
            {
                var destination = Format.Text(entry, "path");
                if (Format.Text(entry, "kind") != "directory" || Format.Flag(entry, "hidden") || string.IsNullOrEmpty(destination)) continue;
                var label = Format.Text(entry, "name") + (Format.Flag(entry, "isRegistered") ? L10n.Text("windows.remoteworkspaceadddialog.registered.4e579b71") : "");
                _folders.Children.Add(ActionIconGlyph.Button(label, ActionIcon.Reveal, async (_, _) => await BrowseAsync(destination)));
                count++;
            }
            _notice.Text = Format.Flag(listing, "truncated") ? L10n.Text("windows.remoteworkspaceadddialog.this_folder_has_more_entries_than_can_be_d.73229557")
                : count == 0 ? L10n.Text("windows.remoteworkspaceadddialog.no_subfolders_here_you_can_select_the_fold.06f46554") : L10n.Text("windows.remoteworkspaceadddialog.select_the_folder_shown_above_or_open_a_su.5baa43ed");
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
        _notice.Text = Clone ? L10n.Text("windows.remoteworkspaceadddialog.cloning_on_the_selected_computer.4595f76c") : L10n.Text("windows.remoteworkspaceadddialog.registering_folder.dcacb71b");
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
                    if (string.IsNullOrEmpty(sessionId)) throw new InvalidOperationException(L10n.Text("windows.remoteworkspaceadddialog.the_computer_did_not_return_a_clone_sessio.8d908281"));
                    _cloneSession = sessionId;
                }
                id = await WatchCloneAsync(peer, _cloneSession);
                if (string.IsNullOrEmpty(id)) return;
            }
            else
            {
                var added = await RemoteWorkspaces.CallOnPeerAsync(peer, "workspace.add", new JsonObject { ["path"] = path });
                id = Format.Text(added, "id");
                if (string.IsNullOrEmpty(id)) throw new InvalidOperationException(L10n.Text("windows.remoteworkspaceadddialog.the_computer_did_not_return_the_folder_rel.f089dcc0"));
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
                            _notice.Text = L10n.Text("windows.remoteworkspaceadddialog.the_clone_finished_but_its_registered_fold.0732e241");
                        }
                        return id;
                    case "failed":
                        _cloneSession = null;
                        _notice.Text = FriendlyError.Display(Format.Text(status, "error", L10n.Text("windows.remoteworkspaceadddialog.the_clone_did_not_finish.fa812d0f")));
                        return "";
                }
                _notice.Text = L10n.Text("windows.remoteworkspaceadddialog.cloning_on_the_selected_computer.4595f76c");
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                _notice.Text = L10n.Text("windows.remoteworkspaceadddialog.waiting_for_the_computer_0.030a34a1", $"{FriendlyError.Display(ex.Message)}");
            }
            await Task.Delay(TimeSpan.FromSeconds(2), _closed.Token);
        }
        _notice.Text = L10n.Text("windows.remoteworkspaceadddialog.stopped_waiting_for_the_clone_it_may_still.a0c65769");
        return "";
    }
}
