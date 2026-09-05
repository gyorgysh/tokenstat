// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Private material is encrypted with a non-exportable Android Keystore key. */
object SshSecrets {
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
        val entries = old.all.mapValues { (_, value) ->
            require(value is String) { "Invalid legacy SSH key" }
            value
        }
        if (entries.isEmpty()) return
        val secure = context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
        val edit = secure.edit()
        for ((ref, pem) in entries) {
            // The legacy entry is authoritative until its deletion commits.
            val encrypted = seal(ref, pem)
            check(open(ref, encrypted) == pem) { "Could not verify encrypted SSH key" }
            edit.putString(ref, encrypted)
        }
        check(edit.commit()) { "Could not save encrypted SSH keys" }
        check(old.edit().clear().commit()) { "Could not remove legacy SSH keys" }
    }

    @Synchronized
    fun put(context: Context, ref: String, pem: String) {
        migrate(context)
        check(context.getSharedPreferences(STORE, Context.MODE_PRIVATE).edit()
            .putString(ref, seal(ref, pem)).commit()) { "Could not save SSH key" }
    }

    @Synchronized
    fun get(context: Context, ref: String): String? {
        migrate(context)
        return context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            .getString(ref, null)?.let { open(ref, it) }
    }
}
