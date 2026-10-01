// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.localization

import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

object L10n {
    private val catalogs = ConcurrentHashMap<String, LanguageCatalog>()

    fun text(key: String, vararg arguments: Any?): String {
        val language = Locale.getDefault().toLanguageTag()
        return catalogs.getOrPut(language) {
            LanguageCatalog.load(listOf(language), ::read)
        }.text(key, arguments.map { it.toString() })
    }

    private fun read(language: String, table: String): Map<String, String> {
        val stream = L10n::class.java.getResourceAsStream("/$language/$table.json") ?: return emptyMap()
        return stream.bufferedReader(Charsets.UTF_8).use { reader ->
            runCatching {
                Json.parseToJsonElement(reader.readText()).jsonObject.mapValues { it.value.jsonPrimitive.content }
            }.getOrDefault(emptyMap())
        }
    }
}

internal class LanguageCatalog(private val strings: Map<String, String>) {
    fun text(key: String, arguments: List<String> = emptyList()): String {
        val template = strings[key] ?: return key
        if (arguments.isEmpty()) return template
        return placeholder.replace(template) { match ->
            match.groupValues[1].toIntOrNull()?.let(arguments::getOrNull) ?: match.value
        }
    }

    companion object {
        private val placeholder = Regex("\\{([0-9]+)\\}")

        fun load(languages: List<String>, read: (String, String) -> Map<String, String>): LanguageCatalog {
            val strings = (read("en", "common") + read("en", "android")).toMutableMap()
            for (language in languages) {
                val normalized = language.replace('_', '-')
                val components = normalized.split('-')
                val translated = mutableMapOf<String, String>()
                for (count in 1..components.size) {
                    val tag = components.take(count).joinToString("-")
                    translated.putAll(read(tag, "common") + read(tag, "android"))
                }
                if (translated.isNotEmpty()) {
                    strings.putAll(translated)
                    break
                }
            }
            return LanguageCatalog(strings)
        }
    }
}
