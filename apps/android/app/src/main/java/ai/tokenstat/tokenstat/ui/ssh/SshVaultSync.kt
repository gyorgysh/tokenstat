// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import ai.tokenstat.tokenstat.AppViewModel
import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/// Two-way vault sync, port of the sync half of `SSHLibraryModel.swift`.
///
/// Pull the vault's records, apply what is newer, push what it has never
/// seen, so both sides end up saying the same thing. Without this a second
/// device unlocks into empty lists: the records only exist in the vault.

enum class VaultVerdict { TAKE_REMOTE, PUSH_LOCAL, SAME }

/// Newer wins. A record this device does not have is always taken, and a
/// record written before stamps existed reads as 0, which loses to anything
/// stamped and ties with anything else that never was.
fun vaultVerdict(remoteMs: Long, localMs: Long?): VaultVerdict {
    if (localMs == null) return VaultVerdict.TAKE_REMOTE
    if (remoteMs > localMs) return VaultVerdict.TAKE_REMOTE
    if (localMs > remoteMs) return VaultVerdict.PUSH_LOCAL
    return VaultVerdict.SAME
}

private fun JsonObject.optStr(key: String): String? =
    this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull

private fun JsonObject.optLong(key: String): Long? = this[key]?.jsonPrimitive?.longOrNull

private fun JsonObject.optBool(key: String): Boolean? = this[key]?.jsonPrimitive?.booleanOrNull

/// A vault record's envelope, or null for tombstones and undecodable rows.
fun vaultEnvelopeOf(record: JsonObject): JsonObject? = try {
    val text = record.optStr("plaintext") ?: return null
    Json.parseToJsonElement(text) as? JsonObject
} catch (e: Exception) {
    null
}

/// Folder records first, each after its own parent, then the rest in arrival
/// order. A folder whose parent is missing entirely still goes out at the
/// end: the host rejects it and says so, which beats dropping it silently.
fun orderVaultRecords(records: List<JsonObject>, localFolderIds: Set<String>): List<JsonObject> {
    val folders = mutableListOf<Pair<JsonObject, JsonObject>>()
    val rest = mutableListOf<JsonObject>()
    for (record in records) {
        val folder = vaultEnvelopeOf(record)?.get("folder") as? JsonObject
        if (record.optBool("deleted") != true && folder != null) folders.add(record to folder)
        else rest.add(record)
    }
    val placed = localFolderIds.toMutableSet()
    val sorted = mutableListOf<JsonObject>()
    val remaining = folders.toMutableList()
    while (remaining.isNotEmpty()) {
        val ready = remaining.filter { (_, folder) ->
            val parent = folder.optStr("parentId")
            parent == null || placed.contains(parent)
        }
        if (ready.isEmpty()) break
        for ((record, folder) in ready) {
            sorted.add(record)
            folder.optStr("id")?.let { placed.add(it) }
        }
        val readyIds = ready.mapNotNull { it.second.optStr("id") }.toSet()
        remaining.removeAll { readyIds.contains(it.second.optStr("id")) }
    }
    sorted.addAll(remaining.map { it.first })
    return sorted + rest
}

data class VaultSyncResult(val changed: Boolean, val error: String?, val vaultError: String?)

object SshVaultSync {
    /// Both directions, in the one order that converges: the pull answers
    /// with what the vault holds, and everything here that is not in that
    /// answer is pushed. `asked` separates a sync somebody pressed from the
    /// one every arrival at the screen runs: a vault that cannot be read is
    /// worth a sentence when the answer to a button press would otherwise be
    /// nothing at all.
    suspend fun sync(
        model: AppViewModel,
        context: Context,
        tier: String,
        hosts: List<JsonObject>,
        keys: List<JsonObject>,
        snippets: List<JsonObject>,
        folders: List<JsonObject>,
        asked: Boolean,
    ): VaultSyncResult {
        val records = try {
            val answer = model.core(
                "ssh.vault.record.list",
                buildJsonObject { put("recovery", ""); put("tier", tier) },
            ) as? JsonObject
            (answer?.get("records") as? JsonArray)?.filterIsInstance<JsonObject>().orEmpty()
        } catch (e: Exception) {
            return VaultSyncResult(false, null, if (asked) e.message else null)
        }
        // Every id the vault holds, decodable or not: pushing over an
        // unreadable record would replace what a newer client wrote.
        val known = records.mapNotNull { it.optStr("id") }.toSet()
        var changed = false
        var error: String? = null
        var vaultError: String? = null
        val localFolderIds = folders.mapNotNull { it.optStr("id") }.toSet()
        for (record in orderVaultRecords(records, localFolderIds)) {
            val id = record.optStr("id") ?: continue
            if (record.optBool("deleted") == true) {
                try {
                    if (applyDeletion(model, context, id, keys)) changed = true
                } catch (e: Exception) {
                    error = e.message
                }
                continue
            }
            val envelope = vaultEnvelopeOf(record) ?: continue
            try {
                val host = envelope["host"] as? JsonObject
                val folder = envelope["folder"] as? JsonObject
                val snippet = envelope["snippet"] as? JsonObject
                val key = envelope["key"] as? JsonObject
                if (host != null) {
                    val local = hosts.firstOrNull { it.optStr("id") == host.optStr("id") }
                    when (vaultVerdict(host.optLong("updatedMs") ?: 0L, local?.optLong("updatedMs"))) {
                        VaultVerdict.TAKE_REMOTE -> {
                            applySave(model, "ssh.host.save", host); changed = true
                        }
                        VaultVerdict.PUSH_LOCAL -> {
                            if (local != null) mirror(model, tier, "host:${local.optStr("id")}", "host", local)
                                ?.let { vaultError = it }
                        }
                        VaultVerdict.SAME -> {}
                    }
                } else if (folder != null) {
                    val local = folders.firstOrNull { it.optStr("id") == folder.optStr("id") }
                    when (vaultVerdict(folder.optLong("updatedMs") ?: 0L, local?.optLong("updatedMs"))) {
                        VaultVerdict.TAKE_REMOTE -> {
                            applySave(model, "ssh.folder.save", folder); changed = true
                        }
                        VaultVerdict.PUSH_LOCAL -> {
                            if (local != null) mirror(model, tier, "folder:${local.optStr("id")}", "folder", local)
                                ?.let { vaultError = it }
                        }
                        VaultVerdict.SAME -> {}
                    }
                } else if (snippet != null) {
                    val local = snippets.firstOrNull { it.optStr("id") == snippet.optStr("id") }
                    when (vaultVerdict(snippet.optLong("updatedMs") ?: 0L, local?.optLong("updatedMs"))) {
                        VaultVerdict.TAKE_REMOTE -> {
                            applySave(model, "ssh.snippet.save", snippet); changed = true
                        }
                        VaultVerdict.PUSH_LOCAL -> {
                            if (local != null) mirror(model, tier, "snippet:${local.optStr("id")}", "snippet", local)
                                ?.let { vaultError = it }
                        }
                        VaultVerdict.SAME -> {}
                    }
                } else if (key != null) {
                    if (applyKey(model, context, tier, key, keys)) changed = true
                }
            } catch (e: Exception) {
                error = e.message
            }
        }
        // Everything here the vault has never heard of goes in. Folders
        // before the hosts that name them: a client reading this back
        // rejects a host whose folder it has not seen.
        for (folder in folders) {
            val id = folder.optStr("id") ?: continue
            if (!known.contains("folder:$id")) {
                mirror(model, tier, "folder:$id", "folder", folder)?.let { vaultError = it }
            }
        }
        for (host in hosts) {
            val id = host.optStr("id") ?: continue
            if (!known.contains("host:$id")) {
                mirror(model, tier, "host:$id", "host", host)?.let { vaultError = it }
            }
        }
        for (snippet in snippets) {
            val id = snippet.optStr("id") ?: continue
            if (!known.contains("snippet:$id")) {
                mirror(model, tier, "snippet:$id", "snippet", snippet)?.let { vaultError = it }
            }
        }
        for (key in keys) {
            val id = key.optStr("id") ?: continue
            if (!known.contains("key:$id")) {
                pushMissingKey(model, context, tier, key)?.let { vaultError = it }
            }
        }
        return VaultSyncResult(changed, error, vaultError)
    }

    /// Write a record that arrived from the vault, keeping the timestamp it
    /// came with so the next verdict compares revisions, not arrivals.
    private suspend fun applySave(model: AppViewModel, method: String, record: JsonObject) {
        val stamped = JsonObject(record + ("keepUpdatedMs" to JsonPrimitive(true)))
        model.core(method, stamped)
    }

    /// A key is the one record where an equal stamp still means work: the
    /// row can be here while the private half is not, which is what a
    /// freshly enrolled device looks like.
    private suspend fun applyKey(
        model: AppViewModel,
        context: Context,
        tier: String,
        remote: JsonObject,
        localKeys: List<JsonObject>,
    ): Boolean {
        val id = remote.optStr("id") ?: return false
        val local = localKeys.firstOrNull { it.optStr("id") == id }
        val havePrivate = local?.optStr("secretRef")?.let {
            withContext(Dispatchers.IO) { SshSecrets.get(context, it) }
        } != null
        when (vaultVerdict(remote.optLong("updatedMs") ?: 0L, local?.optLong("updatedMs"))) {
            VaultVerdict.TAKE_REMOTE -> {}
            VaultVerdict.SAME -> if (havePrivate) return false
            VaultVerdict.PUSH_LOCAL -> {
                if (local != null) pushMissingKey(model, context, tier, local)
                return false
            }
        }
        val pem = remote.optStr("privateKey") ?: return false
        val ref = "android:$id"
        withContext(Dispatchers.IO) { SshSecrets.put(context, ref, pem) }
        model.core(
            "ssh.key.save",
            buildJsonObject {
                put("id", id)
                put("label", remote.optStr("label") ?: "")
                put("algorithm", remote.optStr("algorithm") ?: "ed25519")
                put("publicKey", remote.optStr("publicKey") ?: "")
                put("secretRef", ref)
                put("hardwareBacked", remote.optBool("hardwareBacked") == true)
                put("updatedMs", remote.optLong("updatedMs") ?: 0L)
                put("keepUpdatedMs", true)
            },
        )
        return true
    }

    /// Copy one local key into the vault for the other devices. A key with
    /// no private half on this device is skipped, not pushed as a row
    /// nothing can connect with.
    private suspend fun pushMissingKey(
        model: AppViewModel,
        context: Context,
        tier: String,
        local: JsonObject,
    ): String? {
        val id = local.optStr("id") ?: return null
        val material = local.optStr("secretRef")?.let {
            withContext(Dispatchers.IO) { SshSecrets.get(context, it) }
        } ?: return null
        val synced = buildJsonObject {
            put("id", id)
            put("label", local.optStr("label") ?: "")
            put("algorithm", local.optStr("algorithm") ?: "ed25519")
            put("publicKey", local.optStr("publicKey") ?: "")
            put("privateKey", material)
            put("hardwareBacked", local.optBool("hardwareBacked") == true)
            put("updatedMs", local.optLong("updatedMs") ?: 0L)
        }
        return mirror(model, tier, "key:$id", "key", synced)
    }

    /// Copy a record into the encrypted vault for the other devices.
    /// Returns the failure to report, if any: every caller has already
    /// written the record locally by the time this runs, so a failure here
    /// must not turn a save that worked into one that looks like it did not.
    private suspend fun mirror(model: AppViewModel, tier: String, id: String, kind: String, payload: JsonObject): String? {
        val plaintext = buildJsonObject { put("kind", kind); put(kind, payload) }.toString()
        return try {
            model.core(
                "ssh.vault.record.put",
                buildJsonObject {
                    put("id", id); put("plaintext", plaintext); put("recovery", ""); put("tier", tier)
                },
            )
            null
        } catch (e: Exception) {
            e.message
        }
    }

    private suspend fun applyDeletion(
        model: AppViewModel,
        context: Context,
        id: String,
        localKeys: List<JsonObject>,
    ): Boolean {
        when {
            id.startsWith("host:") -> model.core("ssh.host.delete", buildJsonObject { put("id", id.removePrefix("host:")) })
            id.startsWith("folder:") -> model.core("ssh.folder.delete", buildJsonObject { put("id", id.removePrefix("folder:")) })
            id.startsWith("snippet:") -> model.core("ssh.snippet.delete", buildJsonObject { put("id", id.removePrefix("snippet:")) })
            id.startsWith("key:") -> {
                val keyId = id.removePrefix("key:")
                localKeys.firstOrNull { it.optStr("id") == keyId }?.optStr("secretRef")?.let {
                    withContext(Dispatchers.IO) { SshSecrets.delete(context, it) }
                }
                model.core("ssh.key.delete", buildJsonObject { put("id", keyId) })
            }
            else -> return false
        }
        return true
    }
}
