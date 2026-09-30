// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

using System.Text.Json.Nodes;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Host;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>
/// A short note that rides the next step. The turn keeps going.
/// Stop drops the note. A host that cannot carry one falls back to the queue.
/// </summary>
internal sealed partial class ChatPage
{
    private readonly Dictionary<string, long> _steerProtocol = [];
    private readonly HashSet<string> _steerUnsupported = [];
    private bool _deliveringSteer;
    private int _steerDeliverGeneration;
    private bool _steerProbeInFlight;
    private int _steerProbeTicket;
    private bool _steerProbedWhileBusy;
    private string? _steerError;

    private string SteerPeerKey() =>
        RemoteWorkspaces.TrySplit(_workspaceId, out var peer, out _) ? peer : "";

    private bool SteerUnsupported() => _steerUnsupported.Contains(SteerPeerKey());

    private void RememberUnsupported() => _steerUnsupported.Add(SteerPeerKey());

    private static bool IsUnknownMethod(Exception ex) =>
        ex is HostException host && host.Code == "unknown_method";

    private static bool IsStillInTurn(Exception ex) =>
        ex.Message == "This chat is still in the middle of a turn.";

    private static bool IsSteerFallback(Exception ex) => ex.Message is
        "This agent cannot take a note mid-turn." or
        "This chat is not asking before tools, so a note cannot ride the next step." or
        "This chat is not in the middle of a turn.";

    private static string PendingSteerText(JsonNode? chat) =>
        Format.Text(chat, "pendingSteer").Trim();

    private bool OpenChatIs(string chat) => IsLoaded && _openId == chat;

    /// <summary>
    /// Drop in-flight probe and delivery work for the conversation being left.
    /// A protocol number already read stays, because it belongs to the computer.
    /// </summary>
    private void AbandonSteerDelivery()
    {
        _steerDeliverGeneration++;
        _deliveringSteer = false;
        _steerProbeTicket++;
        _steerProbeInFlight = false;
        _steerProbedWhileBusy = false;
        _steerError = null;
    }

    /// <summary>
    /// The button may say "Next step" only once this computer's protocol is
    /// known to be new enough. An unknown answer queues, so a failed probe
    /// never sticks as an old host.
    /// </summary>
    private bool SteerKnownAvailable()
    {
        if (SteerUnsupported()) return false;
        if (!_steerProtocol.TryGetValue(SteerPeerKey(), out var protocol)) return false;
        if (protocol < RemoteFeatureGate.SteerMinProtocol) return false;
        if (_attachments.Count > 0) return false;
        var backend = Format.Text(_openChat, "backend");
        if (backend != "claude" && backend != "codex" && backend != "muse") return false;
        // This computer's own host has no muse hook home, so it refuses a muse note.
        if (backend == "muse") return SteerPeerKey().Length > 0;
        return Format.Text(_openChat, "autonomy", "standard") == "standard";
    }

    private void RefreshComposerHint()
    {
        if (Busy() && SteerKnownAvailable())
            _draft.PlaceholderText = "Add a note for the next step";
        else if (Busy())
            _draft.PlaceholderText = "Send after this turn";
        else
            _draft.PlaceholderText = "Ask about this folder";
    }

    private async Task<long?> ReadProtocolAsync()
    {
        var peer = SteerPeerKey();
        if (_steerProtocol.TryGetValue(peer, out var cached)) return cached;
        var read = peer.Length == 0
            ? await WorkbenchOps.ProtocolAsync()
            : await RemoteFeatureGate.PeerProtocolAsync(peer);
        if (read is not long number) return null;
        _steerProtocol[peer] = number;
        return number;
    }

    /// <summary>
    /// One probe when a chat opens, and one more while it is busy if that
    /// probe learned nothing. A poll tick must not ask again every 400ms.
    /// </summary>
    private void ProbeSteerIfNeeded(bool fromBusyLoop)
    {
        if (!IsLoaded || _openId is null || SteerUnsupported()) return;
        if (_steerProtocol.ContainsKey(SteerPeerKey())) return;
        if (_steerProbeInFlight) return;
        if (fromBusyLoop && _steerProbedWhileBusy) return;
        if (fromBusyLoop) _steerProbedWhileBusy = true;
        var ticket = ++_steerProbeTicket;
        _steerProbeInFlight = true;
        var generation = _openGeneration;
        var openId = _openId;
        _ = ProbeSteerAsync(ticket, generation, openId);
    }

    private async Task ProbeSteerAsync(int ticket, int generation, string? openId)
    {
        try
        {
            await ReadProtocolAsync();
            if (ticket != _steerProbeTicket || generation != _openGeneration || _openId != openId || !IsLoaded) return;
            if (Busy() && SteerKnownAvailable()) PaintConversation();
        }
        finally
        {
            if (ticket == _steerProbeTicket) _steerProbeInFlight = false;
        }
    }

    /// <summary>
    /// Park the draft on the running turn. True means this send is finished
    /// (parked, kept as an error, or the conversation changed). False means
    /// the existing queue should carry it.
    /// </summary>
    private async Task<bool> TryParkSteerAsync(string chat, string text, bool sendNext, string[] attachmentIds)
    {
        if (sendNext || attachmentIds.Length > 0 || text.Length == 0 || !Busy()) return false;
        if (SteerUnsupported()) return false;
        var backend = Format.Text(_openChat, "backend");
        if (backend != "claude" && backend != "codex" && backend != "muse") return false;
        if (backend != "muse" && Format.Text(_openChat, "autonomy", "standard") != "standard") return false;

        var protocol = await ReadProtocolAsync();
        if (!OpenChatIs(chat)) return true;
        if (protocol is null || protocol < RemoteFeatureGate.SteerMinProtocol) return false;

        try
        {
            await CallChatAsync("chat.steer", new JsonObject { ["id"] = chat, ["text"] = text });
            if (!OpenChatIs(chat)) return true;
            ParkLocalSteer(text);
            if (_draft.Text.Trim() == text) _draft.Text = "";
            _steerError = null;
            PaintConversation();
            StartPoll();
            return true;
        }
        catch (Exception ex)
        {
            if (!OpenChatIs(chat)) return true;
            if (IsUnknownMethod(ex))
            {
                RememberUnsupported();
                _steerError = null;
                return false;
            }
            if (IsSteerFallback(ex))
            {
                _steerError = null;
                return false;
            }
            Banner(ex.Message);
            return true;
        }
    }

    private void ApplyOpenChat(string chatId, bool wasBusy, bool transcriptChanged)
    {
        var previous = PendingSteerText(_openChat);
        _openChat = FindChat(chatId);
        _running = Format.Flag(_openChat, "running");
        _started = _events.Count > 0 || !string.IsNullOrEmpty(Format.Text(_openChat, "resumeToken"));
        if (_titleBox.FocusState == FocusState.Unfocused)
        {
            _titleBox.Text = Format.Text(_openChat, "title", "New chat");
        }
        var note = PendingSteerText(_openChat);
        if (wasBusy != Busy() || previous != note)
        {
            PaintConversation();
        }
        else if (transcriptChanged)
        {
            RebuildTranscript();
            RefreshCost();
        }
        if (!Busy()) _steerProbedWhileBusy = false;
        else ProbeSteerIfNeeded(fromBusyLoop: true);
    }

    private async Task DeliverParkedSteerAsync(string chat)
    {
        var ticket = ++_steerDeliverGeneration;
        _deliveringSteer = true;
        try
        {
            JsonNode result;
            try
            {
                result = await CallChatAsync("chat.steerDeliver", new JsonObject { ["id"] = chat });
            }
            catch (Exception ex)
            {
                if (!SteerCurrent(ticket, chat)) return;
                if (IsStillInTurn(ex))
                {
                    _steerError = null;
                    return;
                }
                if (IsUnknownMethod(ex))
                {
                    RememberUnsupported();
                    ClearLocalSteer();
                    _steerError = null;
                    _deliveringSteer = false;
                    await DrainQueueAsync(deliverNote: false);
                    if (SteerCurrent(ticket, chat)) PaintConversation();
                    return;
                }
                var previousNote = PendingSteerText(_openChat);
                var previousBusy = Busy();
                BannerSteer(ex.Message);
                await ReloadOpenChatAsync(chat);
                if (!SteerCurrent(ticket, chat)) return;
                PaintIfSteerChromeChanged(previousNote, previousBusy);
                return;
            }

            if (!SteerCurrent(ticket, chat)) return;
            _steerError = null;
            if (Format.Flag(result, "delivered"))
            {
                if (result["conversation"] is JsonObject conversation)
                    ApplyDeliveredConversation(conversation);
                else
                    ClearLocalSteer();
                PaintConversation();
                return;
            }

            var reloaded = await ReloadOpenChatAsync(chat);
            if (!SteerCurrent(ticket, chat)) return;
            if (!reloaded) ClearLocalSteer();
            _deliveringSteer = false;
            await DrainQueueAsync(deliverNote: false);
            if (SteerCurrent(ticket, chat)) PaintConversation();
        }
        finally
        {
            if (ticket == _steerDeliverGeneration) _deliveringSteer = false;
        }
    }

    private bool SteerCurrent(int ticket, string chat) =>
        ticket == _steerDeliverGeneration && OpenChatIs(chat);

    private async Task<bool> ReloadOpenChatAsync(string chat)
    {
        try
        {
            await RefreshCatalogAsync(refreshMenus: false);
        }
        catch
        {
            return false;
        }
        if (!OpenChatIs(chat)) return false;
        JsonNode? row = null;
        foreach (var item in _chats)
        {
            if (Format.Text(item, "id") == chat)
            {
                row = item;
                break;
            }
        }
        if (row is null) return false;
        _openChat = row;
        _running = Format.Flag(row, "running");
        return true;
    }

    private void ApplyDeliveredConversation(JsonNode conversation)
    {
        if (conversation.DeepClone() is not JsonObject copy) return;
        var id = Format.Text(copy, "id");
        _openChat = copy;
        _running = Format.Flag(copy, "running");
        _started = true;
        for (var i = 0; i < _chats.Count; i++)
        {
            if (Format.Text(_chats[i], "id") != id) continue;
            _chats[i] = copy;
            return;
        }
        if (copy.Parent is null) _chats.Add(copy);
    }

    private void PaintIfSteerChromeChanged(string previousNote, bool previousBusy)
    {
        if (PendingSteerText(_openChat) != previousNote || Busy() != previousBusy)
            PaintConversation();
    }

    private async Task ClearSteerAsync()
    {
        if (_openId is not string chat) return;
        ClearLocalSteer();
        PaintConversation();
        try
        {
            await CallChatAsync("chat.steerClear", new JsonObject { ["id"] = chat });
            if (!OpenChatIs(chat)) return;
            _steerError = null;
        }
        catch (Exception ex)
        {
            if (!OpenChatIs(chat)) return;
            if (IsUnknownMethod(ex))
            {
                RememberUnsupported();
                _steerError = null;
                return;
            }
            if (_steerError != ex.Message)
            {
                _steerError = ex.Message;
                Banner(ex.Message);
            }
        }
    }

    private void BannerSteer(string text)
    {
        if (_steerError == text) return;
        _steerError = text;
        Banner(text);
    }

    private void ParkLocalSteer(string text)
    {
        WriteSteer(_openChat, text);
        var id = Format.Text(_openChat, "id");
        foreach (var row in _chats)
        {
            if (ReferenceEquals(row, _openChat)) continue;
            if (Format.Text(row, "id") == id) WriteSteer(row, text);
        }
    }

    private void ClearLocalSteer() => ParkLocalSteer("");

    private static void WriteSteer(JsonNode? node, string text)
    {
        if (node is not JsonObject obj) return;
        if (string.IsNullOrWhiteSpace(text))
        {
            if (obj.ContainsKey("pendingSteer")) obj.Remove("pendingSteer");
            return;
        }
        var trimmed = text.Trim();
        if (Format.Text(obj, "pendingSteer") == trimmed) return;
        obj["pendingSteer"] = trimmed;
    }

    private UIElement SteerNoteBanner(string note)
    {
        var title = new TextBlock
        {
            Text = "On the next step",
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            Foreground = Theme.AccentBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var remove = ActionIconGlyph.Button("Remove", ActionIcon.Delete, async (_, _) => await ClearSteerAsync());
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(remove, "Remove this note");
        ToolTipService.SetToolTip(remove, "Remove this note");
        var header = new Grid { ColumnSpacing = Theme.SpaceS };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(title);
        Grid.SetColumn(remove, 1);
        header.Children.Add(remove);
        var body = new TextBlock
        {
            Text = note,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 3,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var stack = new StackPanel { Spacing = Theme.SpaceXs };
        stack.Children.Add(header);
        stack.Children.Add(body);
        var stroke = Theme.Brush(static () => Theme.Accent);
        stroke.Opacity = 0.35;
        var border = new Border
        {
            Background = Theme.AccentSoftBrush,
            BorderBrush = stroke,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(Theme.SpaceS),
            Child = stack,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(border, "On the next step. " + note);
        return border;
    }
}
