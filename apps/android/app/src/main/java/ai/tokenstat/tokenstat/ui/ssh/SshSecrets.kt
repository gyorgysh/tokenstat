// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Private material is encrypted with a non-exportable Android Keystore key. */
object SshSecrets {
    private const val TAG = "SshSecrets"
    private const val LEGACY = "ai.tokenstat.ssh.secrets"
    private const val STORE = "ai.tokenstat.ssh.secrets.v2"
    private const val ALIAS = "ai.tokenstat.ssh.storage.v2"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build())
            generateKey()
        }
    }

    private fun seal(ref: String, pem: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(ref.toByteArray(Charsets.UTF_8))
        val iv = Base64.encodeToString(cipher.iv, Base64.NO_WRAP)
        val encrypted = Base64.encodeToString(cipher.doFinal(pem.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
        return "v2:$iv:$encrypted"
    }

    private fun openOrNull(ref: String, encoded: String): String? {
        return try {
            open(ref, encoded)
        } catch (e: Exception) {
            Log.w(TAG, "cannot decrypt key $ref", e)
            null
        }
    }

    private fun open(ref: String, encoded: String): String {
        val parts = encoded.split(':')
        require(parts.size == 3 && parts[0] == "v2") { "Invalid encrypted SSH key" }
        val iv = Base64.decode(parts[1], Base64.NO_WRAP)
        require(iv.size == 12) { "Invalid SSH key nonce" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        cipher.updateAAD(ref.toByteArray(Charsets.UTF_8))
        return String(cipher.doFinal(Base64.decode(parts[2], Base64.NO_WRAP)), Charsets.UTF_8)
    }

    /** Commit and verify encrypted copies before removing any legacy plaintext. */
    @Synchronized
    fun migrate(context: Context) {
        val old = context.getSharedPreferences(LEGACY, Context.MODE_PRIVATE)
        val raw = old.all
        if (raw.isEmpty()) return
        val secure = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
        val edit = secure.edit()
        var migrated = 0
        for ((ref, value) in raw) {
            // One bad legacy entry must not poison the whole store: skip it
            // so the remaining keys still migrate and stay usable.
            if (value !is String) {
                Log.w(TAG, "skipping non-string legacy entry $ref")
                continue
            }
            try {
                // The legacy entry is authoritative until its deletion commits.
                val encrypted = seal(ref, value)
                check(open(ref, encrypted) == value) { "Could not verify encrypted SSH key" }
                edit.putString(ref, encrypted)
                migrated++
            } catch (e: Exception) {
                Log.w(TAG, "skipping legacy entry $ref that could not be sealed", e)
            }
        }
        if (migrated == 0) return
        check(edit.commit()) { "Could not save encrypted SSH keys" }
        // Only remove the entries that migrated; quarantine the rest for a
        // later retry instead of dropping or blocking on them.
        val cleanup = old.edit()
        for ((ref, value) in raw) {
            if (value is String && secure.getString(ref, null) != null) {
                cleanup.remove(ref)
            }
        }
        check(cleanup.commit()) { "Could not remove legacy SSH keys" }
    }

    @Synchronized
    fun put(context: Context, ref: String, pem: String) {
        try {
            migrate(context)
        } catch (e: Exception) {
            // Best-effort: a locked Keystore or corrupt legacy entry must not
            // block saving a fresh key. Migration retries on the next call.
            Log.w(TAG, "migration failed on put, continuing to v2 store", e)
        }
        val sealed = seal(ref, pem)
        // Round-trip before committing so an unreadable value never replaces
        // a good one.
        check(open(ref, sealed) == pem) { "Could not verify SSH key" }
        check(context.getSharedPreferences(STORE, Context.MODE_PRIVATE).edit()
            .putString(ref, sealed).commit()) { "Could not save SSH key" }
    }

    @Synchronized
    fun get(context: Context, ref: String): String? {
        try {
            migrate(context)
        } catch (e: Exception) {
            // Fall through to the v2 store: an already-migrated key stays
            // readable even when migration itself is unavailable.
            Log.w(TAG, "migration failed on get, reading v2 store", e)
        }
        val encoded = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            .getString(ref, null) ?: return null
        // Tamper/corruption is a missing key, not a crash: callers expect
        // nullable-get semantics.
        return openOrNull(ref, encoded)
    }
}
