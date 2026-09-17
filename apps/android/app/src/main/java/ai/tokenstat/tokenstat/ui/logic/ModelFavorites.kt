// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import android.content.Context

/// Which model ids this device pins to the top of the agent picker.
///
/// Port of `ModelFavoritesStore` in `Sources/Design/FavoriteModelPicker.swift`.
/// It is a per-device convenience, never synced and never sent anywhere: a
/// forty-model list is unreadable, and the four somebody actually uses belong
/// above the rest.
interface ModelFavorites {
    fun ids(backend: String): List<String>
    fun toggle(backend: String, model: String)

    fun contains(backend: String, model: String): Boolean =
        model.isNotEmpty() && model in ids(backend)
}

/// Favourites first, in the order they were pinned, then the rest as the host
/// listed them. Pure, so the ordering has a test that needs no preferences.
fun favoriteOrderedModels(ids: List<String>, favorites: List<String>): List<String> {
    val pinned = favorites.filter { it in ids }
    return pinned + ids.filter { it !in pinned }
}

/// Stored as one preference per backend, because the set is small and a key
/// per agent means a rename of one agent cannot disturb another's list.
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

/// The store a preview or a unit test uses, which forgets everything.
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
