# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from localization_rules import technical_uses


class LocalizationRulesTests(unittest.TestCase):
    def test_stable_values_cannot_come_from_a_language_catalog(self):
        sources = (
            'scope: String = L10n.text("apple.scope")',
            'addingIn = L10n.text("apple.column")',
            'Format.Number(stats, L10n.Text("windows.cpu"))',
            'Text(schedule, "kind", L10n.Text("windows.once"))',
            'AutonomyPill(L10n.Text("windows.label"), L10n.Text("windows.bypass"), current, enabled)',
            'ChatSegmented(\n options = listOf(L10n.text("android.bypass") to L10n.text("android.label")),\n selected = "bypass",\n)',
            'private readonly List<string> _sectionOrder = [L10n.Text("windows.continue"), L10n.Text("windows.activity")];',
            'if (raw.contains(L10n.text("android.error"))) {}',
            'ShowCompanion(L10n.Text("windows.browser"))',
            '_inspectorTab = L10n.Text("windows.files")',
            '_filter = L10n.Text("windows.conversations")',
            'events.ToString(L10n.Text("windows.number"))',
            'SimpleDateFormat(L10n.text("android.date"), Locale.getDefault())',
            'Arguments = L10n.Text("windows.powershell", script)',
            'Path.Combine(AppContext.BaseDirectory, L10n.Text("windows.assets"), "tokenstat.ico")',
            'Path.Combine(\n Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),\n L10n.Text("windows.programs"), "tokenstat")',
            'new FontFamily(L10n.Text("windows.icon_font"))',
            'private static readonly FontFamily IconFont = new(L10n.Text("windows.font"))',
            'public static FontFamily Mono { get; } = new(L10n.Text("windows.font_uri"))',
            'new Uri(L10n.Text("windows.asset_uri"))',
            'new[] { L10n.Text("windows.exe"), ".cmd" }.Any(extension => command.EndsWith(extension, StringComparison.OrdinalIgnoreCase))',
            'args.Request.Headers.GetHeader(L10n.Text("windows.header"))',
            'core.Environment.CreateWebResourceResponse(null, 403, L10n.Text("windows.reason"), "Content-Length: 0")',
        )
        for source in sources:
            with self.subTest(source=source):
                self.assertTrue(list(technical_uses(source)))

    def test_display_labels_remain_translatable(self):
        source = '''
            Text(L10n.text("apple.title"))
            Format.Text(stats, "label", L10n.Text("windows.fallback"))
            Format.Text(item, "id", L10n.Text("windows.fallback"))
            Format.Text(chat, "backend", L10n.Text("windows.agent"))
            AutonomyPill(L10n.Text("windows.label"), "bypass", current, enabled)
            ChatSegmented(
                options = listOf("bypass" to L10n.text("android.label")),
                selected = "bypass",
            )
            val features = listOf(L10n.text("android.feature") to listOf("1 GiB"))
            var asset = Path.Combine(AppContext.BaseDirectory, "Assets");
            Text = L10n.Text("windows.status", Path.GetFileName(asset));
            var matches = new[] { L10n.Text("windows.choice") }.Any(choice => choice.Length > 0);
            if (!File.Exists(Path.Combine(root, "Tokenstat.exe")))
                throw new Failure(L10n.Text("windows.missing_download"));
            Path.Combine(root, "paren)in-name", @"quote""in-name");
            Text = L10n.Text("windows.after_path");
        '''
        self.assertEqual(list(technical_uses(source)), [])

    def test_reports_the_value_instead_of_the_label(self):
        source = 'AutonomyPill(L10n.Text("windows.label"), L10n.Text("windows.value"), current, enabled)'
        self.assertEqual([key for _, key in technical_uses(source)], ["windows.value"])


if __name__ == "__main__":
    unittest.main()
