// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.components

import ai.tokenstat.tokenstat.ui.localization.L10n

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*

@Composable
fun NameEditorDialog(title: String, initial: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var name by remember(initial) { mutableStateOf(initial) }
    val clean = name.trim()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(name, { name = it }, singleLine = true, label = { Text(L10n.text("android.nameeditordialog.name.dcd1d522")) }) },
        confirmButton = { TextButton(enabled = clean.isNotEmpty() && clean.length <= 120 && clean.none { it.isISOControl() }, onClick = { onSave(clean) }) { Text(L10n.text("common.save")) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(L10n.text("common.cancel")) } },
    )
}
