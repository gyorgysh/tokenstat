// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

internal fun chatFastModeAvailable(model: String?, models: JsonArray?, backend: String? = null): Boolean {
    if (models == null) return false
    if (backend == "grok") return models.any { (it as? JsonPrimitive)?.content == (model ?: "") }
    if (models.isEmpty()) return true
    if (model == null) return models.any { (it as? JsonPrimitive)?.content == "" }
    val candidate = model.removeSuffix("[1m]")
    return models.any { item ->
        val prefix = (item as? JsonPrimitive)?.content ?: return@any false
        if (candidate == prefix) return@any true
        if (prefix.isEmpty()) return@any false
        if (!candidate.startsWith(prefix)) return@any false
        val suffix = candidate.substring(prefix.length)
        suffix.length == 9 && suffix[0] == '-' && suffix.drop(1).all { it in '0'..'9' }
    }
}

internal fun chatFastModeOn(chat: JsonObject?): Boolean =
    (chat?.get("fastMode") as? JsonPrimitive)?.booleanOrNull == true
