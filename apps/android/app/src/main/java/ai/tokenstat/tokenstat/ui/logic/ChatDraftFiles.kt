// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class ChatDraftFiles(
    private val directory: File,
    private val capacity: Int = 300,
    private val delayMs: Long = 500,
) {
    private val writer = Executors.newSingleThreadScheduledExecutor { Thread(it, "chat-drafts").apply { isDaemon = true } }
    private val pending = mutableMapOf<String, String>()
    private val kept: MutableSet<String> by lazy {
        directory.list()?.filter { it.endsWith(SUFFIX) }?.toMutableSet() ?: mutableSetOf()
    }

    private fun name(owner: String) =
        MessageDigest.getInstance("SHA-256").digest(owner.toByteArray()).joinToString("") { "%02x".format(it) } + SUFFIX

    fun has(owner: String): Boolean = synchronized(pending) {
        pending[owner]?.let { return it.isNotEmpty() }
        name(owner) in kept
    }

    fun read(owner: String): String = synchronized(pending) {
        pending[owner]?.let { return it }
        if (name(owner) !in kept) return ""
        runCatching { File(directory, name(owner)).takeIf { it.length() <= BYTES }?.readText() }.getOrNull().orEmpty()
    }

    fun write(owner: String, text: String) {
        synchronized(pending) {
            if (owner !in pending && text.isEmpty() && name(owner) !in kept) return
            pending[owner] = text
        }
        writer.schedule({ save(owner, text) }, if (text.isEmpty()) 0 else delayMs, TimeUnit.MILLISECONDS)
    }

    fun flush() {
        val waiting = synchronized(pending) { pending.toMap() }
        waiting.forEach { (owner, text) -> writer.execute { save(owner, text) } }
    }

    private fun save(owner: String, text: String) = synchronized(pending) {
        if (pending[owner] != text) return@synchronized
        pending.remove(owner)
        val file = File(directory, name(owner))
        runCatching {
            if (text.isEmpty()) {
                file.delete()
                kept.remove(file.name)
                return@runCatching
            }
            val bytes = text.toByteArray()
            if (bytes.size > BYTES) return@runCatching
            directory.mkdirs()
            val temporary = File(directory, file.name + ".tmp")
            temporary.writeBytes(bytes)
            if (!temporary.renameTo(file)) temporary.delete() else kept.add(file.name)
            trim(file)
        }
        Unit
    }

    private fun trim(newest: File) {
        if (kept.size <= capacity) return
        directory.listFiles { file -> file.name.endsWith(SUFFIX) && file != newest }.orEmpty()
            .sortedBy { it.lastModified() }
            .take(kept.size - capacity)
            .forEach { if (it.delete()) kept.remove(it.name) }
    }

    private companion object {
        const val SUFFIX = ".txt"
        const val BYTES = 512 * 1024
    }
}
