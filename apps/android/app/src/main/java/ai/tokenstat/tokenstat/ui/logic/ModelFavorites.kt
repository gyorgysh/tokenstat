// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import android.content.Context

interface ModelFavorites {
    fun ids(backend: String): List<String>
    fun toggle(backend: String, model: String)

    fun contains(backend: String, model: String): Boolean =
        model.isNotEmpty() && model in ids(backend)
}

fun favoriteOrderedModels(ids: List<String>, favorites: List<String>): List<String> {
    val pinned = favorites.filter { it in ids }
    return pinned + ids.filter { it !in pinned }
}

class SharedPrefsModelFavorites(context: Context) : ModelFavorites {
    private val prefs = context.getSharedPreferences("ts.models.favorites", Context.MODE_PRIVATE)

    override fun ids(backend: String): List<String> {
        if (backend.isEmpty()) return emptyList()
        return prefs.getString(backend, "").orEmpty()
            .split('\n')
            .filter { it.isNotBlank() }
    }

    override fun toggle(backend: String, model: String) {
        val cleaned = model.trim()
        if (backend.isEmpty() || cleaned.isEmpty()) return
        val list = ids(backend).toMutableList()
        if (!list.remove(cleaned)) list.add(0, cleaned)
        prefs.edit().apply {
            if (list.isEmpty()) remove(backend) else putString(backend, list.joinToString("\n"))
        }.apply()
    }
}

class InMemoryModelFavorites(
    private val byBackend: MutableMap<String, MutableList<String>> = mutableMapOf(),
) : ModelFavorites {
    override fun ids(backend: String): List<String> = byBackend[backend].orEmpty()

    override fun toggle(backend: String, model: String) {
        val cleaned = model.trim()
        if (backend.isEmpty() || cleaned.isEmpty()) return
        val list = byBackend.getOrPut(backend) { mutableListOf() }
        if (!list.remove(cleaned)) list.add(0, cleaned)
        if (list.isEmpty()) byBackend.remove(backend)
    }
}
