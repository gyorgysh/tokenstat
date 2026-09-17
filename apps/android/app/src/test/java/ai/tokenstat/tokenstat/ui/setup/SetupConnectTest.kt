// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.setup

import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Pins the provisioning rules ported from `ClientSetupModel.swift`: one auth
/// payload, the session params every step shares, and the machine-name offer.
class SetupConnectTest {
    private fun key(id: String = "key_1", ref: String = "android:key_1") = buildJsonObject {
        put("id", id)
        put("label", "laptop")
        put("secretRef", ref)
    }

    @Test
    fun authPayloadNeedsAChoice() {
        assertFailsWith("Choose how to sign in to this server.") {
            setupAuthPayload(SetupCredential.None, "", null, null)
        }
        assertFailsWith("Enter the password for this server.") {
            setupAuthPayload(SetupCredential.Password, "", null, null)
        }
    }

    @Test
    fun authPayloadUsesPasswordOnce() {
        val payload = setupAuthPayload(SetupCredential.Password, "s3cret", null, null)
        assertEquals("password", payload["kind"]?.toString()?.trim('"'))
        assertEquals("s3cret", payload["password"]?.toString()?.trim('"'))
    }

    @Test
    fun authPayloadLoadsKeyMaterial() {
        val payload = setupAuthPayload(SetupCredential.Key("key_1"), "", key(), "PEM")
        assertEquals("privateKey", payload["kind"]?.toString()?.trim('"'))
        assertEquals("PEM", payload["pem"]?.toString()?.trim('"'))
    }

    @Test
    fun authPayloadRejectsMissingKey() {
        assertFailsWith("That key is no longer in your vault.") {
            setupAuthPayload(SetupCredential.Key("key_gone"), "", null, "PEM")
        }
        assertFailsWith("That key has no private material on this device.") {
            setupAuthPayload(SetupCredential.Key("key_1"), "", key(), null)
        }
    }

    @Test
    fun authPayloadSupportsAgentKeys() {
        val payload = setupAuthPayload(
            SetupCredential.Key("key_1"),
            "",
            key(ref = "agent:SHA256:abc"),
            null,
        )
        assertEquals("agent", payload["kind"]?.toString()?.trim('"'))
        assertEquals("SHA256:abc", payload["fingerprint"]?.toString()?.trim('"'))
    }

    @Test
    fun credentialReadyMatchesApple() {
        assertFalse(SetupCredential.None.ready(""))
        assertFalse(SetupCredential.Password.ready(""))
        assertTrue(SetupCredential.Password.ready("x"))
        assertTrue(SetupCredential.Key("key_1").ready(""))
    }

    @Test
    fun sessionParamsCarryHostAndAuth() {
        val params = setupSessionParams(
            buildJsonObject {
                put("hostname", "example.com")
                put("port", 2222)
                put("username", "ada")
                put("initialDirectory", "/srv")
                put("hostKeys", buildJsonArray { })
            },
            buildJsonObject { put("kind", "password") },
            rows = 24,
            cols = 100,
        )
        assertEquals("example.com", params["hostname"]?.toString()?.trim('"'))
        assertEquals("2222", params["port"]?.toString())
        assertEquals("ada", params["username"]?.toString()?.trim('"'))
        assertEquals("24", params["rows"]?.toString())
        assertEquals("password", (params["auth"] as kotlinx.serialization.json.JsonObject)["kind"]?.toString()?.trim('"'))
    }

    @Test
    fun machineNameSuggestionOffersDistro() {
        assertEquals(
            "ubuntu",
            suggestMachineName(buildJsonObject { put("distro", "Ubuntu 24.04") }, "server"),
        )
        assertNull(suggestMachineName(buildJsonObject { put("distro", "Ubuntu") }, "cloud one"))
        assertNull(suggestMachineName(buildJsonObject {}, "server"))
    }

    @Test
    fun availableNameSkipsTakenLabels() {
        assertEquals("server", availableMachineName("server", emptySet()))
        assertEquals("server-2", availableMachineName("server", setOf("server")))
        assertEquals("cloud one", availableMachineName("  cloud one  ", setOf("server")))
        assertEquals("server", availableMachineName("   ", emptySet()))
    }

    @Test
    fun provisionInfoReadsFacts() {
        val info = SetupProvisionInfo.of(buildJsonObject {
            put("account", buildJsonObject { put("handle", "ada") })
            put("runsAs", buildJsonObject { put("name", "root") })
            put("alwaysOn", true)
            put("tunnel", buildJsonObject { put("online", false) })
            put("allowedDevices", 2)
            put("agents", buildJsonArray {
                add(buildJsonObject { put("installed", false) })
            })
            put("protocolVersion", "21")
        })
        assertEquals("ada", info.signedInHandle)
        assertTrue(info.alwaysOn)
        assertFalse(info.tunnelOnline)
        assertEquals("root", info.runsAs)
        assertEquals(2, info.allowedDevices)
        assertFalse(info.anyAgentInstalled)
        assertEquals(21L, info.protocol)
    }

    @Test
    fun recoveryBuildsTheStack() {
        assertEquals(listOf(SetupStep.WHERE), recoverSetupPath(SetupAction.CHECK_ADDRESS))
        assertEquals(
            listOf(SetupStep.WHERE, SetupStep.CREDENTIAL),
            recoverSetupPath(SetupAction.CHECK_CREDENTIAL),
        )
        assertEquals(
            listOf(SetupStep.WHERE, SetupStep.CREDENTIAL, SetupStep.CHECK, SetupStep.INSTALL),
            recoverSetupPath(SetupAction.NEW_CODE),
        )
        assertEquals(
            listOf(
                SetupStep.WHERE, SetupStep.CREDENTIAL, SetupStep.CHECK,
                SetupStep.INSTALL, SetupStep.FINISH,
            ),
            recoverSetupPath(SetupAction.CHECK_SERVER),
        )
        assertEquals(
            listOf(
                SetupStep.WHERE, SetupStep.CREDENTIAL, SetupStep.CHECK,
                SetupStep.INSTALL, SetupStep.FINISH, SetupStep.AGENT,
            ),
            recoverSetupPath(SetupAction.SIGN_IN_AGENT),
        )
        assertEquals(SetupStep.AGENT, SetupAction.SIGN_IN_AGENT.step())
        assertNull(recoverSetupPath(SetupAction.RETRY))
        assertNull(recoverSetupPath(SetupAction.SIGN_IN_ACCOUNT))
    }

    private fun assertFailsWith(message: String, body: () -> Unit) {
        try {
            body()
        } catch (e: SetupAuthMissing) {
            assertEquals(message, e.message)
            return
        }
        throw AssertionError("expected SetupAuthMissing($message)")
    }
}
