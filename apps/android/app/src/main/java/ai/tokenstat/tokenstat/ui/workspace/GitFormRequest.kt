// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.workspace

import ai.tokenstat.tokenstat.ui.localization.L10n
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** A native read can finish after dismissal; it must not update the closed form. */
internal suspend fun gitFormRequest(
    request: suspend (String, JsonObject) -> JsonElement,
    method: String,
    params: JsonObject,
): JsonElement {
    currentCoroutineContext().ensureActive()
    val answer = request(method, params)
    currentCoroutineContext().ensureActive()
    return answer
}

internal fun JsonElement.gitFormObject(): JsonObject = this as? JsonObject
    ?: error(L10n.text("android.workspacecommit.the_request_failed.db4fb447"))
