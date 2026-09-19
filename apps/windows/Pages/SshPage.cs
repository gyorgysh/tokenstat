// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Collections.Concurrent;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Navigation;
using Windows.System;
using Windows.UI;

namespace Tokenstat.Pages;

internal sealed class SshPage : Page, IToolbarItems
{
    private readonly StackPanel _listRoot = new() { Spacing = Theme.SpaceL };
    private readonly ScrollViewer _listView;
    private readonly Grid _sessionGrid = new();
    private readonly StackPanel _status = new() { Spacing = Theme.SpaceS };
    private readonly TextBlock _view = new()
    {
        FontFamily = Fonts.Mono,
        FontSize = 13,
        Foreground = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255)),
        TextWrapping = TextWrapping.Wrap,
        IsTextSelectionEnabled = true,
    };
    private readonly ScrollViewer _scroll = new()
    {
        Background = new SolidColorBrush(Color.FromArgb(255, 0, 0, 0)),
        Padding = new Thickness(Theme.SpaceS),
    };
    private readonly TextBox _input = new()
    {
        PlaceholderText = "Type, then Enter",
        FontFamily = Fonts.Mono,
    };
    private readonly StackPanel _suggestRoot = new() { Spacing = Theme.SpaceS };

    private string? _sessionId;
    private string? _sessionHostId;
    private long _offset;
    private CancellationTokenSource? _poll;
    private SSHSection _section;
    private bool _loading;
    private bool _reloadRequested;
    private readonly Border _stripHost = new();
    private readonly Border _bodyHost = new();

    public SshPage(SSHSection section = SSHSection.Hosts)
    {
        _section = section;
        _listView = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceM),
            Content = _listRoot,
        };
        _bodyHost.Child = _listView;

        _scroll.Content = _view;
        _sessionGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _sessionGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _sessionGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _sessionGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var sessionChrome = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Padding = new Thickness(Theme.SpaceS),
        };
        sessionChrome.Children.Add(ActionIconGlyph.Button("Close", ActionIcon.Disconnect, async (_, _) =>
        {
            await CloseSessionAsync();
            ShowList();
            await LoadAsync();
        }));
        sessionChrome.Children.Add(ActionIconGlyph.Button("Suggest", ActionIcon.Search, async (_, _) =>
        {
            await SuggestAsync();
        }));
        sessionChrome.Children.Add(_status);
        Grid.SetRow(_suggestRoot, 1);
        Grid.SetRow(_scroll, 2);
        Grid.SetRow(_input, 3);
        _sessionGrid.Children.Add(sessionChrome);
        _sessionGrid.Children.Add(_suggestRoot);
        _sessionGrid.Children.Add(_scroll);
        _sessionGrid.Children.Add(_input);
        _input.KeyDown += InputOnKeyDown;

        RefreshStrip();
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(_stripHost, 0);
        Grid.SetRow(_bodyHost, 1);
        root.Children.Add(_stripHost);
        root.Children.Add(_bodyHost);
        Content = root;
        Loaded += async (_, _) => await LoadAsync();
        Unloaded += (_, _) => _ = CloseSessionAsync();
    }

    public event Action? ToolbarChanged { add { } remove { } }

    /// <summary>Global screen: no folder to name.</summary>
    public UIElement? ToolbarScope => null;

    /// <summary>
    /// The library re-read, which stays reachable while a session runs below.
    /// A reload rebuilds the hidden list and leaves the session alone.
    /// </summary>
    public IList<UIElement> ToolbarActions()
    {
        return new List<UIElement>
        {
            Buttons.ToolbarIcon(
                ActionIcon.Refresh,
                "Reload the library",
                async (_, _) =>
                {
                    LogoRefresh.Began();
                    await LoadAsync();
                }),
        };
    }

    /// <summary>
    /// The four library sections as tabs. The strip stays up while a session
    /// runs below it, so leaving a shell for the library is one tap rather
    /// than a close. The session keeps running on the host either way.
    /// </summary>
    private void RefreshStrip()
    {
        var tabs = new List<(string Value, string Label, ActionIcon? Glyph)>();
        foreach (var section in Sections.SshRows)
        {
            tabs.Add((section.ToString(), section.Label(), null));
        }
        _stripHost.Child = TabStrip.View(
            tabs,
            _section.ToString(),
            async value =>
            {
                if (Enum.TryParse<SSHSection>(value, out var next) && next != _section)
                {
                    _section = next;
                    RefreshStrip();
                    ShowList();
                    await LoadAsync();
                }
            });
    }

    private void ShowList()
    {
        _bodyHost.Child = _listView;
    }

    private void ShowSession()
    {
        _bodyHost.Child = _sessionGrid;
    }

    private async Task LoadAsync()
    {
        if (_loading)
        {
            _reloadRequested = true;
            return;
        }
        _loading = true;
        try
        {
            do
            {
                _reloadRequested = false;
                await LoadOnceAsync();
            }
            while (_reloadRequested);
        }
        finally
        {
            _loading = false;
        }
    }

    private async Task LoadOnceAsync()
    {
        _listRoot.Children.Clear();
        _listRoot.Children.Add(new TextBlock
        {
            Text = _section.Label(),
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        var skeleton = Motion.SkeletonCard();
        _listRoot.Children.Add(skeleton);

        switch (_section)
        {
            case SSHSection.Vault:
                _listRoot.Children.Add(await SshVault.CardAsync(this, LoadAsync));
                break;
            case SSHSection.Keys:
                await LoadKeysTabAsync();
                break;
            case SSHSection.Snippets:
                await LoadSnippetsAsync();
                break;
            case SSHSection.KnownHosts:
                await LoadKnownHostsAsync();
                break;
            default:
                _listRoot.Children.Add(await SshVault.CardAsync(this, LoadAsync));
                await LoadHostsAsync();
                await LoadSessionsAsync();
                await LoadFoldersAsync();
                await LoadConfigAsync();
                break;
        }
        _listRoot.Children.Remove(skeleton);
    }

    private async Task LoadKeysTabAsync()
    {
        JsonArray? keys = null;
        try
        {
            keys = Format.Items(await AppServices.Host.CallAsync("ssh.key.list"));
        }
        catch (Exception ex)
        {
            _listRoot.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
        }
        AddVaultCard(keys);
        await LoadKeysAsync(keys);
    }

    /// <summary>
    /// Saved hosts with their connect, edit and delete actions, plus the add
    /// form entry. The Hosts tab, and the screen the sidebar group opens.
    /// </summary>
    private async Task LoadHostsAsync()
    {
        JsonNode listed;
        try
        {
            listed = await AppServices.Host.CallAsync("ssh.host.list");
        }
        catch (Exception ex)
        {
            _listRoot.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }

        var array = listed as JsonArray ?? listed["hosts"] as JsonArray;
        if (array is null || array.Count == 0)
        {
            _listRoot.Children.Add(EmptyState.View(
                "No saved hosts",
                "Add a host below, then connect with a password or a key.",
                EmptyArtKind.WorkspaceAccess));
        }
        else
        {
            var list = new StackPanel { Spacing = Theme.SpaceS };
            foreach (var host in array)
            {
                var label = Format.Text(host, "label", Format.Text(host, "hostname"));
                var username = Format.Text(host, "username");
                var hostname = Format.Text(host, "hostname");
                var port = Format.Long(host, "port");
                if (port <= 0)
                {
                    port = 22;
                }
                var keyHint = HostKeyId(host);
                var subtitle = $"{username}@{hostname}:{port}";
                if (!string.IsNullOrEmpty(keyHint))
                {
                    subtitle += " · key";
                }
                var open = new Button
                {
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                    Content = new StackPanel
                    {
                        Spacing = 2,
                        Children =
                        {
                            new TextBlock { Text = label, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
                            new TextBlock { Text = subtitle, Opacity = 0.7 },
                        },
                    },
                };
                var record = host;
                open.Click += async (_, _) => await ConnectAsync(record);
                var row = new Grid();
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                Grid.SetColumn(open, 0);
                row.Children.Add(open);
                var tools = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = Theme.SpaceS,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                tools.Children.Add(ActionIconGlyph.Button(
                    "Edit", ActionIcon.Edit, async (_, _) => await EditHostAsync(record)));
                tools.Children.Add(ActionIconGlyph.Button(
                    "Delete", ActionIcon.Delete, async (_, _) => await DeleteHostAsync(record)));
                Grid.SetColumn(tools, 1);
                row.Children.Add(tools);
                list.Children.Add(row);
            }
            _listRoot.Children.Add(Chrome.Card("Hosts", list));
        }
        _listRoot.Children.Add(ActionIconGlyph.Button(
            "Add host", ActionIcon.Create, async (_, _) => await EditHostAsync(null)));
    }

    /// <summary>
    /// The credential vault, as one card above the key list. Like the Apple
    /// vault screen it leads with what the store holds and gates use on
    /// presence: a key whose secret is not on this PC connects with a
    /// password or a pasted key, never with a displayed one.
    /// </summary>
    private void AddVaultCard(JsonArray? keys)
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Children =
            {
                ActionIconGlyph.Button("Generate", ActionIcon.Create, async (_, _) => await AddKeyAsync(generate: true)),
                ActionIconGlyph.Button("Import", ActionIcon.Upload, async (_, _) => await AddKeyAsync(generate: false)),
            },
        });
        var onThisPc = 0;
        var total = keys?.Count ?? 0;
        if (keys is not null)
        {
            foreach (var key in keys)
            {
                if (SshSecrets.Has(Format.Text(key, "secretRef")))
                {
                    onThisPc++;
                }
            }
        }
        body.Children.Add(new TextBlock
        {
            Text = keys is null
                ? "The key list is unavailable, so the vault cannot be counted."
                : total == 0
                    ? "No keys yet. Import one to stop typing passwords."
                    : $"{onThisPc} of {total} key secrets on this PC, in the Windows credential store.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.8,
        });
        if (keys is not null)
        {
            foreach (var key in keys)
            {
                var label = Format.Text(key, "label", Format.Text(key, "fingerprint", "Key"));
                var id = Format.Text(key, "id");
                var secretRef = Format.Text(key, "secretRef");
                var ready = SshSecrets.Has(secretRef);
                var row = new Grid();
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var name = new TextBlock
                {
                    Text = ready ? label : $"{label} · not on this PC",
                    TextWrapping = TextWrapping.Wrap,
                    VerticalAlignment = VerticalAlignment.Center,
                };
                Grid.SetColumn(name, 0);
                row.Children.Add(name);
                if (!string.IsNullOrEmpty(id))
                {
                    var record = key;
                    var remove = ActionIconGlyph.Button(
                        "Remove", ActionIcon.Delete, async (_, _) => await RemoveKeyAsync(record));
                    Grid.SetColumn(remove, 1);
                    row.Children.Add(remove);
                }
                body.Children.Add(row);
            }
        }
        _listRoot.Children.Add(Chrome.Card("Keys on this PC", body));
    }

    private async Task RemoveKeyAsync(JsonNode? key)
    {
        var id = Format.Text(key, "id");
        var label = Format.Text(key, "label", Format.Text(key, "fingerprint", "Key"));
        var secretRef = Format.Text(key, "secretRef");
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        var dialog = new ContentDialog
        {
            Title = "Remove key",
            Content = $"Remove {label} from this PC and the account vault, if configured? Saved hosts that use it will ask for a password or a pasted key.",
            PrimaryButtonText = "Remove",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            await SshVaultSync.WriteAsync("ssh.key.delete", new JsonObject { ["id"] = id });
        }
        catch (Exception ex)
        {
            _listRoot.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        SshSecrets.Forget(secretRef);
        await LoadAsync();
    }

    private async Task LoadKeysAsync(JsonArray? keys)
    {
        if (keys is null)
        {
            try
            {
                keys = Format.Items(await AppServices.Host.CallAsync("ssh.key.list"));
            }
            catch (Exception ex)
            {
                _listRoot.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
                return;
            }
        }

        var array = keys;
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            Children =
            {
                ActionIconGlyph.Button("Generate", ActionIcon.Create, async (_, _) => await AddKeyAsync(generate: true)),
                ActionIconGlyph.Button("Import", ActionIcon.Upload, async (_, _) => await AddKeyAsync(generate: false)),
            },
        });
        if (array is not null)
        {
            foreach (var key in array)
            {
                var label = Format.Text(key, "label", Format.Text(key, "fingerprint", "Key"));
                var algo = Format.Text(key, "algorithm");
                var ready = SshSecrets.Has(Format.Text(key, "secretRef"));
                body.Children.Add(new TextBlock
                {
                    Text = string.IsNullOrEmpty(algo) ? label : $"{label} · {algo}",
                    TextWrapping = TextWrapping.Wrap,
                });
                if (!ready)
                {
                    body.Children.Add(new TextBlock
                    {
                        Text = "Private material is not on this PC. Import the PEM to use this key here.",
                        Opacity = 0.7,
                        TextWrapping = TextWrapping.Wrap,
                    });
                }
            }
        }
        _listRoot.Children.Add(Chrome.Card("Keys", body));
    }

    private async Task AddKeyAsync(bool generate)
    {
        var labelBox = new TextBox { PlaceholderText = "Label" };
        var pemBox = new TextBox
        {
            PlaceholderText = "Paste PEM",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 140,
            MinWidth = 420,
            Visibility = generate ? Visibility.Collapsed : Visibility.Visible,
        };
        var pass = new PasswordBox { PlaceholderText = "Passphrase, if any" };
        var form = new StackPanel { Spacing = Theme.SpaceS, MinWidth = 420 };
        form.Children.Add(labelBox);
        if (!generate)
        {
            form.Children.Add(pemBox);
            form.Children.Add(pass);
        }
        var dialog = new ContentDialog
        {
            Title = generate ? "Generate a key" : "Import a key",
            Content = form,
            PrimaryButtonText = generate ? "Generate" : "Import",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        var label = labelBox.Text.Trim();
        if (label.Length == 0)
        {
            _listRoot.Children.Insert(1, Chrome.Banner(
                "A label is required.",
                Theme.Danger,
                Symbol.Important));
            return;
        }
        try
        {
            JsonNode material;
            if (generate)
            {
                material = await AppServices.Host.CallAsync("ssh.key.generate");
            }
            else
            {
                var pem = pemBox.Text.Trim();
                if (pem.Length == 0)
                {
                    _listRoot.Children.Insert(1, Chrome.Banner(
                        "Paste a PEM to import.",
                        Theme.Danger,
                        Symbol.Important));
                    return;
                }
                var inspect = new JsonObject { ["pem"] = pem };
                if (!string.IsNullOrEmpty(pass.Password))
                {
                    inspect["passphrase"] = pass.Password;
                }
                material = await AppServices.Host.CallAsync("ssh.key.inspect", inspect);
            }
            var privateKey = Format.Text(material, "privateKey");
            if (string.IsNullOrEmpty(privateKey))
            {
                _listRoot.Children.Insert(1, Chrome.Banner(
                    "The key had no private material.",
                    Theme.Danger,
                    Symbol.Important));
                return;
            }
            var id = "key_" + Guid.NewGuid().ToString("N");
            var secretRef = CredentialVault.RefFor(id);
            if (!SshSecrets.Put(secretRef, privateKey))
            {
                _listRoot.Children.Insert(1, Chrome.Banner(
                    "The key could not be stored in the Windows credential store.",
                    Theme.Danger,
                    Symbol.Important));
                return;
            }
            await SshVaultSync.WriteAsync(
                "ssh.key.save",
                new JsonObject
                {
                    ["id"] = id,
                    ["label"] = label,
                    ["algorithm"] = Format.Text(material, "algorithm", "ed25519"),
                    ["publicKey"] = Format.Text(material, "publicKey"),
                    ["fingerprint"] = Format.Text(material, "fingerprint"),
                    ["secretRef"] = secretRef,
                });
        }
        catch (Exception ex)
        {
            _listRoot.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        await LoadAsync();
    }

    private async Task ConnectAsync(JsonNode? host)
    {
        if (host is not JsonObject record)
        {
            return;
        }
        var username = Format.Text(record, "username");
        var hostname = Format.Text(record, "hostname");
        var port = Format.Long(record, "port");
        if (port <= 0)
        {
            port = 22;
        }

        var keyId = HostKeyId(record);
        JsonNode? keyRecord = null;
        var pemReady = false;
        if (!string.IsNullOrEmpty(keyId))
        {
            try
            {
                var listed = await AppServices.Host.CallAsync("ssh.key.list");
                var keys = Format.Items(listed);
                if (keys is not null)
                {
                    foreach (var key in keys)
                    {
                        if (Format.Text(key, "id") == keyId)
                        {
                            keyRecord = key;
                            pemReady = SshSecrets.Has(Format.Text(key, "secretRef"));
                            break;
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                _listRoot.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            }
        }

        var password = new PasswordBox { PlaceholderText = "Password" };
        var pemBox = new TextBox
        {
            PlaceholderText = "Paste PEM to use a key",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 100,
        };
        var passphrase = new PasswordBox { PlaceholderText = "Key passphrase, if any" };
        var form = new StackPanel { Spacing = Theme.SpaceS, MinWidth = 360 };
        form.Children.Add(new TextBlock { Text = $"{username}@{hostname}:{port}", Opacity = 0.8 });
        if (!string.IsNullOrEmpty(keyId) && !pemReady)
        {
            form.Children.Add(new TextBlock
            {
                Text = "This host uses a key. The private material is not on this PC. Connect with a password, or paste a PEM.",
                TextWrapping = TextWrapping.Wrap,
                Opacity = 0.8,
            });
        }
        if (pemReady)
        {
            form.Children.Add(new TextBlock
            {
                Text = "A key from the credential vault will be used. Leave the password blank, or fill it to use a password instead.",
                TextWrapping = TextWrapping.Wrap,
                Opacity = 0.8,
            });
        }
        form.Children.Add(password);
        if (!string.IsNullOrEmpty(keyId) || pemReady)
        {
            form.Children.Add(pemBox);
            form.Children.Add(passphrase);
        }
        var dialog = new ContentDialog
        {
            Title = "Connect",
            Content = form,
            PrimaryButtonText = "Connect",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }

        var pasted = pemBox.Text?.Trim() ?? "";
        var storedPem = pemReady ? SshSecrets.Get(Format.Text(keyRecord, "secretRef")) : null;
        var pem = pasted.Length > 0 ? pasted : (storedPem ?? "");
        var useKey = pem.Length > 0;
        if (!useKey && string.IsNullOrEmpty(password.Password))
        {
            _listRoot.Children.Insert(1, Chrome.Banner(
                "A password or a private key is required.",
                Theme.Danger,
                Symbol.Important));
            return;
        }

        JsonArray hostKeys;
        try
        {
            hostKeys = await EnsureHostKeysAsync(record, hostname, (int)port, username);
        }
        catch (Exception ex)
        {
            _listRoot.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }

        JsonObject auth;
        if (useKey)
        {
            auth = new JsonObject
            {
                ["kind"] = "privateKey",
                ["pem"] = pem,
            };
            if (!string.IsNullOrEmpty(passphrase.Password))
            {
                auth["passphrase"] = passphrase.Password;
            }
        }
        else
        {
            auth = new JsonObject
            {
                ["kind"] = "password",
                ["password"] = password.Password,
            };
        }

        JsonNode opened;
        try
        {
            opened = await AppServices.Host.CallAsync(
                "ssh.session.open",
                new JsonObject
                {
                    ["hostname"] = hostname,
                    ["port"] = port,
                    ["username"] = username,
                    ["initialDirectory"] = Format.Text(record, "initialDirectory", "~"),
                    ["hostKeys"] = hostKeys,
                    ["rows"] = 24,
                    ["cols"] = 80,
                    ["auth"] = auth,
                },
                TimeSpan.FromSeconds(30));
        }
        catch (Exception ex)
        {
            _listRoot.Children.Insert(1, Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }

        _sessionId = Format.Text(opened, "id");
        _sessionHostId = Format.Text(record, "id");
        if (string.IsNullOrEmpty(_sessionId))
        {
            _listRoot.Children.Insert(1, Chrome.Banner(
                "The host did not return a session id.",
                Theme.Danger,
                Symbol.Important));
            return;
        }
        _offset = 0;
        _view.Text = "";
        _status.Children.Clear();
        ShowSession();
        _poll?.Cancel();
        _poll = new CancellationTokenSource();
        _ = PollAsync(_poll.Token);
    }

    /// <summary>
    /// Add a host, or edit the label, address, user, and starting directory
    /// of a saved one. Keys, secrets, and fingerprints stay where they are:
    /// this form never shows private material.
    /// </summary>
    private async Task EditHostAsync(JsonNode? host)
    {
        var editing = host is JsonObject;
        var savedPort = Format.Long(host, "port");
        var labelBox = new TextBox
        {
            PlaceholderText = "Label",
            Text = Format.Text(host, "label"),
            MinWidth = 360,
        };
        var hostnameBox = new TextBox
        {
            PlaceholderText = "Hostname",
            Text = Format.Text(host, "hostname"),
            MinWidth = 360,
        };
        var portBox = new TextBox
        {
            PlaceholderText = "Port",
            Text = savedPort > 0 ? savedPort.ToString() : "22",
            MinWidth = 120,
        };
        var usernameBox = new TextBox
        {
            PlaceholderText = "Username",
            Text = Format.Text(host, "username"),
            MinWidth = 360,
        };
        var directoryBox = new TextBox
        {
            PlaceholderText = "Starting directory, for example ~",
            Text = Format.Text(host, "initialDirectory", "~"),
            MinWidth = 360,
        };
        var form = new StackPanel { Spacing = Theme.SpaceS, MinWidth = 360 };
        form.Children.Add(labelBox);
        form.Children.Add(hostnameBox);
        form.Children.Add(portBox);
        form.Children.Add(usernameBox);
        form.Children.Add(directoryBox);
        var dialog = new ContentDialog
        {
            Title = editing ? "Edit host" : "Add host",
            Content = form,
            PrimaryButtonText = editing ? "Save" : "Add",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        if (!ushort.TryParse(portBox.Text.Trim(), out var port) || port == 0)
        {
            LibraryBanner("Port must be between 1 and 65535.");
            return;
        }
        try
        {
            var payload = new JsonObject
            {
                ["label"] = labelBox.Text.Trim(),
                ["hostname"] = hostnameBox.Text.Trim(),
                ["port"] = port,
                ["username"] = usernameBox.Text.Trim(),
                ["initialDirectory"] = directoryBox.Text.Trim(),
            };
            if (host is JsonObject existing)
            {
                foreach (var (key, value) in existing)
                {
                    if (!payload.ContainsKey(key))
                    {
                        payload[key] = value?.DeepClone();
                    }
                }
            }
            await SshVaultSync.WriteAsync("ssh.host.save", payload);
        }
        catch (Exception ex)
        {
            LibraryBanner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private async Task DeleteHostAsync(JsonNode? host)
    {
        var id = Format.Text(host, "id");
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        var label = Format.Text(host, "label", Format.Text(host, "hostname", "this host"));
        var dialog = new ContentDialog
        {
            Title = "Delete host",
            Content = $"Delete {label}? Saved snippets stay.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            await SshVaultSync.WriteAsync("ssh.host.delete", new JsonObject { ["id"] = id });
        }
        catch (Exception ex)
        {
            LibraryBanner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private static string HostKeyId(JsonNode? host) =>
        Format.Text(host, "keyId", Format.Text(host, "identity", Format.Text(host, "credentialId")));

    private async Task<JsonArray> EnsureHostKeysAsync(
        JsonObject record, string hostname, int port, string username)
    {
        if (record["hostKeys"] is JsonArray existing && existing.Count > 0)
        {
            return CloneStrings(existing);
        }

        var probed = await AppServices.Host.CallAsync(
            "ssh.host.probe",
            new JsonObject
            {
                ["hostname"] = hostname,
                ["port"] = port,
                ["username"] = username,
                ["hostKeys"] = new JsonArray(),
            },
            TimeSpan.FromSeconds(20));
        var fingerprint = Format.Text(probed, "fingerprint");
        if (string.IsNullOrEmpty(fingerprint))
        {
            throw new InvalidOperationException("The server did not offer a fingerprint.");
        }

        JsonObject save;
        try
        {
            save = JsonNode.Parse(record.ToJsonString())?.AsObject() ?? new JsonObject();
        }
        catch
        {
            save = new JsonObject
            {
                ["id"] = Format.Text(record, "id"),
                ["label"] = Format.Text(record, "label", hostname),
                ["hostname"] = hostname,
                ["port"] = port,
                ["username"] = username,
            };
        }
        save["hostKeys"] = new JsonArray { JsonValue.Create(fingerprint) };
        await SshVaultSync.WriteAsync("ssh.host.save", save);
        return new JsonArray { JsonValue.Create(fingerprint) };
    }

    private static JsonArray CloneStrings(JsonArray source)
    {
        var copy = new JsonArray();
        foreach (var item in source)
        {
            if (item is JsonValue value && value.GetValueKind() == System.Text.Json.JsonValueKind.String)
            {
                copy.Add(JsonValue.Create(value.GetValue<string>()));
            }
        }
        return copy;
    }

    /// <summary>
    /// Sessions this host is still holding, so a relaunched app adopts what
    /// it left running instead of showing an empty screen over live shells.
    /// </summary>
    private async Task LoadSessionsAsync()
    {
        JsonArray? sessions;
        try
        {
            sessions = Format.Items(await AppServices.Host.CallAsync("ssh.session.list"));
        }
        catch (Exception ex)
        {
            _listRoot.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        if (sessions is null || sessions.Count == 0)
        {
            return;
        }
        var list = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var session in sessions)
        {
            if (session is null)
            {
                continue;
            }
            var id = Format.Text(session, "id");
            var label = Format.Text(session, "label", "Shell");
            var alive = Format.Flag(session, "alive");
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var name = new TextBlock
            {
                Text = alive ? label : $"{label} · closed",
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap,
            };
            Grid.SetColumn(name, 0);
            row.Children.Add(name);
            if (!string.IsNullOrEmpty(id) && alive)
            {
                var adopt = ActionIconGlyph.Button(
                    "Open", ActionIcon.Next, async (_, _) => await AdoptSessionAsync(id));
                Grid.SetColumn(adopt, 1);
                row.Children.Add(adopt);
            }
            list.Children.Add(row);
        }
        _listRoot.Children.Add(Chrome.Card(
            "Running sessions",
            list,
            "Shells this PC left open. Opening one picks up where it left off."));
    }

    private async Task AdoptSessionAsync(string id)
    {
        _sessionId = id;
        _sessionHostId = null;
        _offset = 0;
        _view.Text = "";
        _status.Children.Clear();
        _suggestRoot.Children.Clear();
        ShowSession();
        _poll?.Cancel();
        _poll = new CancellationTokenSource();
        _ = PollAsync(_poll.Token);
        await Task.CompletedTask;
    }

    /// <summary>
    /// What to offer part-way through a command: saved snippets first, then
    /// names the server itself reported. Tapping a row types its text,
    /// rubbing out the characters it stands in for first.
    /// </summary>
    private async Task SuggestAsync()
    {
        var id = _sessionId;
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        _suggestRoot.Children.Clear();
        JsonNode answer;
        try
        {
            answer = await AppServices.Host.CallAsync(
                "ssh.session.suggest",
                new JsonObject
                {
                    ["id"] = id,
                    ["fragment"] = _input.Text ?? "",
                });
        }
        catch (Exception ex)
        {
            SessionBanner(ex.Message);
            return;
        }
        var rows = answer["rows"] as JsonArray;
        if (rows is null || rows.Count == 0)
        {
            _suggestRoot.Children.Add(new TextBlock
            {
                Text = Format.Flag(answer, "pending")
                    ? "Asking the server for names. Type on and try again."
                    : "Nothing saved matches this line.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }
        var list = new StackPanel { Spacing = Theme.SpaceXs };
        foreach (var row in rows)
        {
            if (row is null)
            {
                continue;
            }
            var title = Format.Text(row, "title");
            var detail = Format.Text(row, "detail");
            var record = row;
            var pick = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Content = new StackPanel
                {
                    Spacing = 2,
                    Children =
                    {
                        new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
                        new TextBlock
                        {
                            Text = detail,
                            Opacity = 0.7,
                            TextWrapping = TextWrapping.Wrap,
                            Visibility = string.IsNullOrEmpty(detail) ? Visibility.Collapsed : Visibility.Visible,
                        },
                    },
                },
            };
            pick.Click += (_, _) => InsertSuggestion(record);
            list.Children.Add(pick);
        }
        _suggestRoot.Children.Add(Chrome.Card("Suggestions", list));
        if (Format.Flag(answer, "pending"))
        {
            _suggestRoot.Children.Add(new TextBlock
            {
                Text = "Still asking the server for names. These are the saved ones.",
                Opacity = 0.7,
            });
        }
    }

    private void InsertSuggestion(JsonNode row)
    {
        var insert = Format.Text(row, "insert");
        if (string.IsNullOrEmpty(insert))
        {
            return;
        }
        var replace = (int)Math.Min(Format.Long(row, "replace"), (_input.Text ?? "").Length);
        var fragment = _input.Text ?? "";
        _input.Text = fragment[..(fragment.Length - replace)] + insert;
        _suggestRoot.Children.Clear();
    }

    /// <summary>
    /// True when a snippet is saved against the server the open session is
    /// on. Those lead, because somebody scoped them on purpose.
    /// </summary>
    private bool IsScopedToSession(JsonNode snippet)
    {
        if (string.IsNullOrEmpty(_sessionHostId))
        {
            return false;
        }
        if (snippet["hostIds"] is JsonArray scoped)
        {
            foreach (var held in scoped)
            {
                if (held?.GetValueKind() == System.Text.Json.JsonValueKind.String
                    && held.GetValue<string>() == _sessionHostId)
                {
                    return true;
                }
            }
        }
        return false;
    }

    /// <summary>
    /// Saved commands, runnable in the open session. A value for a
    /// {{placeholder}} is asked for at run time and never stored, because
    /// the useful ones are hostnames, ticket numbers, and passwords.
    /// </summary>
    private async Task LoadSnippetsAsync()
    {
        JsonArray? snippets;
        try
        {
            snippets = Format.Items(await AppServices.Host.CallAsync("ssh.snippet.list"));
        }
        catch (Exception ex)
        {
            _listRoot.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(ActionIconGlyph.Button(
            "Add snippet", ActionIcon.Create, async (_, _) => await EditSnippetAsync(null)));
        var sessionOpen = !string.IsNullOrEmpty(_sessionId);
        var ordered = new List<(JsonNode Node, bool Scoped)>();
        if (snippets is not null)
        {
            foreach (var snippet in snippets)
            {
                if (snippet is null)
                {
                    continue;
                }
                ordered.Add((snippet, IsScopedToSession(snippet)));
            }
            // Scoped first: somebody scoped them on purpose.
            ordered.Sort((a, b) => b.Scoped.CompareTo(a.Scoped));
        }
        foreach (var (snippet, scoped) in ordered)
        {
            var title = Format.Text(snippet, "title", "Snippet");
            if (scoped)
            {
                title += " · for this server";
            }
            var command = Format.Text(snippet, "command");
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var name = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            name.Children.Add(new TextBlock
            {
                Text = title,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
            });
            name.Children.Add(new TextBlock
            {
                Text = command,
                FontFamily = Fonts.Mono,
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            Grid.SetColumn(name, 0);
            row.Children.Add(name);
            var tools = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var record = snippet;
            if (sessionOpen && !string.IsNullOrEmpty(command))
            {
                tools.Children.Add(ActionIconGlyph.Button(
                    "Run", ActionIcon.Run, async (_, _) => await SendSnippetAsync(record)));
            }
            tools.Children.Add(ActionIconGlyph.Button(
                "Edit", ActionIcon.Edit, async (_, _) => await EditSnippetAsync(record)));
            tools.Children.Add(ActionIconGlyph.Button(
                "Delete", ActionIcon.Delete, async (_, _) => await DeleteSnippetAsync(record)));
            Grid.SetColumn(tools, 1);
            row.Children.Add(tools);
            body.Children.Add(row);
        }
        if (body.Children.Count == 1)
        {
            body.Children.Add(new TextBlock
            {
                Text = "No snippets yet. Save the commands you retype.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        _listRoot.Children.Add(Chrome.Card(
            "Snippets",
            body,
            sessionOpen ? "Run types a snippet into the open session." : "Open a session to run a snippet."));
    }

    private async Task EditSnippetAsync(JsonNode? snippet)
    {
        var titleBox = new TextBox
        {
            PlaceholderText = "Title",
            Text = Format.Text(snippet, "title"),
            MinWidth = 360,
        };
        var commandBox = new TextBox
        {
            PlaceholderText = "Command, with {{placeholders}} for values asked at run time",
            Text = Format.Text(snippet, "command"),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            FontFamily = Fonts.Mono,
            MinHeight = 96,
            MinWidth = 360,
        };
        var tagsBox = new TextBox
        {
            PlaceholderText = "Tags, comma separated",
            Text = TagsText(snippet?["tags"]),
            MinWidth = 360,
        };
        var form = new StackPanel { Spacing = Theme.SpaceS, MinWidth = 360 };
        form.Children.Add(titleBox);
        form.Children.Add(commandBox);
        form.Children.Add(tagsBox);
        var dialog = new ContentDialog
        {
            Title = snippet is null ? "Add snippet" : "Edit snippet",
            Content = form,
            PrimaryButtonText = snippet is null ? "Add" : "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            var payload = new JsonObject
            {
                ["title"] = titleBox.Text.Trim(),
                ["command"] = commandBox.Text,
                ["tags"] = TagsArray(tagsBox.Text),
            };
            if (snippet is JsonObject existing)
            {
                foreach (var (key, value) in existing)
                {
                    if (!payload.ContainsKey(key))
                    {
                        payload[key] = value?.DeepClone();
                    }
                }
            }
            await SshVaultSync.WriteAsync("ssh.snippet.save", payload);
        }
        catch (Exception ex)
        {
            LibraryBanner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private async Task DeleteSnippetAsync(JsonNode? snippet)
    {
        var id = Format.Text(snippet, "id");
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        var dialog = new ContentDialog
        {
            Title = "Delete snippet",
            Content = $"Delete {Format.Text(snippet, "title", "this snippet")}?",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            await SshVaultSync.WriteAsync("ssh.snippet.delete", new JsonObject { ["id"] = id });
        }
        catch (Exception ex)
        {
            LibraryBanner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private async Task SendSnippetAsync(JsonNode snippet)
    {
        var id = _sessionId;
        if (string.IsNullOrEmpty(id))
        {
            LibraryBanner("Open a session first, then run the snippet into it.");
            return;
        }
        var command = Format.Text(snippet, "command");
        var names = Placeholders(command);
        if (names.Count > 0)
        {
            var boxes = new Dictionary<string, TextBox>();
            var form = new StackPanel { Spacing = Theme.SpaceS, MinWidth = 320 };
            foreach (var name in names)
            {
                var box = new TextBox { PlaceholderText = name, MinWidth = 320 };
                boxes[name] = box;
                form.Children.Add(box);
            }
            var dialog = new ContentDialog
            {
                Title = Format.Text(snippet, "title", "Run snippet"),
                Content = form,
                PrimaryButtonText = "Run",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
            {
                return;
            }
            foreach (var (name, box) in boxes)
            {
                command = command.Replace("{{" + name + "}}", box.Text, StringComparison.Ordinal);
            }
        }
        try
        {
            await AppServices.Host.CallAsync(
                "ssh.session.write",
                new JsonObject
                {
                    ["id"] = id,
                    ["data"] = Format.ByteArray(Encoding.UTF8.GetBytes(command + "\r\n")),
                });
        }
        catch (Exception ex)
        {
            LibraryBanner(ex.Message);
            return;
        }
        ShowSession();
    }

    private static List<string> Placeholders(string command)
    {
        var names = new List<string>();
        var at = 0;
        while (at < command.Length)
        {
            var open = command.IndexOf("{{", at, StringComparison.Ordinal);
            if (open < 0)
            {
                break;
            }
            var shut = command.IndexOf("}}", open + 2, StringComparison.Ordinal);
            if (shut < 0)
            {
                break;
            }
            var name = command[(open + 2)..shut].Trim();
            if (name.Length > 0 && !names.Contains(name, StringComparer.Ordinal))
            {
                names.Add(name);
            }
            at = shut + 2;
        }
        return names;
    }

    private static string TagsText(JsonNode? node)
    {
        if (node is not JsonArray array)
        {
            return "";
        }
        var parts = new List<string>();
        foreach (var item in array)
        {
            var text = item?.GetValueKind() == System.Text.Json.JsonValueKind.String
                ? item.GetValue<string>()
                : null;
            if (!string.IsNullOrWhiteSpace(text))
            {
                parts.Add(text.Trim());
            }
        }
        return string.Join(", ", parts);
    }

    private static JsonArray TagsArray(string raw)
    {
        var array = new JsonArray();
        foreach (var part in raw.Split(','))
        {
            var tag = part.Trim();
            if (tag.Length > 0)
            {
                array.Add(JsonValue.Create(tag));
            }
        }
        return array;
    }

    /// <summary>
    /// Folders group hosts in the library. Deleting one never deletes what
    /// is in it: children move up one level, which is recoverable, where a
    /// cascade is not.
    /// </summary>
    private async Task LoadFoldersAsync()
    {
        JsonArray? folders;
        try
        {
            folders = Format.Items(await AppServices.Host.CallAsync("ssh.folder.list"));
        }
        catch (Exception ex)
        {
            _listRoot.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(ActionIconGlyph.Button(
            "Add folder", ActionIcon.Create, async (_, _) => await AddFolderAsync()));
        if (folders is not null)
        {
            foreach (var folder in folders)
            {
                if (folder is null)
                {
                    continue;
                }
                var id = Format.Text(folder, "id");
                var row = new Grid();
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var name = new TextBlock
                {
                    Text = Format.Text(folder, "name", "Folder"),
                    VerticalAlignment = VerticalAlignment.Center,
                };
                Grid.SetColumn(name, 0);
                row.Children.Add(name);
                if (!string.IsNullOrEmpty(id))
                {
                    var remove = ActionIconGlyph.Button(
                        "Delete", ActionIcon.Delete, async (_, _) => await DeleteFolderAsync(id));
                    Grid.SetColumn(remove, 1);
                    row.Children.Add(remove);
                }
                body.Children.Add(row);
            }
        }
        _listRoot.Children.Add(Chrome.Card("Folders", body));
    }

    private async Task AddFolderAsync()
    {
        var nameBox = new TextBox { PlaceholderText = "Folder name", MinWidth = 320 };
        var dialog = new ContentDialog
        {
            Title = "Add folder",
            Content = nameBox,
            PrimaryButtonText = "Add",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            await SshVaultSync.WriteAsync(
                "ssh.folder.save",
                new JsonObject { ["name"] = nameBox.Text.Trim() });
        }
        catch (Exception ex)
        {
            LibraryBanner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private async Task DeleteFolderAsync(string id)
    {
        var dialog = new ContentDialog
        {
            Title = "Delete folder",
            Content = "Delete this folder? Hosts inside it move up one level.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Chrome.ShowDialog(this, dialog) != ContentDialogResult.Primary)
        {
            return;
        }
        try
        {
            await SshVaultSync.WriteAsync("ssh.folder.delete", new JsonObject { ["id"] = id });
        }
        catch (Exception ex)
        {
            LibraryBanner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    /// <summary>
    /// Which servers this machine has decided to trust, and how to take it
    /// back. Forgetting is what makes the next connection ask again, which
    /// is the only honest answer to a changed server key.
    /// </summary>
    private async Task LoadKnownHostsAsync()
    {
        JsonArray? rows;
        try
        {
            rows = Format.Items(await AppServices.Host.CallAsync("ssh.knownhost.list"));
        }
        catch (Exception ex)
        {
            _listRoot.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }
        if (rows is null || rows.Count == 0)
        {
            return;
        }
        var body = new StackPanel { Spacing = Theme.SpaceS };
        foreach (var row in rows)
        {
            if (row is null)
            {
                continue;
            }
            var hostId = Format.Text(row, "hostId");
            var label = Format.Text(row, "label", Format.Text(row, "hostname", "Server"));
            var prints = row["fingerprints"] as JsonArray;
            var detail = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            detail.Children.Add(new TextBlock { Text = label, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            if (prints is not null)
            {
                foreach (var print in prints)
                {
                    var text = print?.GetValueKind() == System.Text.Json.JsonValueKind.String
                        ? print.GetValue<string>()
                        : "";
                    if (!string.IsNullOrEmpty(text))
                    {
                        detail.Children.Add(new TextBlock
                        {
                            Text = text,
                            FontFamily = Fonts.Mono,
                            FontSize = 12,
                            Opacity = 0.7,
                            TextWrapping = TextWrapping.Wrap,
                        });
                    }
                }
            }
            var line = new Grid();
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(detail, 0);
            line.Children.Add(detail);
            if (!string.IsNullOrEmpty(hostId))
            {
                var forget = ActionIconGlyph.Button(
                    "Forget", ActionIcon.Delete, async (_, _) => await ForgetKnownHostAsync(hostId));
                Grid.SetColumn(forget, 1);
                line.Children.Add(forget);
            }
            body.Children.Add(line);
        }
        _listRoot.Children.Add(Chrome.Card(
            "Known servers",
            body,
            "Forgetting a server asks about its key on the next connection."));
    }

    private async Task ForgetKnownHostAsync(string hostId)
    {
        try
        {
            await AppServices.Host.CallAsync("ssh.knownhost.forget", new JsonObject { ["id"] = hostId });
        }
        catch (Exception ex)
        {
            LibraryBanner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    /// <summary>
    /// Hosts already in ~/.ssh/config, offered for import. Saved ones are
    /// skipped, so importing twice changes nothing.
    /// </summary>
    private async Task LoadConfigAsync()
    {
        JsonArray? candidates;
        try
        {
            candidates = Format.Items(await AppServices.Host.CallAsync("ssh.config.preview"), "candidates");
        }
        catch
        {
            return;
        }
        var fresh = 0;
        if (candidates is not null)
        {
            foreach (var candidate in candidates)
            {
                if (candidate is not null && !Format.Flag(candidate, "alreadySaved"))
                {
                    fresh++;
                }
            }
        }
        if (fresh == 0)
        {
            return;
        }
        var body = new StackPanel { Spacing = Theme.SpaceS };
        body.Children.Add(new TextBlock
        {
            Text = $"{fresh} host{(fresh == 1 ? "" : "s")} in the SSH config {(fresh == 1 ? "is" : "are")} not saved here yet.",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.8,
        });
        body.Children.Add(ActionIconGlyph.Button(
            "Import from SSH config", ActionIcon.Download, async (_, _) => await ImportConfigAsync()));
        _listRoot.Children.Add(Chrome.Card("SSH config", body));
    }

    private async Task ImportConfigAsync()
    {
        try
        {
            var imported = await AppServices.Host.CallAsync("ssh.config.import", new JsonObject());
            _listRoot.Children.Insert(1, Chrome.Banner(
                $"Imported {Format.Long(imported, "imported")} hosts from the SSH config.",
                Theme.Success,
                Symbol.Accept));
        }
        catch (Exception ex)
        {
            LibraryBanner(ex.Message);
            return;
        }
        await LoadAsync();
    }

    private void LibraryBanner(string text)
    {
        _listRoot.Children.Insert(1, Chrome.Banner(text, Theme.Danger, Symbol.Important));
    }

    private async Task PollAsync(CancellationToken token)
    {
        var id = _sessionId;
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        while (!token.IsCancellationRequested)
        {
            JsonNode chunk;
            try
            {
                chunk = await AppServices.Host.CallAsync(
                    "ssh.session.read",
                    new JsonObject
                    {
                        ["id"] = id,
                        ["offset"] = _offset,
                    });
            }
            catch (Exception ex)
            {
                if (!token.IsCancellationRequested)
                {
                    SessionBanner(ex.Message);
                }
                return;
            }
            if (token.IsCancellationRequested)
            {
                return;
            }
            var next = Format.Long(chunk, "nextOffset");
            if (next > _offset)
            {
                _offset = next;
            }
            var text = Encoding.UTF8.GetString(Format.Bytes(chunk["data"]));
            Append(text);
            if (Format.Flag(chunk, "closed"))
            {
                var error = Format.Text(chunk, "error");
                SessionBanner(string.IsNullOrEmpty(error) ? "The SSH session closed." : error);
                return;
            }
            try
            {
                await Task.Delay(150, token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private async void InputOnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter)
        {
            return;
        }
        e.Handled = true;
        var id = _sessionId;
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        var line = _input.Text ?? "";
        _input.Text = "";
        var payload = Encoding.UTF8.GetBytes(line + "\r\n");
        try
        {
            await AppServices.Host.CallAsync(
                "ssh.session.write",
                new JsonObject
                {
                    ["id"] = id,
                    ["data"] = Format.ByteArray(payload),
                });
        }
        catch (Exception ex)
        {
            SessionBanner(ex.Message);
        }
    }

    private async Task CloseSessionAsync()
    {
        _poll?.Cancel();
        var id = _sessionId;
        _sessionId = null;
        if (string.IsNullOrEmpty(id))
        {
            return;
        }
        try
        {
            await AppServices.Host.CallAsync("ssh.session.close", new JsonObject { ["id"] = id });
        }
        catch
        {
            // Leaving the page must not throw.
        }
    }

    private void Append(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }
        var combined = _view.Text + text;
        if (combined.Length > TerminalPage.BufferCap)
        {
            combined = combined[(combined.Length - (TerminalPage.BufferCap - 20_000))..];
        }
        _view.Text = combined;
        _scroll.UpdateLayout();
        _scroll.ChangeView(null, _scroll.ExtentHeight, null);
    }

    private void SessionBanner(string text)
    {
        _status.Children.Clear();
        _status.Children.Add(Chrome.Banner(text, Theme.Danger, Symbol.Important));
    }
}

/// <summary>
/// Private key bytes, held in memory and in the Windows credential store.
/// The host record keeps a secretRef, never PEM: "wincred:" ids live in
/// Credential Manager under tokenstat/ssh/ and survive restarts, "winmem:"
/// ids are this process only. Like the Apple vault, use is gated on the
/// secret being present, and secret material is never displayed. Removing a
/// key deletes both the host record and the stored secret.
/// </summary>
internal static class SshSecrets
{
    private static readonly ConcurrentDictionary<string, string> Store = new();

    public static bool Put(string secretRef, string pem)
    {
        if (string.IsNullOrEmpty(secretRef) || string.IsNullOrEmpty(pem))
        {
            return false;
        }
        var vaultId = CredentialVault.IdFromRef(secretRef);
        if (vaultId is not null && !CredentialVault.Save(vaultId, pem))
        {
            return false;
        }
        Store[secretRef] = pem;
        return true;
    }

    public static string? Get(string secretRef)
    {
        if (string.IsNullOrEmpty(secretRef))
        {
            return null;
        }
        if (Store.GetValueOrDefault(secretRef) is string cached)
        {
            return cached;
        }
        var vaultId = CredentialVault.IdFromRef(secretRef);
        if (vaultId is null)
        {
            return null;
        }
        var loaded = CredentialVault.Load(vaultId);
        if (loaded is not null)
        {
            Store[secretRef] = loaded;
        }
        return loaded;
    }

    public static bool Has(string secretRef)
    {
        if (string.IsNullOrEmpty(secretRef))
        {
            return false;
        }
        if (Store.ContainsKey(secretRef))
        {
            return true;
        }
        var vaultId = CredentialVault.IdFromRef(secretRef);
        return vaultId is not null && CredentialVault.Contains(vaultId);
    }

    public static void Forget(string secretRef)
    {
        if (string.IsNullOrEmpty(secretRef))
        {
            return;
        }
        Store.TryRemove(secretRef, out _);
        var vaultId = CredentialVault.IdFromRef(secretRef);
        if (vaultId is not null)
        {
            CredentialVault.Remove(vaultId);
        }
    }
}
