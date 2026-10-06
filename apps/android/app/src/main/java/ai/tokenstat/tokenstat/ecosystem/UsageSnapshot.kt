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

    companion object {
        fun owner(account: JsonObject): String? {
            if (account["signedIn"]?.jsonPrimitive?.booleanOrNull != true) return null
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
            val days = (calendar["rows"] as JsonArray).flatMap { (it as JsonArray).filterIsInstance<JsonObject>() }
                .map { row ->
                    val raw = row["value"]!!.jsonPrimitive.content.toBigInteger()
                    require(raw.signum() >= 0)
                    UsageDay(row["date"]!!.jsonPrimitive.content,
                        raw.min(Long.MAX_VALUE.toBigInteger()).toLong(), row["locked"]?.jsonPrimitive?.booleanOrNull ?: false)
                }.sortedBy { it.date }.takeLast(35)
            val fetchedAt = calendar["fetchedAtMs"]?.jsonPrimitive?.longOrNull ?: System.currentTimeMillis()
            UsageSnapshot(owner, fetchedAt, days, calendar["noticeCode"]?.jsonPrimitive?.contentOrNull == "stale").takeIf { it.valid }
        }.getOrNull()
    }
}

/** An epoch also distinguishes signing back into the same account. */
data class UsageLease(val owner: String, val epoch: Long)

class UsageSession {
    var epoch = 0L; private set
    private var owner: String? = null
    private var blocked = false

    fun verify(next: String?, observed: Long, fromApp: Boolean): UsageLease? {
        if (observed != epoch || blocked && !fromApp) return null
        if (fromApp) blocked = false
        if (next != owner) { epoch++; owner = next }
        return lease()
    }
    fun clear(block: Boolean = false) { epoch++; owner = null; blocked = block }
    fun lease(): UsageLease? = owner?.let { UsageLease(it, epoch) }
    fun current(lease: UsageLease): Boolean = lease == lease()
}
