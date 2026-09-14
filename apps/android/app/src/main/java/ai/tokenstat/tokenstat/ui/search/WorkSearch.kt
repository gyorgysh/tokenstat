// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.search

import ai.tokenstat.tokenstat.ui.components.ActionIcon

/// A screen or setting inside the app, offered by search beside folders.
///
/// Ported from `WorkSearchPlaces.swift` and `ClientAppPlaces.swift`. One
/// catalogue, kept next to the destinations it names: a place nobody can be
/// sent to reads as a search result that does nothing. The identifier says
/// where the place goes (`"tab:home"`, `"account:thisDevice:tabs"`).
data class SearchPlace(
    val id: String,
    val title: String,
    /// Where it lives, said the way a person would: "Account · This device".
    val detail: String,
    val icon: ActionIcon,
    /// Words somebody might type for this that the title does not contain.
    val keywords: List<String> = emptyList(),
)

/// Where a place goes. Parsed from the identifier, so the sheet can hand a
/// place back without knowing what a tab is.
sealed interface SearchOpen {
    data class Tab(val name: String) : SearchOpen
    data class Device(val machineId: String) : SearchOpen
    object Account : SearchOpen
    data class Folder(val hostId: String, val folderId: String) : SearchOpen
}

object SearchPlaces {
    fun all(machineIds: Map<String, String>, machinePlatforms: Map<String, String>): List<SearchPlace> =
        tabs() + screens() + devices(machineIds, machinePlatforms)

    fun destinationOf(place: SearchPlace, machineIdOf: (peer: String) -> String?): SearchOpen? {
        val parts = place.id.split(":", limit = 3)
        return when (parts.firstOrNull()) {
            "tab" -> if (parts.size > 1) SearchOpen.Tab(parts[1]) else null
            "home", "workspaces" -> SearchOpen.Tab(parts[0])
            "account" -> SearchOpen.Account
            "device" -> {
                val peer = parts.getOrNull(1)
                if (peer.isNullOrEmpty()) null else SearchOpen.Device(machineIdOf(peer) ?: peer)
            }
            else -> null
        }
    }

    private fun tabs(): List<SearchPlace> = listOf(
        SearchPlace(
            "tab:home", "Home", "Tab",
            ActionIcon.Home,
            listOf("dashboard", "spend", "today", "week", "activity", "limits", "start"),
        ),
        SearchPlace(
            "tab:workspaces", "Workspaces", "Tab",
            ActionIcon.Reveal,
            listOf("folders", "projects", "chat", "sessions", "repos", "git", "terminal"),
        ),
        SearchPlace(
            "tab:insights", "Insights", "Tab",
            ActionIcon.Benchmarks,
            listOf("breakdown", "models", "projects", "reports", "charts", "cost"),
        ),
        SearchPlace(
            "tab:devices", "Devices", "Tab",
            ActionIcon.Device,
            listOf("computers", "laptop", "mac", "linked", "pair", "remote", "servers", "terminal", "keys", "vault", "shell"),
        ),
    )

    /// Every machine on the account, so a name somebody knows finds the
    /// device rather than making them count rows on Devices.
    private fun devices(
        machineIds: Map<String, String>,
        machinePlatforms: Map<String, String>,
    ): List<SearchPlace> = machineIds.map { (peer, name) ->
        SearchPlace(
            id = "device:$peer",
            title = name,
            detail = "Devices · ${machinePlatforms[peer] ?: "Linked device"}",
            icon = ActionIcon.Device,
            keywords = listOf("machine", "computer", "device"),
        )
    }

    /// The screens and settings that are not tabs. Written out rather than
    /// derived, because what somebody would type for a setting is rarely its
    /// heading: nobody searches for "This device", they search for "traffic".
    private fun screens(): List<SearchPlace> = listOf(
        SearchPlace(
            "home:editor", "Customize Home", "Home",
            ActionIcon.Layout,
            listOf("cards", "arrange", "sections", "customise", "edit", "rearrange", "hide"),
        ),
        SearchPlace(
            "workspaces:editor", "Customize Workspaces", "Workspaces",
            ActionIcon.Layout,
            listOf("folders", "chats", "sessions", "arrange", "sections", "customise", "edit", "rearrange", "hide", "order"),
        ),
        SearchPlace(
            "account:thisDevice", "Settings", "Behind your avatar · This device",
            ActionIcon.Settings,
            listOf("preferences", "options", "config", "setup", "device"),
        ),
        SearchPlace(
            "account:account", "Account", "Behind your avatar",
            ActionIcon.Account,
            listOf("profile", "handle", "sign out", "log out", "avatar", "relay", "usage"),
        ),
        SearchPlace(
            "account:account:plans", "Plan", "Account",
            ActionIcon.Plans,
            listOf("plans", "subscription", "billing", "upgrade", "price", "tier", "pro", "renew"),
        ),
        SearchPlace(
            "account:thisDevice:notifications", "Notifications", "Account · This device",
            ActionIcon.Settings,
            listOf("push", "alerts", "notify", "sounds", "badge", "settings"),
        ),
        SearchPlace(
            "account:thisDevice:traffic", "Local traffic", "Account · This device",
            ActionIcon.Connect,
            listOf("network", "connections", "direct", "relayed", "lan", "settings"),
        ),
        SearchPlace(
            "account:legal", "Terms and privacy", "Account · Legal",
            ActionIcon.Security,
            listOf("legal", "policy", "licence", "license", "conditions"),
        ),
    )

    /// Every word typed has to start a word in the place, so "not" finds
    /// Notifications and "tab bar" finds Tabs, while a word from nowhere in
    /// it removes the place rather than ranking it last.
    ///
    /// Ranked by where the match landed: the title first, then the words
    /// kept for searching, then the trail that says where it lives.
    private val wordBoundary = Regex("[^\\p{L}\\p{Nd}]+")

    fun rank(query: String, places: List<SearchPlace>, limit: Int = 6): List<SearchPlace> {
        val words = query.lowercase().split(wordBoundary).filter { it.isNotEmpty() }
        if (words.isEmpty()) return emptyList()
        val scored = places.mapNotNull { place ->
            var total = 0
            for (word in words) {
                total += score(word, place) ?: return@mapNotNull null
            }
            place to total
        }
        return scored.sortedWith(compareByDescending<Pair<SearchPlace, Int>> { it.second }.thenBy { it.first.title })
            .take(limit).map { it.first }
    }

    private fun score(word: String, place: SearchPlace): Int? {
        if (starts(place.title, word)) return if (place.title.lowercase() == word) 6 else 4
        if (place.keywords.any { starts(it, word) }) return 2
        if (starts(place.detail, word)) return 1
        return null
    }

    private fun starts(text: String, word: String): Boolean =
        text.lowercase().split(wordBoundary).any { it.startsWith(word) }
}
