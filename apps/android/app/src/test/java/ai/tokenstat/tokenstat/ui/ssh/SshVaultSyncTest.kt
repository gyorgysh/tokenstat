// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.ssh

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SshVaultSyncTest {
    // vaultVerdict — port of the merge rule in SSHLibraryModel: newer wins,
    // missing loses, equal stamps tie.
    @Test fun verdictTakesMissingAndNewer() {
        assertEquals(VaultVerdict.TAKE_REMOTE, vaultVerdict(10L, null))
        assertEquals(VaultVerdict.TAKE_REMOTE, vaultVerdict(10L, 5L))
        assertEquals(VaultVerdict.PUSH_LOCAL, vaultVerdict(5L, 10L))
        assertEquals(VaultVerdict.SAME, vaultVerdict(10L, 10L))
        // Unstamped rows read as 0 and tie with each other.
        assertEquals(VaultVerdict.SAME, vaultVerdict(0L, 0L))
    }

    // vaultEnvelopeOf — tombstones and undecodable rows decode to null so
    // the pull walks past them instead of dying on them.
    @Test fun envelopeSkipsTombstonesAndGarbage() {
        val tombstone = buildJsonObject { put("id", "host:a"); put("deleted", true) }
        assertNull(vaultEnvelopeOf(tombstone))
        val garbage = buildJsonObject { put("id", "host:b"); put("plaintext", "not json") }
        assertNull(vaultEnvelopeOf(garbage))
        val good = buildJsonObject {
            put("id", "host:c")
            put("plaintext", """{"kind":"host","host":{"id":"c"}}""")
        }
        assertEquals("host", vaultEnvelopeOf(good)?.get("kind").toString().trim('"'))
    }

    // orderVaultRecords — folders first, each after its own parent, then the
    // rest in arrival order; orphans go out last rather than never.
    @Test fun ordersFoldersBeforeHosts() {
        fun record(id: String, folderId: String? = null, parentId: String? = null) = buildJsonObject {
            put("id", id)
            val folder = if (folderId == null) {
                null
            } else {
                buildJsonObject {
                    put("id", folderId)
                    if (parentId != null) put("parentId", parentId)
                }
            }
            val envelope = buildJsonObject {
                if (folder == null) put("kind", "host") else {
                    put("kind", "folder")
                    put("folder", folder)
                }
            }
            put("plaintext", envelope.toString())
        }
        val host = record("host:h")
        val child = record("folder:child", folderId = "child", parentId = "parent")
        val parent = record("folder:parent", folderId = "parent")
        val ordered = orderVaultRecords(listOf(host, child, parent), emptySet()).mapNotNull {
            it["id"].toString().trim('"')
        }
        assertEquals(listOf("folder:parent", "folder:child", "host:h"), ordered)
    }

    @Test fun orphanFolderStillGoesOut() {
        val orphan = buildJsonObject {
            put("id", "folder:orphan")
            put("plaintext", """{"kind":"folder","folder":{"id":"orphan","parentId":"missing"}}""")
        }
        val ordered = orderVaultRecords(listOf(orphan), emptySet())
        assertEquals(1, ordered.size)
    }
}
