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
using Windows.System;
using Windows.UI;

namespace Tokenstat.Pages;

internal sealed class SshPage : Page
{
    private readonly StackPanel _listRoot = new() { Spacing = Theme.SpaceL };
    private readonly ScrollViewer _listView;
    private readonly Grid _sessionGrid = new();
    private readonly StackPanel _status = new() { Spacing = Theme.SpaceS };
    private readonly TextBlock _view = new()
    {
        FontFamily = new FontFamily("Consolas"),
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
        FontFamily = new FontFamily("Consolas"),
    };

    private string? _sessionId;
    private long _offset;
    private CancellationTokenSource? _poll;

    public SshPage()
    {
        _listView = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceL),
            Content = _listRoot,
        };

        _scroll.Content = _view;
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
        sessionChrome.Children.Add(_status);
        Grid.SetRow(_scroll, 1);
        Grid.SetRow(_input, 2);
        _sessionGrid.Children.Add(sessionChrome);
        _sessionGrid.Children.Add(_scroll);
        _sessionGrid.Children.Add(_input);
        _input.KeyDown += InputOnKeyDown;

        Content = _listView;
        Loaded += async (_, _) => await LoadAsync();
        Unloaded += (_, _) => _ = CloseSessionAsync();
    }

    private void ShowList()
    {
        Content = _listView;
    }

    private void ShowSession()
    {
        Content = _sessionGrid;
    }

    private async Task LoadAsync()
    {
        _listRoot.Children.Clear();
        _listRoot.Children.Add(new TextBlock
        {
            Text = "SSH",
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        _listRoot.Children.Add(ActionIconGlyph.Button(
            "Refresh", ActionIcon.Refresh, async (_, _) => await LoadAsync()));

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
            _listRoot.Children.Add(Chrome.Empty(
                "No saved hosts",
                "Save a server on a Mac, then connect from here with a password or a key.",
                Symbol.Link));
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
                list.Children.Add(open);
            }
            _listRoot.Children.Add(Chrome.Card("Hosts", list));
        }

        await LoadKeysAsync();
    }

    private async Task LoadKeysAsync()
    {
        JsonNode listed;
        try
        {
            listed = await AppServices.Host.CallAsync("ssh.key.list");
        }
        catch (Exception ex)
        {
            _listRoot.Children.Add(Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important));
            return;
        }

        var array = Format.Items(listed);
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
            var secretRef = "winmem:" + id;
            SshSecrets.Put(secretRef, privateKey);
            await AppServices.Host.CallAsync(
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
                Text = "A key on this PC will be used. Leave the password blank, or fill it to use a password instead.",
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
        await AppServices.Host.CallAsync("ssh.host.save", save);
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
/// Private key bytes for this process only. The host list stores a secretRef,
/// not PEM, and this cut does not invent a Windows vault.
/// </summary>
internal static class SshSecrets
{
    private static readonly ConcurrentDictionary<string, string> Store = new();

    public static void Put(string secretRef, string pem)
    {
        if (!string.IsNullOrEmpty(secretRef))
        {
            Store[secretRef] = pem;
        }
    }

    public static string? Get(string secretRef) =>
        string.IsNullOrEmpty(secretRef) ? null : Store.GetValueOrDefault(secretRef);

    public static bool Has(string secretRef) =>
        !string.IsNullOrEmpty(secretRef) && Store.ContainsKey(secretRef);
}
