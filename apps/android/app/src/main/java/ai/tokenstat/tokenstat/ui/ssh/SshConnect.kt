// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

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
        title = { Text("Connect to $username@$hostname") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text("$hostname:$port", color = colors.textSecondary)
                // "Use": the password, or one of the saved keys. Passwords
                // are used for this connection and are never saved.
                Box {
                    OutlinedTextField(
                        value = if (selectedKeyId.isEmpty()) "Password"
                        else savedKeys.find { it.sshString("id") == selectedKeyId }?.sshString("label") ?: "Password",
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Use") },
                        trailingIcon = {
                            IconButton(onClick = { authOpen = true }) {
                                Icon(ActionIcon.More.vector, "Choose authentication")
                            }
                        },
                        modifier = Modifier.fillMaxWidth().clickable { authOpen = true },
                        singleLine = true,
                    )
                    DropdownMenu(expanded = authOpen, onDismissRequest = { authOpen = false }) {
                        DropdownMenuItem(
                            text = { Text("Password") },
                            onClick = { selectedKeyId = ""; authOpen = false },
                        )
                        savedKeys.forEach { key ->
                            val label = key.sshString("label") ?: "Key"
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
                        label = { Text("Password") },
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                    )
                } else {
                    OutlinedTextField(
                        passphrase,
                        { passphrase = it },
                        label = { Text("Key passphrase (if any)") },
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                    )
                }
                Text(
                    "Passwords are used for this connection and are never saved.",
                    style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                    color = colors.textSecondary,
                )
                error?.let { Text(it, color = colors.danger) }
            }
        },
        confirmButton = {
            TsAccentButton(
                label = if (busy) "Connecting…" else "Connect",
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
                                    ?: throw IllegalStateException("The server did not offer a host key.")
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
                                throw IllegalStateException("The saved key has no private material on this device.")
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
                            opened.sshString("id") ?: throw IllegalStateException("The session opened without an id.")
                        }.onSuccess(onOpened).onFailure { error = it.message }
                        busy = false
                    }
                },
            )
        },
        // Full size, like Connect beside it. A small Cancel next to a
        // full-size primary reads broken, and it misses the 48dp touch
        // minimum the capsule comment promises for actions.
        dismissButton = { TsSecondaryButton(label = "Cancel", onClick = onDismiss) },
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
        title = { Text("Rename key") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                OutlinedTextField(
                    label,
                    { label = it },
                    label = { Text("Label") },
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
                label = if (busy) "Saving…" else "Save",
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
        dismissButton = { TsSecondaryButton(label = "Cancel", small = true, onClick = onDismiss) },
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
        title = { Text("Add a key") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                OutlinedTextField(label, { label = it }, label = { Text("Label") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                OutlinedTextField(pem, { pem = it }, label = { Text("Paste PEM, or leave blank to generate") }, modifier = Modifier.fillMaxWidth(), minLines = 4)
                OutlinedTextField(
                    passphrase,
                    { passphrase = it },
                    label = { Text("Passphrase") },
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
                    label = "Generate",
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
                    label = "Import",
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
        dismissButton = { TsSecondaryButton(label = "Cancel", small = true, onClick = onDismiss) },
    )
}

private suspend fun persistKey(context: Context, model: AppViewModel, label: String, material: JsonObject) {
    val privateKey = material.sshString("privateKey") ?: error("The key had no private material.")
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
