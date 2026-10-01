// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.ui.localization.L10n

import android.content.Context
import android.util.Base64
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import ai.tokenstat.tokenstat.ui.components.ActionIcon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import ai.tokenstat.tokenstat.AppViewModel
import ai.tokenstat.tokenstat.ui.components.TsAccentButton
import ai.tokenstat.tokenstat.ui.components.TsSecondaryButton
import ai.tokenstat.tokenstat.ui.theme.LocalTsColors
import ai.tokenstat.tokenstat.ui.theme.Space
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

fun JsonObject.sshString(key: String): String? =
    this[key]?.takeUnless { it is kotlinx.serialization.json.JsonNull }?.jsonPrimitive?.contentOrNull

/// Password or stored-key connect from a host row, then hand the session id up.
@Composable
fun SshConnectDialog(
    model: AppViewModel,
    host: JsonObject,
    keys: JsonArray,
    onDismiss: () -> Unit,
    onOpened: (String) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    var password by remember { mutableStateOf("") }
    var passphrase by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val hostname = host.sshString("hostname").orEmpty()
    val username = host.sshString("username") ?: "root"
    val port = host["port"]?.jsonPrimitive?.content?.toIntOrNull() ?: 22
    val hostKeys = (host["hostKeys"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty()
    val savedKeys = remember(keys) { keys.filterIsInstance<JsonObject>() }
    // The host's own choice first, like the iOS connect form. A key that is
    // no longer in the library selects nothing rather than a missing id.
    val storedRef = host.sshString("credentialId") ?: host.sshString("keyId") ?: host.sshString("identity")
    var selectedKeyId by remember(host) {
        mutableStateOf(storedRef?.takeIf { ref -> savedKeys.any { it.sshString("id") == ref } } ?: "")
    }
    var authOpen by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(L10n.text("android.sshconnect.connect_to_0_1.938a75db", "${username}", "${hostname}")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text("$hostname:$port", color = colors.textSecondary)
                // "Use": the password, or one of the saved keys. Passwords
                // are used for this connection and are never saved.
                Box {
                    OutlinedTextField(
                        value = if (selectedKeyId.isEmpty()) L10n.text("android.sshconnect.password.e7cf3ef4")
                        else savedKeys.find { it.sshString("id") == selectedKeyId }?.sshString("label") ?: L10n.text("android.sshconnect.password.e7cf3ef4"),
                        onValueChange = {},
                        readOnly = true,
                        label = { Text(L10n.text("android.sshconnect.use.c36d819e")) },
                        trailingIcon = {
                            IconButton(onClick = { authOpen = true }) {
                                Icon(ActionIcon.More.vector, L10n.text("android.sshconnect.choose_authentication.97790843"))
                            }
                        },
                        modifier = Modifier.fillMaxWidth().clickable { authOpen = true },
                        singleLine = true,
                    )
                    DropdownMenu(expanded = authOpen, onDismissRequest = { authOpen = false }) {
                        DropdownMenuItem(
                            text = { Text(L10n.text("android.sshconnect.password.e7cf3ef4")) },
                            onClick = { selectedKeyId = ""; authOpen = false },
                        )
                        savedKeys.forEach { key ->
                            val label = key.sshString("label") ?: L10n.text("android.sshconnect.key.99a52df3")
                            DropdownMenuItem(
                                text = { Text(label) },
                                onClick = { selectedKeyId = key.sshString("id") ?: ""; authOpen = false },
                            )
                        }
                    }
                }
                if (selectedKeyId.isEmpty()) {
                    OutlinedTextField(
                        password,
                        { password = it },
                        label = { Text(L10n.text("android.sshconnect.password.e7cf3ef4")) },
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                    )
                } else {
                    OutlinedTextField(
                        passphrase,
                        { passphrase = it },
                        label = { Text(L10n.text("android.sshconnect.key_passphrase_if_any.09728ced")) },
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                    )
                }
                Text(
                    L10n.text("android.sshconnect.passwords_are_used_for_this_connection_and.47e746d5"),
                    style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                    color = colors.textSecondary,
                )
                error?.let { Text(it, color = colors.danger) }
            }
        },
        confirmButton = {
            TsAccentButton(
                label = if (busy) L10n.text("android.sshconnect.connecting.72021eb7") else L10n.text("common.connect"),
                enabled = !busy,
                onClick = {
                    scope.launch {
                        busy = true
                        error = null
                        runCatching {
                            var keysForOpen = hostKeys
                            if (keysForOpen.isEmpty()) {
                                val probe = model.core(
                                    "ssh.host.probe",
                                    buildJsonObject {
                                        put("hostname", hostname)
                                        put("port", port)
                                        put("username", username)
                                        put("initialDirectory", host.sshString("initialDirectory") ?: "~")
                                        put("hostKeys", buildJsonArray {})
                                    },
                                ) as JsonObject
                                val fingerprint = probe.sshString("fingerprint")
                                    ?: throw IllegalStateException(L10n.text("android.sshconnect.the_server_did_not_offer_a_host_key.3c1b0e56"))
                                keysForOpen = listOf(fingerprint)
                                val saved = buildJsonObject {
                                    host.forEach { (k, v) -> put(k, v) }
                                    put("hostKeys", buildJsonArray { keysForOpen.forEach { add(JsonPrimitive(it)) } })
                                }
                                model.core("ssh.host.save", saved)
                            }
                            val keyRef = selectedKeyId.takeIf { it.isNotEmpty() }
                            val pem = keyRef?.let { id ->
                                val rec = savedKeys.find { it.sshString("id") == id }
                                rec?.sshString("secretRef")?.let { withContext(Dispatchers.IO) { SshSecrets.get(context, it) } }
                            }
                            if (keyRef != null && pem.isNullOrBlank()) {
                                throw IllegalStateException(L10n.text("android.sshconnect.the_saved_key_has_no_private_material_on_t.195cf970"))
                            }
                            val auth = if (!pem.isNullOrBlank()) {
                                buildJsonObject {
                                    put("kind", "privateKey")
                                    put("pem", pem)
                                    if (passphrase.isNotBlank()) put("passphrase", passphrase)
                                }
                            } else {
                                buildJsonObject {
                                    put("kind", "password")
                                    put("password", password)
                                }
                            }
                            val opened = model.core(
                                "ssh.session.open",
                                buildJsonObject {
                                    put("hostname", hostname)
                                    put("port", port)
                                    put("username", username)
                                    put("initialDirectory", host.sshString("initialDirectory") ?: "~")
                                    put("hostKeys", buildJsonArray { keysForOpen.forEach { add(JsonPrimitive(it)) } })
                                    put("rows", 24)
                                    put("cols", 80)
                                    put("auth", auth)
                                    // Carried so `ssh.session.list` can name
                                    // what it is holding. The host never dials
                                    // with either: it reaches the server by
                                    // hostname and username the way it always
                                    // did.
                                    host.sshString("id")?.let { put("hostId", it) }
                                    put("label", host.sshString("label") ?: hostname)
                                },
                            ) as JsonObject
                            opened.sshString("id") ?: throw IllegalStateException(L10n.text("android.sshconnect.the_session_opened_without_an_id.09911388"))
                        }.onSuccess(onOpened).onFailure { error = it.message }
                        busy = false
                    }
                },
            )
        },
        // Full size, like Connect beside it. A small Cancel next to a
        // full-size primary reads broken, and it misses the 48dp touch
        // minimum the capsule comment promises for actions.
        dismissButton = { TsSecondaryButton(label = L10n.text("common.cancel"), onClick = onDismiss) },
    )
}

/// Rename a saved key. The private half is never shown here: it lives in
/// the device store under `secretRef`, and the fingerprint and public half
/// are copied from the row menu instead.
@Composable
fun SshKeyRenameDialog(model: AppViewModel, key: JsonObject, onDismiss: () -> Unit, onSaved: () -> Unit) {
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    var label by remember(key) { mutableStateOf(key.sshString("label") ?: "") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(L10n.text("android.sshconnect.rename_key.f1c3ef11")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                OutlinedTextField(
                    label,
                    { label = it },
                    label = { Text(L10n.text("android.sshconnect.label.0e66373f")) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
                key.sshString("fingerprint")?.takeIf { it.isNotBlank() }?.let {
                    Text(it, style = androidx.compose.material3.MaterialTheme.typography.bodySmall, color = colors.textSecondary)
                }
                error?.let { Text(it, color = colors.danger) }
            }
        },
        confirmButton = {
            TsAccentButton(
                label = if (busy) L10n.text("android.sshconnect.saving.23e39291") else L10n.text("common.save"),
                small = true,
                enabled = !busy && label.isNotBlank(),
                onClick = {
                    scope.launch {
                        busy = true
                        error = null
                        runCatching {
                            val map = key.toMutableMap()
                            map["label"] = JsonPrimitive(label.trim())
                            model.core("ssh.key.save", JsonObject(map))
                        }.onSuccess { onSaved() }.onFailure { error = it.message }
                        busy = false
                    }
                },
            )
        },
        dismissButton = { TsSecondaryButton(label = L10n.text("common.cancel"), small = true, onClick = onDismiss) },
    )
}

@Composable
fun SshKeyImportDialog(model: AppViewModel, onDismiss: () -> Unit, onSaved: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val colors = LocalTsColors.current
    var label by remember { mutableStateOf("") }
    var pem by remember { mutableStateOf("") }
    var passphrase by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(L10n.text("android.sshconnect.add_a_key.2feab16f")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                OutlinedTextField(label, { label = it }, label = { Text(L10n.text("android.sshconnect.label.0e66373f")) }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                OutlinedTextField(pem, { pem = it }, label = { Text(L10n.text("android.sshconnect.paste_pem_or_leave_blank_to_generate.b4360b7f")) }, modifier = Modifier.fillMaxWidth(), minLines = 4)
                OutlinedTextField(
                    passphrase,
                    { passphrase = it },
                    label = { Text(L10n.text("android.sshconnect.passphrase.e7611f05")) },
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
                error?.let { Text(it, color = colors.danger) }
            }
        },
        confirmButton = {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                TsSecondaryButton(
                    label = L10n.text("android.sshconnect.generate.49e49bb4"),
                    small = true,
                    enabled = !busy && label.isNotBlank(),
                    onClick = {
                        scope.launch {
                            busy = true
                            error = null
                            runCatching {
                                val material = model.core("ssh.key.generate") as JsonObject
                                persistKey(context, model, label, material)
                            }.onSuccess { onSaved() }.onFailure { error = it.message }
                            busy = false
                        }
                    },
                )
                TsAccentButton(
                    label = L10n.text("android.sshconnect.import.2cff9baa"),
                    small = true,
                    enabled = !busy && label.isNotBlank() && pem.isNotBlank(),
                    onClick = {
                        scope.launch {
                            busy = true
                            error = null
                            runCatching {
                                val material = model.core(
                                    "ssh.key.inspect",
                                    buildJsonObject {
                                        put("pem", pem)
                                        if (passphrase.isNotBlank()) put("passphrase", passphrase)
                                    },
                                ) as JsonObject
                                persistKey(context, model, label, material)
                            }.onSuccess { onSaved() }.onFailure { error = it.message }
                            busy = false
                        }
                    },
                )
            }
        },
        dismissButton = { TsSecondaryButton(label = L10n.text("common.cancel"), small = true, onClick = onDismiss) },
    )
}

private suspend fun persistKey(context: Context, model: AppViewModel, label: String, material: JsonObject) {
    val privateKey = material.sshString("privateKey") ?: error(L10n.text("android.sshconnect.the_key_had_no_private_material.a3963eb0"))
    val id = java.util.UUID.randomUUID().toString()
    val ref = "android:$id"
    withContext(Dispatchers.IO) { SshSecrets.put(context, ref, privateKey) }
    model.core(
        "ssh.key.save",
        buildJsonObject {
            put("id", "key_$id")
            put("label", label)
            put("algorithm", material.sshString("algorithm") ?: "ed25519")
            put("publicKey", material.sshString("publicKey") ?: "")
            put("fingerprint", material.sshString("fingerprint") ?: "")
            put("secretRef", ref)
        },
    )
}

fun bytesToUtf8(data: JsonArray): String {
    val bytes = ByteArray(data.size) { i ->
        data[i].jsonPrimitive.content.toInt().toByte()
    }
    return String(bytes, Charsets.UTF_8)
}

fun utf8ToJsonBytes(text: String): JsonArray = rawToJsonBytes(text.toByteArray(Charsets.UTF_8))

fun rawToJsonBytes(bytes: ByteArray): JsonArray = buildJsonArray {
    bytes.forEach { add(JsonPrimitive(it.toInt() and 0xFF)) }
}

fun bytesToBase64(data: JsonArray): String {
    val bytes = ByteArray(data.size) { i ->
        data[i].jsonPrimitive.content.toInt().toByte()
    }
    return Base64.encodeToString(bytes, Base64.NO_WRAP)
}
