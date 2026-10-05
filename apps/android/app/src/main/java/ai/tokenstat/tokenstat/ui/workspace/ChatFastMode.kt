// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

internal fun chatFastModeAvailable(model: String?, models: JsonArray?): Boolean {
    if (models == null) return false
    if (models.isEmpty()) return true
    if (model == null) return false
    return models.any { item ->
        val prefix = (item as? JsonPrimitive)?.content ?: return@any false
        if (model == prefix) return@any true
        if (!model.startsWith(prefix)) return@any false
        val suffix = model.substring(prefix.length)
        suffix.startsWith('[') || (suffix.length == 9 && suffix[0] == '-' && suffix.drop(1).all { it in '0'..'9' })
    }
}

internal fun chatFastModeOn(chat: JsonObject?): Boolean =
    (chat?.get("fastMode") as? JsonPrimitive)?.booleanOrNull == true
