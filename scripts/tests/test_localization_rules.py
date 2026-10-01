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
        '''
        self.assertEqual(list(technical_uses(source)), [])

    def test_reports_the_value_instead_of_the_label(self):
        source = 'AutonomyPill(L10n.Text("windows.label"), L10n.Text("windows.value"), current, enabled)'
        self.assertEqual([key for _, key in technical_uses(source)], ["windows.value"])


if __name__ == "__main__":
    unittest.main()
