// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
package ai.tokenstat.tokenstat.ui.setup

import ai.tokenstat.tokenstat.core.CoreFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Pins the setup journey rules ported from `ClientSetupState.swift`: the
/// identity check, milestone words, and code-based failure mapping.
class SetupStateTest {

    @Test
    fun identityNormalizesHex() {
        val key = "AB12".repeat(16)
        assertEquals("ab12".repeat(16), SetupIdentity.normalize("  $key\n"))
        assertNull(SetupIdentity.normalize("short"))
        assertNull(SetupIdentity.normalize("zz".repeat(32)))
        assertNull(SetupIdentity.normalize(""))
    }

    @Test
    fun identityMatchesAcrossCase() {
        val lower = "ab12".repeat(16)
        assertTrue(SetupIdentity.matches(lower, "AB12".repeat(16)))
        assertFalse(SetupIdentity.matches(lower, "cd34".repeat(16)))
        assertFalse(SetupIdentity.matches("short", lower))
    }

    @Test
    fun accountIdentityPrefersHandle() {
        assertEquals("ada", SetupIdentity.accountIdentity(" ada ", "id-1"))
        assertEquals("id-1", SetupIdentity.accountIdentity("  ", "id-1"))
        assertEquals("", SetupIdentity.accountIdentity(null, null))
    }

    @Test
    fun milestoneSummariesMatchApple() {
        assertEquals(
            "Its fingerprint is verified. Setup carries on from your sign-in details.",
            SetupMilestone.TRUSTED.summary(),
        )
        assertEquals("It is checked and ready to install.", SetupMilestone.CHECKED.summary())
        assertEquals(
            "The installer was started. Setup asks the server what actually happened before it does anything again.",
            SetupMilestone.INSTALL_REQUESTED.summary(),
        )
        assertEquals(
            "The server is installed. Setup is waiting for it to reach your account.",
            SetupMilestone.VERIFYING.summary(),
        )
        assertEquals("The server answered. One last check finishes this.", SetupMilestone.HOST_READY.summary())
    }

    @Test
    fun failureMapsFromCodes() {
        val unreachable = SetupFailure.from(CoreFailure("ssh_unreachable", "dial timeout"))
        assertEquals(SetupAction.CHECK_ADDRESS, unreachable.action)
        assertEquals(SetupStep.WHERE, unreachable.action.step())
        assertTrue(unreachable.explanation.contains("Check its address"))
        assertEquals("dial timeout", unreachable.details)

        val changed = SetupFailure.from(CoreFailure("ssh_host_key_changed", "key differs"))
        assertEquals(SetupAction.REVIEW_FINGERPRINT, changed.action)
        assertEquals("Nothing was sent to it.", changed.changed)

        val expired = SetupFailure.from(CoreFailure("pairing_expired", "gone"))
        assertEquals(SetupAction.NEW_CODE, expired.action)
        assertEquals(SetupStep.INSTALL, expired.action.step())

        val signedOut = SetupFailure.from(CoreFailure("signed_out", "bye"))
        assertEquals(SetupAction.SIGN_IN_ACCOUNT, signedOut.action)
        assertNull(signedOut.action.step())

        val old = SetupFailure.from(CoreFailure("unknown_method", "nope"))
        assertEquals(SetupAction.UPDATE_MACHINE, old.action)
    }

    @Test
    fun failureFallsBackOnWords() {
        val helper = SetupFailure.from(CoreFailure("weird", "Unknown method: x"))
        assertEquals(SetupAction.UPDATE_MACHINE, helper.action)
        val login = SetupFailure.from(CoreFailure("weird", "not logged in"))
        assertEquals(SetupAction.SIGN_IN_ACCOUNT, login.action)
        val other = SetupFailure.from(CoreFailure("weird", "mystery"))
        assertEquals(SetupAction.RETRY, other.action)
        assertNull(other.action.step())
        assertEquals("mystery", other.explanation)
    }

    @Test
    fun nonCoreErrorsStayReadable() {
        val failure = SetupFailure.from(RuntimeException("boom"))
        assertEquals("boom", failure.explanation)
        assertEquals(SetupAction.RETRY, failure.action)
        assertEquals("boom", SetupFailure.readable(RuntimeException("boom")))
    }

    @Test
    fun actionTitlesMatchApple() {
        assertEquals("Check the address", SetupAction.CHECK_ADDRESS.title())
        assertEquals("Review the fingerprint", SetupAction.REVIEW_FINGERPRINT.title())
        assertEquals("Check the credential", SetupAction.CHECK_CREDENTIAL.title())
        assertEquals("Check the server", SetupAction.CHECK_SERVER.title())
        assertEquals("Get a new code", SetupAction.NEW_CODE.title())
        assertEquals("Sign in", SetupAction.SIGN_IN_AGENT.title())
        assertEquals("How to update", SetupAction.UPDATE_MACHINE.title())
        assertEquals("Try again", SetupAction.RETRY.title())
    }

    @Test
    fun firstTaskReadsWithoutChanging() {
        assertEquals(
            "Give me a short tour of this project: what it does, how it is laid out, and where you would start.",
            SETUP_FIRST_TASK,
        )
    }
}
