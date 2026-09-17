// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.setup

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Pins the agent readiness rules ported from `Models.swift`: unknown is a
/// real answer, and tapping Sign in needs a willing agent, a handoff, and a
/// host that speaks it.
class SetupAgentTest {
    @Test
    fun readinessSummariesMatchApple() {
        assertEquals("Not installed", AgentReadiness.NOT_INSTALLED.summary())
        assertEquals("Not signed in", AgentReadiness.NEEDS_SIGN_IN.summary())
        assertEquals("Signed in", AgentReadiness.SIGNED_IN.summary())
        assertEquals("Sign-in expired", AgentReadiness.EXPIRED.summary())
        assertEquals("Sign-in not checked", AgentReadiness.UNKNOWN.summary())
    }

    @Test
    fun readinessParsesRawValues() {
        assertEquals(AgentReadiness.NOT_INSTALLED, AgentReadiness.parse("notInstalled"))
        assertEquals(AgentReadiness.NEEDS_SIGN_IN, AgentReadiness.parse("needsSignIn"))
        assertEquals(AgentReadiness.SIGNED_IN, AgentReadiness.parse("signedIn"))
        assertEquals(AgentReadiness.EXPIRED, AgentReadiness.parse("expired"))
    }

    @Test
    fun unknownStatesDecodeAsUnknown() {
        // Missing on a host before protocol 9, or a value from the future:
        // "not checked", never "signed out".
        assertEquals(AgentReadiness.UNKNOWN, AgentReadiness.parse(null))
        assertEquals(AgentReadiness.UNKNOWN, AgentReadiness.parse(""))
        assertEquals(AgentReadiness.UNKNOWN, AgentReadiness.parse("quantum"))
    }

    @Test
    fun agentParsesCatalogEntry() {
        val agent = SetupAgent.of(buildJsonObject {
            put("id", "claude_code")
            put("name", "Claude Code")
            put("installed", true)
            put("readiness", "needsSignIn")
            put("signIn", buildJsonObject { put("supported", true) })
        })
        assertEquals("claude_code", agent?.id)
        assertEquals("Claude Code", agent?.name)
        assertTrue(agent?.installed == true)
        assertEquals(AgentReadiness.NEEDS_SIGN_IN, agent?.readiness)
        assertTrue(agent?.signInSupported == true)
        assertNull(SetupAgent.of(buildJsonObject { put("name", "no id") }))
    }

    @Test
    fun signInNeedsAReasonAHandoffAndAProtocol() {
        val willing = SetupAgent("a", "A", installed = true, AgentReadiness.NEEDS_SIGN_IN, signInSupported = true)
        assertTrue(willing.canSignIn(9L))
        assertTrue(willing.canSignIn(null))
        // A host too old to have been asked fails closed, with the update
        // banner beside it rather than a button that cannot work.
        assertFalse(willing.canSignIn(8L))
        assertFalse(willing.copy(readiness = AgentReadiness.SIGNED_IN).canSignIn(9L))
        assertFalse(willing.copy(readiness = AgentReadiness.UNKNOWN).canSignIn(9L))
        assertFalse(willing.copy(installed = false).canSignIn(9L))
        assertFalse(willing.copy(signInSupported = false).canSignIn(9L))
        assertTrue(willing.copy(readiness = AgentReadiness.EXPIRED).canSignIn(9L))
    }
}
