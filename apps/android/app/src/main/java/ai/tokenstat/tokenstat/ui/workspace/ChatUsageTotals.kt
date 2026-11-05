// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import java.math.BigInteger
import kotlinx.serialization.json.*

/** Whole-conversation totals from the host, with only subsequently accepted tail events added. */
internal data class ChatUsageTotals(
    val input: BigInteger,
    val output: BigInteger,
    val cacheRead: BigInteger,
    val cacheWrite: BigInteger,
    val cost: Double,
) {
    val isEmpty: Boolean get() = input.signum() == 0 && output.signum() == 0 && cacheRead.signum() == 0 && cacheWrite.signum() == 0 && cost == 0.0

    fun adding(other: ChatUsageTotals): ChatUsageTotals? {
        val counts = listOf(input + other.input, output + other.output, cacheRead + other.cacheRead, cacheWrite + other.cacheWrite)
        val nextCost = cost + other.cost
        if (counts.any { it > maximum } || !nextCost.isFinite()) return null
        return ChatUsageTotals(counts[0], counts[1], counts[2], counts[3], nextCost)
    }

    fun tail(rows: List<JsonObject>): ChatUsageTotals? {
        var total = this
        for (row in rows) {
            // A new summary can overlap previously counted events. Ask the host
            // for verified totals instead of adding an ambiguous segment twice.
            when (row.str("kind")) { "retainedUsage", "teamAgentSegment" -> return null }
            val event = row["event"] as? JsonObject ?: continue
            if (event.str("kind") != "usage") continue
            total = total.adding(decode(event, event = true) ?: return null) ?: return null
        }
        return total
    }

    companion object {
        private val maximum = BigInteger.ONE.shiftLeft(64) - BigInteger.ONE
        fun decode(value: JsonObject?, event: Boolean = false): ChatUsageTotals? {
            value ?: return null
            fun count(vararg keys: String): BigInteger? {
                val key = keys.firstOrNull { it in value }
                if (key == null) return if (event) BigInteger.ZERO else null
                val raw = value[key] as? JsonPrimitive ?: return null
                if (event && raw is JsonNull) return BigInteger.ZERO
                if (raw.isString) return null
                return raw.content.toBigIntegerOrNull()?.takeIf { it.signum() >= 0 && it <= maximum }
            }
            val input = count("input") ?: return null
            val output = count("output") ?: return null
            val read = count("cacheRead", "cache_read") ?: return null
            val write = count("cacheWrite", "cache_write") ?: return null
            val costKey = if (event) listOf("costUsd", "cost_usd").firstOrNull { it in value } else "cost"
            val rawCost = costKey?.let { value[it] }
            val cost = if (event && (rawCost == null || rawCost is JsonNull)) 0.0
                else (rawCost as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull ?: return null
            if (!cost.isFinite() || cost < 0) return null
            return ChatUsageTotals(input, output, read, write, cost)
        }
    }
}
