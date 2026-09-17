// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VaultLockCacheTest {
    @Test
    fun snapshotParsesStatus() {
        val snapshot = VaultLockSnapshot.of(buildJsonObject {
            put("created", true)
            put("locked", true)
            put("enrolled", false)
            put("recordCount", 3)
        })
        assertEquals(VaultLockSnapshot(true, true, false, 3), snapshot)
    }

    @Test
    fun missingOrUnreachableStatusStoresNothing() {
        assertNull(VaultLockSnapshot.of(null))
        // An unreachable account is not a vault state: the cache keeps what
        // it knew rather than storing the absence.
        assertNull(
            VaultLockSnapshot.of(buildJsonObject {
                put("created", false)
                put("unreachable", "timeout")
            }),
        )
    }

    @Test
    fun detailMatchesAppleRow() {
        assertEquals("not set up", VaultLockSnapshot(false, false, false, 0).detail(canWrite = true))
        assertEquals("not syncing", VaultLockSnapshot(false, false, false, 0).detail(canWrite = false))
        // No "locked" here: the badge beside it says that.
        assertNull(VaultLockSnapshot(true, true, false, 0).detail(canWrite = true))
        assertEquals("1 record", VaultLockSnapshot(true, false, true, 1).detail(canWrite = true))
        assertEquals("3 records", VaultLockSnapshot(true, false, true, 3).detail(canWrite = true))
        assertEquals(
            "3 records · not syncing",
            VaultLockSnapshot(true, false, true, 3).detail(canWrite = false),
        )
    }
}
