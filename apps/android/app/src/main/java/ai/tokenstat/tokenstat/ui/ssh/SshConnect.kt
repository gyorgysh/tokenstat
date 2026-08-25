// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import android.content.Context
import android.util.Base64
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
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

private const val PREF = "ai.tokenstat.ssh.secrets"

object SshSecrets {
    fun put(context: Context, ref: String, pem: String) {
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit().putString(ref, pem).apply()
    }

    fun get(context: Context, ref: String): String? =
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE).getString(ref, null)
}

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

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Connect to $username@$hostname") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text("$hostname:$port", color = colors.textSecondary)
                OutlinedTextField(
                    password,
                    { password = it },
                    label = { Text("Password") },
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
                OutlinedTextField(
                    passphrase,
                    { passphrase = it },
                    label = { Text("Key passphrase (if any)") },
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
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
                            val keyRef = host.sshString("keyId") ?: host.sshString("identity")
                            val pem = keyRef?.let { id ->
                                val rec = keys.filterIsInstance<JsonObject>().find { it.sshString("id") == id }
                                rec?.sshString("secretRef")?.let { SshSecrets.get(context, it) }
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
                                },
                            ) as JsonObject
                            opened.sshString("id") ?: throw IllegalStateException("The session opened without an id.")
                        }.onSuccess(onOpened).onFailure { error = it.message }
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
    SshSecrets.put(context, ref, privateKey)
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
