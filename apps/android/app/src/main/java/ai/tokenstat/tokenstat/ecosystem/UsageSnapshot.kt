// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ecosystem

import java.security.MessageDigest
import java.time.LocalDate
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable
data class UsageDay(val date: String, val value: Long, val locked: Boolean)

@Serializable
data class UsageSnapshot(
    val owner: String,
    val updatedAt: Long? = null,
    val days: List<UsageDay> = emptyList(),
    val refreshFailed: Boolean = false,
    val limits: List<QuotaProvider> = emptyList(),
) {
    fun value(week: Boolean, today: LocalDate = LocalDate.now()): Long? {
        val wanted = if (week) (6 downTo 0).map { today.minusDays(it.toLong()).toString() }
            else listOf(today.toString())
        val rows = wanted.map { date -> days.singleOrNull { it.date == date && !it.locked } ?: return null }
        return rows.fold(0L) { total, day -> if (Long.MAX_VALUE - total < day.value) Long.MAX_VALUE else total + day.value }
    }

    val valid: Boolean get() = owner.matches(Regex("[a-f0-9]{64}")) && days.size <= 35
        && days.map { it.date }.distinct().size == days.size
        && days.all { it.value >= 0 && runCatching { LocalDate.parse(it.date) }.isSuccess }
        && (updatedAt == null || updatedAt in 0..(System.currentTimeMillis() + 300_000))
        && limits.size <= 32 && limits.map { it.source }.distinct().size == limits.size && limits.all { it.valid }

    companion object {
        fun owner(account: JsonObject): String? {
            if ((account["signedIn"] as? JsonPrimitive)?.booleanOrNull != true) return null
            val host = (account["host"] as? JsonPrimitive)?.contentOrNull ?: return null
            val identity = (account["accountId"] as? JsonPrimitive)?.contentOrNull
                ?: (account["handle"] as? JsonPrimitive)?.contentOrNull ?: return null
            if (host.isBlank() || identity.isBlank()) return null
            // Length delimiters avoid ambiguous identities, and the widget
            // never stores an account name, URL, credential or workspace path.
            return MessageDigest.getInstance("SHA-256").digest("${host.length}:$host${identity.length}:$identity".toByteArray())
                .joinToString("") { "%02x".format(it.toInt() and 255) }
        }

        fun calendar(owner: String, calendar: JsonObject): UsageSnapshot? = runCatching {
            // This widget promises all-device usage, never silently local data.
            require(calendar["scope"]?.jsonPrimitive?.content == "account")
            val days = (calendar["rows"] as JsonArray).flatMap { (it as JsonArray).filter { cell -> cell !is JsonNull } }
                .map { row ->
                    val cell = row as JsonObject
                    val raw = cell["value"]!!.jsonPrimitive.content.toBigInteger()
                    require(raw.signum() >= 0)
                    val locked = if ("locked" in cell) cell["locked"]!!.jsonPrimitive.booleanOrNull ?: error("Invalid lock state") else false
                    UsageDay(cell["date"]!!.jsonPrimitive.content, raw.min(Long.MAX_VALUE.toBigInteger()).toLong(), locked)
                }
            require(days.map { it.date }.distinct().size == days.size)
            require(days.all { LocalDate.parse(it.date).toString() == it.date })
            // Missing cache age must never turn a remembered grid into a fresh fetch.
            val fetchedAt = calendar["fetchedAtMs"]?.jsonPrimitive?.longOrNull ?: return null
            UsageSnapshot(owner, fetchedAt, days.sortedBy { it.date }.takeLast(35), calendar["noticeCode"]?.jsonPrimitive?.contentOrNull == "stale").takeIf { it.valid }
        }.getOrNull()
    }
}

/** An epoch also distinguishes signing back into the same account. */
data class UsageLease(val owner: String, val epoch: Long)

class UsageSession {
    var epoch = 0L; private set
    private var owner: String? = null
    private var blocked = false
    private var verified = false

    fun verify(next: String?, observed: Long, fromApp: Boolean): UsageLease? {
        if (observed != epoch || blocked && !fromApp) return null
        if (fromApp) blocked = false
        verified = true
        if (next != owner) { epoch++; owner = next }
        return lease()
    }
    fun clear(block: Boolean = false) { epoch++; owner = null; blocked = block; verified = true }
    fun acceptsCachedOwner(owner: String): Boolean = !blocked && (!verified || this.owner == owner)
    fun lease(): UsageLease? = owner?.let { UsageLease(it, epoch) }
    fun current(lease: UsageLease): Boolean = lease == lease()
}

/** A dated provider observation, never a prediction of what a reset will contain. */
@Serializable
data class QuotaWindow(val label: String, val percent: Double, val resetsAt: Long? = null, val scope: String? = null) {
    val id: String get() = "$label|${scope.orEmpty()}"
    val displayLabel: String get() = scope?.let { "$label ($it)" } ?: label
    val kind: QuotaWindowSelection get() {
        val normalized = label.lowercase(java.util.Locale.ROOT).replace('-', ' ').trim()
        return when {
            normalized == "5h" || normalized == "5 hour" || normalized.endsWith("· 5 hour") -> QuotaWindowSelection.FIVE_HOUR
            normalized == "weekly" || normalized == "7d" || normalized.endsWith("· weekly") -> QuotaWindowSelection.WEEKLY
            else -> QuotaWindowSelection.HIGHEST
        }
    }
    val compactLabel: String get() {
        val period = when (kind) { QuotaWindowSelection.FIVE_HOUR -> "5h"; QuotaWindowSelection.WEEKLY -> "7d"; else -> return label }
        val detail = scope ?: label.substringBeforeLast(" · ", "").takeIf { it.isNotBlank() }
        return if (detail.isNullOrBlank() || detail.lowercase(java.util.Locale.ROOT) in listOf("general", "primary")) period else "$period · $detail"
    }
    val fraction: Float get() = (percent / 100).coerceIn(0.0, 1.0).toFloat()
    fun expired(now: Long) = resetsAt?.let { it <= now } == true
    val valid: Boolean get() = label.isNotBlank() && label.toByteArray().size <= 160 && percent.isFinite() && percent in 0.0..10_000.0
        && (scope == null || scope.toByteArray().size <= 80) && (resetsAt == null || resetsAt > 0)
}

enum class QuotaWindowSelection(val key: String) {
    HIGHEST("highest"), FIVE_HOUR("fiveHour"), WEEKLY("weekly"), BOTH("both"), ALL("all");
    fun windows(provider: QuotaProvider, now: Long): List<QuotaWindow> {
        fun best(candidates: List<QuotaWindow>): QuotaWindow? {
            val primary = candidates.filter { it.scope?.lowercase(java.util.Locale.ROOT) in listOf("general", "primary") }.ifEmpty { candidates }
            return primary.filterNot { it.expired(now) }.ifEmpty { primary }.maxByOrNull { it.percent }
        }
        return when (this) {
            HIGHEST -> listOfNotNull(provider.peak(now) ?: provider.windows.firstOrNull())
            FIVE_HOUR, WEEKLY -> listOfNotNull(best(provider.windows.filter { it.kind == this }))
            BOTH -> FIVE_HOUR.windows(provider, now) + WEEKLY.windows(provider, now)
            ALL -> provider.windows.sortedWith(compareBy<QuotaWindow> { it.expired(now) }.thenByDescending { it.percent })
        }
    }
    companion object { fun fromKey(key: String?) = entries.firstOrNull { it.key == key } ?: HIGHEST }
}
@Serializable
data class QuotaProvider(val source: String, val observedAt: Long, val windows: List<QuotaWindow>, val stale: Boolean = false) {
    val name: String get() = when (source) {
        "claude_code" -> "Claude"; "codex" -> "Codex"; "cursor" -> "Cursor"; "grok" -> "Grok"; "antigravity" -> "Antigravity"; "opencode" -> "OpenCode"
        else -> source.replace('_', ' ').replace('-', ' ').replaceFirstChar { it.uppercaseChar() }
    }
    fun stale(now: Long) = stale || now - observedAt > 15 * 60_000 || observedAt > now + 300_000
    fun peak(now: Long): QuotaWindow? = windows.filter { !it.expired(now) }.maxByOrNull { it.percent }
    val valid: Boolean get() = source.matches(Regex("[a-z0-9_-]{1,64}")) && observedAt > 0
        && windows.size <= 8 && windows.all { it.valid } && windows.map { it.id }.distinct().size == windows.size
    companion object {
        fun parse(value: JsonElement): List<QuotaProvider>? = runCatching {
            val providers = value as JsonArray
            require(providers.size <= 32)
            providers.mapNotNull { element ->
                val provider = element as JsonObject
                val source = provider["source"]!!.jsonPrimitive.content
                require(source.matches(Regex("[a-z0-9_-]{1,64}")))
                val observed = (provider["observedAtMs"] ?: provider["observed_at_ms"])!!.jsonPrimitive.long
                val windows = provider["windows"] as JsonArray
                // The host includes unavailable providers with an explicit zero date.
                // They must not discard usable readings from the other providers.
                if (observed == 0L && windows.isEmpty()) return@mapNotNull null
                QuotaProvider(source, observed,
                    windows.map { element ->
                        val window = element as JsonObject
                        QuotaWindow(window["label"]!!.jsonPrimitive.content, window["percent"]!!.jsonPrimitive.double,
                            window["resetsAtMs"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.long,
                            window["scope"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content)
                    }, provider["stale"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.boolean ?: false)
            }.also { readings -> require(readings.all { it.valid } && readings.map { it.source }.distinct().size == readings.size) }
        }.getOrNull()
    }
}
