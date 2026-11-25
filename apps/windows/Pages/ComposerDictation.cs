// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Speech.Recognition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;

namespace Tokenstat.Pages;

internal static class ComposerDictation
{
    public static Button Button(TextBox draft, Func<bool> current) => Buttons.ToolbarIcon(
        ActionIcon.Dictate, L10n.Text("windows.dictation.title"), async (_, _) => await DictateAsync(draft, current));

    public static async Task DictateAsync(TextBox draft, Func<bool> current)
    {
        if (!current() || !draft.IsEnabled || draft.IsReadOnly) return;
        var original = draft.Text;
        var start = draft.SelectionStart;
        var length = draft.SelectionLength;
        var privacy = new TextBlock { Text = L10n.Text("windows.dictation.privacy"), TextWrapping = TextWrapping.Wrap };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var preview = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            MinHeight = 72, MaxHeight = 160, Header = L10n.Text("windows.dictation.preview") };
        var listen = ActionIconGlyph.Button(L10n.Text("windows.dictation.start"), ActionIcon.Dictate, (_, _) => { });
        var stop = ActionIconGlyph.Button(L10n.Text("common.stop"), ActionIcon.Stop, (_, _) => { });
        stop.IsEnabled = false;
        var controls = new FlowPanel { Spacing = Theme.SpaceS };
        controls.Children.Add(listen);
        controls.Children.Add(stop);
        var panel = new StackPanel { Spacing = Theme.SpaceS };
        panel.Children.Add(privacy);
        panel.Children.Add(controls);
        panel.Children.Add(status);
        panel.Children.Add(preview);
        var dialog = new ContentDialog { Title = L10n.Text("windows.dictation.title"), Content = panel,
            PrimaryButtonText = L10n.Text("windows.dictation.insert"), IsPrimaryButtonEnabled = false,
            CloseButtonText = L10n.Text("common.cancel") };

        SpeechRecognitionEngine? engine = null;
        var watchdog = draft.DispatcherQueue.CreateTimer();
        watchdog.Interval = TimeSpan.FromMilliseconds(250);
        DateTimeOffset deadline = default;
        void Release()
        {
            watchdog.Stop();
            var previous = engine;
            engine = null;
            if (previous is null) return;
            try { previous.Dispose(); }
            catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"Dictation shutdown: {ex.Message}"); }
        }

        void Stop()
        {
            var running = engine;
            if (running is null || !stop.IsEnabled) return;
            stop.IsEnabled = false;
            deadline = DateTimeOffset.UtcNow.AddSeconds(5);
            status.Text = L10n.Text("windows.dictation.finishing");
            try { running.RecognizeAsyncStop(); }
            catch
            {
                Release();
                listen.IsEnabled = true;
                dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(preview.Text);
                status.Text = L10n.Text("windows.dictation.unavailable");
            }
        }

        watchdog.Tick += (_, _) =>
        {
            if (!current() || draft.Text != original) { Release(); dialog.Hide(); }
            else if (DateTimeOffset.UtcNow >= deadline)
            {
                if (stop.IsEnabled) Stop();
                else
                {
                    Release();
                    listen.IsEnabled = true;
                    dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(preview.Text);
                    status.Text = L10n.Text("windows.dictation.unavailable");
                }
            }
        };
        stop.Click += (_, _) => Stop();
        listen.Click += (_, _) =>
        {
            if (engine is not null || !current()) return;
            try
            {
                var running = engine = new SpeechRecognitionEngine();
                running.LoadGrammar(new DictationGrammar());
                running.SetInputToDefaultAudioDevice();
                running.SpeechRecognized += (_, args) =>
                {
                    var phrase = args.Result.Text.Trim();
                    if (phrase.Length == 0) return;
                    draft.DispatcherQueue.TryEnqueue(() =>
                    {
                        if (!ReferenceEquals(engine, running) || !current()) return;
                        preview.Text = preview.Text.Length == 0 ? phrase : preview.Text + " " + phrase;
                    });
                };
                running.RecognizeCompleted += (_, args) => draft.DispatcherQueue.TryEnqueue(() =>
                {
                    if (!ReferenceEquals(engine, running)) return;
                    Release();
                    listen.IsEnabled = true;
                    stop.IsEnabled = false;
                    dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(preview.Text);
                    status.Text = args.Error is not null ? L10n.Text("windows.dictation.unavailable")
                        : dialog.IsPrimaryButtonEnabled ? "" : L10n.Text("windows.dictation.no_text");
                });
                running.RecognizeAsync(RecognizeMode.Multiple);
                listen.IsEnabled = dialog.IsPrimaryButtonEnabled = false;
                stop.IsEnabled = true;
                status.Text = L10n.Text("windows.dictation.listening");
                deadline = DateTimeOffset.UtcNow.AddMinutes(2);
                watchdog.Start();
            }
            catch
            {
                Release();
                status.Text = L10n.Text("windows.dictation.unavailable");
            }
        };

        draft.Unloaded += Retire;
        void Retire(object sender, RoutedEventArgs args) { Release(); dialog.Hide(); }
        try
        {
            if (await Chrome.ShowDialog(draft, dialog) != ContentDialogResult.Primary || !current() || draft.Text != original) return;
            var phrase = preview.Text.Trim();
            if (phrase.Length == 0) return;
            var before = original[..start];
            var after = original[(start + length)..];
            if (before.Length > 0 && !char.IsWhiteSpace(before[^1])) phrase = " " + phrase;
            if (after.Length > 0 && !char.IsWhiteSpace(after[0]) && !char.IsPunctuation(after[0])) phrase += " ";
            draft.Text = before + phrase + after;
            draft.Select(before.Length + phrase.Length, 0);
            draft.Focus(FocusState.Programmatic);
        }
        finally
        {
            draft.Unloaded -= Retire;
            Release();
        }
    }
}
