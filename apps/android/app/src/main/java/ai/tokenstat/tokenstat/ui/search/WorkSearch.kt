// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.search

import ai.tokenstat.tokenstat.ui.localization.L10n

import ai.tokenstat.tokenstat.ui.components.ActionIcon

data class SearchPlace(
    val id: String,
    val title: String,
    val detail: String,
    val icon: ActionIcon,
    val keywords: List<String> = emptyList(),
)

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
            "tab:home", L10n.text("common.home"), L10n.text("android.worksearch.tab.90ddf196"),
            ActionIcon.Home,
            listOf("dashboard", "spend", "today", "week", "activity", "limits", "start"),
        ),
        SearchPlace(
            "tab:workspaces", L10n.text("common.projects"), L10n.text("android.worksearch.tab.90ddf196"),
            ActionIcon.Reveal,
            listOf("folders", "projects", "chat", "sessions", "repos", "git", "terminal"),
        ),
        SearchPlace(
            "tab:insights", L10n.text("common.insights"), L10n.text("android.worksearch.tab.90ddf196"),
            ActionIcon.Benchmarks,
            listOf("breakdown", "models", "projects", "reports", "charts", "cost"),
        ),
        SearchPlace(
            "tab:devices", L10n.text("common.devices"), L10n.text("android.worksearch.tab.90ddf196"),
            ActionIcon.Device,
            listOf("computers", "laptop", "mac", "linked", "pair", "remote", "servers", "terminal", "keys", "vault", "shell"),
        ),
    )

    private fun devices(
        machineIds: Map<String, String>,
        machinePlatforms: Map<String, String>,
    ): List<SearchPlace> = machineIds.map { (peer, name) ->
        SearchPlace(
            id = "device:$peer",
            title = name,
            detail = L10n.text("android.worksearch.devices_0.163a371d", "${machinePlatforms[peer] ?: L10n.text("android.worksearch.linked_device.a7ba6a12")}"),
            icon = ActionIcon.Device,
            keywords = listOf("machine", "computer", "device"),
        )
    }

    private fun screens(): List<SearchPlace> = listOf(
        SearchPlace(
            "home:editor", L10n.text("android.worksearch.customize_home.642cec6e"), L10n.text("common.home"),
            ActionIcon.Layout,
            listOf("cards", "arrange", "sections", "customise", "edit", "rearrange", "hide"),
        ),
        SearchPlace(
            "workspaces:editor", L10n.text("android.worksearch.customize_projects.00ab91c5"), L10n.text("common.projects"),
            ActionIcon.Layout,
            listOf("folders", "chats", "sessions", "arrange", "sections", "customise", "edit", "rearrange", "hide", "order"),
        ),
        SearchPlace(
            "account:thisDevice", L10n.text("common.settings"), L10n.text("android.worksearch.behind_your_avatar_this_device.41f21261"),
            ActionIcon.Settings,
            listOf("preferences", "options", "config", "setup", "device"),
        ),
        SearchPlace(
            "account:account", L10n.text("common.account"), L10n.text("android.worksearch.behind_your_avatar.f60fd55f"),
            ActionIcon.Account,
            listOf("profile", "handle", L10n.text("android.worksearch.sign_out.601f2951"), L10n.text("android.worksearch.log_out.6a832af4"), "avatar", "relay", "usage"),
        ),
        SearchPlace(
            "account:account:plans", L10n.text("android.worksearch.plan.fa8ed0bd"), L10n.text("common.account"),
            ActionIcon.Plans,
            listOf("plans", "subscription", "billing", "upgrade", "price", "tier", "pro", "renew"),
        ),
        SearchPlace(
            "account:thisDevice:notifications", L10n.text("android.worksearch.notifications.78801183"), L10n.text("android.worksearch.account_this_device.8bb3f277"),
            ActionIcon.Settings,
            listOf("push", "alerts", "notify", "sounds", "badge", "settings"),
        ),
        SearchPlace(
            "account:thisDevice:traffic", L10n.text("android.worksearch.local_traffic.ab770f30"), L10n.text("android.worksearch.account_this_device.8bb3f277"),
            ActionIcon.Connect,
            listOf("network", "connections", "direct", "relayed", "lan", "settings"),
        ),
        SearchPlace(
            "account:legal", L10n.text("android.worksearch.terms_and_privacy.8d60f3a9"), L10n.text("android.worksearch.account_legal.a5b160c5"),
            ActionIcon.Security,
            listOf("legal", "policy", "licence", "license", "conditions"),
        ),
    )

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
