// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Host;

namespace Tokenstat.Pages;
internal sealed partial class ChatPage
{
    private UIElement RoutingControls()
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        if (_openId is not string chat) return body;
        var generation = _openGeneration;
        var snapshot = _openChat;
        bool Current() => OpenChatIs(chat) && generation == _openGeneration;
        async Task ApplyAsync(string method, JsonObject extra)
        {
            try
            {
                if (!Current() || snapshot?["sendRevision"] is null) return;
                var request = new JsonObject { ["id"] = chat, ["expectedRevision"] = Format.Long(snapshot, "sendRevision") };
                foreach (var item in extra) request[item.Key] = item.Value?.DeepClone();
                await CallChatAsync(method, request);
                if (!Current()) return;
                await RefreshCatalogAsync();
                if (Current()) { _openChat = FindChat(chat); PaintConversation(); StartPoll(); }
            }
            catch (Exception ex) { if (Current()) Banner(ex.Message); }
        }
        if (snapshot?["routing"] is JsonObject state && state["limit"] is JsonObject limit)
        {
            body.Children.Add(new TextBlock { Text = (Format.Text(limit,"kind") == "usage" ? L10n.Text("common.chat_limit_reached", Format.Text(limit,"provider")) : L10n.Text("common.chat_throttled", Format.Text(limit,"provider"))), TextWrapping=TextWrapping.Wrap, FontWeight=Microsoft.UI.Text.FontWeights.SemiBold });
            var reset = limit["resetsAtMs"] is null ? (long?)null : Format.Long(limit,"resetsAtMs");
            body.Children.Add(Muted(reset.HasValue ? L10n.Text("common.chat_resets_at", DateTimeOffset.FromUnixTimeMilliseconds(reset.Value).LocalDateTime.ToString("g")) : L10n.Text("common.chat_reset_unknown")));
            if (Format.Flag(state,"needsDeliveryCheck")) body.Children.Add(Muted(L10n.Text("common.chat_route_delivery")));
            if (Format.Text(state,"note") is string note && note.Length > 0) body.Children.Add(Muted(note));
            var policy = state["policy"] as JsonObject;
            var wait = new CheckBox { Content = L10n.Text("common.chat_wait_reset"), IsChecked = Format.Flag(policy,"waitForReset"), IsEnabled=reset.HasValue && !Format.Flag(state,"needsDeliveryCheck") };
            wait.Click += async (_,_) => { var changed=(JsonObject?)policy?.DeepClone() ?? new JsonObject(); changed["waitForReset"]=wait.IsChecked==true; await ApplyAsync("chat.routing",new JsonObject{["routing"]=changed}); };
            body.Children.Add(wait);
            var actions = new FlowPanel { Spacing=Theme.SpaceS };
            var retry = ActionIconGlyph.Button(L10n.Text("common.chat_route_retry"), ActionIcon.Refresh, async (_,_) => await ApplyAsync("chat.routeAction",new JsonObject{["choice"]="resume"}));
            retry.IsEnabled=!Format.Flag(snapshot,"running") && !Format.Flag(state,"needsDeliveryCheck");
            actions.Children.Add(retry);
            actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.cancel"),ActionIcon.Stop,async (_,_)=>await ApplyAsync("chat.routeAction",new JsonObject{["choice"]="cancel"})));
            body.Children.Add(actions);
        }
        body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.chat_routing"),ActionIcon.Settings,async (_,_)=>await ShowRoutingAsync()));
        return body;
    }

    private async Task ShowRoutingAsync()
    {
        if (_openId is not string chat) return;
        var generation=_openGeneration;
        bool Current()=>OpenChatIs(chat)&&generation==_openGeneration;
        try
        {
            var protocol=RemoteFeatureGate.ProtocolOf(await CallChatAsync("protocol",new JsonObject()));
            if (!Current()) return;
            if (protocol<34) { Banner(L10n.Text("common.chat_route_unavailable")); return; }
            var state=await CallChatAsync("chat.routing",new JsonObject{["id"]=chat});
            if (!Current()) return;
            var revision=_openChat?["sendRevision"]?.DeepClone();
            var policy=(JsonObject?)state["policy"]?.DeepClone() ?? new JsonObject();
            var routes=(policy["routes"] as JsonArray)?.Select(r=>(JsonObject)r!.DeepClone()).ToList() ?? [];
            var enabled=new CheckBox{Content=L10n.Text("common.chat_routing_enabled"),IsChecked=Format.Flag(policy,"enabled")};
            var wait=new CheckBox{Content=L10n.Text("common.chat_wait_reset"),IsChecked=Format.Flag(policy,"waitForReset")};
            var returns=new CheckBox{Content=L10n.Text("common.chat_return_preferred"),IsChecked=Format.Flag(policy,"returnPreferred")};
            var defaults=new CheckBox{Content=L10n.Text("common.chat_route_default"),IsChecked=Format.Flag(policy,"useAsDefault")};
            var body=new StackPanel{Spacing=Theme.SpaceM,MaxWidth=560};
            body.Children.Add(Muted(L10n.Text("common.chat_route_explanation")));
            body.Children.Add(enabled);body.Children.Add(wait);body.Children.Add(returns);body.Children.Add(defaults);
            body.Children.Add(Chrome.SectionLabel(L10n.Text("common.chat_route_order")));
            var rows=new StackPanel{Spacing=Theme.SpaceS}; body.Children.Add(rows);
            void PaintRoutes()
            {
                rows.Children.Clear();
                for(var i=0;i<routes.Count;i++)
                {
                    var index=i;var route=routes[i];
                    var row=new StackPanel{Spacing=Theme.SpaceS};
                    row.Children.Add(Muted($"{index+1}. {Format.Text(route,"backend")}"));
                    var models=new ComboBox{HorizontalAlignment=HorizontalAlignment.Stretch};
                    var choices=new List<string>{""};
                    if(Backend(Format.Text(route,"backend"))?["models"] is JsonArray list) choices.AddRange(list.Select(m=>m?.GetValue<string>() ?? "").Where(m=>m.Length>0));
                    var selected=Format.Text(route,"model"); if(!choices.Contains(selected))choices.Add(selected);
                    foreach(var model in choices) models.Items.Add(new ComboBoxItem{Content=model.Length==0?L10n.Text("windows.chatpage.default.21b111cb"):model,Tag=model});
                    models.SelectedIndex=choices.IndexOf(selected);
                    models.SelectionChanged+=(_,_)=>{if(models.SelectedItem is ComboBoxItem choice)route["model"]=(string?)choice.Tag;};
                    row.Children.Add(models);
                    var actions=new FlowPanel{Spacing=Theme.SpaceS};
                    var up=ActionIconGlyph.Button(L10n.Text("common.move_up"),ActionIcon.Move,(_,_)=>{(routes[index-1],routes[index])=(routes[index],routes[index-1]);PaintRoutes();});up.IsEnabled=index>0;actions.Children.Add(up);
                    actions.Children.Add(ActionIconGlyph.Button(L10n.Text("common.remove"),ActionIcon.Delete,(_,_)=>{routes.RemoveAt(index);PaintRoutes();}));
                    row.Children.Add(actions);rows.Children.Add(row);
                }
            }
            PaintRoutes();
            var add=new ComboBox{HorizontalAlignment=HorizontalAlignment.Stretch};
            foreach(var backend in _backends.Where(b=>Format.Text(b,"id")!="sh" && Installed(b)))add.Items.Add(new ComboBoxItem{Content=Format.Text(backend,"label"),Tag=Format.Text(backend,"id")});
            body.Children.Add(add);
            body.Children.Add(ActionIconGlyph.Button(L10n.Text("common.add"),ActionIcon.Create,(_,_)=>{if(add.SelectedItem is ComboBoxItem picked && routes.Count<8){routes.Add(new JsonObject{["backend"]=(string?)picked.Tag});PaintRoutes();}}));
            var dialog=new ContentDialog{Title=L10n.Text("common.chat_routing"),Content=new ScrollViewer{Content=body,MaxHeight=500},PrimaryButtonText=L10n.Text("common.save"),CloseButtonText=L10n.Text("common.cancel")};
            if(await Chrome.ShowDialog(this,dialog)!=ContentDialogResult.Primary || !Current() || revision is null)return;
            policy["enabled"]=enabled.IsChecked==true;policy["waitForReset"]=wait.IsChecked==true;policy["returnPreferred"]=returns.IsChecked==true;policy["useAsDefault"]=defaults.IsChecked==true;
            policy["routes"]=new JsonArray(routes.Select(r=>(JsonNode)r.DeepClone()).ToArray());
            await CallChatAsync("chat.routing",new JsonObject{["id"]=chat,["expectedRevision"]=revision,["routing"]=policy});
            if(!Current())return;
            await RefreshCatalogAsync();if(Current()){_openChat=FindChat(chat);PaintConversation();StartPoll();}
        }
        catch(Exception ex){if(Current())Banner(ex.Message);}
    }
}
