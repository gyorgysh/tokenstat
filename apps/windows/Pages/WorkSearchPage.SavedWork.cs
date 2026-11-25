// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal sealed partial class WorkSearchPage
{
    private async Task SearchSavedWorkAsync(string query, int offset, CancellationToken token)
    {
        var generation = AppServices.AccountGeneration;
        bool Current() => !token.IsCancellationRequested && generation == AppServices.AccountGeneration && IsLoaded;
        _cursor = null;
        if (offset == 0)
        {
            _results.Children.Clear();
            _hitCount = 0;
            _unreadable = 0;
            _lastQuery = query;
        }
        _busy.IsActive = true;
        _busy.Visibility = Visibility.Visible;
        try
        {
            var store = await SavedWork.OpenAsync();
            var list = (await store.ListAsync()).OfType<JsonObject>()
                .Where(record => Format.Text(record, "kind") == "conversation").ToArray();
            if (!Current()) return;
            var terms = query.Split((char[]?)null, StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
            var next = offset;
            var limit = Math.Min(list.Length, offset + 40);
            while (next < limit)
            {
                var id = Format.Text(list[next++], "id");
                if (id.Length == 0) continue;
                JsonNode? saved;
                try { saved = await store.ReadAsync(id); }
                catch when (Current()) { _unreadable++; continue; }
                if (!Current()) return;
                if (saved is null) { _unreadable++; continue; }
                var title = Format.Text(saved, "title");
                var transcript = Format.Text(saved, "text");
                if (!terms.All(term => title.Contains(term, StringComparison.CurrentCultureIgnoreCase)
                    || transcript.Contains(term, StringComparison.CurrentCultureIgnoreCase))) continue;
                var hit = terms.Length == 0 ? 0 : Math.Max(0, transcript.IndexOf(terms[0], StringComparison.CurrentCultureIgnoreCase) - 28);
                if (hit > 0 && char.IsLowSurrogate(transcript[hit])) hit--;
                var end = Math.Min(transcript.Length, hit + 160);
                if (end < transcript.Length && char.IsLowSurrogate(transcript[end])) end--;
                var excerpt = transcript[hit..end].Replace('\n', ' ');
                if (hit > 0) excerpt = "…" + excerpt;
                if (end < transcript.Length) excerpt += "…";
                var action = ActionIconGlyph.Button(title, ActionIcon.Comment,
                    async (_, _) => await ReadSavedWorkAsync(store, id, Current));
                var body = new StackPanel { Spacing = Theme.SpaceS };
                body.Children.Add(action);
                body.Children.Add(new TextBlock { Text = excerpt, TextWrapping = TextWrapping.Wrap, Opacity = 0.75 });
                _results.Children.Add(Chrome.Card(L10n.Text("windows.savedwork.conversation"), body));
                _hitCount++;
            }
            if (!Current()) return;
            if (next < list.Length)
            {
                var more = ActionIconGlyph.Button(L10n.Text("windows.savedwork.search_more"), ActionIcon.More, (_, _) => { });
                more.Click += async (_, _) =>
                {
                    if (!Current() || !_results.Children.Remove(more)) return;
                    await SearchSavedWorkAsync(query, next, token);
                };
                _results.Children.Add(more);
            }
            else if (_hitCount == 0)
            {
                _results.Children.Add(Chrome.Empty(L10n.Text("windows.savedwork.none"),
                    L10n.Text("windows.savedwork.empty_help"), ActionIcon.Save));
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            if (Current()) _results.Children.Add(Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important));
        }
        finally
        {
            if (Current())
            {
                _busy.IsActive = false;
                _busy.Visibility = Visibility.Collapsed;
                RenderInspector();
            }
        }
    }

    private async Task ReadSavedWorkAsync(SavedWork store, string id, Func<bool> current)
    {
        try
        {
            var saved = await store.ReadAsync(id);
            if (!current() || saved is null) return;
            var transcript = new TextBox { Text = Format.Text(saved, "text"), IsReadOnly = true, AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap, MaxHeight = 500, MinHeight = 140 };
            var panel = new StackPanel { Spacing = Theme.SpaceS };
            if (Format.Flag(saved, "partial"))
                panel.Children.Add(new TextBlock { Text = L10n.Text("windows.savedwork.partial"), TextWrapping = TextWrapping.Wrap });
            panel.Children.Add(transcript);
            var dialog = new ContentDialog
            {
                Title = Format.Text(saved, "title"), Content = panel, CloseButtonText = L10n.Text("common.close"),
                SecondaryButtonText = L10n.Text("windows.savedwork.remove"), DefaultButton = ContentDialogButton.Close,
            };
            void Retire() => DispatcherQueue.TryEnqueue(() => { transcript.Text = ""; dialog.Hide(); });
            void OnUnload(object sender, RoutedEventArgs args) => Retire();
            ContentDialogResult decision;
            AppServices.AccountChanged += Retire;
            Unloaded += OnUnload;
            try { decision = await Chrome.ShowDialog(this, dialog); }
            finally { AppServices.AccountChanged -= Retire; Unloaded -= OnUnload; transcript.Text = ""; }
            if (decision != ContentDialogResult.Secondary || !current()) return;
            var confirmation = new ContentDialog { Title = L10n.Text("windows.savedwork.remove"),
                Content = L10n.Text("windows.savedwork.remove_help"), PrimaryButtonText = L10n.Text("windows.savedwork.remove"),
                CloseButtonText = L10n.Text("common.cancel"), DefaultButton = ContentDialogButton.Close };
            if (await Chrome.ShowDialog(this, confirmation) != ContentDialogResult.Primary || !current()) return;
            await store.RemoveAsync(id);
            if (current()) await SearchAsync(false);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (current()) _results.Children.Insert(0, Chrome.Banner(FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important)); }
    }
}
