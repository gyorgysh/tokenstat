// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.logic

import java.time.LocalDate

internal object InsightDayAxis {
    fun position(key: String): Long? = runCatching { LocalDate.parse(key).toEpochDay() }.getOrNull()
}
